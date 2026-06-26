"""Self-contained fixtures for the moto-backed end-to-end journey.

Deliberately mirrors ``backend/tests/conftest.py`` (same table schema + bucket) so
this suite stands on its own and can run in isolation (``pytest tests_integration``)
without depending on the unit conftest. The single-table key schema and the GSI1
index match ``DataStack`` so the library/reflection queries behave like prod.
"""

import boto3
import pytest
from moto import mock_aws

TABLE = "MangoE2E"
BUCKET = "mango-e2e-bucket"
REGION = "us-east-1"


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    # STAGE=test makes shared.response.user_id honor the x-mango-user header,
    # so each simulated request carries an identity exactly like a JWT sub would.
    monkeypatch.setenv("TABLE_NAME", TABLE)
    monkeypatch.setenv("BUCKET_NAME", BUCKET)
    monkeypatch.setenv("BEDROCK_MODEL_ID", "anthropic.claude-test")
    monkeypatch.setenv("AI_MAX_EFFORT", "false")
    monkeypatch.setenv("STAGE", "test")
    monkeypatch.setenv("AWS_DEFAULT_REGION", REGION)
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")


@pytest.fixture
def aws():
    """A moto-mocked DynamoDB single table (PK/SK + GSI1) and S3 bucket."""
    with mock_aws():
        ddb = boto3.client("dynamodb", region_name=REGION)
        ddb.create_table(
            TableName=TABLE,
            KeySchema=[
                {"AttributeName": "PK", "KeyType": "HASH"},
                {"AttributeName": "SK", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "PK", "AttributeType": "S"},
                {"AttributeName": "SK", "AttributeType": "S"},
                {"AttributeName": "GSI1PK", "AttributeType": "S"},
                {"AttributeName": "GSI1SK", "AttributeType": "S"},
            ],
            GlobalSecondaryIndexes=[
                {
                    "IndexName": "GSI1",
                    "KeySchema": [
                        {"AttributeName": "GSI1PK", "KeyType": "HASH"},
                        {"AttributeName": "GSI1SK", "KeyType": "RANGE"},
                    ],
                    "Projection": {"ProjectionType": "ALL"},
                }
            ],
            BillingMode="PAY_PER_REQUEST",
        )
        boto3.client("s3", region_name=REGION).create_bucket(Bucket=BUCKET)
        yield
