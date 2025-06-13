from aws_cdk import (
    Stack,
    aws_s3 as s3,
    aws_kms as kms,
    aws_iam as iam,
    CfnOutput,
    RemovalPolicy,
    Duration
)
from constructs import Construct
from aws_cdk.aws_ec2 import IVpc


class StorageStack(Stack):
    """Storage infrastructure stack including S3 buckets."""
    
    def __init__(self, scope: Construct, construct_id: str, config: dict, vpc: IVpc, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)
        
        self.config = config
        self.stage = config["environment"]
        self.vpc = vpc
        
        # Create encryption key for production
        if config["s3"]["encryption"] == "KMS_MANAGED":
            self.kms_key = self._create_kms_key()
        else:
            self.kms_key = None
        
        # Create test bucket
        self.test_bucket = self._create_test_bucket()
        
        # Create application buckets
        self.uploads_bucket = self._create_uploads_bucket()
        self.exports_bucket = self._create_exports_bucket()
        self.logs_bucket = self._create_logs_bucket()
        
        # Output bucket names
        self._create_outputs()
    
    def _create_kms_key(self) -> kms.Key:
        """Create KMS key for S3 encryption (production only)."""
        key = kms.Key(
            self,
            f"S3EncryptionKey-{self.stage}",
            description=f"KMS key for S3 encryption in {self.stage} environment",
            enable_key_rotation=True,
            removal_policy=RemovalPolicy.RETAIN if self.stage == "prod" else RemovalPolicy.DESTROY
        )
        
        key.add_alias(f"alias/{self.config['projectName']}-s3-{self.stage}")
        
        return key
    
    def _create_test_bucket(self) -> s3.Bucket:
        """Create test S3 bucket for infrastructure testing."""
        bucket = s3.Bucket(
            self,
            f"TestBucket-{self.stage}",
            bucket_name=f"{self.config['projectName']}-test-{self.stage}-{self.account}",
            versioned=self.config["s3"]["versioning"],
            encryption=self._get_bucket_encryption(),
            encryption_key=self.kms_key,
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            removal_policy=RemovalPolicy.DESTROY if self.stage == "beta" else RemovalPolicy.RETAIN,
            auto_delete_objects=True if self.stage == "beta" else False,
            lifecycle_rules=[self._create_lifecycle_rule("test")] if self.config["s3"].get("lifecycleRules") else None,
            cors=[
                s3.CorsRule(
                    allowed_methods=[s3.HttpMethods.GET, s3.HttpMethods.PUT, s3.HttpMethods.POST],
                    allowed_origins=["*"],
                    allowed_headers=["*"],
                    max_age=3000
                )
            ]
        )
        
        # Add sample test file
        bucket.add_object_ownership(s3.ObjectOwnership.BUCKET_OWNER_ENFORCED)
        
        return bucket
    
    def _create_uploads_bucket(self) -> s3.Bucket:
        """Create bucket for user uploads."""
        bucket = s3.Bucket(
            self,
            f"UploadsBucket-{self.stage}",
            bucket_name=f"{self.config['projectName']}-uploads-{self.stage}-{self.account}",
            versioned=self.config["s3"]["versioning"],
            encryption=self._get_bucket_encryption(),
            encryption_key=self.kms_key,
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            removal_policy=RemovalPolicy.RETAIN,
            lifecycle_rules=[self._create_lifecycle_rule("uploads")] if self.config["s3"].get("lifecycleRules") else None,
            cors=[
                s3.CorsRule(
                    allowed_methods=[s3.HttpMethods.GET, s3.HttpMethods.PUT, s3.HttpMethods.POST, s3.HttpMethods.DELETE],
                    allowed_origins=["*"],  # Replace with your app domain in production
                    allowed_headers=["*"],
                    exposed_headers=["ETag"],
                    max_age=3000
                )
            ]
        )
        
        return bucket
    
    def _create_exports_bucket(self) -> s3.Bucket:
        """Create bucket for exports and reports."""
        bucket = s3.Bucket(
            self,
            f"ExportsBucket-{self.stage}",
            bucket_name=f"{self.config['projectName']}-exports-{self.stage}-{self.account}",
            versioned=False,  # Exports are typically immutable
            encryption=self._get_bucket_encryption(),
            encryption_key=self.kms_key,
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            removal_policy=RemovalPolicy.RETAIN,
            lifecycle_rules=[self._create_lifecycle_rule("exports")] if self.config["s3"].get("lifecycleRules") else None
        )
        
        return bucket
    
    def _create_logs_bucket(self) -> s3.Bucket:
        """Create bucket for application logs."""
        bucket = s3.Bucket(
            self,
            f"LogsBucket-{self.stage}",
            bucket_name=f"{self.config['projectName']}-logs-{self.stage}-{self.account}",
            versioned=False,
            encryption=s3.BucketEncryption.S3_MANAGED,  # Always use S3 managed for logs
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            removal_policy=RemovalPolicy.DESTROY if self.stage == "beta" else RemovalPolicy.RETAIN,
            auto_delete_objects=True if self.stage == "beta" else False,
            lifecycle_rules=[
                s3.LifecycleRule(
                    id="DeleteOldLogs",
                    expiration=Duration.days(30 if self.stage == "beta" else 90)
                )
            ]
        )
        
        # Grant write permissions to AWS services for logging
        bucket.add_to_resource_policy(
            iam.PolicyStatement(
                effect=iam.Effect.ALLOW,
                principals=[iam.ServicePrincipal("logging.s3.amazonaws.com")],
                actions=["s3:PutObject"],
                resources=[f"{bucket.bucket_arn}/*"]
            )
        )
        
        return bucket
    
    def _get_bucket_encryption(self) -> s3.BucketEncryption:
        """Get bucket encryption based on configuration."""
        if self.config["s3"]["encryption"] == "KMS_MANAGED":
            return s3.BucketEncryption.KMS
        return s3.BucketEncryption.S3_MANAGED
    
    def _create_lifecycle_rule(self, bucket_type: str) -> s3.LifecycleRule:
        """Create lifecycle rule based on configuration."""
        rules = self.config["s3"]["lifecycleRules"]
        
        transitions = []
        if "transitionToIA" in rules:
            transitions.append(
                s3.Transition(
                    storage_class=s3.StorageClass.INFREQUENT_ACCESS,
                    transition_after=Duration.days(rules["transitionToIA"])
                )
            )
        
        if "transitionToGlacier" in rules:
            transitions.append(
                s3.Transition(
                    storage_class=s3.StorageClass.GLACIER,
                    transition_after=Duration.days(rules["transitionToGlacier"])
                )
            )
        
        rule = s3.LifecycleRule(
            id=f"{bucket_type}-lifecycle-rule",
            transitions=transitions
        )
        
        if "expiration" in rules:
            rule.expiration = Duration.days(rules["expiration"])
        
        return rule
    
    def _create_outputs(self):
        """Create stack outputs."""
        CfnOutput(
            self,
            "TestBucketName",
            value=self.test_bucket.bucket_name,
            description=f"Test bucket name for {self.stage} environment"
        )
        
        CfnOutput(
            self,
            "UploadsBucketName",
            value=self.uploads_bucket.bucket_name,
            description=f"Uploads bucket name for {self.stage} environment"
        )
        
        CfnOutput(
            self,
            "ExportsBucketName",
            value=self.exports_bucket.bucket_name,
            description=f"Exports bucket name for {self.stage} environment"
        )
        
        CfnOutput(
            self,
            "LogsBucketName",
            value=self.logs_bucket.bucket_name,
            description=f"Logs bucket name for {self.stage} environment"
        )
