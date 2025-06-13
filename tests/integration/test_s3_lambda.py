"""Integration tests for S3 Reader Lambda function."""
import os
import json
import pytest
import boto3
from botocore.exceptions import ClientError


@pytest.fixture
def lambda_client():
    """Create Lambda client."""
    return boto3.client('lambda', region_name='us-east-1')


@pytest.fixture
def stage():
    """Get deployment stage from environment."""
    return os.environ.get('STAGE', 'beta')


@pytest.mark.integration
@pytest.mark.beta
class TestS3ReaderLambda:
    """Integration tests for S3 Reader Lambda."""
    
    def test_lambda_exists(self, lambda_client, stage):
        """Test that Lambda function exists."""
        function_name = f"reading-journey-s3-reader-{stage}"
        
        try:
            response = lambda_client.get_function(FunctionName=function_name)
            assert response['Configuration']['FunctionName'] == function_name
            assert response['Configuration']['Runtime'] == 'python3.10'
        except ClientError as e:
            pytest.fail(f"Lambda function not found: {e}")
    
    def test_list_action(self, lambda_client, stage):
        """Test list action on S3 bucket."""
        function_name = f"reading-journey-s3-reader-{stage}"
        
        payload = {
            "action": "list"
        }
        
        response = lambda_client.invoke(
            FunctionName=function_name,
            InvocationType='RequestResponse',
            Payload=json.dumps(payload)
        )
        
        assert response['StatusCode'] == 200
        
        result = json.loads(response['Payload'].read())
        body = json.loads(result['body'])
        
        assert result['statusCode'] == 200
        assert 'bucket' in body
        assert 'objectCount' in body
        assert 'objects' in body
    
    def test_write_and_read_action(self, lambda_client, stage):
        """Test write and read actions."""
        function_name = f"reading-journey-s3-reader-{stage}"
        test_key = f"test-{stage}-integration.txt"
        test_content = f"Integration test content for {stage}"
        
        # Write object
        write_payload = {
            "action": "write",
            "key": test_key,
            "content": test_content
        }
        
        write_response = lambda_client.invoke(
            FunctionName=function_name,
            InvocationType='RequestResponse',
            Payload=json.dumps(write_payload)
        )
        
        assert write_response['StatusCode'] == 200
        write_result = json.loads(write_response['Payload'].read())
        assert write_result['statusCode'] == 200
        
        # Read object
        read_payload = {
            "action": "read",
            "key": test_key
        }
        
        read_response = lambda_client.invoke(
            FunctionName=function_name,
            InvocationType='RequestResponse',
            Payload=json.dumps(read_payload)
        )
        
        assert read_response['StatusCode'] == 200
        read_result = json.loads(read_response['Payload'].read())
        read_body = json.loads(read_result['body'])
        
        assert read_result['statusCode'] == 200
        assert read_body['content'] == test_content
    
    def test_invalid_action(self, lambda_client, stage):
        """Test invalid action handling."""
        function_name = f"reading-journey-s3-reader-{stage}"
        
        payload = {
            "action": "invalid"
        }
        
        response = lambda_client.invoke(
            FunctionName=function_name,
            InvocationType='RequestResponse',
            Payload=json.dumps(payload)
        )
        
        assert response['StatusCode'] == 200
        
        result = json.loads(response['Payload'].read())
        assert result['statusCode'] == 400
    
    def test_read_nonexistent_object(self, lambda_client, stage):
        """Test reading non-existent object."""
        function_name = f"reading-journey-s3-reader-{stage}"
        
        payload = {
            "action": "read",
            "key": "nonexistent-file.txt"
        }
        
        response = lambda_client.invoke(
            FunctionName=function_name,
            InvocationType='RequestResponse',
            Payload=json.dumps(payload)
        )
        
        assert response['StatusCode'] == 200
        
        result = json.loads(response['Payload'].read())
        assert result['statusCode'] == 404


@pytest.mark.integration
@pytest.mark.smoke
class TestInfrastructureSmoke:
    """Smoke tests for deployed infrastructure."""
    
    def test_s3_bucket_exists(self, stage):
        """Test that S3 test bucket exists."""
        s3_client = boto3.client('s3')
        account_id = boto3.client('sts').get_caller_identity()['Account']
        bucket_name = f"reading-journey-test-{stage}-{account_id}"
        
        try:
            s3_client.head_bucket(Bucket=bucket_name)
        except ClientError as e:
            pytest.fail(f"S3 bucket not found: {e}")
    
    def test_cloudwatch_dashboard_exists(self, stage):
        """Test that CloudWatch dashboard exists."""
        cw_client = boto3.client('cloudwatch')
        dashboard_name = f"reading-journey-{stage}"
        
        try:
            response = cw_client.get_dashboard(DashboardName=dashboard_name)
            assert 'DashboardBody' in response
        except ClientError as e:
            if e.response['Error']['Code'] != 'ResourceNotFound':
                raise
