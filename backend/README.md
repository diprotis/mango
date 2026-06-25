# Mango — AWS backend

AWS CDK (Python) backend for Mango: API Gateway HTTP API → Python 3.12 Lambdas,
backed by single-table DynamoDB, an S3 content bucket, a Cognito user pool, and a
Secrets Manager secret for the Anthropic key. Deployable to **beta** and **prod**.

## Requirements

Python 3.12, Node 20+ (for the CDK CLI), and AWS credentials.

## Install

```bash
cd backend
python3 -m pip install -r requirements.txt -r requirements-dev.txt
```

## Test

```bash
python3 -m pytest            # 29 unit tests
```

(Or `make backend-test`. Lint with `make backend-lint` — flake8 + black.)

## Synth

```bash
npx aws-cdk@2 synth -c stage=beta      # clean synth for beta (and prod)
```

## Deploy beta / prod

First time in an account, bootstrap once:

```bash
npx aws-cdk@2 bootstrap
```

Then deploy a stage (`beta` or `prod`):

```bash
npx aws-cdk@2 deploy -c stage=beta --require-approval never --all
npx aws-cdk@2 deploy -c stage=prod --require-approval never --all
```

(Or `make backend-deploy-beta` / `make backend-deploy-prod`.) The prod stage uses
`RETAIN` removal policies, DynamoDB PITR, and S3 versioning. CI deploys via a
GitHub OIDC role (repo secret `AWS_DEPLOY_ROLE_ARN`) — Beta on push to `main`,
Prod on a published Release.

## Set the Anthropic secret

The secret is created empty; set its value after the first deploy. The key lives
only server-side.

```bash
aws secretsmanager put-secret-value \
  --secret-id mango/beta/anthropic-api-key \
  --secret-string '{"apiKey":"sk-ant-..."}'
```

## More

Architecture, the full API surface, the single-table data model, the OIDC deploy
role's trust policy and permissions, and the security notes (SSRF guard, auth
gating, least-privilege IAM) are in [../docs/BACKEND.md](../docs/BACKEND.md).
