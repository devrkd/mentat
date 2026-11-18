# ADR-0001: Multi-tenant client onboarding & account management

| | |
|---|---|
| **Status** | Accepted (2026-11-18) |
| **Deciders** | devrkd (project owner) + principal-architect review |
| **Scope** | Account/tenant management, self-service GitHub onboarding, multi-tenant boundary enforcement |
| **Complements** | [`docs/multi-tenancy-plan.md`](../multi-tenancy-plan.md) (approved direction this ADR operationalizes), [`docs/github-app-identities-plan.md`](github-app-identities-plan.md), [`docs/VAULT.md`](VAULT.md) |
| **Supersedes** | Nothing (first ADR; establishes `docs/adr/` convention) |

> **Self-contained:** this ADR describes the whole system and the change so a
> reviewer can evaluate it without reading project source code. Code
> references (`file:line`) are included only as evidence anchors.

---

## 1. Context — what mentat2 is

Mentat2 is a self-hosted **agent-orchestration platform**: a GitHub issue or
label triggers a chain of AI agent runs (plan → code/docs → review → CI gate)
that produce reviewed pull requests on the triggering repository. It runs as
one docker-compose deployment on a single VM (Hetzner-class), entered only via
a Cloudflare Tunnel (no open ports except optional SSH).

### 1.1 Component inventory (data-plane today)

| Component | Role |
|---|---|
| **runner** (Go + SQLite) | Data-plane authority. HTTP API (`POST /runs`, `GET /runs[/{id}][/logs]`, `/healthz`, `/tokens/github/{role}`, `/state`, `/memory/candidates`, `/costs/*`). Creates one-shot **agent containers** on the host Docker daemon through two restricted socket proxies (read-only and write-capable). Mints GitHub App installation tokens (JWT → app/installations/{id}/access_tokens), injects per-run env (model key, `GITHUB_TOKEN`, egress proxy URL), enforces phase budgets/watchdogs, records runs + per-session cost ledger. |
| **n8n** (7 chained flows) | Orchestrator. `github-issues` webhook = the **only GitHub ingress** (HMAC-verified, fail-closed). `agent-run-complete` webhook receives runner callbacks and chains phase webhooks (`agent-{plan,exec,review}-complete` → `agent-ci-gate`). Calls the runner API with a shared bearer `API_TOKEN`. |
| **agent-runtime images** | GHCR toolchain matrix (`agent-runtime:jdk21`, `:node22`; BYOI contract for custom stacks), selected per repo via runtime profiles. |
| **teams YAML** | Per-phase agent definitions (`issue-planner`, `issue-coder`, `issue-docs`, `issue-reviewer`, `issue-ci-fixer`, `smoke`): model, toolsets, hooks. Injected read-only into agent containers. |
| **Vault** (KV v2 + vault-agent) | Secret store + renderer. Model keys at `secret/mentat/model`, pipeline secrets at `secret/mentat/pipeline`, GitHub App PEMs rendered to `.secrets/*.pem`. Runner resolves the provider key at dispatch (`SECRET_SOURCE=vault`) via AppRole. |
| **Webhook router** (Cloudflare Worker) | Laptop-era fan-out (routes by assignee to per-person tunnel hosts). Holds no secrets, does not verify HMAC — forwards signature headers untouched. To be retired by this ADR's ingress model. |
| **Ingress** | Cloudflare Tunnel; only `/webhook/*` paths are routed publicly. UIs (n8n, runner, Grafana, Dozzle, flow-live) are loopback-only on the VM. |
| **Observability** | Loki (agent container logs, redacted), Promtail, Grafana dashboards, Dozzle (live logs), flow-live (read-only run/phase viewer). Operator-scoped today. |
| **Egress** | `agent-net` is an internal docker bridge; agents reach the internet only via a Squid allowlist proxy (TLS/443, domain allowlist: model APIs, GitHub, Maven/npm, Nuclino). |

### 1.2 Event flow today

