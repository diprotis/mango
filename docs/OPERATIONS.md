# Mango — Operations & SOPs

How to deploy, test, and ship Mango across environments. Pairs with
[DEPLOY.md](DEPLOY.md) (raw backend deploy commands) and
[RUN_ON_IPHONE.md](RUN_ON_IPHONE.md) (on-device build).

## Environments at a glance

| Environment | AWS account / profile | CDK stage | App "Backend" setting | How it deploys | Data policy |
|---|---|---|---|---|---|
| **Offline (Mock)** | none | — | `Offline (Mock)` (default) | n/a (on-device) | on-device only |
| **Personal** | your own (`diprotis-dev`) | `dev` | `Personal` + your URL | `make backend-deploy-personal` (manual) | DESTROY / auto-delete |
| **Beta** | shared beta | `beta` | `Beta` (from AppConfig.plist) | CI on push to `main` (OIDC) | DESTROY |
| **Prod** | shared prod | `prod` | `Prod` (from AppConfig.plist) | CI on GitHub **Release** (OIDC) | RETAIN + PITR + versioned |

The app defaults to **Offline** so it always runs with no network/key. Beta/Prod
URLs are baked into `ios/Mango/Resources/AppConfig.plist` (or injected by CI);
Personal is entered in **Settings → Backend → Personal**.

---

## SOP 1 — Deploy & launch to your personal AWS (`diprotis-dev`)

Use this for solo development against real AWS, isolated in your own account.

**Prerequisites**
- AWS CLI v2 with a `diprotis-dev` profile: `aws sts get-caller-identity --profile diprotis-dev`
- Node 20+, Python 3.12, and `cd backend && pip install -r requirements.txt`

**Steps**
```bash
# 1. One-time per account/region
make backend-bootstrap                       # PROFILE defaults to diprotis-dev

# 2. Deploy the dev stage into your account
make backend-deploy-personal                 # cdk deploy -c stage=dev --profile diprotis-dev

# 3. Put the Anthropic key in the dev secret
aws secretsmanager put-secret-value \
  --secret-id mango/dev/anthropic-api-key \
  --secret-string '{"apiKey":"sk-ant-..."}' --profile diprotis-dev

# 4. Get the API URL
aws cloudformation describe-stacks --profile diprotis-dev \
  --query "Stacks[?contains(StackName,'Mango-dev')].Outputs[]" --output table

# 5. Verify
curl https://<ApiUrl>/health                 # → {"status":"ok","stage":"dev"}
```

**Launch the app against it:** Settings → Backend → **Personal** → paste `<ApiUrl>`.
(See the auth note in SOP 5 — `/v1` calls need a Cognito token until the sign-in
epic lands; `/health` works today.)

**Teardown:** `cd backend && npx aws-cdk@2 destroy -c stage=dev --profile diprotis-dev --all`

---

## SOP 2 — Deploy & launch to Beta / Prod

Beta and Prod live in shared account(s) and are normally deployed by **CI** (SOP 3),
not by hand. Manual deploy is the break-glass path.

**Promotion model**
- **Beta** ← every push to `main` (CI deploys the `beta` stage).
- **Prod** ← publishing a GitHub **Release** (CI deploys the `prod` stage).

**One-time per account**
- Bootstrap each account/region (`cdk bootstrap`).
- Create the GitHub OIDC deploy role (trust policy in [BACKEND.md](BACKEND.md)) and set
  its ARN as the `AWS_DEPLOY_ROLE_ARN` repo secret.
- Put the Anthropic key in each stage's secret: `mango/beta/anthropic-api-key`,
  `mango/prod/anthropic-api-key`.
- Bake the resulting API URLs into `AppConfig.plist` (commit) **or** set the
  `BETA_API_URL` / `PROD_API_URL` repo secrets so `ios-release.yml` injects them.

**Manual (break-glass)**
```bash
make backend-deploy-beta   PROFILE=<beta-profile>
make backend-deploy-prod   PROFILE=<prod-profile>
```

