"""Stage configuration loading."""

import json
import os

_CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "config")


def load_config(stage: str) -> dict:
    """Load configuration for a stage (beta/prod), with safe defaults."""
    path = os.path.join(_CONFIG_DIR, f"{stage}.json")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            cfg = json.load(fh)
    except FileNotFoundError:
        cfg = {}
    cfg.setdefault("environment", stage)
    cfg.setdefault("region", "us-east-1")
    cfg.setdefault("claudeModel", "claude-3-5-sonnet-latest")
    return cfg
