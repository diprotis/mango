"""A deployable Mango stage (beta or prod) composed of all stacks."""

from aws_cdk import Stage
from constructs import Construct

from .ai_stack import AiStack
from .api_stack import ApiStack
from .auth_stack import AuthStack
from .data_stack import DataStack


class MangoStage(Stage):
    def __init__(self, scope: Construct, construct_id: str, *, config: dict, **kwargs):
        super().__init__(scope, construct_id, **kwargs)

        data = DataStack(self, "Data", config=config)
        auth = AuthStack(self, "Auth", config=config)
        ai = AiStack(self, "Ai", config=config)

        ApiStack(
            self,
            "Api",
            config=config,
            table=data.table,
            bucket=data.bucket,
            user_pool=auth.user_pool,
            user_pool_client=auth.user_pool_client,
            anthropic_secret=ai.anthropic_secret,
        )
