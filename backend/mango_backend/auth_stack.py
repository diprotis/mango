"""Cognito user pool for app authentication.

Builds one user pool + one public app client (auth code + PKCE) wired to a
Hosted UI domain, with optional Google / Sign in with Apple / phone (SMS)
sign-in turned on per environment via config. Plain ``cdk synth`` works with no
secrets: every optional provider defaults to off, so the only resources created
are the pool, the public client, and the Hosted UI domain.
"""

from aws_cdk import CfnOutput, Duration, RemovalPolicy, SecretValue, Stack
from aws_cdk import aws_cognito as cognito
from aws_cdk import aws_iam as iam
from aws_cdk import aws_secretsmanager as secretsmanager
from constructs import Construct


class AuthStack(Stack):
    def __init__(self, scope: Construct, construct_id: str, *, config: dict, **kwargs):
        super().__init__(scope, construct_id, **kwargs)
        stage = config["environment"]
        is_prod = stage == "prod"
        enable_phone = bool(config.get("enablePhone"))
        enable_google = bool(config.get("enableGoogle"))
        enable_apple = bool(config.get("enableApple"))

        # --- SMS role (only when phone sign-in is enabled) --------------------
        # Cognito needs an IAM role it can assume to publish SMS via SNS. The
        # external id ties the trust policy to this pool to prevent confused-
        # deputy use. Created only when phone sign-in is on.
        sms_role = None
        if enable_phone:
            sms_external_id = f"mango-{stage}-cognito-sms"
            sms_role = iam.Role(
                self,
                "CognitoSmsRole",
                assumed_by=iam.ServicePrincipal(
                    "cognito-idp.amazonaws.com",
                    conditions={"StringEquals": {"sts:ExternalId": sms_external_id}},
                ),
                inline_policies={
                    "AllowSnsPublish": iam.PolicyDocument(
                        statements=[
                            iam.PolicyStatement(
                                actions=["sns:Publish"],
                                resources=["*"],
                            )
                        ]
                    )
                },
            )

        self.user_pool = cognito.UserPool(
            self,
            "UserPool",
            self_sign_up_enabled=True,
            sign_in_aliases=cognito.SignInAliases(email=True, phone=enable_phone),
            auto_verify=cognito.AutoVerifiedAttrs(email=True, phone=enable_phone),
            standard_attributes=cognito.StandardAttributes(
                email=cognito.StandardAttribute(required=True, mutable=True),
            ),
            password_policy=cognito.PasswordPolicy(
                min_length=8,
                require_lowercase=True,
                require_digits=True,
                require_uppercase=False,
                require_symbols=False,
            ),
            account_recovery=cognito.AccountRecovery.EMAIL_ONLY,
            sms_role=sms_role,
            sms_role_external_id=(sms_external_id if enable_phone else None),
            removal_policy=RemovalPolicy.RETAIN if is_prod else RemovalPolicy.DESTROY,
        )

        # --- Hosted UI domain -------------------------------------------------
        # The prefix must be globally unique across all of AWS. Default to an
        # account-scoped name (account id resolves at deploy time) so synth
        # works without configuration; override with ``cognitoDomainPrefix``.
        domain_prefix = config.get("cognitoDomainPrefix") or f"mango-{stage}-{self.account}"
        self.user_pool_domain = self.user_pool.add_domain(
            "HostedUiDomain",
            cognito_domain=cognito.CognitoDomainOptions(domain_prefix=domain_prefix),
        )

        # --- Identity providers (optional) ------------------------------------
        supported_providers = [cognito.UserPoolClientIdentityProvider.COGNITO]
        idp_dependencies = []

        if enable_google:
            google_secret = secretsmanager.Secret(
                self,
                "GoogleOAuthSecret",
                secret_name=f"mango/{stage}/google-oauth",
                description="Google OAuth client secret for Cognito federation (set out-of-band).",
            )
            google_idp = cognito.UserPoolIdentityProviderGoogle(
                self,
                "GoogleIdP",
                user_pool=self.user_pool,
                client_id=config["googleClientId"],
                client_secret_value=SecretValue.secrets_manager(google_secret.secret_name),
                scopes=["openid", "email", "profile"],
                attribute_mapping=cognito.AttributeMapping(
                    email=cognito.ProviderAttribute.GOOGLE_EMAIL,
                ),
            )
            supported_providers.append(cognito.UserPoolClientIdentityProvider.GOOGLE)
            idp_dependencies.append(google_idp)

        if enable_apple:
            apple_secret = secretsmanager.Secret(
                self,
                "AppleSigninSecret",
                secret_name=f"mango/{stage}/apple-signin",
                description="Sign in with Apple .p8 private key for Cognito (set out-of-band).",
            )
            apple_idp = cognito.UserPoolIdentityProviderApple(
                self,
                "AppleIdP",
                user_pool=self.user_pool,
                client_id=config["appleServicesId"],
                team_id=config["appleTeamId"],
                key_id=config["appleKeyId"],
                private_key_value=SecretValue.secrets_manager(apple_secret.secret_name),
                scopes=["email", "name"],
                attribute_mapping=cognito.AttributeMapping(
                    email=cognito.ProviderAttribute.APPLE_EMAIL,
                ),
            )
            supported_providers.append(cognito.UserPoolClientIdentityProvider.APPLE)
            idp_dependencies.append(apple_idp)

        # --- App client (public, OAuth auth code + PKCE) ----------------------
        self.user_pool_client = self.user_pool.add_client(
            "AppClient",
            # Public PKCE client. No USER_PASSWORD_AUTH (that non-PKCE flow on a
            # public client is a credential-stuffing risk). user_srp covers native
            # SRP; admin_user_password is a server-side admin flow (admin creds
            # only) used by the deploy smoke test — it does not weaken the
            # user-facing auth-code + PKCE path.
            auth_flows=cognito.AuthFlow(user_srp=True, admin_user_password=True),
            generate_secret=False,
            prevent_user_existence_errors=True,
            supported_identity_providers=supported_providers,
            o_auth=cognito.OAuthSettings(
                flows=cognito.OAuthFlows(authorization_code_grant=True),
                scopes=[
                    cognito.OAuthScope.OPENID,
                    cognito.OAuthScope.EMAIL,
                    cognito.OAuthScope.PROFILE,
                ],
                callback_urls=["mango://callback"],
                logout_urls=["mango://signout"],
            ),
            access_token_validity=Duration.minutes(60),
            id_token_validity=Duration.minutes(60),
            refresh_token_validity=Duration.days(30),
        )

        # The client references the providers by name, so they must exist first.
        for idp in idp_dependencies:
            self.user_pool_client.node.add_dependency(idp)

        # --- Outputs ----------------------------------------------------------
        hosted_ui_url = f"https://{domain_prefix}.auth.{self.region}.amazoncognito.com"
        CfnOutput(self, "UserPoolId", value=self.user_pool.user_pool_id)
        CfnOutput(self, "UserPoolClientId", value=self.user_pool_client.user_pool_client_id)
        CfnOutput(self, "UserPoolDomain", value=hosted_ui_url)
        CfnOutput(self, "Region", value=self.region)
