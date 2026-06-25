"""Optional Anthropic API-key secret.

The backend itself no longer needs this: generation/grading run on Amazon
Bedrock via IAM (see ``api_stack.py``). This secret is OPTIONAL and exists only
for the on-device "Direct-Claude" testing path; it can be left empty (or the
stack removed) without affecting the deployed API.
"""

from aws_cdk import RemovalPolicy, Stack
from aws_cdk import aws_secretsmanager as sm
from constructs import Construct


class AiStack(Stack):
    def __init__(self, scope: Construct, construct_id: str, *, config: dict, **kwargs):
        super().__init__(scope, construct_id, **kwargs)
        is_prod = config["environment"] == "prod"

        # Created empty. OPTIONAL — only the on-device Direct-Claude path uses it;
        # the backend Lambdas call Bedrock via IAM and do not read this secret.
        # If you do use Direct-Claude, set the value out-of-band after deploy:
        #   aws secretsmanager put-secret-value \
        #     --secret-id mango/<stage>/anthropic-api-key \
        #     --secret-string '{"apiKey":"sk-ant-..."}'
        self.anthropic_secret = sm.Secret(
            self,
            "AnthropicApiKey",
            secret_name=f"mango/{config['environment']}/anthropic-api-key",
            description="Optional Anthropic API key (on-device Direct-Claude path only).",
            removal_policy=RemovalPolicy.RETAIN if is_prod else RemovalPolicy.DESTROY,
        )
