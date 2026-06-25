# Mango Specs (spec-driven development)

We build features **spec-first**: write the spec, review it, then implement against
its acceptance criteria and verify with tests/CI. Specs are the source of truth for
*what* and *why*; code is *how*.

## Workflow

1. **Draft** a spec from the template (`SPEC_TEMPLATE.md`), numbered `NNNN-slug.md`.
2. **Review** — at least one reviewer (human or a review agent) signs off; resolve
   open decisions.
3. **Approve** — flip status to `Approved`; the acceptance criteria are now the contract.
4. **Implement** in small PRs that reference the spec; keep `shared/api/openapi.yaml`
   ⇄ DTOs ⇄ handlers in sync (see [../../CLAUDE.md](../../CLAUDE.md)).
5. **Verify** — every acceptance criterion has a test or a documented manual check;
   `make backend-test` + `make ios-test` green.
6. **Done** — flip status to `Done`, link the merged PRs.

Status values: `Draft` · `Approved` · `In progress` · `Done`. Keep specs updated as
reality changes — a stale spec is a bug.

## Index

| # | Spec | Epic | Status |
|---|---|---|---|
| 0001 | [Environments & deployment](0001-environments-and-deploy.md) | M1 | Approved (impl 🔶) |
| 0002 | [Claude-consistent UI theme](0002-claude-ui-theme.md) | M2 | In progress (impl ✅) |
| 0003 | [Authentication (Cognito + app)](0003-authentication.md) | M3 | Approved — Hosted UI |
| 0004 | [Data model + S3 data lake](0004-data-model-and-lake.md) | M4 | Draft |

See [../ROADMAP.md](../ROADMAP.md) for the full backlog and sequencing.
