import boto3
import pytest
from moto import mock_aws

TABLE = "MangoTest"
BUCKET = "mango-test-bucket"


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    monkeypatch.setenv("TABLE_NAME", TABLE)
    monkeypatch.setenv("BUCKET_NAME", BUCKET)
    monkeypatch.setenv("BEDROCK_MODEL_ID", "anthropic.claude-test")
    monkeypatch.setenv("AI_MAX_EFFORT", "false")
    monkeypatch.setenv("STAGE", "test")
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")


@pytest.fixture
def aws():
    with mock_aws():
        ddb = boto3.client("dynamodb", region_name="us-east-1")
        ddb.create_table(
            TableName=TABLE,
            KeySchema=[
                {"AttributeName": "PK", "KeyType": "HASH"},
                {"AttributeName": "SK", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "PK", "AttributeType": "S"},
                {"AttributeName": "SK", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )
        boto3.client("s3", region_name="us-east-1").create_bucket(Bucket=BUCKET)
        yield