```
GitHub repo webhook (Issues + Pull requests, ONE shared secret)
  → [Worker: label filter, per-assignee routing, dedupe/claims]   (laptop era)
  → cloudflared tunnel → n8n POST /webhook/github-issues
      1. "Verify and filter" node: HMAC-SHA256(rawBody, GITHUB_WEBHOOK_SECRET), fail closed
      2. repo := payload.repository.full_name        (single identity source)
      3. GET runner /tokens/github/orchestrator       (bearer API_TOKEN) → relabel via api.github.com
      4. POST runner /runs {team:"issue-planner", task_id, repo_url, prompt}
  → runner: resolve image/runtime profile, mint installation token (dev or review app),
            inject env, create container on agent-net (egress only via allowlist proxy)
  → container exits → runner POSTs CALLBACK_URL (n8n /webhook/agent-run-complete)
  → n8n chains: plan → exec → review → CI gate → done / ci-fix loop
```

### 1.3 What already respects the repo boundary (verified)

The **repo-boundary invariant** is already half-true: `repo` enters only at the
webhook and is propagated unmodified; per-repo state is keyed everywhere.

| Layer | Mechanism |
|---|---|
| Dispatch identity | `repo` comes only from `body.repository.full_name`; HMAC verification fails closed |
| Resume matching | Phase flows filter run history by repo — another repo's issue #N cannot hijack a flow |
| GitHub API calls | Every flow builds `/repos/{repo}/…` paths from the propagated repo |
| Runner state | Runs carry `repo_url`; memory (`<owner>__<repo>.jsonl`), task journal, cost ledger, session DBs, workspace snapshot volumes are all `owner__repo`-keyed |
| Agent tokens | Installation tokens are scoped to the app installation's repos (but the installation is org-wide — see §2) |

### 1.4 Single-tenant chokepoint inventory (evidence anchors)

| # | Coupling | Evidence |
|---|---|---|
| 1 | One client/org: Apps installed only on PaperPalAI; `paperpal-agent-*[bot]` identity defaults | `runner/internal/config/config.go:250-260`, `compose.yaml:155-165` |
| 2 | One **static installation ID per app** — no repo→installation resolution; a second org cannot be served | `runner/internal/ghapp/ghapp.go` (single installation per client) |
| 3 | One global `GITHUB_WEBHOOK_SECRET` shared by repo webhook and n8n | `compose.yaml:224`, `n8n/flows/github-issue-dispatch.json:26` |
| 4 | One `API_TOKEN` guards the entire runner API incl. the token broker | `runner/internal/api/server.go:78-91` |
| 5 | n8n flows have **no repo allowlist** — any valid-HMAC delivery from any repo dispatches; labels/teams are hardcoded constants; Nuclino MCP (PaperPal KB) baked into teams | `n8n/flows/*.json`, `teams/issue-planner.yaml:136-145` |
| 6 | Single callback URL; internal n8n webhooks unauthenticated (orch-net only) | `compose.yaml:135`, flow webhook nodes |
| 7 | Global model keys at `secret/mentat/model`; tenant path (`tenants/<owner>/model`) exists only as a doc note | `runner/internal/secrets/secrets.go:98-104`, `docs/VAULT.md:109` |
| 8 | Global model routing chain (request > phase env > global env > team default); n8n never pins a model | `runner/internal/api/server.go:169-191` |
| 9 | Shared infra: one runner DB/cost ledger, shared `agent-cache` fallback volume, one MCP proxy (Nuclino key), one egress allowlist, operator-wide dashboards/flow-live | compose + `infra/egress-proxy/allowlist.txt` |
| 10 | Webhook router routes per-developer laptop; no client dimension | `infra/webhook-router/worker.js`, `wrangler.toml:23-24` |

---

## 2. Problem statement

We want external **clients** to onboard themselves: connect their GitHub
account, install the platform's GitHub Apps on their repos, link the repos
they want served, supply their own model API keys, and watch their own runs —
with strict isolation from other tenants, without operator involvement, and
without restructuring the single-VM data-plane.

## 3. Decision drivers

