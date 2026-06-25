# 0005 — Backend AI provider on Amazon Bedrock

- **Epic:** M3 · **Status:** In progress · **Owner:** backend · **Updated:** 2026-06-25
- **Reviewers:** orchestrator

## 1. Summary
Switch the Mango backend's AI generation/grading off the Anthropic public API and
onto **Amazon Bedrock**. The `generate_roadmap` and `grade_exercise` Lambdas now
call Claude through `bedrock-runtime:InvokeModel` using IAM auth — no API key and
no Secrets Manager dependency on the production path. Public functions in
`shared/claude.py` keep their signatures, so handlers, prompts, and existing tests
are unchanged.

## 2. Goals / Non-goals
- **Goals:** Bedrock-only backend inference via IAM; reuse the existing prompt +
  JSON-extraction code; least-privilege `bedrock:InvokeModel` on just the two AI
  Lambdas; configurable model id per stage; optional extended-thinking
  ("max effort") with a safe fallback for models that don't support it.
- **Non-goals:** iOS changes; the on-device Direct-Claude path (still uses the
  optional Anthropic key); streaming responses; per-user model selection.

## 3. Background & context
Previously `claude.py` read an API key from Secrets Manager and POSTed to
`api.anthropic.com`. Running Claude on Bedrock lets the backend authenticate with
its Lambda execution role (no shared secret to rotate/leak) and keeps traffic in
AWS. Anthropic models on Bedrock accept the same "messages" body shape, so only
the transport changes. Replaces the secret-based design noted in 0001.

## 4. User stories
- As an operator, I enable Bedrock model access once per region and set a model id
  in config — no API key to provision or rotate.
- As a developer, I run the existing pytest suite offline; Bedrock is monkeypatched.

## 5. Requirements
- **FR-1** `claude._invoke` calls `bedrock-runtime.invoke_model` with body
  `{anthropic_version:"bedrock-2023-05-31", max_tokens, system, messages, temperature}`
  and parses `content[].text` from the response.
- **FR-2** Model id comes from `BEDROCK_MODEL_ID`; region from `BEDROCK_REGION` →
  `AWS_REGION` → `us-east-1`. The runtime client is cached and monkeypatchable.
- **FR-3** When `AI_MAX_EFFORT=true`, add `thinking={type:enabled, budget_tokens:4000}`,
  force `temperature=1`, and raise `max_tokens` to fit the budget plus answer.
- **FR-4** If a max-effort invoke raises `ClientError`, retry once **without**
  thinking (restoring the caller's temperature/max_tokens); otherwise re-raise.
- **FR-5** `generate_roadmap`, `grade`, `extract_json` keep their signatures.
- **NFR:** least-privilege IAM (only roadmap/grade Lambdas get `bedrock:InvokeModel`);
  no Secrets read on the prod path; stdlib + boto3 only.

## 6. Design
- **Invoke:** `boto3.client("bedrock-runtime").invoke_model(modelId, contentType,
  accept, body=json.dumps(body))`; `json.loads(resp["body"].read())`.
- **IAM:** one `iam.PolicyStatement` (`bedrock:InvokeModel`,
  `bedrock:InvokeModelWithResponseStream`) over
  `arn:aws:bedrock:*::foundation-model/*` and
  `arn:aws:bedrock:*:*:inference-profile/*`, attached to `roadmap_fn` + `grade_fn`
  only. The two Anthropic-secret grants are removed.
- **Config:** `bedrockModelId`, `bedrockRegion`, `aiMaxEffort` in
  `config/{dev,beta,prod}.json`; surfaced as Lambda env in `api_stack.py`.
  `ANTHROPIC_SECRET_ARN` / `CLAUDE_MODEL` env removed.
- **Max-effort + fallback:** see FR-3/FR-4 — makes extended thinking safe even if
  the selected model/inference-profile lacks it.
- **AiStack:** the Anthropic secret is now OPTIONAL (Direct-Claude only); the
  `anthropic_secret` constructor param stays in `ApiStack` (unused) so `stage.py`
  is untouched.

## 7. Acceptance criteria
- [x] `claude._invoke` uses `bedrock-runtime.invoke_model`; no urllib / Secrets code.
- [x] `bedrock:InvokeModel` policy on roadmap + grade Lambdas; no Secrets read in synth.
- [x] Config carries `bedrockModelId` / `bedrockRegion` / `aiMaxEffort`.
- [x] Max-effort fallback retries once without thinking on `ClientError`.
- [x] `pytest` (existing + new Bedrock tests) green; `cdk synth -c stage=beta` exits 0.

## 8. Test plan
`tests/test_claude_bedrock.py`: a fake `_runtime` returns a canned Bedrock payload;
asserts `grade` and `generate_roadmap` parse it, and that max-effort retries once
without thinking after a `ClientError`. Existing `test_generate_roadmap` /
`test_grade_exercise` monkeypatch the public functions and stay green. CI runs
`cdk synth` for beta+prod.

## 9. Rollout & migration
1. In the Bedrock console, **enable model access** for the target Claude model in
   each stage's region.
2. Set `bedrockModelId` in `config/<stage>.json` to that model (or inference-profile)
   id; deploy. The Anthropic secret can be left empty / ignored.
   Backward-compatible: handlers/contract unchanged; no data migration.

## 10. Risks & open decisions
- **Model availability/quotas vary by region** → mitigated by configurable id +
  enabling access per region; default `anthropic.claude-3-5-sonnet-20240620-v1:0`
  is a placeholder. **Decision:** set the production id to the approved Claude
  Opus 4.8 Bedrock model/inference-profile.
- **Not every model supports extended thinking** → the `ClientError` fallback drops
  the thinking block and retries.
- **Some newer models require an inference profile ARN** rather than a bare model id
  → the IAM policy already covers `inference-profile/*`.

## 11. Tasks & estimate
- [x] Rewrite `claude.py` on Bedrock (M). — [x] Stack env + IAM (S). — [x] Config (S).
- [x] Tests + conftest (S). — [x] Docs (OPERATIONS/DEPLOY/CLAUDE) + this spec (S).
- [ ] Operator: enable Bedrock access + set the Opus 4.8 model id (you).

## 12. References
`backend/src/shared/claude.py` · `backend/mango_backend/api_stack.py` ·
[../OPERATIONS.md](../OPERATIONS.md) · [../DEPLOY.md](../DEPLOY.md) · [0001](0001-environments-and-deploy.md).
