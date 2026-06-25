import json

import boto3

from handlers import delete_account

TABLE = "MangoTest"
BUCKET = "mango-test-bucket"


def _event(method="DELETE", user="u-1"):
    return {
        "requestContext": {"http": {"method": method}},
        "headers": {"x-mango-user": user},
        "body": None,
    }


def _seed_user(uid: str):
    table = boto3.resource("dynamodb", region_name="us-east-1").Table(TABLE)
    table.put_item(Item={"PK": f"USER#{uid}", "SK": "PROFILE", "name": "Ada"})
    table.put_item(Item={"PK": f"USER#{uid}", "SK": "PROGRESS", "totalXP": 100})
    table.put_item(Item={"PK": f"USER#{uid}", "SK": "BOOK#bk_1", "addedAt": "x"})
    table.put_item(
        Item={"PK": f"USER#{uid}", "SK": "REFLECTION#2026-06-01T00:00:00+00:00", "text": "hi"}
    )
    s3 = boto3.client("s3", region_name="us-east-1")
    s3.put_object(Bucket=BUCKET, Key=f"users/{uid}/journal/r1.json", Body=b"{}")
    s3.put_object(Bucket=BUCKET, Key=f"users/{uid}/journal/r2.json", Body=b"{}")


def _user_items(uid: str):
    from boto3.dynamodb.conditions import Key

    table = boto3.resource("dynamodb", region_name="us-east-1").Table(TABLE)
    return table.query(KeyConditionExpression=Key("PK").eq(f"USER#{uid}")).get("Items", [])


def _user_objects(uid: str):
    s3 = boto3.client("s3", region_name="us-east-1")
    return s3.list_objects_v2(Bucket=BUCKET, Prefix=f"users/{uid}/").get("Contents", [])


def test_delete_cascade_removes_items_and_objects(aws):
    _seed_user("u-1")
    assert len(_user_items("u-1")) == 4
    assert len(_user_objects("u-1")) == 2

    resp = delete_account.handler(_event(), None)
    assert resp["statusCode"] == 200
    body = json.loads(resp["body"])
    assert body["deleted"] is True
    assert body["itemsDeleted"] == 4
    assert body["objectsDeleted"] == 2

    assert _user_items("u-1") == []
    assert _user_objects("u-1") == []


def test_delete_only_targets_caller(aws):
    _seed_user("u-1")
    _seed_user("u-2")

    delete_account.handler(_event(user="u-1"), None)

    # The other user's data is untouched.
    assert len(_user_items("u-2")) == 4
    assert len(_user_objects("u-2")) == 2


def test_delete_when_no_data_is_noop(aws):
    resp = delete_account.handler(_event(user="ghost"), None)
    assert resp["statusCode"] == 200
    body = json.loads(resp["body"])
    assert body["itemsDeleted"] == 0
    assert body["objectsDeleted"] == 0
