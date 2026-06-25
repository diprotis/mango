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
aws secretsmanager put-secret-value --secret-id mango/dev/anthropic-api-key \
  --secret-string '{"apiKey":"sk-ant-..."}' --profile diprotis-dev
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

Set each stage's secret (`mango/beta|prod/anthropic-api-key`) and bake the API URLs
into `ios/Mango/Resources/AppConfig.plist` (or via the `BETA_API_URL` / `PROD_API_URL`
CI secrets). See [OPERATIONS.md](OPERATIONS.md) SOP 2–3 and [BACKEND.md](BACKEND.md)
for the GitHub OIDC deploy role.

## Teardown (dev / beta only; prod is RETAIN)

```bash
cd backend && npx aws-cdk@2 destroy -c stage=dev --profile diprotis-dev --all
```
