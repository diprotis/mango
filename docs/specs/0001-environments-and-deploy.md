# 0001 — Environments & deployment

- **Epic:** M1 · **Status:** Approved (implementation 🔶) · **Updated:** 2026-06-25

## 1. Summary
A developer can run the app against Offline (Mock), their personal AWS (`dev` stage),
or shared Beta/Prod, with CI/CD deploying the backend and the app picking an
environment at runtime.

## 2. Goals / Non-goals
- **Goals:** four runtime targets; one-command deploys; CI on push/release; the app
  defaults to a real backend (Prod) when a tester turns the backend on, Personal only
  when chosen; first-run still works fully offline.
- **Non-goals:** auth (0003), per-user data sync (0004).

## 3. Background
Monorepo with `ios/` + `backend/` (CDK). Stages `dev`/`beta`/`prod`. The app talks to
one backend selected in Settings.

## 4. User stories
- As a dev, I deploy to my own AWS and point the app at it.
- As a tester, I switch the app between Beta/Prod without a rebuild.
- As a contributor, CI builds/tests both halves on every PR.

## 5. Requirements
- **FR-1** `APIEnvironment` = {mock, personal, beta, prod}; resolver returns a URL or nil. ✅
- **FR-2** Beta/Prod URLs come from `AppConfig.plist` (or CI); Personal is user-entered. ✅
- **FR-3** Default environment `mock` (offline first-run). ✅
- **FR-4** CDK `dev` stage + `make backend-deploy-personal`. ✅
- **FR-5** CI: backend-ci, backend-deploy (beta/main, prod/release), ios-ci, ios-release. ✅
- **NFR:** no third-party iOS deps; least-privilege IAM; secrets server-side. ✅

## 6. Design
Implemented in `Services/Networking/APIEnvironment.swift`, `AppSettings`,
`AIServiceProvider`, `Resources/AppConfig.plist`; backend `config/dev.json`;
`.github/workflows/*`. See [../OPERATIONS.md](../OPERATIONS.md).

## 7. Acceptance criteria
- [x] App runs offline by default; switching env changes the backend with no rebuild.
- [x] `cdk synth` passes for dev/beta/prod; backend tests green.
- [ ] Real dev+beta deployed; `/health` returns ok; URLs baked into AppConfig.plist. *(runs on your Mac)*

## 8. Test plan
`APIEnvironmentTests` (resolver) ✅; backend pytest + synth ✅; manual `/health` after deploy.

## 9. Rollout
Already in `main`. Remaining: actual deploy (SOP 1/2).

## 10. Risks & decisions
Sandbox can't deploy (no AWS creds) — deploy is a manual step. Resolved.

## 11. Tasks
- [x] Env model, dev stage, CI, SOPs. — [ ] Deploy + bake URLs (you).

## 12. References
[OPERATIONS.md](../OPERATIONS.md) · [DEPLOY.md](../DEPLOY.md) · [ROADMAP.md](../ROADMAP.md) M1.
