"""DELETE /v1/me — erase all server-side data for the caller.

Removes every single-table item under PK=``USER#<sub>`` and every S3 object under
the ``users/<sub>/`` prefix, then best-effort deletes the Cognito user (admin
API, when ``COGNITO_USER_POOL_ID`` is set), and returns a summary count.
"""

import os

import boto3
from boto3.dynamodb.conditions import Key

from shared.response import http_method, json_response, ok, user_id
from shared.storage import bucket_name, s3_client, table


def _delete_table_items(uid: str) -> int:
    """Query all items for the user (paginated) and batch-delete them."""
    tbl = table()
    deleted = 0
    last_key = None
    while True:
        kwargs = {
            "KeyConditionExpression": Key("PK").eq(f"USER#{uid}"),
            "ProjectionExpression": "PK, SK",
        }
        if last_key:
            kwargs["ExclusiveStartKey"] = last_key
        resp = tbl.query(**kwargs)
        items = resp.get("Items", [])
        if items:
            with tbl.batch_writer() as batch:
                for it in items:
                    batch.delete_item(Key={"PK": it["PK"], "SK": it["SK"]})
                    deleted += 1
        last_key = resp.get("LastEvaluatedKey")
        if not last_key:
            break
    return deleted


def _delete_s3_objects(uid: str) -> int:
    """List + delete all objects under users/<uid>/ (paginated, 1000 per call)."""
    client = s3_client()
    bucket = bucket_name()
    prefix = f"users/{uid}/"
    deleted = 0
    token = None
    while True:
        list_kwargs = {"Bucket": bucket, "Prefix": prefix}
        if token:
            list_kwargs["ContinuationToken"] = token
        resp = client.list_objects_v2(**list_kwargs)
        keys = [{"Key": obj["Key"]} for obj in resp.get("Contents", [])]
        if keys:
            client.delete_objects(Bucket=bucket, Delete={"Objects": keys})
            deleted += len(keys)
        if resp.get("IsTruncated"):
            token = resp.get("NextContinuationToken")
        else:
            break
    return deleted


def _delete_cognito_user(uid: str) -> bool:
    """Best-effort delete the Cognito user via the admin API. No-op when the pool
    isn't configured (local/test). Cognito admin APIs accept the user's ``sub`` as
    ``Username``. Never raises — the data deletion above is the hard contract.
    """
    pool = os.environ.get("COGNITO_USER_POOL_ID")
    if not pool:
        return False
    try:
        boto3.client("cognito-idp").admin_delete_user(UserPoolId=pool, Username=uid)
        return True
    except Exception:
        return False


def handler(event, context):
    try:
        uid = user_id(event)
    except PermissionError:
        return json_response(401, {"error": "unauthorized"})

    if http_method(event) != "DELETE":
        return json_response(405, {"error": "method not allowed"})

    items_deleted = _delete_table_items(uid)
    objects_deleted = _delete_s3_objects(uid)
    cognito_deleted = _delete_cognito_user(uid)

    return ok(
        {
            "deleted": True,
            "itemsDeleted": items_deleted,
            "objectsDeleted": objects_deleted,
            "cognitoDeleted": cognito_deleted,
        }
    )
