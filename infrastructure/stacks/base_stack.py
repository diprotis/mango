from aws_cdk import (
    Stack,
    aws_ec2 as ec2,
    aws_logs as logs,
    aws_iam as iam,
    CfnOutput,
    RemovalPolicy
)
from constructs import Construct


class BaseStack(Stack):
    """Base infrastructure stack including VPC and common resources."""
    
    def __init__(self, scope: Construct, construct_id: str, config: dict, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)
        
        self.config = config
        self.stage = config["environment"]
        
        # Create VPC
        self.vpc = self._create_vpc()
        
        # Create VPC Flow Logs
        if config["vpc"]["enableFlowLogs"]:
            self._create_flow_logs()
        
        # Create common IAM roles
        self._create_common_roles()
        
        # Outputs
        CfnOutput(
            self,
            "VpcId",
            value=self.vpc.vpc_id,
            description=f"VPC ID for {self.stage} environment"
        )
    
    def _create_vpc(self) -> ec2.Vpc:
        """Create VPC with public and private subnets."""
        vpc = ec2.Vpc(
            self,
            f"VPC-{self.stage}",
            vpc_name=f"{self.config['projectName']}-vpc-{self.stage}",
            max_azs=self.config["vpc"]["maxAzs"],
            nat_gateways=self.config["vpc"]["natGateways"],
            subnet_configuration=[
                ec2.SubnetConfiguration(
                    name="Public",
                    subnet_type=ec2.SubnetType.PUBLIC,
                    cidr_mask=24
                ),
                ec2.SubnetConfiguration(
                    name="Private",
                    subnet_type=ec2.SubnetType.PRIVATE_WITH_EGRESS,
                    cidr_mask=24
                ),
                ec2.SubnetConfiguration(
                    name="Isolated",
                    subnet_type=ec2.SubnetType.PRIVATE_ISOLATED,
                    cidr_mask=24
                )
            ],
            enable_dns_hostnames=True,
            enable_dns_support=True
        )
        
        # Add VPC Endpoints for AWS services
        vpc.add_gateway_endpoint(
            "S3Endpoint",
            service=ec2.GatewayVpcEndpointAwsService.S3
        )
        
        vpc.add_gateway_endpoint(
            "DynamoDBEndpoint",
            service=ec2.GatewayVpcEndpointAwsService.DYNAMODB
        )
        
        # Add interface endpoints for other services
        vpc.add_interface_endpoint(
            "SecretsManagerEndpoint",
            service=ec2.InterfaceVpcEndpointAwsService.SECRETS_MANAGER
        )
        
        vpc.add_interface_endpoint(
            "CloudWatchLogsEndpoint",
            service=ec2.InterfaceVpcEndpointAwsService.CLOUDWATCH_LOGS
        )
        
        return vpc
    
    def _create_flow_logs(self):
        """Create VPC Flow Logs."""
        flow_log_group = logs.LogGroup(
            self,
            f"FlowLogGroup-{self.stage}",
            log_group_name=f"/aws/vpc/{self.config['projectName']}-{self.stage}",
            retention=logs.RetentionDays.SEVEN_DAYS if self.stage == "beta" else logs.RetentionDays.THIRTY_DAYS,
            removal_policy=RemovalPolicy.DESTROY if self.stage == "beta" else RemovalPolicy.RETAIN
        )
        
        self.vpc.add_flow_log(
            f"FlowLog-{self.stage}",
            destination=ec2.FlowLogDestination.to_cloud_watch_logs(flow_log_group),
            traffic_type=ec2.FlowLogTrafficType.ALL
        )
    
    def _create_common_roles(self):
        """Create common IAM roles that will be used across the application."""
        # Create a basic Lambda execution role that other stacks can enhance
        self.lambda_execution_role = iam.Role(
            self,
            f"LambdaExecutionRole-{self.stage}",
            assumed_by=iam.ServicePrincipal("lambda.amazonaws.com"),
            managed_policies=[
                iam.ManagedPolicy.from_aws_managed_policy_name("service-role/AWSLambdaBasicExecutionRole"),
                iam.ManagedPolicy.from_aws_managed_policy_name("service-role/AWSLambdaVPCAccessExecutionRole")
            ],
            description=f"Basic Lambda execution role for {self.stage} environment"
        )
        
        # Add X-Ray permissions if tracing is enabled
        if self.config["lambda"].get("tracingEnabled", True):
            self.lambda_execution_role.add_managed_policy(
                iam.ManagedPolicy.from_aws_managed_policy_name("AWSXRayDaemonWriteAccess")
            )
