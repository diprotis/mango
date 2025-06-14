#!/usr/bin/env python3
import aws_cdk as cdk
from aws_cdk import Stack, aws_s3 as s3, aws_lambda as lambda_
import os


class SimpleStack(Stack):
    def __init__(self, scope, construct_id, **kwargs):
        super().__init__(scope, construct_id, **kwargs)
        
        # Create a simple S3 bucket
        bucket = s3.Bucket(
            self,
            "MyTestBucket",
            bucket_name=f"my-test-bucket-{self.account}-{self.region}",
            removal_policy=cdk.RemovalPolicy.DESTROY,
            auto_delete_objects=True
        )
        
        # Create a simple Lambda function
        hello_lambda = lambda_.Function(
            self,
            "HelloWorldFunction",
            runtime=lambda_.Runtime.PYTHON_3_10,
            code=lambda_.Code.from_asset("../src/lambdas/hello_world"),
            handler="index.handler"
        )
        
        # Grant Lambda permission to read from bucket
        bucket.grant_read(hello_lambda)


app = cdk.App()
SimpleStack(app, "SimpleStack", env=cdk.Environment(
    account=os.environ.get("CDK_DEFAULT_ACCOUNT"),
    region=os.environ.get("CDK_DEFAULT_REGION", "us-east-1")
))
app.synth()
