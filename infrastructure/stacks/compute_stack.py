from aws_cdk import (
    Stack,
    aws_lambda as lambda_,
    aws_iam as iam,
    aws_logs as logs,
    CfnOutput,
    Duration,
    RemovalPolicy
)
from constructs import Construct
from aws_cdk.aws_ec2 import IVpc
from aws_cdk.aws_s3 import IBucket
from pathlib import Path


class ComputeStack(Stack):
    """Compute infrastructure stack including Lambda functions."""
    
    def __init__(self, scope: Construct, construct_id: str, config: dict, vpc: IVpc, bucket: IBucket, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)
        
        self.config = config
        self.stage = config["environment"]
        self.vpc = vpc
        self.test_bucket = bucket
        
        # Create Lambda functions
        self.s3_reader_lambda = self._create_s3_reader_lambda()
        
        # Grant permissions
        self._configure_permissions()
        
        # Create outputs
        self._create_outputs()
    
    def _create_s3_reader_lambda(self) -> lambda_.Function:
        """Create test Lambda function that reads from S3."""
        # Lambda role
        lambda_role = iam.Role(
            self,
            f"S3ReaderLambdaRole-{self.stage}",
            assumed_by=iam.ServicePrincipal("lambda.amazonaws.com"),
            description=f"Role for S3 reader Lambda in {self.stage} environment",
            managed_policies=[
                iam.ManagedPolicy.from_aws_managed_policy_name("service-role/AWSLambdaBasicExecutionRole"),
                iam.ManagedPolicy.from_aws_managed_policy_name("service-role/AWSLambdaVPCAccessExecutionRole")
            ]
        )
        
        # Add X-Ray permissions if enabled
        if self.config["lambda"].get("tracingEnabled", True):
            lambda_role.add_managed_policy(
                iam.ManagedPolicy.from_aws_managed_policy_name("AWSXRayDaemonWriteAccess")
            )
        
        # Get Lambda source path
        lambda_path = Path(__file__).parent.parent.parent / "src" / "lambdas" / "s3_reader"
        
        # Create Lambda function
        function = lambda_.Function(
            self,
            f"S3ReaderLambda-{self.stage}",
            function_name=f"{self.config['projectName']}-s3-reader-{self.stage}",
            runtime=lambda_.Runtime.PYTHON_3_10,
            handler="handler.lambda_handler",
            code=lambda_.Code.from_asset(str(lambda_path)),
            role=lambda_role,
            vpc=self.vpc,
            vpc_subnets={
                "subnet_type": self.vpc.select_subnets(subnet_group_name="Private").subnet_type
            },
            memory_size=self.config["lambda"]["memorySize"],
            timeout=Duration.seconds(self.config["lambda"]["timeout"]),
            environment={
                "STAGE": self.stage,
                "TEST_BUCKET_NAME": self.test_bucket.bucket_name,
                "LOG_LEVEL": "DEBUG" if self.stage == "beta" else "INFO"
            },
            tracing=lambda_.Tracing.ACTIVE if self.config["lambda"].get("tracingEnabled", True) else lambda_.Tracing.DISABLED,
            log_retention=logs.RetentionDays(self.config["lambda"]["logRetentionDays"]),
            description=f"Test Lambda function to read from S3 in {self.stage} environment"
        )
        
        # Add reserved concurrent executions for production
        if self.stage == "prod" and "reservedConcurrentExecutions" in self.config["lambda"]:
            function.add_reserved_concurrent_executions(
                self.config["lambda"]["reservedConcurrentExecutions"]
            )
        
        return function
    
    def _configure_permissions(self):
        """Configure IAM permissions for Lambda functions."""
        # Grant read permissions to the test bucket
        self.test_bucket.grant_read(self.s3_reader_lambda)
        
        # Add custom policy for listing objects
        self.s3_reader_lambda.add_to_role_policy(
            iam.PolicyStatement(
                effect=iam.Effect.ALLOW,
                actions=[
                    "s3:ListBucket",
                    "s3:GetBucketLocation",
                    "s3:GetBucketVersioning"
                ],
                resources=[self.test_bucket.bucket_arn]
            )
        )
        
        # Add policy for reading objects with specific prefixes
        self.s3_reader_lambda.add_to_role_policy(
            iam.PolicyStatement(
                effect=iam.Effect.ALLOW,
                actions=[
                    "s3:GetObject",
                    "s3:GetObjectVersion",
                    "s3:GetObjectMetadata",
                    "s3:GetObjectVersionMetadata"
                ],
                resources=[f"{self.test_bucket.bucket_arn}/*"]
            )
        )
    
    def _create_outputs(self):
        """Create stack outputs."""
        CfnOutput(
            self,
            "S3ReaderLambdaArn",
            value=self.s3_reader_lambda.function_arn,
            description=f"S3 Reader Lambda ARN for {self.stage} environment"
        )
        
        CfnOutput(
            self,
            "S3ReaderLambdaName",
            value=self.s3_reader_lambda.function_name,
            description=f"S3 Reader Lambda name for {self.stage} environment"
        )
