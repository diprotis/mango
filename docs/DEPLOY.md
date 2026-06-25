# Backend deploy — command reference

Full procedures, testing, and CI/CD live in **[OPERATIONS.md](OPERATIONS.md)**. This is
the quick command card for the three tiers. The Cowork sandbox has no AWS
credentials — run these on a machine with the right profile.

## Tiers

| Tier | Stage | Where | Command |
|---|---|---|---|
| Personal | `dev` | your account (`diprotis-dev`) | `make backend-deploy-personal` |
| Beta | `beta` | shared (CI on push to `main`) | `make backend-deploy-beta` |
| Prod | `prod` | shared (CI on Release) | `make backend-deploy-prod` |

`make` targets default to `PROFILE=diprotis-dev` (override with `PROFILE=...`).

## Personal (dev) on your own AWS

```bash
aws sts get-caller-identity --profile diprotis-dev
cd backend && pip install -r requirements.txt
make backend-bootstrap                 # one-time per account/region
make backend-deploy-personal           # cdk deploy -c stage=dev --profile diprotis-dev
# Enable Bedrock model access (Bedrock console → Model access) for your Claude
# model in us-east-1, then set "bedrockModelId" in backend/config/dev.json.
# The backend calls Bedrock via IAM — no Anthropic API key/secret required.
aws cloudformation describe-stacks --profile diprotis-dev \
  --query "Stacks[?contains(StackName,'Mango-dev')].Outputs[]" --output table
curl https://<ApiUrl>/health           # {"status":"ok","stage":"dev"}
```

Point the app at it: **Settings → Backend → Personal → `<ApiUrl>`**.

## Beta / Prod

Normally deployed by CI (push to `main` → beta; publish a Release → prod). Manual
break-glass:

```bash
make backend-deploy-beta  PROFILE=<beta-profile>
make backend-deploy-prod  PROFILE=<prod-profile>
```

Enable Bedrock model access for your Claude model in each stage's region and set
`bedrockModelId` in `config/beta.json` / `config/prod.json` (the backend uses Bedrock
via IAM — no Anthropic key/secret). Then bake the API URLs into
`ios/Mango/Resources/AppConfig.plist` (or via the `BETA_API_URL` / `PROD_API_URL`
CI secrets). See [OPERATIONS.md](OPERATIONS.md) SOP 2–3 and [BACKEND.md](BACKEND.md)
for the GitHub OIDC deploy role.

## Teardown (dev / beta only; prod is RETAIN)

```bash
cd backend && npx aws-cdk@2 destroy -c stage=dev --profile diprotis-dev --all
```
