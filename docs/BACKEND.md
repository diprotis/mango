# Backend

The Mango backend is an AWS CDK (Python) app under `backend/`: an API Gateway
**HTTP API (v2)** fronting Python 3.12 Lambdas, backed by a single-table DynamoDB
store, an S3 content bucket, a Cognito user pool, and a Secrets Manager secret for
the Anthropic key. Everything is packaged into a deployable **Stage**
(`MangoStage`) so the same code ships to `beta` and `prod` with
environment-appropriate safety settings.

## Stacks

`MangoStage` composes four stacks (`mango_backend/stage.py`):

- **DataStack** — the DynamoDB table (single-table, `PK`/`SK` + a `GSI1` index,
  pay-per-request billing) and the S3 content bucket (public access blocked, SSL
  enforced, S3-managed encryption). In `prod` both use `RETAIN` removal policies;
  the table also enables point-in-time recovery (PITR) and the bucket enables
  versioning.
- **AuthStack** — a Cognito user pool (email sign-in, self-sign-up, email
  verification, an 8-char minimum password policy) plus an app client with SRP and
  password auth flows. It outputs `UserPoolId` and `UserPoolClientId`.
- **AiStack** — a Secrets Manager secret named `mango/<stage>/anthropic-api-key`,
  created empty; you set its value out-of-band after deploy.
- **ApiStack** — the HTTP API, the Lambda functions, the Cognito JWT authorizer,
  the routes, and least-privilege IAM grants. It outputs the `ApiUrl`.

## API endpoints

Defined in `shared/api/openapi.yaml` and wired in `api_stack.py`. All routes
except `/health` require a Cognito-issued JWT (`Authorization: Bearer <token>`).

| Method & path | Lambda | Purpose |
|---|---|---|
| `GET /health` | `health` | Liveness probe (unauthenticated); returns status + stage |
| `POST /v1/content/parse` | `content_parse` | Fetch + extract a `url`/`text`/`gutenberg` source into a normalized book, storing text in S3 |
| `POST /v1/roadmaps/generate` | `generate_roadmap` | Claude-backed roadmap; accepts an **inline book** (`book.text`) **or** a stored `bookId` |
| `POST /v1/exercises/grade` | `grade_exercise` | Grade an answer + award XP (quizzes scored deterministically; reflections/applications by Claude) |
| `GET`/`PUT /v1/me/progress` | `progress` | Read or upsert the caller's gamification progress |

## Data model (single table)

One DynamoDB table holds every entity, keyed by `PK`/`SK`:

| Entity | PK | SK | Notes |
|---|---|---|---|
| Book metadata | `BOOK#<id>` | `META` | title, author, wordCount, `contentRef` (S3 key) |
| Cached roadmap | `BOOK#<id>` | `ROADMAP` | best-effort JSON cache |
| User progress | `USER#<id>` | `PROGRESS` | totalXP, streaks, freezes, `updatedAt` |

Full book text lives in S3 at `books/<id>.txt`; the table stores only the opaque
`contentRef` pointer. A `GSI1` (`GSI1PK`/`GSI1SK`) is provisioned for future
access patterns.

## Deploy beta / prod

Requirements: Python 3.12, Node 20+ (for the CDK CLI), AWS credentials. From
`backend/`:

```bash
python3 -m pip install -r requirements.txt -r requirements-dev.txt
python3 -m pytest                       # 29 unit tests
npx aws-cdk@2 synth -c stage=beta       # clean synth for beta (and prod)
npx aws-cdk@2 bootstrap                 # first time in an account only
npx aws-cdk@2 deploy -c stage=beta --require-approval never --all
```

Swap `-c stage=prod` to deploy production. The stage is selected by CDK context
(`-c stage=…`) or `MANGO_STAGE`, and loads `config/<stage>.json`.

## Setting the Anthropic secret

The secret is created empty, so set its value after the first deploy:

```bash
aws secretsmanager put-secret-value \
  --secret-id mango/beta/anthropic-api-key \
  --secret-string '{"apiKey":"sk-ant-..."}'
```

The Lambdas read and cache it via `shared/agent.py`; the key never leaves the
server side.

## GitHub OIDC deploy role

`.github/workflows/backend-deploy.yml` deploys **Beta on every push to `main`**
and **Prod when a GitHub Release is published**, using GitHub's OIDC provider
(no long-lived AWS keys). Provide the role ARN in the repo secret
`AWS_DEPLOY_ROLE_ARN`. The role needs:

- A **trust policy** federated to GitHub's OIDC provider
  (`token.actions.githubusercontent.com`), with `sts:AssumeRoleWithWebIdentity`,
  an `sts.amazonaws.com` audience condition, and a `sub` condition restricting it
  to this repository (e.g. `repo:<owner>/<repo>:ref:refs/heads/main` and your
  release refs).
- **Permissions** to run CDK: assume the `cdk-*` bootstrap roles
  (`sts:AssumeRole`) — the modern-template path — or, equivalently, CloudFormation
  plus create/update permissions for the resources in these stacks (DynamoDB, S3,
  Lambda, API Gateway v2, Cognito, Secrets Manager, IAM, and CDK asset access).

The workflow requests `id-token: write` and `contents: read`.

## Security notes

- **SSRF guard** (`src/shared/http.py`): `fetch_url` only allows `http(s)`,
  resolves the host and refuses private, loopback, link-local, reserved,
  multicast, unspecified, or unresolvable addresses, and re-validates **every
  redirect** target so a public URL cannot bounce the fetcher to an internal one.
- **Auth gating** (`src/shared/response.py`): `user_id` reads the caller from the
  Cognito JWT claims (`sub`/`username`). The `x-mango-user` header fallback is
  permitted only in non-prod stages; in `beta`/`prod` a missing claim raises and
  the handler returns `401`.
- **Least privilege** (`api_stack.py`): each Lambda gets only what it needs — the
  parse/roadmap/progress functions get table access, the parse function read/write
  to the bucket, the roadmap function read-only on the bucket, and only the
  roadmap and grade functions can read the Anthropic secret. The grade function
  never touches the table.

See `backend/README.md` for the short command reference.