1. **Self-service**: the whole flow (install → link → keys → smoke run) must work without an operator.
2. **Repo-boundary invariant** (from `docs/multi-tenancy-plan.md` §3): *`repo` enters only at the webhook (authenticated + authorized against the linked-repo registry) and is propagated unmodified through every hop; every store and every token is keyed by it.*
3. **Least privilege**: an agent run on repo A must not be able to touch repo B, even of the same tenant.
4. **Tenant-provided LLM keys**: the platform never pays/bills for tokens (locked decision in the base plan).
5. **Keep the deployment class**: single VM + compose; no Kubernetes, no managed services.
6. **Fail closed**: unknown repo / bad HMAC / unlinked repo must be dropped or rejected, with audit evidence.
7. **Incremental**: milestones must each be independently shippable and testable; the single-operator path keeps working throughout.

## 4. Decisions

| # | Decision | Options considered | Why |
|---|---|---|---|
| **D1** | **Multi-tenant product** — tenants self-onboard onto one deployment | per-client dedicated deployments | Base plan §0 (locked): single VM, compose unchanged |
| **D2** | **Separate `accounts` control-plane service** (Go + SQLite + embedded server-rendered UI), new compose service on `orch-net` | (a) extend the runner with `/accounts/*`; (b) grow flow-live into the portal | Accounts is cold control-plane (identity/registry/onboarding UX); runner is the hot data-plane (dispatch loop, docker). Separate blast radius, separate auth surface, independent restarts/redeploys. (a) couples onboarding to dispatch-loop restarts; (b) bloats a read-only viewer into a control plane. Cost accepted: one more service + image to build/publish. |
| **D3** | **GitHub OAuth as the only portal login** | email magic-link/password in addition | Users are GitHub users by definition; zero credential storage; no email infrastructure. Consequence: portal availability tracks GitHub's. |
| **D4** | **Platform-published 3-role GitHub Apps** (dev / review / orchestrator), tenants click Install; runner resolves the installation per repo | (a) consolidate to 1 app; (b) per-tenant Apps (white-label) | (D4a) one app = simplest UX but every token gets the union of permissions; (D4b) per-tenant apps mean per-tenant PEM management and app lifecycle — rejected. Matches existing runner role split (`dev`/`review`/`orch`) and least privilege per role. Consequence: tenant installs 3 apps (3 clicks); runner needs repo→installation resolution. |
| **D5** | **Per-repo webhooks** registered programmatically at onboarding, each with its own secret; **HMAC verification stays in n8n** ("Verify and filter" node), which now looks up the per-repo secret + enabled-flag from the accounts internal API | app-level webhooks; verify at an accounts-gateway edge | Base plan §0 (locked). Per-repo secrets cap blast radius of a leak to one repo. Keeping verification in n8n minimizes flow churn (vs. a new ingress gateway); the accounts lookup makes secrets revocable per repo. |
| **D6** | **Runner is the boundary authority**: `POST /runs` validates the repo against the registry; installation tokens are narrowed per run to the single repo; run APIs gain repo/owner scoping | trust n8n to gate | n8n only orchestrates; the runner must be independently safe (defense in depth; also protects direct API use) |
| **D7** | **Tenant model keys live in Vault** at `secret/mentat/tenants/<owner>/model`; accounts writes them via a dedicated `mentat-accounts` AppRole (write-only on `tenants/*`); runner resolves tenant path first, global path as policy-controlled fallback | keys in accounts SQLite (encrypted), keys in env | The dispatch seam already exists (`vault://` ref grammar, `docs/VAULT.md:109`); Vault gives at-rest encryption + rotation semantics for free; SQLite would duplicate a secret store |
| **D8** | **Registry source of truth = accounts DB**; runner and n8n consume a narrow internal API with caching; an `ENABLED_REPOS` env-JSON stopgap ships first in M0 so gates exist before the service does | runner-owned tenants tables (base plan wording) | One writer, one audit trail; the runner remains the *enforcer*, not the *recorder*. The env stopgap keeps M0 shippable standalone. |
| **D9** | **Build order: M0 runner core first**, portal afterwards | portal first against current runner | Everything in the portal depends on multi-installation tokens + registry gates; building it first would be rework |