**Launch the app:** Settings → Backend → **Beta** or **Prod** (URLs come from
AppConfig.plist). For TestFlight builds, `ios-release.yml` bakes the URLs and uploads.

---

## SOP 3 — CI/CD & GitHub Actions (monorepo)

One repo, path-filtered workflows so app and backend build independently.

| Workflow | Trigger | Does |
|---|---|---|
| `backend-ci.yml` | push/PR touching `backend/**` | black + flake8 + pytest + `cdk synth` (beta+prod) |
| `backend-deploy.yml` | push `main` → **beta**; Release → **prod** | `cdk deploy` via GitHub OIDC (no static keys) |
| `ios-ci.yml` | push/PR touching `ios/**` | `xcodebuild` build + unit tests on macOS runner |
| `ios-release.yml` | GitHub **Release** / manual | archive + upload to **TestFlight** (secrets-gated) |

**Required GitHub secrets**

| Secret | Used by | Notes |
|---|---|---|
| `AWS_DEPLOY_ROLE_ARN` | backend-deploy | OIDC role the workflow assumes |
| `APP_STORE_CONNECT_KEY_ID` / `_ISSUER_ID` / `_API_KEY_B64` | ios-release | App Store Connect API key (`.p8` base64-encoded) |
| `APPLE_TEAM_ID` | ios-release | 10-char team id |
| `BETA_API_URL` / `PROD_API_URL` | ios-release | optional; baked into AppConfig.plist at build |

`ios-release.yml` **no-ops safely** if the Apple secrets are absent (forks /
contributors won't see red builds). Branch strategy: feature branches → PR → `main`
(beta) → tag a Release (prod).

---

## SOP 4 — Test the front-end with mocks (offline)

The fastest loop; no network, no key, no backend.

1. Settings → Backend → **Offline (Mock)** (this is the default).
2. Run on Simulator (`make ios-test` for the unit suite) or a device
   ([RUN_ON_IPHONE.md](RUN_ON_IPHONE.md)).
3. Everything works: add books, generate a roadmap (on-device generator), do
   lessons, earn XP/streaks. Great for UI/UX iteration and demos.
4. Pure logic is covered by XCTest (LevelCurve, StreakCalculator, TextStats,
   HTMLText, DTO decoding, GamificationEngine, **APIEnvironment**).

---

## SOP 5 — Test the front-end against a real backend

Default to **Beta/Prod**; only use **Personal** when you say so.

1. Deploy a backend (SOP 1 or 2) and confirm `curl <ApiUrl>/health`.
2. In the app: Settings → Backend → pick **Prod** (default real target) or **Beta**;
   or **Personal** and paste your `dev`-stage URL. Beta/Prod URLs come from
   AppConfig.plist, so unless you choose Personal you hit the shared stacks.
3. Generate a roadmap / grade a reflection — these now call the live Lambda → Claude.

> **Auth note (current limitation, tracked as the Sign-up/Auth epic in
> [ROADMAP.md](ROADMAP.md)):** `/v1/*` routes require a Cognito JWT, and the app does
> not have sign-in yet, so real-backend AI calls will return **401** until that epic
> ships. Until then: use **Offline** or **on-device Claude key** in the app, and test
> the deployed `/v1` endpoints with a manually-minted Cognito token, e.g.
> ```bash
> aws cognito-idp admin-initiate-auth --user-pool-id <id> --client-id <id> \
>   --auth-flow ADMIN_USER_PASSWORD_AUTH \
>   --auth-parameters USERNAME=<email>,PASSWORD=<pw> --profile <profile>
> # use the returned IdToken as:  Authorization: Bearer <IdToken>
> ```
> `/health` needs no token and is the day-one smoke test.

---

## Quick reference

```bash
# Backend
make backend-test                 # pytest
make backend-synth                # cdk synth beta
make backend-deploy-personal      # dev stage → your AWS (diprotis-dev)
make backend-deploy-beta          # beta stage
make backend-deploy-prod          # prod stage

# iOS
make ios-test                     # unit tests on a simulator
make ios-open                     # open in Xcode
```
