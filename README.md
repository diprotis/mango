# 🥭 Mango

Turn any book into a motivating, game-like learning journey. Mango is a native
iOS reading companion that pairs a calm, Claude-inspired reading experience with
an active-learning loop — quizzes, reflections, and real-world application tasks —
wrapped in streaks, XP, levels, and badges so reading actually sticks.

This is a **monorepo**: a SwiftUI iOS app and a separately deployed AWS backend,
each with its own CI and Beta/Prod stages.

```
mango/
├── ios/                      # SwiftUI + SwiftData app (iOS 17+)
│   ├── Mango.xcodeproj       # open this in Xcode
│   ├── Mango/                # app source (design system, models, services, features)
│   ├── MangoTests/           # XCTest unit tests
│   └── project.yml           # XcodeGen spec (optional, regenerates the project)
├── backend/                  # AWS CDK (Python): API Gateway + Lambda + DynamoDB + S3 + Cognito
│   ├── mango_backend/        # CDK stacks (data, auth, ai, api) + stage
│   ├── src/                  # Lambda handlers + shared modules
│   └── tests/                # pytest suite
├── shared/api/openapi.yaml   # the iOS ⇄ backend contract
├── docs/                     # architecture, gamification, design system, roadmap, backend
└── .github/workflows/        # iOS CI, backend CI, backend deploy (Beta/Prod)
```

---

## Quick start — iOS app (works offline in ~2 minutes)

**Requirements:** macOS with **Xcode 16 or newer** (the project uses Xcode 16
file-system-synchronized groups and targets iOS 17+).

1. Open the project:
   ```bash
   open ios/Mango.xcodeproj
   ```
2. Pick an iPhone simulator (e.g. *iPhone 16*) and press **Run** (⌘R).
3. That's it. The app launches into onboarding, then a home screen with a bundled
   public-domain sample book (*Meditations*) and a ready-made gamified journey.

The app is **fully usable with no API key and no backend** — roadmaps and grading
fall back to an on-device generator (`MockAIService`). To turn on real AI:

- **Settings → AI engine → Direct Claude API**, paste an `sk-ant-…` key (stored in
  the Keychain). Roadmaps and reflection grading now come from Claude on-device.
- Or **Mango Backend** mode + a base URL once you've deployed the backend (note:
  using the deployed backend from the app needs Cognito sign-in — see the roadmap).

> If `Mango.xcodeproj` ever fails to open, regenerate it with
> [XcodeGen](https://github.com/yonsm/XcodeGen): `brew install xcodegen && cd ios && xcodegen generate`.

Run the unit tests: **⌘U**, or `make ios-test`.

---

## Quick start — AWS backend

**Requirements:** Python 3.12, Node 20+ (for the CDK CLI), and AWS credentials.

```bash
cd backend
python3 -m pip install -r requirements.txt -r requirements-dev.txt
python3 -m pytest            # 29 unit tests
npx aws-cdk@2 synth -c stage=beta
```

Deploy a stage (first time in an account needs `cdk bootstrap`):

```bash
npx aws-cdk@2 bootstrap
npx aws-cdk@2 deploy -c stage=beta --require-approval never --all
```

Then set the Anthropic key the Lambdas read from Secrets Manager:

```bash
aws secretsmanager put-secret-value \
  --secret-id mango/beta/anthropic-api-key \
  --secret-string '{"apiKey":"sk-ant-..."}'
```

See **[docs/BACKEND.md](docs/BACKEND.md)** for the architecture, the API surface,
and the GitHub OIDC deploy role.

---

## CI/CD

| Workflow | Trigger | What it does |
|---|---|---|
| `ios-ci.yml` | push/PR touching `ios/**` | `xcodebuild` build + unit tests on a macOS runner |
| `backend-ci.yml` | push/PR touching `backend/**` | black + flake8 + pytest + `cdk synth` (beta & prod) |
| `backend-deploy.yml` | push to `main` → **Beta**; published Release → **Prod** | `cdk deploy` via GitHub OIDC (no static AWS keys) |

The deploy workflow needs one repo secret, `AWS_DEPLOY_ROLE_ARN` (an IAM role that
trusts GitHub's OIDC provider). Details in `docs/BACKEND.md`.

---

## First-time git setup (one-time)

The folder isn't a git repo yet. On your Mac:

```bash
cd ~/Documents/Claude/Projects/mango
git init -b main
git add .
git commit -m "Mango v0.1 — iOS app + AWS backend monorepo"
git remote add origin https://github.com/diprotis/mango.git
git push -u origin main
```

---

## Status

**Working now:** onboarding → profile-built library, add books via web URL /
Project Gutenberg / pasted text / PDF, immersive reader, AI-generated gamified
roadmaps (mock offline, or real Claude on-device), the lesson loop (quiz /
reflection / application) with XP, levels, streaks + streak-freeze, daily goal,
achievements, and a profile with a weekly streak strip. Backend is deployable with
29 passing tests and clean synth on both stages.

**Planned next (see [docs/PRODUCT_ROADMAP.md](docs/PRODUCT_ROADMAP.md)):** Cognito
sign-in so the app can use the deployed backend, social leagues, spaced-repetition
"insight review," EPUB import, and progress sync.

> Heads-up: the earlier `read-spark-achieve` repo is private, so its code couldn't
> be pulled into this build. If you make it public (or push it here), the next pass
> can align naming/feature parity with it.

## Docs
- [Architecture](docs/ARCHITECTURE.md) · [Backend](docs/BACKEND.md) · [Design system](docs/DESIGN_SYSTEM.md) · [Gamification](docs/GAMIFICATION.md) · [Product roadmap](docs/PRODUCT_ROADMAP.md)
