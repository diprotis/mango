#!/usr/bin/env python3
"""CDK entrypoint for the Mango backend.

Synthesize / deploy a specific stage with:  cdk synth -c stage=beta
Defaults to the ``beta`` stage when no context is provided.
"""

import os

import aws_cdk as cdk

from mango_backend.config import load_config
from mango_backend.stage import MangoStage

app = cdk.App()

stage_name = app.node.try_get_context("stage") or os.environ.get("MANGO_STAGE", "beta")
config = load_config(stage_name)

MangoStage(
    app,
    f"Mango-{config['environment']}",
    config=config,
    env=cdk.Environment(
        account=os.environ.get("CDK_DEFAULT_ACCOUNT"),
        region=config.get("region", "us-east-1"),
    ),
)

app.synth()
