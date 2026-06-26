"""HTTP API (API Gateway v2) + Lambda handlers with least-privilege grants."""

from aws_cdk import CfnOutput, Duration, Stack
from aws_cdk import aws_apigatewayv2 as apigw
from aws_cdk import aws_apigatewayv2_authorizers as authorizers
from aws_cdk import aws_apigatewayv2_integrations as integrations
from aws_cdk import aws_iam as iam
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
        analytics_bucket,
        events_stream_name,
        features_table,
        **kwargs,
    ):
        super().__init__(scope, construct_id, **kwargs)
        # ``anthropic_secret`` is kept in the signature for compatibility with
        # MangoStage but is no longer used: backend AI now runs on Bedrock (IAM).
        del anthropic_secret
        del analytics_bucket, features_table  # reserved for future producers
        stage = config["environment"]

        common_env = {
            "TABLE_NAME": table.table_name,
            "BUCKET_NAME": bucket.bucket_name,
            "BEDROCK_MODEL_ID": config.get(
                "bedrockModelId", "anthropic.claude-3-5-sonnet-20240620-v1:0"
            ),
            "BEDROCK_REGION": config.get("bedrockRegion", ""),
            "AI_MAX_EFFORT": str(config.get("aiMaxEffort", True)).lower(),
            "EVENTS_STREAM_NAME": events_stream_name,
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
        profile_fn = make_fn("ProfileFn", "handlers.profile.handler", timeout=15)
        library_fn = make_fn("LibraryFn", "handlers.library.handler", timeout=15)
        reflections_fn = make_fn("ReflectionsFn", "handlers.reflections.handler", timeout=15)
        delete_fn = make_fn("DeleteAccountFn", "handlers.delete_account.handler", timeout=30)
        events_fn = make_fn("EventsFn", "handlers.events.handler", timeout=10)
        catalog_fn = make_fn("CatalogFn", "handlers.catalog.handler", timeout=10)

        # Least-privilege grants (grade_fn never touches the table)
        for fn in (
            parse_fn,
            roadmap_fn,
            progress_fn,
            profile_fn,
            library_fn,
            reflections_fn,
            delete_fn,
        ):
            table.grant_read_write_data(fn)
        bucket.grant_read_write(parse_fn)
        bucket.grant_read(roadmap_fn)
        bucket.grant_read_write(delete_fn)  # enumerates + deletes users/<sub>/ objects

        # Backend AI runs on Amazon Bedrock (IAM auth, no API key). Only the
        # generate/grade Lambdas may invoke models.
        bedrock_policy = iam.PolicyStatement(
            actions=["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
            resources=[
                "arn:aws:bedrock:*::foundation-model/*",
                "arn:aws:bedrock:*:*:inference-profile/*",
            ],
        )
        roadmap_fn.add_to_role_policy(bedrock_policy)
        grade_fn.add_to_role_policy(bedrock_policy)

        # The events Lambda may write only to the analytics Firehose stream.
        events_stream_arn = Stack.of(self).format_arn(
            service="firehose",
            resource="deliverystream",
            resource_name=events_stream_name,
        )
        events_fn.add_to_role_policy(
            iam.PolicyStatement(
                actions=["firehose:PutRecord", "firehose:PutRecordBatch"],
                resources=[events_stream_arn],
            )
        )

        # Account deletion also removes the Cognito user (admin API, scoped to
        # this pool). The pool id is passed only to the delete Lambda.
        delete_fn.add_environment("COGNITO_USER_POOL_ID", user_pool.user_pool_id)
        delete_fn.add_to_role_policy(
            iam.PolicyStatement(
                actions=["cognito-idp:AdminDeleteUser"],
                resources=[user_pool.user_pool_arn],
            )
        )

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

        route_count = {"n": 0}

        def route(path: str, method: apigw.HttpMethod, fn: _lambda.Function, secured: bool = True):
            route_count["n"] += 1
            http_api.add_routes(
                path=path,
                methods=[method],
                integration=integrations.HttpLambdaIntegration(
                    f"Integ{route_count['n']}{fn.node.id}", fn
                ),
                authorizer=authorizer if secured else None,
            )

        route("/health", apigw.HttpMethod.GET, health_fn, secured=False)
        route("/v1/content/parse", apigw.HttpMethod.POST, parse_fn)
        route("/v1/roadmaps/generate", apigw.HttpMethod.POST, roadmap_fn)
        route("/v1/exercises/grade", apigw.HttpMethod.POST, grade_fn)
        route("/v1/me/progress", apigw.HttpMethod.GET, progress_fn)
        route("/v1/me/progress", apigw.HttpMethod.PUT, progress_fn)
        route("/v1/me/profile", apigw.HttpMethod.GET, profile_fn)
        route("/v1/me/profile", apigw.HttpMethod.PUT, profile_fn)
        route("/v1/me/library", apigw.HttpMethod.GET, library_fn)
        route("/v1/me/library", apigw.HttpMethod.POST, library_fn)
        route("/v1/me/library/{bookId}", apigw.HttpMethod.DELETE, library_fn)
        route("/v1/reflections", apigw.HttpMethod.GET, reflections_fn)
        route("/v1/reflections", apigw.HttpMethod.POST, reflections_fn)
        route("/v1/me", apigw.HttpMethod.DELETE, delete_fn)
        route("/v1/events", apigw.HttpMethod.POST, events_fn)
        route("/v1/catalog", apigw.HttpMethod.GET, catalog_fn, secured=False)
        route("/v1/catalog/{id}", apigw.HttpMethod.GET, catalog_fn, secured=False)

        CfnOutput(self, "ApiUrl", value=http_api.api_endpoint)
