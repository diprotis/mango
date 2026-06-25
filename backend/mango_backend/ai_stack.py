"""Secrets for the Anthropic API key (the key lives only server-side)."""

from aws_cdk import RemovalPolicy, Stack
from aws_cdk import aws_secretsmanager as sm
from constructs import Construct


class AiStack(Stack):
    def __init__(self, scope: Construct, construct_id: str, *, config: dict, **kwargs):
        super().__init__(scope, construct_id, **kwargs)
        is_prod = config["environment"] == "prod"

        # Created empty; set the real value out-of-band after deploy:
        #   aws secretsmanager put-secret-value \
        #     --secret-id mango/<stage>/anthropic-api-key \
        #     --secret-string '{"apiKey":"sk-ant-..."}'
        self.anthropic_secret = sm.Secret(
            self,
            "AnthropicApiKey",
            secret_name=f"mango/{config['environment']}/anthropic-api-key",
            description="Anthropic API key used by Mango Lambdas for generation/grading.",
            removal_policy=RemovalPolicy.RETAIN if is_prod else RemovalPolicy.DESTROY,
        )