## 5. Target architecture

```
                         ┌────────────────────────── Cloud VM (compose; network shape unchanged) ──────────────────────────┐
 GitHub repo webhooks ──►│ n8n  github-issue-dispatch ("Verify and filter")                                                │
 (per-repo secret)       │   1. GET accounts /internal/repos/{repo} → {enabled, webhook_secret, owner, installations}       │
                         │   2. HMAC verify (per-repo secret, fail closed) + enabled gate → else drop + audit event         │
                         │   3. token via runner /tokens/github/{role}?repo=  → dispatch runner /runs (unchanged shape)     │
                         │                                                                                                  │
 Tenant browser ────────►│ accounts  (NEW control-plane: Go + SQLite + server-rendered UI)                                  │
   https://app.<domain>  │   /auth/github…            OAuth login (sessions, CSRF)                                           │
     (tunnel, public)    │   /onboarding/…            app-install capture, repo picker, key entry, smoke run                 │
                         │   /dashboard/…            linked repos, run history, live logs (owner-scoped)                     │
                         │   /internal/…             registry + per-repo secrets        (orch-net only, internal bearer)     │
                         │        │ writes tenant model keys                                                                 │
                         │        ▼                                                                                          │
                         │   Vault  secret/mentat/tenants/<owner>/model      (AppRole: mentat-accounts, write-only tenants/*)│
                         │                                                                                                   │
                         │ runner (data-plane, boundary authority)                                                           │
                         │   POST /runs rejects repo ∉ registry (403) · mints repo-narrowed installation tokens               │
                         │   GET /runs?repo=… & owner-scoped surfaces · /tokens/github/{role}?repo=… · signed callbacks       │
                         └───────────────────────────────────────────────────────────────────────────────────────────────────┘
```

Unchanged: agent container lifecycle, teams/runtime profiles, egress proxy,
Loki/Grafana/Dozzle data paths, Vault boot chain, tunnel transport.

### 5.1 `accounts` service specification

- **Stack**: Go (stdlib `net/http`, `database/sql` + SQLite, `slog`), matching runner idioms; one Dockerfile; built+published by the existing `images` GitHub Actions workflow; shipped to the VM inside the existing L2 `host-config` payload (see `docs/INFRA.md` layering).
- **Networks**: `orch-net` (internal API + n8n/runner reachability). The portal is exposed publicly **only** through the tunnel ingress as `app.<domain>`; the internal API is not routable from the internet.
- **Auth**: session cookies (HttpOnly, Secure, SameSite=Lax) after GitHub OAuth callback; CSRF tokens on state-changing forms; internal API uses a separate shared bearer (Vault-rendered) distinct from the runner's `API_TOKEN`.

**Schema (SQLite)**

```sql
tenants        (id PK, github_login UNIQUE, display_name, status, created_at)
users          (id PK, tenant_id FK, github_id UNIQUE, email, role CHECK(role IN('owner','admin')), created_at)
app_installations (id PK, tenant_id FK, app_role CHECK(app_role IN('dev','review','orch')),
                   installation_id INTEGER, gh_account_login, installed_at,
                   UNIQUE(tenant_id, app_role))
linked_repos   (id PK, tenant_id FK, repo_full_name UNIQUE,
                webhook_id, webhook_secret_enc,          -- per-repo secret, encrypted at rest
                runtime_profile, status CHECK(status IN('pending_profile','live','paused')),
                last_event_at, created_at)
tenant_tokens  (id PK, tenant_id FK, token_hash UNIQUE, scopes, created_at, last_used_at, revoked_at)
audit_log      (id PK, actor, action, object, detail_json, created_at)
```

Model keys are **not** stored here — they go straight to Vault (D7).

**Internal API contract (orch-net only)**

