"""HTTP API (API Gateway v2) + Lambda handlers with least-privilege grants."""

from aws_cdk import CfnOutput, Duration, Stack
from aws_cdk import aws_apigatewayv2 as apigw
from aws_cdk import aws_apigatewayv2_authorizers as authorizers
from aws_cdk import aws_apigatewayv2_integrations as integrations
from aws_cdk import aws_lambda as _lambda
from constructs import Construct


class ApiStack(Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        *,
        config: dict,
        table,
        bucket,
        user_pool,
        user_pool_client,
        anthropic_secret,
        **kwargs,
    ):
        super().__init__(scope, construct_id, **kwargs)
        stage = config["environment"]

        common_env = {
            "TABLE_NAME": table.table_name,
            "BUCKET_NAME": bucket.bucket_name,
            "ANTHROPIC_SECRET_ARN": anthropic_secret.secret_arn,
            "CLAUDE_MODEL": config.get("claudeModel", "claude-3-5-sonnet-latest"),
            "STAGE": stage,
        }

        def make_fn(
            name: str, handler: str, timeout: int = 30, memory: int = 256
        ) -> _lambda.Function:
            return _lambda.Function(
                self,
                name,
                runtime=_lambda.Runtime.PYTHON_3_12,
                handler=handler,
                code=_lambda.Code.from_asset("src"),
                timeout=Duration.seconds(timeout),
                memory_size=memory,
                environment=common_env,
            )

        health_fn = make_fn("HealthFn", "handlers.health.handler", timeout=10, memory=128)
        parse_fn = make_fn("ContentParseFn", "handlers.content_parse.handler", timeout=30)
        roadmap_fn = make_fn(
            "RoadmapFn", "handlers.generate_roadmap.handler", timeout=60, memory=512
        )
        grade_fn = make_fn("GradeFn", "handlers.grade_exercise.handler", timeout=60, memory=384)
        progress_fn = make_fn("ProgressFn", "handlers.progress.handler", timeout=15)

        # Least-privilege grants (grade_fn never touches the table)
        for fn in (parse_fn, roadmap_fn, progress_fn):
            table.grant_read_write_data(fn)
        bucket.grant_read_write(parse_fn)
        bucket.grant_read(roadmap_fn)
        anthropic_secret.grant_read(roadmap_fn)
        anthropic_secret.grant_read(grade_fn)

        authorizer = authorizers.HttpUserPoolAuthorizer(
            "JwtAuthorizer", user_pool, user_pool_clients=[user_pool_client]
        )

        http_api = apigw.HttpApi(
            self,
            "HttpApi",
            api_name=f"mango-{stage}",
            cors_preflight=apigw.CorsPreflightOptions(
                allow_headers=["authorization", "content-type"],
                allow_methods=[apigw.CorsHttpMethod.ANY],
                allow_origins=["*"],
            ),
        )

        def route(path: str, method: apigw.HttpMethod, fn: _lambda.Function, secured: bool = True):
            http_api.add_routes(
                path=path,
                methods=[method],
                integration=integrations.HttpLambdaIntegration(f"{fn.node.id}Integ", fn),
                authorizer=authorizer if secured else None,
            )

        route("/health", apigw.HttpMethod.GET, health_fn, secured=False)
        route("/v1/content/parse", apigw.HttpMethod.POST, parse_fn)
        route("/v1/roadmaps/generate", apigw.HttpMethod.POST, roadmap_fn)
        route("/v1/exercises/grade", apigw.HttpMethod.POST, grade_fn)
        route("/v1/me/progress", apigw.HttpMethod.GET, progress_fn)
        route("/v1/me/progress", apigw.HttpMethod.PUT, progress_fn)

        CfnOutput(self, "ApiUrl", value=http_api.api_endpoint)
