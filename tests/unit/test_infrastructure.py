"""Unit tests for CDK infrastructure."""
import json
from pathlib import Path
import pytest
from aws_cdk import App
from aws_cdk.assertions import Template, Match


def load_config(stage: str) -> dict:
    """Load configuration for testing."""
    config_path = Path(__file__).parent.parent.parent / "infrastructure" / "config" / f"{stage}.json"
    with open(config_path, "r") as f:
        return json.load(f)


class TestInfrastructure:
    """Test CDK infrastructure synthesis."""
    
    def test_config_files_exist(self):
        """Test that configuration files exist."""
        beta_config = Path(__file__).parent.parent.parent / "infrastructure" / "config" / "beta.json"
        prod_config = Path(__file__).parent.parent.parent / "infrastructure" / "config" / "prod.json"
        
        assert beta_config.exists(), "Beta config file missing"
        assert prod_config.exists(), "Production config file missing"
    
    def test_beta_config_structure(self):
        """Test Beta configuration structure."""
        config = load_config("beta")
        
        assert "environment" in config
        assert config["environment"] == "beta"
        assert "account" in config
        assert "region" in config
        assert "vpc" in config
        assert "lambda" in config
        assert "s3" in config
    
    def test_prod_config_structure(self):
        """Test Production configuration structure."""
        config = load_config("prod")
        
        assert "environment" in config
        assert config["environment"] == "prod"
        assert config["dynamodb"]["pointInTimeRecovery"] is True
        assert config["dynamodb"]["deletionProtection"] is True
    
    def test_lambda_config_differences(self):
        """Test that Lambda configs differ between environments."""
        beta_config = load_config("beta")
        prod_config = load_config("prod")
        
        # Production should have higher memory
        assert prod_config["lambda"]["memorySize"] > beta_config["lambda"]["memorySize"]
        
        # Production should have longer log retention
        assert prod_config["lambda"]["logRetentionDays"] > beta_config["lambda"]["logRetentionDays"]