```
GET /internal/repos/{owner}/{repo}
  Authorization: Bearer <internal-token>
  200 → { "enabled": true, "tenant_id": "...", "owner": "<github_owner>",
          "webhook_secret": "<per-repo secret>",
          "installations": { "dev": 12345, "review": 12346, "orch": 12347 },
          "runtime_profile": "jvm-gradle" | null }
  404 → unknown / not linked           (n8n: drop delivery + audit; runner: 403 on POST /runs)
```

Consumers cache aggressively: n8n caches per delivery (one lookup per event),
runner caches with short TTL and falls back to its `ENABLED_REPOS` env snapshot
if accounts is unreachable (fail behavior: runner keeps serving already-enabled
repos; new onboarding pauses — documented degradation, not a security issue).

### 5.2 GitHub App prerequisites (manual, one-time, before M2 demo)

1. The 3 Apps (dev/review/orchestrator) must be **public** ("Any account" installable).
2. Each App's **Setup URL** = `https://app.<domain>/onboarding/github/callback?app=<role>` — GitHub redirects here post-install with `installation_id` (and `setup_action=install|update`).
3. App webhook URL is unused (D5: per-repo webhooks instead); permissions per role per `docs/github-app-identities-plan.md`.
4. One additional **OAuth App** ("Mentat Cloud") for portal login; callback `https://app.<domain>/auth/github/callback`.
5. Tunnel ingress (terraform `infra/cloud/ingress`) gains the `app.<domain>` public hostname routed to the accounts service.

### 5.3 Onboarding sequence (end-user view)

```
1. Sign in            GitHub OAuth → session; tenant auto-created from the user's GitHub login
2. Install the Apps   3 × github.com/apps/<app>/installations/new → setup_url callbacks
                      capture installation_id per role (idempotent on re-install/update)
3. Pick repos         server-to-server: app JWT → installation token → GET /installation/repositories
                      tenant selects; each selection creates a linked_repos row + fresh per-repo secret
4. Provision (automated, idempotent, per repo, via installation tokens):
                        a. POST /repos/{repo}/hooks  (issues+pull_requests → platform webhook URL, per-repo secret)
                        b. create the 12 pipeline labels (standard label set)
                        c. open a PR adding repo-owned .agentflow/project.json
                           (stack picker: jdk21 | node22 | python312 runtime profiles; verification commands)
                        d. scaffold memory/<owner>__<repo>.jsonl
5. Model keys         tenant pastes provider keys → Vault secret/mentat/tenants/<owner>/model
6. Smoke run          accounts dispatches team=smoke against the repo → tenant watches owner-scoped logs
7. Live               tenant labels an issue agent:ready → normal pipeline
```

