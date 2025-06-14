#!/usr/bin/env python3
import aws_cdk as cdk
from aws_cdk import Stack, aws_s3 as s3, aws_lambda as lambda_
import os
import json


def load_config(stage: str) -> dict:
    """Load configuration for the given stage."""
    config_file = f"config/{stage}.json"
    try:
        with open(config_file, "r") as f:
            return json.load(f)
    except FileNotFoundError:
        # Default config if file not found
        return {
            "environment": stage,
            "stackNamePrefix": f"ReadingJourney-{stage.title()}",
            "region": "us-east-1",
        }


class SimpleStack(Stack):
    def __init__(self, scope, construct_id, config: dict, **kwargs):
        super().__init__(scope, construct_id, **kwargs)

        env_name = config["environment"]

        # Create a simple S3 bucket with environment-specific naming
        bucket = s3.Bucket(
            self,
            "MyTestBucket",
            bucket_name=f"my-test-bucket-{env_name}-{self.account}-{self.region}",
            removal_policy=cdk.RemovalPolicy.DESTROY,
            auto_delete_objects=True,
        )

        # Create a simple Lambda function
        hello_lambda = lambda_.Function(
            self,
            "HelloWorldFunction",
            runtime=lambda_.Runtime.PYTHON_3_10,
            code=lambda_.Code.from_asset("src/lambdas/hello_world"),
            handler="index.handler",
        )

        # Grant Lambda permission to read from bucket
        bucket.grant_read(hello_lambda)


app = cdk.App()

# Get stage from context (defaults to 'dev' for local development)
stage = app.node.try_get_context("stage") or "dev"

# Load configuration for the stage
config = load_config(stage)

# Create the stack with environment-specific naming
stack_name = f"{config['stackNamePrefix']}-SimpleStack"

SimpleStack(
    app,
    stack_name,
    config,
    env=cdk.Environment(
        account=os.environ.get("CDK_DEFAULT_ACCOUNT"),
        region=config.get("region", "us-east-1"),
    ),
)

app.synth()
