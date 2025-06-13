#!/usr/bin/env python3
import os
import json
from pathlib import Path

import aws_cdk as cdk
from aws_cdk import Tags

from stacks.base_stack import BaseStack
from stacks.storage_stack import StorageStack
from stacks.compute_stack import ComputeStack
from stacks.monitoring_stack import MonitoringStack


def load_config(stage: str) -> dict:
    """Load configuration for the specified stage."""
    config_path = Path(__file__).parent / "config" / f"{stage}.json"
    with open(config_path, "r") as f:
        return json.load(f)


def main():
    app = cdk.App()
    
    # Get stage from context
    stage = app.node.try_get_context("stage") or "beta"
    config = load_config(stage)
    
    # Create environment
    env = cdk.Environment(
        account=config["account"],
        region=config["region"]
    )
    
    # Common stack properties
    stack_props = {
        "env": env,
        "stack_name": f"{config['projectName']}-{stage}",
        "description": f"Reading Journey Backend - {stage.upper()}",
    }
    
    # Create stacks
    base_stack = BaseStack(
        app,
        f"{config['projectName']}-base-{stage}",
        config=config,
        **stack_props
    )
    
    storage_stack = StorageStack(
        app,
        f"{config['projectName']}-storage-{stage}",
        config=config,
        vpc=base_stack.vpc,
        **stack_props
    )
    
    compute_stack = ComputeStack(
        app,
        f"{config['projectName']}-compute-{stage}",
        config=config,
        vpc=base_stack.vpc,
        bucket=storage_stack.test_bucket,
        **stack_props
    )
    
    monitoring_stack = MonitoringStack(
        app,
        f"{config['projectName']}-monitoring-{stage}",
        config=config,
        lambda_functions=[compute_stack.s3_reader_lambda],
        **stack_props
    )
    
    # Add dependencies
    storage_stack.add_dependency(base_stack)
    compute_stack.add_dependency(storage_stack)
    monitoring_stack.add_dependency(compute_stack)
    
    # Apply tags to all stacks
    for key, value in config["tags"].items():
        Tags.of(app).add(key, value)
    
    app.synth()


if __name__ == "__main__":
    main()
