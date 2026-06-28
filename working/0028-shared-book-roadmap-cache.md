# 0028 — Shared per-book roadmap cache & activity templates

- **Epic:** M11 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-28
- **Reviewers:** Principal/SD/QA

> **Origin.** This spec expands the design recommended in `working/ARCHITECTURE_REVIEW.md` §2.3
> (concern #3 — "Cache per-book catalog activities, shared across users"). Read that section first;
> this is its implementation-grade build-out: the versioned template, the single-flight lock, lazy +
> batch pre-warm, the public activities page behind CloudFront, the cache-aware `generate`, and the
> personalize-on-clone boundary that resolves the 0020⇄0023 tension. It lands **with** `0009`
> (catalog expansion to 100 books) so the shelf ships warm.

## 1. Summary

Roadmap (activity-track) generation today is **per-user, asynchronous, and uncached**: 100 users who
open *Meditations* trigger 100 near-identical ~27 s Bedrock Opus generations of the same artifact —
100× the latency, 100× the cost, and (once `0023` lands) 100× the credit burn. The catalog detail
page also can't answer **"what activities does this book offer?"** without a generated artifact. This
spec introduces a **shared, versioned, per-book activity template** that is computed **once** and
**reused** across every user who opens that book. A book's full track lives in **S3**
(`templates/<bookId>/<ver>.json`); a lightweight **DynamoDB pointer** (`BOOK#<id>/ROADMAP#latest`)
plus a per-version row (`BOOK#<id>/ROADMAP#v<ver>`) index it; the **cache key** is
`sha256(promptVersion + modelId + excerptHash)` so a prompt/model/content change naturally rolls a new
version. A **single-flight lock** (a DynamoDB conditional write with `lockExpiresAt`) guarantees that
concurrent first-opens trigger **exactly one** generation. The template is populated **lazily** on the
first open of a book and proactively by a **batch pre-warm Lambda** over the `0009` catalog. A new
**public** endpoint `GET /v1/catalog/{id}/activities` (the template's `outline`) is served behind
**CloudFront** so the discovery surface is cheap and edge-cached. `POST /v1/roadmaps/generate` becomes
**cache-aware**: on a hit it **clones** the shared base into the user's job and completes
**instantly** — preserving the exact `202 {jobId}` → poll contract (**no iOS change**). Viewing and
cloning the shared base are **free**; **personalization** (`0020`/`0044`) is a thin
**personalize-on-clone** overlay that keeps the cache ~100% hot, so **only a true personalized
re-generation costs credits** (`0023`) — which resolves the cache-vs-personalization tension both of
those specs flag. This requires extending `response.ok()` to set `Cache-Control`, keeping
`shared/api/openapi.yaml` in sync, **superseding the documented-but-dead `BOOK#<id>/ROADMAP` key**,
and correcting the stale claim in `0023` §6.6 that the roadmap "is cached at `BOOK#<bookId>/ROADMAP`."
It interacts cleanly with the **agentic engine** (`0038`): the cache stores **whatever the engine
produces** (the rich multi-modal track), so this spec is engine-agnostic.

## 2. Goals / Non-goals

- **Goals:**
  - A **shared, versioned, per-book activity template**: full track JSON in S3
    (`templates/<bookId>/<ver>.json`), indexed by a DDB **pointer** (`BOOK#<id>/ROADMAP#latest`) +
    per-version rows (`BOOK#<id>/ROADMAP#v<ver>`) carrying a lightweight **`outline`** and metadata.
  - A deterministic **cache key** = `sha256(promptVersion + modelId + excerptHash)`, so a change to
    the prompt, the model id, or the book excerpt produces a **new version** (immutable per key) and
    never silently serves a stale or mismatched artifact.
  - A **single-flight lock** (DynamoDB conditional write with `lockExpiresAt`) so N concurrent
    first-opens of a cold book trigger **one** generation; a wedged/crashed generation **self-heals**
    when the lock expires.
  - **Two population paths**: **lazy** (first open of a book warms it) and a **batch pre-warm
    Lambda** that walks the `0009` 100-book catalog so the shelf ships warm.
  - A **public, edge-cached** discovery endpoint `GET /v1/catalog/{id}/activities` (the `outline`),
    fronted by **CloudFront**, with correct `Cache-Control`.
  - A **cache-aware** `POST /v1/roadmaps/generate`: on a hit, **clone** the shared base into the
    user's job and complete it **without** a Bedrock call, preserving the **exact** `202 {jobId}` →
    `GET /v1/roadmaps/jobs/{jobId}` contract (**zero iOS change required**).
  - A crisp **personalize-on-clone boundary**: viewing + cloning the shared base = **free**;
    personalization (`0020`/`0044`) is a **thin overlay** applied on clone, so the cache stays hot and
    **only a true personalized re-generation costs a credit** (`0023`). Resolve the documented
    0020⇄0023 tension.
  - Extend `response.ok()` to accept optional **headers** (so handlers can set `Cache-Control`)
    without breaking its current callers.
  - **Supersede** the documented-but-never-written `BOOK#<id>/ROADMAP` key and **correct** the stale
    `0023` §6.6 claim; update `docs/DATA_MODEL.md`.
  - Be **engine-agnostic**: the cache stores whatever `generate` produces today (the `4×2×2` roadmap)
    or what `0038` produces later (the rich track) — no schema coupling.
- **Non-goals:**
  - **Designing the agentic pipeline** (`0038`) or the **personalization math** (`0020`/`0044`). This
    spec defines *where the base is cached, how it's keyed/locked/warmed/served, and the
    clone/personalize boundary* — not how a base or an overlay is computed.
  - **The credit ledger / paywall / StoreKit** (`0023`). This spec defines **what is free vs metered**
    (view/clone free; personalized re-gen metered) and the seam; the ledger mechanics are `0023`'s.
  - **User-imported books.** The shared cache targets the **catalog** (public, popular, stable text).
    Imported books (`POST /v1/content/parse`, user-scoped, unique text, rarely shared) keep the
    **per-user** generation path unchanged; §6.10 documents the boundary and a forward option.
  - **A WAF / rate-limiter** on the public endpoint (that's `0029`); we note the dependency.
  - **Invalidating CloudFront aggressively / real-time edits** — templates are immutable per version;
    a new version = a new key/object (no in-place mutation, so no purge needed in the steady state).
  - **Moving generation off the current async worker** — the cache-miss path still calls the existing
    `roadmap_worker` (or `0038`'s state machine once it lands); we wrap, not replace.

## 3. Background & context

**As-built (verified by reading the code 2026-06-28).**
- `POST /v1/roadmaps/generate` (`backend/src/handlers/generate_roadmap.py`) resolves the book
  (`roadmap_jobs.resolve_book`: inline `book.text`, or a stored `bookId` whose text is loaded from S3,
  or a bundled-catalog entry whose `text` is inline), persists a **pending job**
  (`roadmap_jobs.create_pending`: `PK=USER#<uid>`, `SK=ROADMAPJOB#<jobId>`, carrying `book`,
  `profile`, `excerpt=full_text[:12000]`, optional `bookId`), `lambda.invoke(InvocationType="Event")`
  the worker, and returns **`202 {jobId, status:"pending"}`**. With **no** worker configured
  (local/offline e2e) it generates **inline** and creates the job already-complete — the same poll
  contract holds.
- `roadmap_worker` (`backend/src/handlers/roadmap_worker.py`) loads the job inputs and calls
  `agent.generate_roadmap(book, profile, excerpt)` — **one** `bedrock-runtime:InvokeModel` call
  (`shared/agent.py`, adaptive extended thinking, effort "medium", `max_tokens=3000` +4096 thinking
  headroom, measured ~27 s) — then `mark_complete`/`mark_failed`. 60 s Lambda budget, off the API
  Gateway 30 s path.
- The roadmap is stored **as a JSON string on the user's job row** (`roadmap_jobs.mark_complete` →
  `SET roadmap = :r` where `:r = json.dumps(roadmap)`). It is **not** in S3 and **not** shared per
  book.
- **`BOOK#<bookId>/ROADMAP` is documented but never written.** `docs/DATA_MODEL.md` lists a
  "Roadmap (cache)" item (`PK=BOOK#<bookId>`, `SK=ROADMAP`, attr `roadmap` JSON string) and access
  pattern #7 ("Read book meta / cached roadmap"), but **no handler writes or reads it**
  (`ARCHITECTURE_REVIEW.md` §1 confirms: "`BOOK#<id>/ROADMAP` … documented but never written").
  This spec **supersedes** that placeholder with the versioned `ROADMAP#latest` / `ROADMAP#v<ver>`
  design.
- The **prompt is profile-agnostic today.** `prompts.roadmap_user(book, profile, excerpt_text)` sends
  `{title, author, wordCount}` + `READER PROFILE: {json.dumps(profile)}` + the excerpt — but the
  profile is **empty until `0020`** ships population. So a per-book base is **essentially free
  quality-wise right now**: every user opening the same book gets a near-identical artifact
  (`ARCHITECTURE_REVIEW.md` §2.3). This is the linchpin that makes a shared base safe to ship before
  personalization exists.
- `shared/response.py`: `ok(body)` is **`json_response(200, body)`** — it takes **no `headers`
  kwarg** (verified). `json_response(status, body)` sets `CORS_HEADERS` (`content-type` +
  `access-control-allow-origin`). `0009` §8.4 already flagged that `ok` must be extended to set
  `Cache-Control`; this spec does it (§6.7).
- `shared/storage.py` exposes `table()`, `s3_client()`, `bucket_name()`, `lambda_client()` — the
  product bucket and the single DynamoDB table. The catalog is `shared/catalog_data.py`
  (`get_item(id)` / `list_items()`), served by `handlers/catalog.py` (public, `security: []`).
- DynamoDB **rejects Python `float`** — coerce to `int` or store JSON strings (`progress.py`,
  `generate_roadmap.py`). Lambdas are **stdlib + boto3 only** (no packaging step). Bedrock is reached
  via IAM (no key). Backend style: black (line-length 100) + flake8 (max 120).

**Why now.** Three forces converge: (1) `0009` grows the catalog to **100 books**, multiplying the
"same book, many users" pattern; (2) `0023` makes each generation **cost a credit**, so re-generating
a shared artifact per user is now a *money* leak, not just a cost leak; (3) `0038` makes a single
generation **much more expensive** (a multi-stage agent pipeline), so caching the shared base is the
difference between a viable and an unviable engine. The architecture review ranks this among the
**highest product leverage** items and sequences it **with `0009`, before `0020`**.

**The stale claims this spec corrects.** Two drafted specs assume a per-book roadmap cache **already
exists**, which is false:
- **`0020` §9/§10 (Open decisions → "Roadmap cache"):** *"today `generate_roadmap` caches the roadmap
  at `BOOK#<bookId>/ROADMAP` (book-scoped, not user-scoped)."* — **It does not** (it writes the job
  row only). 0020's decision (a) "skip the cache for personalized generations" / (b) "move the cache
  to a user+book key" is **reframed** by this spec: the shared base **is** the cache, personalization
  is a **thin overlay on clone** (so neither (a) nor (b) is needed — the base stays hot).
- **`0023` §6.6 (line 472):** *"the roadmap is cached at `BOOK#<bookId>/ROADMAP`, verified in
  `generate_roadmap.py`."* — **Both halves are false** today. This spec **makes it true** (a real
  versioned cache) and is the dependency `0023`'s completion-validation hook (§6.6 D-5) should read
  against. The `0023` text must be updated to point at `ROADMAP#latest` (§6.9 / §9 of this spec).

**Related specs.** `working/ARCHITECTURE_REVIEW.md` §2.3 (origin); `working/0009-catalog-expansion-100-books.md`
(the 100-book catalog this warms; the `Cache-Control` precedent); `working/0008-product-reframe-activity-first.md`
("Start journey" / activity-first; a roadmap = an activity track); `working/0020-feature-store-personalization.md`
(personalization consumer + the stale cache claim); `working/0023-payments-and-credits.md` (credits;
view/clone free, personalized re-gen metered; the stale §6.6 claim); `working/0027-generation-artifact-store-observability.md`
(S3 artifact layout + LLM observability — this spec's `templates/` prefix is a sibling of 0027's
`books/<bookId>/` content; the single-flight metrics ride 0027's observability); `working/0038-agentic-roadmap-engine.md`
(§6.6 / FR-9 — "cache hit clones the base + runs only the Personalizer; a miss runs the full pipeline
once under 0028's single-flight lock and populates the base"; the cache stores the rich track);
`working/0044-personalization-recommendation-engine.md` (the overlay that keeps the cache hot;
"recommendations are free, only a true personalized re-generation costs a credit").

## 4. User stories

- As the **100th reader to open *Meditations***, my activity track appears **near-instantly** because
  the shared base was generated once and cached — I don't wait ~27 s for a fresh Bedrock call, and
  (under `0023`) I'm **not charged a credit** to view it.
- As a **browser on the catalog detail page**, I can see **"what activities this book offers"** (an
  outline of milestones/activity kinds) **before** I commit to starting — served fast from the edge.
- As **Mango (the business)**, a popular book costs **one** Bedrock generation, not one-per-user — so
  Bedrock spend scales with the **catalog size**, not with **traffic**, and credits aren't burned
  re-deriving identical artifacts.
- As an **engaged learner who wants it tailored to me**, I can pay a credit for a **personalized**
  track (`0020`/`0044`); the shared base is still the starting point, so the personalization is fast
  and the base cache stays hot for everyone else.
- As an **operator shipping the 100-book catalog (`0009`)**, I run a **pre-warm** job so the whole
  shelf is warm on launch day and the first 100 users never hit a cold generation.
- As an **on-call engineer**, when two users open the same cold book at the same moment, exactly
  **one** generation runs; if that generation crashes, the lock **expires** and the next open
  re-triggers it — no book is wedged forever.
- As an **offline / first-run user**, none of this is on my path: the bundled sample + `MockAIService`
  still generate locally with **no** network, key, or cache (the offline-first invariant holds).

## 5. Requirements

### 5.1 Functional
- **FR-1 (versioned template store).** A catalog book's full activity track is stored in **S3** at
  `templates/<bookId>/<ver>.json` (immutable once written). DynamoDB carries a **pointer**
  `BOOK#<bookId>/ROADMAP#latest` (the current `ver`, the `cacheKey`, the S3 `ref`, and a lightweight
  `outline`) and a **per-version** row `BOOK#<bookId>/ROADMAP#v<ver>` (same fields, immutable). The
  full track is **never** stored as a DDB attribute (dodging the 400 KB item limit; the rich `0038`
  track can be large).
- **FR-2 (cache key).** The version's identity is `cacheKey = sha256(promptVersion + "|" + modelId +
  "|" + excerptHash)` where `excerptHash = sha256(excerpt[:12000])`, `promptVersion` is a constant
  bumped whenever the prompt/engine semantics change, and `modelId` is the Bedrock model id. A
  generate request **reuses** the latest version **iff** its `cacheKey` matches `ROADMAP#latest`;
  otherwise it is a **miss** (generate a new version). Keys are recorded so a hit is provable.
- **FR-3 (single-flight lock).** On a miss, a generation acquires a **lock** via a conditional
  `UpdateItem` on a `BOOK#<bookId>/ROADMAPLOCK` item (`attribute_not_exists(lockOwner) OR lockExpiresAt
  < now`). The winner generates; concurrent losers **do not** generate — they **poll** the pointer
  (or, in the cache-aware generate path, attach their job to the in-flight result). `lockExpiresAt`
  (now + `LOCK_TTL`, default **120 s**, comfortably above the ~27 s p50 and below a user's patience)
  guarantees a crashed generation **self-heals**: the lock expires and the next request re-acquires.
- **FR-4 (lazy population).** The **first** request that misses (a generate, or the public activities
  endpoint with `?generate=1` — see FR-7) triggers exactly one generation (under the lock), writes
  `templates/<bookId>/<cacheKey-ver>.json` + the two DDB rows, and serves the result.
- **FR-5 (batch pre-warm).** A **pre-warm Lambda** (`handlers/roadmap_prewarm.py`) iterates the
  `0009` catalog (`catalog_data.list_items()`), and for each book whose `ROADMAP#latest` is **absent
  or stale** (cacheKey mismatch), enqueues generation (respecting the single-flight lock so it never
  double-generates a book a user just warmed). It is **idempotent**, **rate-polite** (bounded
  concurrency / paced invokes to stay within Bedrock throttle limits), and **resumable** (re-running
  only fills gaps). Invoked manually (`make roadmap-prewarm`) and/or on a schedule (EventBridge).
- **FR-6 (cache-aware generate — clone on hit).** `POST /v1/roadmaps/generate` for a **catalog**
  `bookId`:
  - **Hit** (`ROADMAP#latest.cacheKey` matches and is not locked): **clone** the shared base into a
    new user job — create the job **already `complete`** with the base track (loaded from S3),
    stamped `bookId` + `fromCache: true` + the source `ver`. Return **`202 {jobId, status:"pending"}`**
    exactly as today; the client's **first poll** sees `complete`. **No Bedrock call. No credit
    (`0023`).** (Personalization, if requested, is the overlay in FR-9.)
  - **Miss**: acquire the lock and run the existing generation path (worker invoke, or `0038`'s state
    machine once it lands); on completion, **write the shared base** (FR-1) **and** complete the
    user's job from it. Losers of the lock race attach to the same forthcoming base.
  - **Inline `book.text` with no catalog `bookId`** (imported/ad-hoc): **unchanged** per-user path
    (no shared cache — §6.10).
  - The **request/response contract is byte-identical** to today (`202 {jobId}` → poll). **No iOS
    change is required.**
- **FR-7 (public activities endpoint).** `GET /v1/catalog/{id}/activities` (public, `security: []`)
  returns the book's **`outline`** (the lightweight "what activities are possible" view: journey
  title/summary + per-milestone titles + activity-kind counts) from `ROADMAP#latest`. If the book is
  **not yet warmed**, return **`200`** with `{ "status": "pending", "outline": null }` (and, behind a
  config flag, **kick off** lazy population — never block the response on generation). The response
  carries a `Cache-Control` header (FR-10) and is served through **CloudFront** (FR-8).
- **FR-8 (CloudFront).** The public, cacheable GETs (`/v1/catalog`, `/v1/catalog/{id}`,
  `/v1/catalog/{id}/activities`) are fronted by an **Amazon CloudFront** distribution over the HTTP
  API, caching by URL (including query string for `/v1/catalog`) and honoring origin `Cache-Control`.
  Authenticated routes either bypass the cache (no-store) or are not routed through the caching
  behavior. (WAF/rate-limiting on this surface is `0029`.)
- **FR-9 (personalize-on-clone boundary).** Cloning the shared base is **free**. When a user requests
  **personalization** (`0020`/`0044`) and the active engine supports it, a **thin overlay** is applied
  **on clone** (reorder/select/difficulty/modality emphasis — *not* an in-prompt regeneration), which
  keeps the base cache **~100% hot**. **Only** a **true personalized re-generation** (a distinct
  personalized cacheKey, when explicitly requested and the overlay is insufficient) runs Bedrock and
  **costs a credit** (`0023`). v1 (before `0020`/`0038`) applies a **no-op overlay** (clone = base),
  so everything is free and the boundary is established but inert.
- **FR-10 (`Cache-Control` via `response.ok`).** Extend `shared/response.ok` to accept an **optional
  `headers` mapping** merged over `CORS_HEADERS`, so the public catalog/activities handlers set
  `Cache-Control: public, max-age=86400` (consistent with `0009` §8.4). **All existing `ok(body)`
  callers keep working unchanged** (the kwarg defaults to none).
- **FR-11 (supersede the dead key + fix stale claims).** Remove the `BOOK#<bookId>/ROADMAP` "Roadmap
  (cache)" row from `docs/DATA_MODEL.md` (replace with `ROADMAP#latest` / `ROADMAP#v<ver>` /
  `ROADMAPLOCK`), update access pattern #7, and **correct** `0023` §6.6 (line 472) to reference the
  real cache. Keep `shared/api/openapi.yaml` ⇄ handlers in sync.
- **FR-12 (engine-agnostic storage).** The cache stores the **opaque** track JSON `generate` produces
  — the `4×2×2` roadmap today, the rich `0038` track later — with no field-level coupling. The
  `outline` is **derived** from whatever track shape is present (a small projector that tolerates both
  the legacy `milestones[].lessons[].exercises[]` and the `0038` `milestones[].lessons[].activities[]`
  shapes).

### 5.2 Non-functional
- **NFR-1 (offline-first preserved).** First launch with the bundled sample + `MockAIService` needs
  **no** network, key, or cache. The shared cache is a **backend** concept (the `RemoteAIService`
  path); Mock/Direct generate locally as today.
- **NFR-2 (float-free).** Every DDB attribute written here is a **string or int** (`ver:int`,
  timestamps/keys/refs as strings, `outline` as a **JSON string** to be safe). No `float` ever
  reaches DynamoDB (invariant). The full track lives in S3, not DDB.
- **NFR-3 (single-flight correctness).** Under N concurrent cold opens, **exactly one** Bedrock
  generation runs (the lock is an atomic conditional write); a lock holder that dies frees the book
  within `LOCK_TTL`. No request returns a partially-written template (the pointer flips to a version
  **only after** the S3 object is durably written).
- **NFR-4 (latency).** A **cache hit** completes the user's job with a single S3 read + DDB writes
  (target the job visible as `complete` on the **first** poll, ≤ ~300 ms server-side). A **miss** is
  bounded by the existing generation (~27 s today; `0038`'s budget later). The public activities GET
  is **edge-cached** (CloudFront) → single-digit-ms for warm hits.
- **NFR-5 (cost).** Bedrock generations per book trend toward **one per (promptVersion, modelId,
  excerpt)** version, not one-per-user. Pre-warm bounds the launch-day burst. The public endpoint is
  edge-cached so discovery traffic doesn't hit Lambda. Token/cost per generation is logged via the
  `0027` observability hooks; a budget alarm is `0032`.
- **NFR-6 (security / privacy).** Templates are derived **only** from public-domain catalog text +
  the public prompt — **no user data**, so `templates/` is **not** user-scoped and is **not** purged
  by `DELETE /v1/me` (correct: it's shared, non-personal content, like `books/<id>.txt`). The user's
  **clone** lives on their job row (`USER#<sub>/ROADMAPJOB#…`), which **is** purged by account
  deletion. The public endpoint exposes only non-sensitive book metadata + an activity outline.
- **NFR-7 (backend style/runtime).** stdlib + boto3 only; `sha256` from `hashlib` (stdlib); black
  (100) + flake8 (120); `pytest` (moto) + `cdk synth -c stage=beta` both pass **offline** (Bedrock
  monkeypatched, S3/DDB on moto, no live CloudFront).
- **NFR-8 (least privilege).** The pre-warm Lambda and the generate/worker path get table + product
  bucket read/write for the `templates/` prefix and the `ROADMAP*` items; `grade_fn` stays table-less
  (invariant). CloudFront's origin access is read-through to the existing public API.
- **NFR-9 (idempotency / no double-write).** Writing a version is keyed by `cacheKey`; re-running a
  generation for the same key **overwrites the same S3 object** (idempotent) and re-points
  `ROADMAP#latest` to the same `ver` — never appends duplicate versions for an identical key.

## 6. Design

### 6.1 Data model (single table — supersedes the dead `BOOK#<id>/ROADMAP`)

All new items live on the **existing** product table (`PK`/`SK` strings; no new infra). They are
**book-scoped** (`PK=BOOK#<bookId>`), **not** user-scoped.

| Entity | PK | SK | Key attributes |
|---|---|---|---|
| **Template pointer** | `BOOK#<bookId>` | `ROADMAP#latest` | `ver:int`, `cacheKey:str`, `ref:str` (S3 key `templates/<bookId>/<ver>.json`), `outline:str` (JSON), `promptVersion:str`, `modelId:str`, `excerptHash:str`, `engine:str` (`legacy`\|`agentic`), `createdAt`, `updatedAt` |
| **Template version** | `BOOK#<bookId>` | `ROADMAP#v<ver>` | same as the pointer (immutable snapshot of that version) |
| **Single-flight lock** | `BOOK#<bookId>` | `ROADMAPLOCK` | `lockOwner:str` (a jobId/uuid), `lockExpiresAt:int` (epoch seconds), `cacheKey:str` (the key being generated), `acquiredAt` |

- **Why a pointer + version rows (not one item):** the pointer is the **fast read** ("what's the
  current template?"); version rows give an **immutable history** (roll back, audit, A/B a
  promptVersion) and let `cacheKey` uniqueness be enforced per version. The **full track is in S3**
  (`ref`), so DDB items stay small and float-free (the `outline` is a compact JSON **string**).
- **`outline` (the public "what activities are possible" view)** — derived from the track:
  ```json
  { "title": "...", "summary": "...",
    "milestones": [ { "title": "...", "activityKinds": { "quiz": 2, "reflection": 1, "application": 1 } } ],
    "activityCount": 16, "estimatedMinutes": 90, "ver": 3 }
  ```
  Small enough to live on the DDB pointer (well under the item limit) and to edge-cache cheaply.
- **`ROADMAPLOCK` TTL:** `lockExpiresAt` is also the table's **TTL attribute** so dead locks are
  reaped by DynamoDB even if no request revisits the book (belt-and-suspenders; the conditional
  `lockExpiresAt < now` is the live correctness gate).
- **Float-free:** `ver` and `lockExpiresAt` are `int`; everything else is a `str` (the `outline` is a
  JSON **string**). Nothing here is ever a Python `float`.

**`docs/DATA_MODEL.md` change (FR-11):** replace the "Roadmap (cache) | `BOOK#<bookId>` | `ROADMAP`"
row with the three rows above; update access pattern #7 to "Read book meta / **current template
pointer**: `GetItem` on `BOOK#<bookId>` / `META` \| `ROADMAP#latest`."

### 6.2 Cache key & versioning

```python
# shared/roadmap_cache.py
import hashlib

PROMPT_VERSION = "rm-2026-06"   # bump on any prompt/engine semantic change

def excerpt_hash(excerpt: str) -> str:
    return hashlib.sha256(excerpt[:12000].encode("utf-8")).hexdigest()

def cache_key(prompt_version: str, model_id: str, excerpt: str) -> str:
    basis = f"{prompt_version}|{model_id}|{excerpt_hash(excerpt)}"
    return hashlib.sha256(basis.encode("utf-8")).hexdigest()
```
- **`promptVersion`** is owned here (a module constant); `0038` bumps it when the engine changes shape
  so old caches roll forward cleanly. **`modelId`** is `os.environ["BEDROCK_MODEL_ID"]` (a model swap
  rolls a new version). **`excerptHash`** ties the cache to the exact text basis (a re-curated catalog
  text → new version). Because the prompt is **profile-agnostic** today (§3), the key intentionally
  **omits** the profile — that's what makes the base *shared*. Personalization is an **overlay**
  (§6.6), not part of the base key.
- **`ver`** is a monotonically increasing int per book (read the current pointer's `ver`, write
  `ver+1`). A `cacheKey` that already equals `ROADMAP#latest.cacheKey` is a **hit** (no new ver).

### 6.3 Single-flight lock (cache stampede prevention)

```python
# shared/roadmap_cache.py  (logic; handlers stay thin)
def acquire_lock(book_id: str, owner: str, key: str, ttl_s: int = 120) -> bool:
    now = int(time.time())
    try:
        table().update_item(
            Key={"PK": f"BOOK#{book_id}", "SK": "ROADMAPLOCK"},
            UpdateExpression="SET lockOwner=:o, lockExpiresAt=:e, cacheKey=:k, acquiredAt=:a",
            ConditionExpression="attribute_not_exists(lockOwner) OR lockExpiresAt < :now",
            ExpressionAttributeValues={":o": owner, ":e": now + ttl_s, ":k": key,
                                       ":a": _now_iso(), ":now": now},
        )
        return True
    except table().meta.client.exceptions.ConditionalCheckFailedException:
        return False     # someone else is generating this book right now
```
- The **winner** generates and, on success, writes the version (§6.4) and **releases** the lock
  (delete the item, or let it expire). **Losers** do **not** call Bedrock. In the cache-aware generate
  path they create their job in `pending` and the worker/poller resolves it from the **forthcoming**
  pointer (the worker checks the pointer before generating; if the winner has populated it, the loser
  **clones** instead of generating). This is the textbook **single-flight / request-coalescing /
  cache-stampede** pattern (one origin recompute, many waiters) applied to a Bedrock origin.
- **Self-healing:** a crashed winner leaves a lock with a past `lockExpiresAt`; the next request's
  conditional write succeeds (`lockExpiresAt < now`) and re-generates. No book wedges permanently.
- **`LOCK_TTL` choice:** 120 s > the ~27 s p50 generation (head-room for tail latency) and < typical
  user patience; tune per `0038`'s longer pipeline (its per-stage timeouts bound the worst case).

### 6.4 Writing a template version (atomic-enough)

```python
def put_version(book_id: str, key: str, track: dict) -> int:
    ver = _next_ver(book_id)                                   # current latest.ver + 1
    ref = f"templates/{book_id}/{ver}.json"
    s3_client().put_object(Bucket=bucket_name(), Key=ref,      # 1) durable full track FIRST
                           Body=json.dumps(track).encode("utf-8"),
                           ContentType="application/json")
    outline = build_outline(track, ver)                        # small projection (§6.1)
    item = {"PK": f"BOOK#{book_id}", "cacheKey": key, "ref": ref, "ver": ver,
            "outline": json.dumps(outline), "promptVersion": PROMPT_VERSION,
            "modelId": os.environ.get("BEDROCK_MODEL_ID", ""), "excerptHash": "...",
            "engine": _engine_tag(), "updatedAt": _now_iso(), "createdAt": _now_iso()}
    table().put_item(Item={**item, "SK": f"ROADMAP#v{ver}"})   # 2) immutable version row
    table().put_item(Item={**item, "SK": "ROADMAP#latest"})    # 3) flip the pointer LAST
    return ver
```
- **Order matters:** the S3 object is written **before** the pointer flips, so a reader that sees
  `ROADMAP#latest` can always load `ref`. The version row precedes the pointer for the same reason.
- **Idempotent on key:** if `track` is regenerated for the same `cacheKey`, the S3 key is the same
  `ver` and the writes overwrite — no duplicate versions.

### 6.5 Cache-aware generate flow (FR-6) — contract-preserving

```
POST /v1/roadmaps/generate {bookId | book.text, profile}
  └─ resolve_book(body)                                   # existing helper (inline | bookId | catalog)
  └─ is this a CATALOG bookId?  ── no ─▶  [unchanged per-user path]  (inline/imported — §6.10)
                                └─ yes ─▶  key = cache_key(PROMPT_VERSION, modelId, excerpt)
       ┌─ ROADMAP#latest.cacheKey == key  AND not locked? ─ HIT ─┐
       │     clone base from S3 → create job ALREADY complete    │
       │     (fromCache:true, ver), [apply overlay if personalized & supported]
       │     return 202 {jobId, status:"pending"}   ← first poll = complete, NO Bedrock, NO credit
       └─ MISS ─▶ acquire_lock(book_id, jobId, key)
                     ├─ won  ─▶ create pending job; invoke worker (or 0038 SFN)
                     │            worker generates → put_version(...) → mark_complete(clone)
                     │            release lock
                     └─ lost ─▶ create pending job; worker, on run, re-checks the pointer:
                                  pointer now matches → CLONE (no Bedrock); else brief backoff/poll
       return 202 {jobId, status:"pending"}   (identical shape in every branch)
```
- The **only** new server logic is the `bookId`-is-catalog branch; the inline/imported branch and the
  `202 {jobId}` → poll contract are **untouched**. The iOS `RoadmapGenerator` + job polling need **no
  change** (`0008` §6.7 and `0038` FR-7 both require this contract be preserved — honored).
- **Worker change:** before calling Bedrock, the worker (a) checks `ROADMAP#latest` for a key match
  (a loser who lost the race finds the base already there → clone), else (b) generates, writes the
  version, and clones into its job. This makes the worker the single place that calls Bedrock, so the
  lock + pointer fully serialize generation.

### 6.6 Personalize-on-clone boundary (resolves 0020 ⇄ 0023)

```
            ┌─────────────────────────── FREE ───────────────────────────┐
 view outline (public) ─▶ clone shared base ─▶ [thin overlay: reorder/select/difficulty/modality]
            └───────────────────────────────────────────────────────────┘
                                                           │
                                  (overlay insufficient & explicitly requested)
                                                           ▼
                                       TRUE personalized re-generation ── COSTS A CREDIT (0023)
                                       (distinct personalized cacheKey; Bedrock call)
```
- **Free:** viewing the activities outline and **cloning** the shared base into a user's journey. This
  is what 99% of users get, and it keeps the base cache **~100% hot**.
- **Overlay (free, thin):** `0020` features + `0044` recommendations are applied **on the clone**
  (`0038`'s **Personalizer** stage / `0044`'s overlay output) — reorder/select activities, set a
  difficulty target, choose modality emphasis. This is **not** an in-prompt Bedrock regeneration, so
  it doesn't invalidate the shared base. (`0044` §6.6/§6.7 and `0038` FR-5/FR-9 specify exactly this;
  `0044` line 322: *"Recommendations are free … only a true personalized re-generation in 0038 costs a
  credit."*)
- **Metered:** a **true personalized re-generation** (when a user explicitly wants a from-scratch
  tailored track and the overlay can't express it) computes a **distinct personalized cacheKey**
  (basis includes a personalization digest), runs Bedrock, and **costs a credit** (`0023`). Its output
  may be cached **per-user** (`USER#<sub>/ROADMAP#<bookId>#<pKey>`), not in the shared `BOOK#`
  namespace — so it never pollutes the shared base.
- **This is the resolution `0020` §10 was missing:** instead of "skip the cache for personalized
  generations" (a) or "move the cache to a user+book key" (b), the **shared base is always the
  cache**, personalization rides as an overlay, and only the rare true re-gen leaves the cache — so
  the base stays maximally shared **and** personalization is supported. `0020`'s `PERSONALIZE_ROADMAP`
  flag still gates whether the overlay runs at all.

### 6.7 `shared/response.py` change (FR-10)

Extend `ok` to accept optional headers, **backward-compatibly**:
```python
def json_response(status: int, body, headers: dict | None = None) -> dict:
    hdrs = dict(CORS_HEADERS)
    if headers:
        hdrs.update(headers)
    return {"statusCode": status, "headers": hdrs, "body": json.dumps(body)}

def ok(body, headers: dict | None = None) -> dict:
    return json_response(200, body, headers)
```
- **Every existing `ok(body)` / `json_response(status, body)` call keeps working** (the new param
  defaults to `None`). The catalog/activities handlers pass
  `headers={"Cache-Control": "public, max-age=86400"}`. This is the change `0009` §8.4 explicitly
  deferred ("verify the `ok` signature … extend it or build the response dict inline") — done here so
  both specs share one mechanism.

### 6.8 API / contract (keep `shared/api/openapi.yaml` in sync)

**New public path** (mirrors the existing `/v1/catalog/{id}`, `security: []`):
```yaml
  /v1/catalog/{id}/activities:
    get:
      summary: Public activity outline (what activities this book's journey offers)
      description: >
        Returns the shared, cached activity outline for a catalog book (milestones +
        activity-kind counts). Served via CloudFront. If the book is not yet warmed,
        returns 200 with status "pending" and a null outline (generation may be kicked
        off lazily; the response never blocks on it).
      security: []
      parameters:
        - { name: id, in: path, required: true, schema: { type: string } }
      responses:
        "200":
          description: Activity outline (or pending)
          headers:
            Cache-Control: { schema: { type: string }, description: "public, max-age=86400" }
          content:
            application/json:
              schema: { $ref: "#/components/schemas/ActivityOutline" }
        "404": { description: Unknown catalog id }
```
**New component schema:**
```yaml
    ActivityOutline:
      type: object
      properties:
        status:    { type: string, enum: [ready, pending] }
        ver:       { type: integer, nullable: true }
        title:     { type: string, nullable: true }
        summary:   { type: string, nullable: true }
        activityCount:    { type: integer, nullable: true }
        estimatedMinutes: { type: integer, nullable: true }
        milestones:
          type: array
          items:
            type: object
            properties:
              title: { type: string }
              activityKinds:
                type: object
                additionalProperties: { type: integer }   # e.g. {"quiz":2,"reflection":1}
```
- **`/v1/roadmaps/generate`** keeps its **`202 {jobId}` / `RoadmapJob`** contract **unchanged**
  (FR-6); the only documentation delta is a note that a catalog hit completes from cache (and, under
  `0023`, costs no credit). **`RoadmapJob`** gains an optional, additive `fromCache: boolean` for
  observability (lenient decode; absent → false) — no breaking change.
- **iOS DTOs:** add an `ActivityOutlineDTO` (lenient `init(from:)`, mirroring
  `CatalogBook.swift`'s tolerant decode) **only if** the iOS catalog detail surfaces the outline
  (optional UI — see §6.9); the generate/poll DTOs are **unchanged**. No iOS change is required for the
  cache itself.

### 6.9 iOS (optional, additive — no required change)

The cache is **server-side and contract-preserving**, so iOS works unchanged. Two **optional**
enhancements (defer to `0011`/`0009` UI work, not required for this spec's ACs):
- **Catalog detail "Activities" preview:** call `GET /v1/catalog/{id}/activities` and render the
  outline (milestone titles + kind counts) as a "what you'll do" teaser before **Start journey**. Uses
  `Palette`/`Typo`/`Metrics` tokens; falls back to nothing when `status: "pending"`.
- **Instant-start affordance:** because a warm book completes on the first poll, the "generating…"
  spinner is effectively skipped — no code change, just a faster perceived flow.

### 6.10 Boundary: imported / inline books (no shared cache)

User-imported books (`POST /v1/content/parse` → `BOOK#<id>/META` + `books/<id>.txt`, user-scoped) and
ad-hoc inline `book.text` generations keep the **per-user** path **unchanged**: unique text, rarely
shared across users, and (for inline) no stable `bookId` to key on. The cache-aware branch (§6.5)
**only** engages for **catalog** `bookId`s. A **forward option** (not built here): hash imported text
to a content-addressed key so two users importing the *same* file share a base — deferred (privacy +
low hit-rate; revisit if telemetry shows duplicate imports).

### 6.11 CDK / infra (`api_stack.py` + a CloudFront distribution)

- **Pre-warm Lambda** via `make_fn`: `roadmap_prewarm_fn` (`handlers.roadmap_prewarm.handler`) with
  `table.grant_read_write_data(...)` + bucket read/write **scoped to `templates/*`** and read on
  catalog; optional **EventBridge** schedule (e.g. nightly) and a manual-invoke path
  (`make roadmap-prewarm`). Bounded concurrency / paced invokes to respect Bedrock throttles.
- **Generate/worker grants:** the existing `roadmap_fn` / worker already have table + bucket
  read/write (same grants); they additionally read/write `templates/*` and the `ROADMAP*` items — the
  **same** table/bucket grant, so **no new principal-level grant** beyond confirming the bucket policy
  allows the `templates/` prefix. `grade_fn` stays **table-less** (invariant).
- **CloudFront** distribution fronting the HTTP API:
  - A **caching behavior** for `GET /v1/catalog*` (path pattern) that **caches by URI + query string**
    and **respects origin `Cache-Control`** (so `max-age=86400` is honored at the edge).
  - A **no-cache / pass-through behavior** for everything else (authenticated routes) — `Authorization`
    forwarded, `Cache-Control: no-store` on those origin responses (unchanged).
  - Origin = the API Gateway HTTP API domain. TLS at the edge; HTTP/2/3. (WAF attaches to the
    **CloudFront** distribution if/when `0029` adds it — note that **WAF cannot attach to HTTP API v2
    directly**, so CloudFront is also the future WAF mount point.)
- **No new tables/buckets.** Templates reuse the **product** S3 bucket (sibling of `books/<id>.txt`);
  the cache items reuse the **single** DynamoDB table.

### 6.12 Diagrams

```
[populate]  generate (miss) ──acquire ROADMAPLOCK──▶ worker/0038 ──Bedrock──▶ track
                                                          └─ put templates/<id>/<ver>.json (S3)
                                                          └─ put ROADMAP#v<ver> + flip ROADMAP#latest (DDB)
                                                          └─ release lock
            pre-warm Lambda ──for each catalog book whose latest is stale──▶ (same path, single-flight)

[serve — generate]  user A ─POST generate(bookId)─▶ HIT (latest.cacheKey==key) ─▶ clone S3 base
                                                     ─▶ job already complete ─▶ 202 {jobId} ─▶ poll=complete
                    user B (same book, same instant) ─▶ MISS+lost lock ─▶ clone once winner populates pointer

[serve — discovery]  iOS / web ─GET /v1/catalog/{id}/activities─▶ CloudFront (edge cache, 24h)
                                                                    └─(miss)─▶ API ─▶ ROADMAP#latest.outline
```

## 7. Acceptance criteria

- [ ] **AC-1 (versioned template written).** A cold catalog-book generation writes
  `templates/<bookId>/<ver>.json` (full track) **and** `BOOK#<bookId>/ROADMAP#v<ver>` +
  `BOOK#<bookId>/ROADMAP#latest` (pointer with `cacheKey`, `ref`, `outline`, `ver`); the full track
  is **not** stored as a DDB attribute. *(pytest, moto + monkeypatched Bedrock.)*
- [ ] **AC-2 (cache key correctness).** `cache_key` is stable for identical `(promptVersion, modelId,
  excerpt)` and changes when **any** of the three changes; `excerpt_hash` truncates at 12 000 chars.
  *(pure unit test, no AWS.)*
- [ ] **AC-3 (cache hit clones, no Bedrock, no credit).** A second `generate` for the same warm
  `bookId` whose `cacheKey` matches creates a job **already `complete`** carrying the base track,
  returns `202 {jobId}`, and **does not** call `agent.generate_roadmap` (monkeypatched to raise if
  called); under `0023` it spends **no** credit. *(pytest asserts Bedrock not invoked + first poll =
  complete.)*
- [ ] **AC-4 (single-flight under concurrency).** Two simultaneous generations for the **same cold**
  book result in **exactly one** Bedrock call; the loser **clones** the winner's base; both jobs end
  `complete` with the **same** `ver`. *(pytest simulates the lock race; asserts call count == 1.)*
- [ ] **AC-5 (lock self-heals).** With a `ROADMAPLOCK` whose `lockExpiresAt` is in the past, a new
  generation **re-acquires** the lock and generates; a fresh (unexpired) lock **blocks** a second
  generation. *(pytest on `acquire_lock`.)*
- [ ] **AC-6 (lazy + idempotent version writes).** Re-running generation for an **identical**
  `cacheKey` overwrites the same `templates/<id>/<ver>.json` and re-points `latest` to the same `ver`
  (no duplicate version). *(pytest.)*
- [ ] **AC-7 (pre-warm walks the catalog, idempotent).** The pre-warm Lambda warms every catalog book
  with an absent/stale `latest`, **skips** already-warm books, and is safe to re-run (only fills gaps);
  it respects the single-flight lock. *(pytest over a fixture catalog with Bedrock counted.)*
- [ ] **AC-8 (public activities endpoint).** `GET /v1/catalog/{id}/activities` returns the
  `ActivityOutline` from `ROADMAP#latest` with `Cache-Control: public, max-age=86400`; an unwarmed
  book returns `200 {status:"pending", outline:null}`; an unknown id returns `404`. *(pytest +
  contract assertion.)*
- [ ] **AC-9 (`ok` headers, backward-compatible).** `ok(body)` still returns the legacy shape;
  `ok(body, headers={...})` merges headers over `CORS_HEADERS`. **All existing `ok`/`json_response`
  callers compile and pass unchanged.** *(unit test + full existing suite green.)*
- [ ] **AC-10 (generate contract unchanged).** Every `generate` branch (hit / miss-won / miss-lost /
  inline) returns **`202 {jobId, status}`** and the job is pollable via `GET /v1/roadmaps/jobs/{id}`;
  the **iOS DTOs/flow are untouched** (the optional `fromCache` decodes leniently; absent → false).
  *(pytest contract test + iOS DTO decode test.)*
- [ ] **AC-11 (personalize-on-clone boundary).** With personalization **off/absent** (v1), clone ==
  base and **no** credit is charged; the seam for a **true personalized re-gen** (distinct cacheKey →
  Bedrock → credit) is present and unit-tested as a no-op overlay. *(pytest; the metered path is
  exercised fully under `0023`/`0038`.)*
- [ ] **AC-12 (float-free + Decimal-safe).** Every persisted cache attribute is `str`/`int` (a
  `Decimal` round-trips to `int`); the full track is JSON in S3, never a DDB attribute. *(pytest
  mirrors `test_progress_coerces_float_to_int`.)*
- [ ] **AC-13 (supersede + fix stale claims).** `docs/DATA_MODEL.md` no longer lists `BOOK#<id>/ROADMAP`
  and documents `ROADMAP#latest`/`ROADMAP#v<ver>`/`ROADMAPLOCK`; `0023` §6.6 (line 472) is corrected to
  reference the real cache; `openapi.yaml` ⇄ handlers in sync; `cdk synth -c stage=beta` passes
  (routes, pre-warm Lambda, CloudFront distribution). *(doc grep + synth.)*
- [ ] **AC-14 (offline-first preserved + no user-data in templates).** Mock/Direct paths never touch
  the cache; `DELETE /v1/me` does **not** delete `templates/*` (shared, non-personal) but **does**
  delete the user's job clones. *(manual + pytest on the deletion scope.)*

## 8. Test plan

**Backend — `pytest` (moto; Bedrock monkeypatched), new files under `backend/tests/`:**
- `test_roadmap_cache.py` (logic in `shared/roadmap_cache.py`):
  - `test_cache_key_stable_and_sensitive` (AC-2) — same inputs → same key; perturb `promptVersion` /
    `modelId` / `excerpt` → different key; `excerpt_hash` 12 k truncation.
  - `test_acquire_lock_single_flight` / `test_lock_expiry_self_heals` (AC-4/AC-5) — first acquire
    succeeds, second is blocked while fresh, succeeds once `lockExpiresAt < now`.
  - `test_put_version_writes_s3_and_pointer` / `test_put_version_idempotent_on_key` (AC-1/AC-6) —
    S3 object + version row + pointer written in order; same key overwrites, no duplicate ver.
  - `test_build_outline_tolerates_both_track_shapes` (FR-12) — projects the legacy
    `exercises[]` shape **and** the `0038` `activities[]` shape into `activityKinds` counts.
  - `test_outline_and_track_are_float_free` (AC-12) — assert int/str only on DDB; Decimal→int.
- `test_generate_roadmap_cache_aware.py` (extends the generate tests):
  - `test_cache_hit_clones_without_bedrock` (AC-3) — monkeypatch `agent.generate_roadmap` to **raise
    if called**; warm the book; assert a second generate completes from cache and Bedrock wasn't
    called; first poll = `complete`; `fromCache` true.
  - `test_cache_miss_generates_once_and_populates` (AC-1/AC-10) — cold book → one Bedrock call →
    `templates/...` + pointer written → job complete.
  - `test_concurrent_first_open_single_generation` (AC-4) — simulate winner/loser; assert one Bedrock
    call and both jobs share `ver`.
  - `test_inline_book_unchanged` (AC-10/§6.10) — inline `book.text` with no catalog `bookId` takes the
    legacy per-user path (no cache items written).
  - `test_no_credit_on_clone` (AC-11; with `0023` present) — clone path does not call `credits.spend`.
- `test_roadmap_prewarm.py` (AC-7) — fixture catalog of 3 books, one already warm; assert the warm one
  is skipped, the other two generate once each, re-run fills nothing new, lock respected.
- `test_catalog_activities.py` (AC-8) — warmed book → `ActivityOutline` + `Cache-Control` header;
  unwarmed → `{status:"pending"}`; unknown id → 404.
- `test_response_ok_headers.py` (AC-9) — `ok(body)` legacy shape; `ok(body, headers=...)` merges;
  existing `ok` callers unaffected (import + call a representative handler).
- `test_delete_account_skips_templates.py` (AC-14) — seed a `templates/<id>/1.json` + a user job
  clone; `DELETE /v1/me` removes the job + `users/<sub>/` but **leaves** `templates/*`.
- `test_contract.py` (extend, AC-10/AC-13) — assert `/v1/catalog/{id}/activities` + `ActivityOutline`
  exist and `/v1/roadmaps/generate` still documents `202 {jobId}`; `cdk synth -c stage=beta` passes.

**iOS — `make ios-test` (only if the optional outline UI ships):**
- `ActivityOutlineDTOTests.swift` — lenient decode (absent fields → nil/empty; `status` default);
  `RoadmapJobDTOTests` extension — `fromCache` absent → false. The generate/poll path is **unchanged**
  → covered by existing tests.

**Manual / live smoke (deployed beta):**
- Warm *Meditations* once; open it from a second account → instant `complete`, no second Bedrock spend
  (check `0027` logs). Hit `…/activities` twice → second is a CloudFront edge hit (response headers /
  `x-cache: Hit`). Run `make roadmap-prewarm` over the `0009` catalog → confirm every book gets a
  `ROADMAP#latest`. Kill a generation mid-flight → confirm the lock expires and the next open
  regenerates. Offline run (Mock) → no cache traffic, first journey works.

## 9. Rollout & migration

- **No data migration.** New SK shapes on the existing table + a new S3 prefix; the dead
  `BOOK#<id>/ROADMAP` key was never written, so there's nothing to migrate (just remove it from the
  doc). Existing user job rows are untouched.
- **Flag / sequencing.**
  - Ship behind `ROADMAP_CACHE_ENABLED` (default **on** in beta once the AC suite is green). With it
    **off**, `generate` is exactly today's per-user path (no cache reads/writes) — a clean kill-switch.
  - **Order:** (1) `shared/roadmap_cache.py` + `response.ok` headers + the public endpoint + CloudFront
    (no behavior change to generate yet); (2) flip `generate`/worker to **cache-aware**; (3) run
    **pre-warm** over the `0009` catalog; (4) update `docs/DATA_MODEL.md` + correct `0023` §6.6.
  - **Lands with `0009`** (the 100-book catalog) so pre-warm has the real shelf; **before `0020`** (so
    the base-then-overlay boundary is in place when personalization arrives) and **before/with `0038`**
    (which depends on this cache — its FR-9 pins the seam).
- **`promptVersion` bumps.** When the prompt or `0038` engine changes shape, bump `PROMPT_VERSION`;
  the next open of each book **misses** and regenerates a new `ver` (old versions remain for
  rollback/audit). A `make roadmap-prewarm` after a bump re-warms the catalog proactively.
- **CloudFront cutover.** Point the iOS `RemoteAIService` base URL (and the public web, if any) at the
  **CloudFront** domain for the catalog GETs; authenticated routes can keep hitting the API directly or
  go through the pass-through behavior. Backward compatible (the API still serves both).
- **Backward compatibility / teardown.** Flag off → today's behavior. Templates are additive content;
  deleting them just forces lazy regeneration. The `fromCache` field is additive/optional. Rollback =
  flag off (+ optionally tear down CloudFront, reverting to direct API).

## 10. Risks & open decisions

- **R-1 (stale cache after a silent prompt/model change).** If the prompt changes but `PROMPT_VERSION`
  isn't bumped, users get an outdated base. *Mitigation:* `cacheKey` includes `modelId` + `excerptHash`
  (so model/content drift auto-rolls); make **bumping `PROMPT_VERSION` part of the prompt-change
  checklist**; a `make roadmap-prewarm` re-warms after a bump. Consider a CI assert that the prompt
  hash matches a recorded `PROMPT_VERSION`.
- **R-2 (lock wedging a popular book).** A crash mid-generation could block a hot book. *Mitigation:*
  `lockExpiresAt` self-heal (FR-3) + the lock is also a **TTL** attribute; `LOCK_TTL` tuned above p99
  generation. Alarm (via `0032`) on locks older than `LOCK_TTL`.
- **R-3 (thundering herd at launch / after a bump).** 100 books × first-opens could spike Bedrock.
  *Mitigation:* **pre-warm** before launch (FR-5) with **bounded concurrency**; single-flight ensures
  at most one generation per book even under a herd.
- **R-4 (CloudFront serving stale `pending`/outline).** An edge-cached "pending" could persist after a
  book warms. *Mitigation:* short(er) `max-age` on a `pending` response (e.g. 60 s) vs 24 h on a
  `ready` outline; or a tiny query-param/versioned path. A new **version** is a new object, so warm
  outlines don't go stale in place.
- **R-5 (CloudFront + auth complexity).** Mis-routing could cache an authenticated response.
  *Mitigation:* only the **public** `/v1/catalog*` behavior caches; everything else is
  pass-through/no-store; assert in `cdk synth` review.
- **R-6 (DDB item-size / hot partition on a viral book).** The pointer item stays small (outline only),
  and a hot `BOOK#<id>` partition is read-mostly (clones read the pointer + S3, not a write per user).
  *Mitigation:* the full track is in S3; the only per-open writes are on the **user's** job partition,
  not the book's.
- **R-7 (engine swap mid-flight, 0038).** When `0038` lands, the cached base shape changes.
  *Mitigation:* `engine` tag on the version + `outline` projector tolerates both shapes (FR-12); bump
  `PROMPT_VERSION` so old `legacy` bases roll to `agentic` on next open.
- **Decisions needed (with recommendations):**
  - **D-1 (recommended: shared cache for catalog only; per-user cache for true personalized re-gens).**
    Whether to also content-address imported books. *Recommend: catalog-only for v1 (§6.10), revisit
    via telemetry.*
  - **D-2 (recommended: `LOCK_TTL = 120 s`, tune up for `0038`).** Lock duration vs generation p99.
  - **D-3 (recommended: lazy + scheduled pre-warm; manual `make roadmap-prewarm` for launches/bumps).**
    Population strategy. *Recommend both; schedule nightly to catch re-curations.*
  - **D-4 (recommended: clone completes the job already-`complete`).** Whether the cloned job goes
    through `pending → complete` (one extra poll) or is created `complete`. *Recommend created-complete
    so the first poll resolves instantly; the `202 {jobId}` shape is still preserved.*
  - **D-5 (recommended: CloudFront for the public catalog GETs now; WAF later via `0029` on the same
    distribution).** Whether to front the whole API or just the public reads. *Recommend public-reads
    behavior + pass-through for the rest.*
  - **D-6 (recommended: `outline` on the DDB pointer).** Store the outline on the pointer (fast, small)
    vs derive it from S3 on each request. *Recommend on-pointer (it's tiny and read-hot).*

## 11. Tasks & estimate

1. **(M)** `shared/roadmap_cache.py` — `cache_key`/`excerpt_hash`, pointer/version read+write
   (`get_latest`, `next_ver`, `put_version`), `acquire_lock`/`release_lock`, `build_outline`
   (tolerant projector), `clone_into_job`. Float-free; stdlib `hashlib`/`time`.
2. **(S)** `shared/response.py` — `json_response`/`ok` optional `headers` (backward-compatible);
   `test_response_ok_headers.py`.
3. **(M)** Make `generate_roadmap.py` + `roadmap_worker.py` **cache-aware** (catalog-`bookId` branch:
   hit→clone, miss→lock+generate+`put_version`+clone, loser→clone-on-pointer); inline/imported path
   unchanged; add `fromCache` to the job view.
4. **(M)** `handlers/roadmap_prewarm.py` — walk `catalog_data.list_items()`, skip warm/stale-aware,
   single-flight-respecting, paced; `make roadmap-prewarm` + optional EventBridge schedule.
5. **(S)** `handlers/catalog.py` + `shared/catalog_data.py` (or a small `catalog_activities` helper) —
   `GET /v1/catalog/{id}/activities` returning the `outline` with `Cache-Control`; 404 unknown; pending
   shape.
6. **(S)** `shared/api/openapi.yaml` — add `/v1/catalog/{id}/activities` + `ActivityOutline`; note the
   generate cache behavior; add optional `fromCache` to `RoadmapJob`.
7. **(M)** CDK (`api_stack.py`) — `roadmap_prewarm_fn` (grants, schedule), `ROADMAPLOCK` TTL on the
   table, and a **CloudFront** distribution (public `/v1/catalog*` caching behavior + pass-through for
   the rest); `cdk synth -c stage=beta` green.
8. **(L)** Backend tests — `test_roadmap_cache.py`, `test_generate_roadmap_cache_aware.py`,
   `test_roadmap_prewarm.py`, `test_catalog_activities.py`, `test_delete_account_skips_templates.py`,
   extend `test_contract.py`; black + flake8.
9. **(S)** Docs — `docs/DATA_MODEL.md` (supersede the dead key; new rows + access pattern #7),
   `docs/BACKEND.md` (cache + pre-warm SOP, CloudFront note), `docs/OPERATIONS.md`
   (`make roadmap-prewarm`); **correct `0023` §6.6 line 472**; note the `0020` §10 reframe.
10. **(S, optional)** iOS — `ActivityOutlineDTO` + a catalog-detail "Activities" preview (deferred to
    `0011`/`0009` UI); `RoadmapJob.fromCache` lenient decode. Not required for this spec's ACs.
11. **(S)** Flag `ROADMAP_CACHE_ENABLED` + rollout (cache infra → cache-aware generate → pre-warm →
    docs), per §9.

## 12. References

> **Verified (2026-06-28) by reading the code:** `generate_roadmap.py` / `roadmap_worker.py` /
> `roadmap_jobs.py` store the roadmap **as a JSON string on the user's job row** and **never** write
> `BOOK#<id>/ROADMAP`; `response.ok(body)` takes **no headers kwarg**; the prompt
> (`prompts.roadmap_user`) is **profile-agnostic** (profile empty until `0020`). These three facts are
> the basis for the shared-base design, the `ok` extension, and the stale-claim corrections.

**Repo (read for accuracy):**
- `backend/src/handlers/{catalog.py, generate_roadmap.py, roadmap_worker.py}` — the generate/worker
  path and the public catalog handler this spec extends.
- `backend/src/shared/{catalog_data.py, roadmap_jobs.py, agent.py, prompts.py, response.py, storage.py}`
  — catalog data, job persistence (`mark_complete` writes the job row), the single Bedrock call,
  the profile-agnostic prompt, the `ok`/`json_response` helpers (no headers today), and
  `table()`/`s3_client()`/`bucket_name()`.
- `docs/DATA_MODEL.md` — the documented-but-dead `BOOK#<id>/ROADMAP` "Roadmap (cache)" row + access
  pattern #7 (both superseded here).
- `shared/api/openapi.yaml` — `/v1/catalog`, `/v1/catalog/{id}`, `/v1/roadmaps/generate` (`202
  {jobId}` / `RoadmapJob`), `CatalogBook` (the contract to extend, kept in sync).
- `CLAUDE.md` invariants — offline-first, Bedrock-only/no-key, stdlib+boto3, **no DDB floats**,
  openapi⇄DTO⇄handler sync, no third-party iOS deps, Xcode-16 sync groups.

**Cross-spec:**
- `working/ARCHITECTURE_REVIEW.md` §2.3 (origin of this design) + §1 (confirms `BOOK#<id>/ROADMAP` is
  dead).
- `working/0009-catalog-expansion-100-books.md` (the 100-book catalog this pre-warms; the
  `Cache-Control: public, max-age=86400` precedent and the "extend `ok` or build the dict inline"
  note this spec resolves).
- `working/0008-product-reframe-activity-first.md` (activity-first; a roadmap = an activity track;
  §6.7 "don't regress the `202 {jobId}` contract").
- `working/0020-feature-store-personalization.md` (§9/§10 — the **stale** "cached at
  `BOOK#<bookId>/ROADMAP`" claim and the cache-vs-personalization decision this spec **reframes** via
  personalize-on-clone).
- `working/0023-payments-and-credits.md` (§6.6 line 472 — the **stale** cache claim to **correct**;
  view/clone **free**, true personalized re-gen **metered**; the completion hook reads the real cache).
- `working/0027-generation-artifact-store-observability.md` (sibling S3 layout `books/<bookId>/…`;
  per-generation token/cost/latency logging that the cache-miss path emits; this spec's `templates/`
  is a shared, non-user-scoped sibling).
- `working/0038-agentic-roadmap-engine.md` (§6.6 / FR-5 / FR-9 — "cache hit clones the base + runs
  only the Personalizer; a miss runs the full pipeline once under **0028's single-flight lock** and
  populates the base"; the cache stores the rich track; preserves `202 {jobId}`).
- `working/0044-personalization-recommendation-engine.md` (the thin **overlay** that keeps the cache
  hot; "recommendations are **free** … only a true personalized re-generation costs a credit").

**Research (web) — LLM response caching, cache stampede / single-flight, CloudFront + API Gateway:**
- LLM response caching patterns & cost/latency wins (semantic vs exact-match cache; cache-the-result
  to avoid re-calling the model) — <https://aws.amazon.com/blogs/machine-learning/reduce-amazon-bedrock-latency-and-cost-with-prompt-caching/>
- Cache stampede / "thundering herd" and the **single-flight / request-coalescing** mitigation (one
  origin recompute, many waiters; lock + lease) — <https://en.wikipedia.org/wiki/Cache_stampede>
- DynamoDB **conditional writes** for distributed locking / single-flight (atomic
  `attribute_not_exists` + TTL lease) — <https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/WorkingWithItems.html#WorkingWithItems.ConditionalUpdate>
- DynamoDB **TTL** for self-expiring lock/lease items — <https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/TTL.html>
- **Amazon CloudFront in front of API Gateway** (caching by URI/query string, honoring origin
  `Cache-Control`, edge TLS) — <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/RequestAndResponseBehaviorCustomOrigin.html>
- **WAF cannot attach to HTTP API (v2) directly** → front with CloudFront (the future WAF mount point)
  — <https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-control-access-aws-waf.html>
- `Cache-Control` semantics for cacheable GET responses (`public, max-age=…`) —
  <https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Cache-Control>
