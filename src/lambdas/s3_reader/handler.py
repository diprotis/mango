"""
Lambda function to read files from S3 bucket.
This is a test function to validate infrastructure setup.
"""
import json
import os
import logging
from typing import Dict, Any
import boto3
from botocore.exceptions import ClientError

# Configure logging
logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

# Initialize S3 client
s3_client = boto3.client("s3")

# Get environment variables
STAGE = os.environ.get("STAGE", "unknown")
TEST_BUCKET_NAME = os.environ.get("TEST_BUCKET_NAME", "")


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Lambda handler to read files from S3.
    
    Args:
        event: Lambda event object
        context: Lambda context object
    
    Returns:
        Response with status and data
    """
    logger.info(f"Received event: {json.dumps(event)}")
    logger.info(f"Stage: {STAGE}, Bucket: {TEST_BUCKET_NAME}")
    
    try:
        # Extract parameters from event
        action = event.get("action", "list")
        key = event.get("key", "")
        
        if action == "list":
            return list_bucket_objects()
        elif action == "read":
            if not key:
                return create_response(400, "Key parameter is required for read action")
            return read_object(key)
        elif action == "write":
            content = event.get("content", "")
            if not key or not content:
                return create_response(400, "Key and content parameters are required for write action")
            return write_object(key, content)
        else:
            return create_response(400, f"Unknown action: {action}")
            
    except ClientError as e:
        logger.error(f"AWS Client Error: {str(e)}")
        return create_response(500, f"AWS Error: {e.response['Error']['Message']}")
    except Exception as e:
        logger.error(f"Unexpected error: {str(e)}")
        return create_response(500, f"Internal error: {str(e)}")


def list_bucket_objects() -> Dict[str, Any]:
    """List objects in the test bucket."""
    try:
        response = s3_client.list_objects_v2(
            Bucket=TEST_BUCKET_NAME,
            MaxKeys=100
        )
        
        objects = []
        if "Contents" in response:
            for obj in response["Contents"]:
                objects.append({
                    "key": obj["Key"],
                    "size": obj["Size"],
                    "lastModified": obj["LastModified"].isoformat()
                })
        
        return create_response(200, {
            "bucket": TEST_BUCKET_NAME,
            "objectCount": len(objects),
            "objects": objects
        })
        
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchBucket":
            return create_response(404, f"Bucket {TEST_BUCKET_NAME} not found")
        raise


def read_object(key: str) -> Dict[str, Any]:
    """Read an object from the test bucket."""
    try:
        response = s3_client.get_object(
            Bucket=TEST_BUCKET_NAME,
            Key=key
        )
        
        # Read content (limit to 1MB for safety)
        content = response["Body"].read(1024 * 1024).decode("utf-8")
        
        return create_response(200, {
            "bucket": TEST_BUCKET_NAME,
            "key": key,
            "contentType": response.get("ContentType", "unknown"),
            "contentLength": response.get("ContentLength", 0),
            "content": content,
            "metadata": response.get("Metadata", {})
        })
        
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchKey":
            return create_response(404, f"Object {key} not found in bucket {TEST_BUCKET_NAME}")
        raise


def write_object(key: str, content: str) -> Dict[str, Any]:
    """Write an object to the test bucket."""
    try:
        response = s3_client.put_object(
            Bucket=TEST_BUCKET_NAME,
            Key=key,
            Body=content.encode("utf-8"),
            ContentType="text/plain",
            Metadata={
                "stage": STAGE,
                "created_by": "s3_reader_lambda"
            }
        )
        
        return create_response(200, {
            "bucket": TEST_BUCKET_NAME,
            "key": key,
            "etag": response["ETag"],
            "message": "Object written successfully"
        })
        
    except ClientError as e:
        raise


def create_response(status_code: int, body: Any) -> Dict[str, Any]:
    """Create a standardized response."""
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "X-Stage": STAGE
        },
        "body": json.dumps(body, default=str)
    }
