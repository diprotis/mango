# Deploying the Mango backend — AWS profile `diprotis-dev`

> Run these on your Mac (any machine with the `diprotis-dev` AWS profile configured).
> The Cowork sandbox has **no AWS credentials**, so the deploy can't be executed from
> chat — but every command below is ready to paste.

## Prerequisites
- **AWS CLI v2** with a `diprotis-dev` profile. Verify it resolves:
  ```bash
  aws sts get-caller-identity --profile diprotis-dev
  ```
- **Node 20+** and **Python 3.12**.
- Install backend deps once:
  ```bash
  cd backend
  python3 -m pip install -r requirements.txt
  ```

All `make` targets below default to `PROFILE=diprotis-dev` (override with `PROFILE=...`).

## 1. One‑time CDK bootstrap (per account + region)
```bash
make backend-bootstrap
# equivalently:
cd backend && npx aws-cdk@2 bootstrap --profile diprotis-dev
```

## 2. Deploy the Beta stage
```bash
make backend-deploy-beta
# equivalently:
cd backend && npx aws-cdk@2 deploy -c stage=beta --profile diprotis-dev --require-approval never --all
```
Creates the `Mango-beta` stage: **Data** (DynamoDB single‑table + S3), **Auth** (Cognito
user pool), **Ai** (Secrets Manager), **Api** (HTTP API + 5 Lambdas, least‑privilege IAM).

## 3. Set the Anthropic API key (server‑side secret)
The stack creates an empty secret; put the real key in:
```bash
aws secretsmanager put-secret-value \
  --secret-id mango/beta/anthropic-api-key \
  --secret-string '{"apiKey":"sk-ant-..."}' \
  --profile diprotis-dev
```

## 4. Read the stack outputs (API URL + Cognito ids)
`cdk deploy` prints them; to fetch again:
```bash
aws cloudformation describe-stacks --profile diprotis-dev \
  --query "Stacks[?contains(StackName,'Mango-beta')].Outputs[]" --output table
```
Note `ApiUrl`, `UserPoolId`, `UserPoolClientId`.

## 5. Verify it's live
```bash
curl https://<ApiUrl>/health        # → {"status":"ok","stage":"beta"}
```
`/health` is public; `/v1/*` routes require a Cognito JWT.

## 6. Point the app at it (later)
App → Settings → **AI engine → Mango Backend** → paste the API URL. Backend mode needs
Cognito sign‑in (not built yet — see [PRODUCT_ROADMAP.md](PRODUCT_ROADMAP.md)); until then
the deploy is validated via `/health` and exercised by CI.

## Prod
Same commands with `-c stage=prod` (RETAIN removal policies, point‑in‑time recovery,
S3 versioning). CI (`.github/workflows/backend-deploy.yml`) deploys **Beta on push to
`main`** and **Prod on a published Release** via GitHub OIDC — see [BACKEND.md](BACKEND.md)
for the deploy‑role trust policy.

## Teardown (beta only; prod is RETAIN)
```bash
cd backend && npx aws-cdk@2 destroy -c stage=beta --profile diprotis-dev --all
```