Operator path (platform's own repos, no UI) remains `scripts/onboard-repo.sh`
(planned in P1), driving the same linked_repos writes through the same internal
API.

### 5.4 Dispatch-time key resolution (after M3)

Runner `ModelKeyRef` becomes owner-aware:

```
resolution order:  vault://secret/mentat/tenants/<owner>/model#<provider>_api_key
                →  vault://secret/mentat/model#<provider>_api_key        (policy toggle; default on at first)
```

A missing tenant key with fallback disabled fails the run **before** any
container is created (existing fail-fast behavior).

## 6. Boundary enforcement & security model

**Invariant (unchanged from base plan §3):** `repo` enters only at the webhook
(authenticated, authorized against the linked-repo registry) and is propagated
unmodified; every store and every token is keyed by it.

| Gate | Where | Effect |
|---|---|---|
| Per-repo HMAC | n8n "Verify and filter" | secret scoped to one repo; leak/revocation affects one repo; unknown repo → drop + Loki audit |
| Enabled-repo gate | n8n (lookup) **and** runner `POST /runs` | an installation may cover 20 repos; only linked ones dispatch — enforced in two independent places |
| Token narrowing | runner `ghapp` | per-run installation token carries `"repositories":["<repo>"]` — the agent physically cannot read sibling repos regardless of installation breadth |
| Repo-scoped APIs | runner | `GET /runs?repo=` server-side (fixes `?limit=500` client-side truncation + cross-tenant reads); run records gain `owner`; SSE logs, flow-live filtered by tenant token → owner |
| Signed callbacks | runner → n8n | `agent-run-complete` carries an HMAC; n8n verifies before acting (closes the unauthenticated-internal-webhook gap) |
| Tenant tokens | accounts → runner | runner API auth evolves from one shared `API_TOKEN` to tenant-scoped tokens (operator token retained for admin) |
| Audit | accounts `audit_log` + Loki events | every registry mutation, gate drop, and key write is attributable |

**Residual risks (accepted, documented):**

- Single shared internal bridge `agent-net` means cross-tenant *container reachability* until P4 introduces per-tenant networks — mitigated meanwhile by token narrowing (no cross-repo GitHub access) and the egress allowlist (no tenant-to-tenant services).
- One shared egress allowlist; new tenant dependency domains require an allowlist change (ops procedure exists).
- SQLite = single-node; acceptable at target scale (base plan Appendix A: 5–20 issues/day, 3–6 concurrent runs).
- n8n internal phase webhooks remain on `orch-net` trust until M3 callback signing lands.

## 7. Changes per subsystem (file-level)

| Subsystem | Changes | Key files |
|---|---|---|
| runner/ghapp | repo→installation resolution, token cache keyed by installation ID, per-run token narrowing, git identity from app slug | `runner/internal/ghapp/ghapp.go`, `runner/internal/orchestr/orchestr.go` |
| runner/API | `POST /runs` registry validation; `GET /runs?repo=`; `/tokens/github/{role}?repo=`; `owner` on run records; signed callback; tenant-token auth | `runner/internal/api/server.go`, `runner/internal/store/store.go`, `runner/internal/config/config.go` |
| runner/secrets | owner-aware `ModelKeyRef` with global fallback | `runner/internal/secrets/secrets.go` |
| accounts (new) | service, schema, OAuth, install capture, provisioning automation, portal UI, internal API | `accounts/**` (new), `compose.yaml`, `infra/host-config/Dockerfile` (payload), `.github/workflows/build-images.yml` |
| n8n (7 flows) | per-repo secret lookup + enabled gate in "Verify and filter"; `repo` param on token calls; `?repo=` history pulls; verify signed callback | `n8n/flows/*.json` |
| Vault | `mentat-accounts` AppRole + write-only `tenants/*` policy; bootstrap adds it | `scripts/` bootstrap, `vault/` |
| infra/ingress | `app.<domain>` public hostname via existing tunnel root | `infra/cloud/ingress/{dns,tunnel}.tf` |
| teams | strip Nuclino MCP server when key empty (tenant-generic teams) | `teams/*.yaml` |
| observability | `orch_repo`/`orch_owner` docker labels at container create; dashboard/flow-live scoping | `runner/internal/orchestr`, `flow-live/`, `grafana/` |
| docs | `docs/ONBOARDING.md` (tenant-facing), `docs/ACCOUNTS.md` (operator) | `docs/` |

## 8. Milestones, PR sequence, verification

| Milestone | PRs | Contents | Verification |
|---|---|---|---|
| **M0 runner core** (= plan P2) | PR-1 | ghapp: per-repo installation resolution + narrowing + cache-by-installation; `/tokens/github/{role}?repo=`; git identity from app slug | ghapp httptest: resolution, narrowing param, cache keying |
| | PR-2 | registry stopgap `ENABLED_REPOS` + `GET /repos/enabled`; `POST /runs` 403 gate; `GET /runs?repo=` | boundary tests: unlinked repo → 403; cross-repo resume isolation (repo A #5 vs repo B #5) |
| | PR-3 | n8n: repo param on token calls, `?repo=` history pulls, enabled gate in "Verify and filter" (global secret until M1) | `scripts/test-n8n-*.sh` contracts stay green |
| **M1 accounts skeleton** | PR-4..5 | service + schema + internal API; runner + n8n consume it (env stopgap becomes fallback); Vault `mentat-accounts` role | `scripts/test-accounts-registry.sh`; compose healthchecks |
| **M2 self-service onboarding** | PR-6..8 | OAuth login, install capture, repo picker, provisioning automation (webhook/labels/PR/memory), key entry, smoke button, portal UI, ingress hostname, docs | `scripts/test-onboarding.sh` (stub GitHub API); local-cloud rehearsal extended with accounts to dry-run a real tenant onboarding against a scratch repo |
| **M3 tenant product surface** | PR-9..10 | owner on runs + scoped APIs/live view + tenant tokens; owner-aware model keys; signed callbacks; `orch_repo`/`orch_owner` labels + dashboards | scope tests: tenant A cannot read tenant B runs; key isolation |
| **M4 (= plan P4, later)** | — | per-tenant `agent-net-<owner>` networks, per-tenant egress allowlists, quotas | cross-tenant network isolation tests |

Each milestone keeps the single-operator path working (backward compatibility is
a per-PR requirement; the `smoke` team path is the standing end-to-end check).

## 9. Consequences

**Positive**

- Clients onboard themselves; operator effort drops to publishing/maintaining the Apps.
- Per-repo secrets + narrowed tokens materially reduce blast radius vs. today's single global secret and org-wide installation tokens.
- Tenant-provided keys keep LLM costs off the platform's books; per-repo cost ledger already gives tenants accurate usage.
- Clean seam for future multi-host/multi-VM scale-out (registry is a logical construct, not tied to one runner).

**Negative / risks & mitigations**

- 3-app install adds friction → onboarding UI shows progress per role and resumes mid-flow.
- GitHub-side app publishing is manual → checklist in `docs/ACCOUNTS.md`; blocks the M2 demo only.
- n8n flow JSON is brittle → every flow change lands in the same PR as its runner API change, guarded by `test-n8n-*` contracts.
- accounts is a new dependency of dispatch → runner/n8n cache + env fallback keep the data-plane running during accounts downtime (degradation: no *new* onboarding).
- SQLite/VM ceilings → documented K8s Jobs port remains the escape hatch (base plan Appendix A).
- Per-tenant MCP integrations (Nuclino is PaperPal-specific) are out of scope here; teams are made tenant-generic first.

## 10. Open questions (not blocking M0/M1)

- Quota/budget defaults per tenant (P4).
- Whether tenant tokens should also scope Loki queries directly, or only via flow-live/dashboards.
- Terms/branding for the public Apps (naming stays platform-owned per D4).

## 11. References

- `docs/multi-tenancy-plan.md` — approved multi-tenancy direction (superseded in part by D8: registry ownership moves from runner DB to accounts).
- `docs/github-app-identities-plan.md` — 3-app role split and permission matrix.
- `docs/VAULT.md` — secret storage, `SECRET_SOURCE=vault` dispatch seam (P3 tenant-key note).
- `docs/INFRA.md` — L0–L4 layer contract; accounts ships via the L2 `host-config` artifact.
- `docs/BUILD-GUIDE.md` — current single-operator setup (the flow this ADR replaces for tenants).
- `docs/model-routing.md` — model resolution chain extended by §5.4.

## Appendix A — reviewer cheat-sheet: what changes for a tenant vs. today

| Concern | Today (single operator) | After this ADR |
|---|---|---|
| Who installs GitHub Apps | Operator, on PaperPalAI org | Tenant clicks Install on public Apps; installation captured automatically |
| Who registers repo webhooks | Operator, manual, one shared secret | Automated per repo, per-repo secret |
| Who sets model keys | Operator `.env` / Vault global | Tenant pastes keys in portal → Vault tenant path |
| Who can trigger runs | Anyone with the single `API_TOKEN` | Tenant-scoped tokens; runner re-validates repo linkage |
| Who sees runs/logs | Operator dashboards (global) | Tenant sees own owner-scoped history/logs; operator sees all |
| Blast radius of a webhook-secret leak | Deployment-wide | One repo |
| Blast radius of an installation token leak | Org-wide repos | One repo (narrowed token) |
