"""DynamoDB + S3 access. boto3 is provided by the Lambda runtime."""

import os

import boto3


def table():
    return boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])


def s3_client():
    return boto3.client("s3")


def bucket_name() -> str:
    return os.environ["BUCKET_NAME"]
