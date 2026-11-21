# OfficerPath AI — Phase 1 Deployment Research: Cloud Run (free-first)

**Date researched:** 2026-11-20 (PKT, Asia/Karachi)
**Scope:** Python + FastAPI backend (`officerpath-pdf-engine`), Docker image, Google Cloud Run.
Wanted config: min instances 0, max 1, 1 vCPU, 1–2 GiB memory, secure env vars,
health checks, graceful shutdown, request timeouts. GitHub as source of truth.
**Rule followed:** research only — nothing created, enabled, or paid for. No billing
account touched, no API enabled, no console access used.

---

## 0. Headline facts (TL;DR)

1. **Cloud Run has a genuine Always Free tier, but it is NOT billing-free.**
   A valid billing account (i.e. a payment method on file) is **required to deploy
   to Cloud Run at all, even if usage stays inside the free tier.** This is the
   single biggest decision in this phase.
2. **Free tier (request-based billing, per billing account, per month):**
   2,000,000 requests · 180,000 vCPU-seconds · 360,000 GiB-seconds · 1 GiB
   internet egress (North America). Figures are quoted at us-central1 (Iowa)
   Tier 1 prices and applied as a spending discount — in a Tier 2 region such
   as Singapore the same discount buys **fewer** seconds.
3. **At realistic low usage (tens of PDF jobs/day) the expected Cloud Run bill
   is $0.00** — usage sits at roughly 8–15% of the free tier. Even 100 jobs/day
   at 60 s each lands almost exactly on the free-tier boundary ($0.00). Only
   beyond ~100 long jobs/day does a real bill start, at ~$0.0017 per extra job
   (us-central1 prices).
4. **Best region: `asia-south1` (Mumbai)**, not Singapore. Mumbai is Tier 1
   pricing (full free-tier value) and geographically closest to Pakistan.
   Singapore (`asia-southeast1`, where Supabase sits) is Tier 2 — higher unit
   prices, free tier worth less. Latency difference between the two was **not
   measured**; test both before committing.
5. **This VM cannot build or deploy anything today:** no Docker, no gcloud.
   Only Python 3.12.3 is present. Builds must happen in GitHub Actions
   (Cloud Build) or on another machine.
6. **Billing alerts do NOT stop spending.** A budget only sends emails. The
   only hard stop is a spend cap (public preview, Cloud Run eligible) or
   service-level limits (max instances = 1 is itself a cost guard).
7. **Existing GCP project status is UNKNOWN and cannot be verified from here:**
   project "n8n Automation" (`n8n-automation-483009`) has Firebase + Cloud
   Messaging API enabled, but whether it has a billing account linked, whether
   the Cloud Run API is enabled, and whether the $300 trial was ever used can
   only be checked in the Cloud Console (needs the user's browser).

---

## 1. This VM — what tooling actually exists

Checked 2026-11-20 ~22:11 PKT, exact outputs:

| Tool | Result |
|---|---|
| `docker --version` | **Not installed** — `docker: command not found` |
| `gcloud --version` | **Not installed** — `gcloud: command not found` |
| `gcloud auth list` | Not runnable (no gcloud) |
| `python3 --version` | **Python 3.12.3** (`/usr/bin/python3`, pip3 present) |
| `which docker gcloud python3 pip3` | Only `/usr/bin/python3`, `/usr/bin/pip3` |

**Consequences:**
- No local Docker build, no local image test, no `gcloud run deploy` from this VM.
- The deployment pipeline must be **GitHub Actions → Cloud Build → Artifact
  Registry → Cloud Run**, or the user installs Docker/gcloud on a machine that
  has them. Installing gcloud/Docker on this VM was **not** done (out of scope
  for a research task; also needs a decision, since `gcloud auth login` is an
  interactive browser step the user must do himself).
- Python 3.12.3 is new enough to develop/test the FastAPI app locally
  (without Docker), but the production image must be built in CI.

---

## 2. Cloud Run free tier — verified from current sources

Primary source: official Google Cloud Run pricing page, read 2026-11-20
(https://cloud.google.com/run/pricing — page crawled 2026-11-20 17:10 UTC).

### 2.1 Request-based billing (the default — and the right choice for this backend)

| Allowance (per billing account, per month) | Amount |
|---|---|
| Requests | **2,000,000 free** |
| CPU | **180,000 vCPU-seconds free** |
| Memory | **360,000 GiB-seconds free** |
| Internet egress | **1 GiB free (within North America)** |

Unit prices beyond the free tier, us-central1 (Tier 1):
- CPU (active time): **$0.000024 / vCPU-second**
- Memory (active time): **$0.0000025 / GiB-second**
- Requests: **$0.40 / 1,000,000**
- Idle min-instance time (only if min instances > 0 — **not our case**):
  CPU $0.0000025 / vCPU-s, memory $0.0000025 / GiB-s.

Key mechanics from the official page:
- Usage is rounded up to the nearest **100 ms**.
- "The free tier usage is aggregated across projects by billing account and
  resets every month; you are billed only for usage past the free tier. **The
  free tier is applied as a spending based discount using Tier 1 pricing.**"
  → In a Tier 2 region the free tier covers **less** than the headline seconds.
- "Cloud Run only charges for the CPU and memory allocated to an instance
  when: the instance is starting; the instance is gracefully shutting down
  (handling the SIGTERM signal); at least one request is being processed."
  → Cold-start time **is billed**. With min instances 0, every cold start
  costs a few billed seconds.
- Requests denied by IAM are not billed; requests that reach the container are.
- Max request timeout: 60 minutes (per Google docs; not re-verified on the
  pricing page — confirm at build time).

### 2.2 Instance-based billing (NOT recommended for this workload)

Free tier: 240,000 vCPU-seconds + 450,000 GiB-seconds/month, but billed for
the **entire instance lifetime** (minimum 1 minute per instance), even while
idle. For sporadic PDF jobs this wastes the allowance on idle time.
Request-based billing is the correct choice; min instances 0 keeps idle cost
at exactly $0.

### 2.3 What happens when the free tier is exceeded

- There is **no hard cutoff and no automatic shutdown**. Usage past the free
  tier is billed at the standard rates above to the linked billing account.
- The free tier does not roll over: unused allowance is gone at month end.
- Free-tier limits are **per billing account**, not per project or per service.
  If the same billing account also runs other Cloud Run services, they share
  one allowance.

### 2.4 Is a billing account REQUIRED to deploy — even for free-tier use?

**Yes.** Verified from multiple sources:
- Official Cloud Run Functions (1st gen) pricing page (cloud.google.com):
  *"Note that even for free tier usage, we require a valid billing account."*
- Google's free-tier documentation (docs.cloud.google.com/free/docs/free-cloud-features,
  as read 2026-10-07 by an independent tracker): *"Google Cloud's Free Tier
  requires a billing account."*
- Google's own n8n Cloud Run hosting docs: *"even if your Cloud Run service
  runs for free you must have billing activated to deploy."*
- Multiple independent 2026 guides confirm the same: Cloud Run will not deploy
  anything until a billing account is linked to the project.

**Practical meaning:** "free-first" still means the user must (a) create a
Google Cloud billing account, (b) attach a payment method (card), and
(c) link it to the project. The card is verified but not charged while usage
stays in the free tier. There is no way to deploy to Cloud Run with no payment
method on file. (Exception: apps deployed from Google AI Studio under the
"Starter Tier" need no billing account — not applicable to a custom FastAPI
container deployed by us.)

### 2.5 New-account $300 trial

Google offers new customers a **$300 credit valid for 90 days** (Free Trial),
usable on most GCP products, on top of the Always Free tier. Whether the
user's Google account / the existing project still qualifies is **unknown**
— it depends on whether a trial was ever claimed on that account. Check in
the Cloud Console (Billing → overview). The trial also requires a payment
method. Do not assume it is available.

### 2.6 Regions, Pakistan, and Supabase (Singapore)

Cloud Run regions relevant to us (from the official pricing page):
- **`asia-south1` (Mumbai, India) — Tier 1 pricing.** Closest GCP region to
  Pakistan; full free-tier value.
- **`asia-southeast1` (Singapore) — Tier 2 pricing.** Where the Supabase
  project lives (ap-southeast-1), but Tier 2 unit prices are higher and the
  free tier (a Tier 1-priced discount) buys fewer seconds there.
- `asia-southeast2` (Jakarta) — Tier 2. `asia-south2` (Delhi) — Tier 2.
- No GCP region exists in Pakistan. **No Pakistan-specific restriction on
  using GCP / Cloud Run was found in the sources checked.** (Pakistan is not
  listed as a restricted country for Cloud Run in any source consulted; if the
  console ever shows a restriction, that would be new information.)
- **Exact Tier 2 unit prices for Singapore were NOT verifiable from the
  fetched pricing page** (the page is interactive; the text fetch shows
  us-central1 defaults only). Do not quote a Singapore price — read it in the
  console or pricing calculator before choosing Singapore. The qualitative
  fact is certain: Singapore costs more than Mumbai for identical usage.
- Latency: no measurements were taken. Mumbai is geographically nearer to
  Punjab than Singapore, so it is the expected latency winner as well as the
  price winner, but this should be confirmed with a real probe at deploy time.
- Supabase co-location note: Supabase is **not** inside GCP, so putting Cloud
  Run in Singapore does **not** make traffic to Supabase free or internal —
  it is internet egress either way. There is therefore no cost reason to pay
  Tier 2 Singapore prices for Supabase proximity. (Traffic between Cloud Run
  and Supabase is small JSON; egress cost is negligible in any region — see §3.)

**Recommendation: deploy in `asia-south1` (Mumbai) first; keep
`asia-southeast1` (Singapore) as a fallback if latency testing favours it.**

### 2.7 Egress (networking) — the only other Cloud Run cost line

- Free: 1 GiB/month internet egress (stated as "within North America" on the
  free-tier summary; secondary sources describe the first 1 GiB as free to
  most Premium Tier destinations — treat the North-America wording as the
  conservative reading).
- Beyond that, Premium Tier (default) internet egress is **$0.12 / GiB for
  the first 1 TiB**, then $0.11, then $0.08. GCP prices egress by
  **destination**, not source region, so serving users in Pakistan from
  Mumbai costs the same $0.12/GiB first tier as from Iowa (secondary sources:
  egresscost.com, verified 2026-09 against cloud.google.com/vpc/network-pricing;
  costfluent.com, read 2026-10-21). Higher rates apply only to destinations
  such as Australia ($0.19) and China ($0.23) — not Pakistan.
- Standard Tier (opt-in) gives 200 GiB free/month, then $0.085/GiB — but
  routes over the public internet with higher latency; not needed at this scale.
- **Inbound traffic (PDF uploads to the backend) is free.** Only responses
  (JSON results) count as egress, and they are kilobytes per job.
- At tens of jobs/day, egress will be far below 1 GiB/month → **$0**.

---

## 3. Cost estimate — wanted config (min 0 / max 1 / 1 vCPU / 1–2 GiB)

Billing mode: request-based (default). Prices: us-central1 Tier 1 list prices
from the official pricing page (read 2026-11-20). Singapore (Tier 2) would be
somewhat higher — exact figures unverified, see §2.6.

### Assumptions (stated, not measured)
- A "job" = one PDF upload + parse (Tesseract/Gemini) + JSON response.
- **Active billed time per job: 30–60 s.** This is an estimate: a 7-page
  CamScanner scan with OCR will plausibly take tens of seconds end-to-end,
  and under request-based billing the whole request duration is billed while
  CPU is allocated. If Gemini calls dominate, wall time may be longer; if the
  job is split into async processing, billed time changes — re-estimate once
  real timings exist.
- Memory: 1 GiB (2 GiB shown as the upper case).
- Health-check / warmup requests: negligible (a handful per day).
- 30-day month. Requests: ~1,000–15,000/month — far under the 2M free allowance → $0.
- Egress: < 1 GiB/month → $0.

### Scenario A — light launch (30 jobs/day, 30 s each, 1 GiB)
- vCPU: 30 × 30 s × 30 = **27,000 vCPU-s/month** (15% of free tier)
- Memory: 27,000 GiB-s (7.5% of free tier)
- **Expected bill: $0.00**

### Scenario B — steady use (100 jobs/day, 60 s each, 2 GiB)
- vCPU: 100 × 60 s × 30 = **180,000 vCPU-s/month** — exactly the free tier
- Memory: 360,000 GiB-s — exactly the free tier
- **Expected bill: $0.00** (at the boundary; any growth above this starts billing)

### Scenario C — heavy use (500 jobs/day, 60 s each, 2 GiB)
- vCPU: 900,000 vCPU-s; overage 720,000 × $0.000024 = **$17.28**
- Memory: 1,800,000 GiB-s; overage 1,440,000 × $0.0000025 = **$3.60**
- Requests 15,000 → $0. Egress → $0.
- **Expected bill: ≈ $20.88/month** (us-central1 prices; at 1 GiB memory it
  would be ≈ $18.63). Singapore Tier 2 would be higher by an unverified amount.

### Marginal cost (beyond the free tier)
- One extra 60 s job at 1 vCPU / 2 GiB: 60 × $0.000024 + 120 × $0.0000025
  = **$0.00174**. At 1 GiB: **$0.00159**. I.e. ~575–630 extra jobs per $1.
- Requests beyond 2M: $0.40 per million — negligible at any realistic scale.

### Hidden / adjacent costs (small but real)
| Item | Free allowance | Beyond that | Expected at our scale |
|---|---|---|---|
| Artifact Registry storage | 0.5 GB/month free | $0.10 / GB / month | A Python+FastAPI+Tesseract image is likely 1–2 GB → **~$0.05–0.15/month**. Keep old image tags pruned. |
| Cloud Build minutes | 2,500 build-minutes/month for `e2-standard-2` (official free-tier docs page) — note: older secondary sources say "120 build-minutes/day"; the official docs page figure is used here and the discrepancy is flagged | ~$0.003–0.006 / build-minute (secondary sources; exact rate unverified) | A few deploys/week, minutes each → **$0** |
| Secret Manager (for env vars/secrets) | Small free tier exists on Google's free-tier list; exact current allowance (secondary sources say 6 active secret versions/month) **not verified from the official page in this research** | Per-operation charges beyond | **$0 expected**; verify allowance in console |
| Cloud Logging/Monitoring | Monthly allotments exist; volume from one small service is tiny | — | **$0 expected** |
| Cold starts | Billed as instance-start time (seconds per cold start) | Included in the per-job seconds above | Already inside the estimates |

### Cost guards already in the wanted config
- **min instances 0** → $0 idle cost; the service scales to zero.
- **max instances 1** → hard cap on parallel spend; a traffic spike or abuse
  can queue/delay jobs but cannot multiply the bill. This is the strongest
  free cost control in the design — keep it.
- **Concurrency 1** (recommended at build time for CPU-heavy OCR) → one job
  per instance, predictable per-job billing, no noisy-neighbour effect.

---

## 4. Billing alerts — what to set up, and what they cannot do

### 4.1 What a budget is (and is not)
- A Cloud Billing **budget** is a monthly amount with threshold rules. When
  spend crosses a threshold it **sends an email / Pub/Sub notification**.
- **Budgets do NOT stop spending.** Google's documentation is explicit:
  an alerts-only budget "does not automatically cap usage or spending" and
  "does not prevent the use or billing of your services." Charges keep
  accruing after the email. (Sources: Google Cloud billing docs as quoted by
  guanacostech.com and cloudwebschool.com, 2026; exodus.elim.io, Oct 2026.)
- Cost data is **not real-time**: billing data typically lags hours (up to
  24 h+), so alerts describe the past.
- Default thresholds on a new budget: **50%, 90%, 100% of actual spend**.
  Forecasted-spend thresholds can also be set (e.g. 100% forecast).
- Budgets live on the **billing account**, not in a project. Creating one
  needs the Billing Account Administrator or Billing Account Costs Manager
  role (a project owner can create budgets scoped to their own project).
- Creating a budget costs nothing and enables no paid service — but a budget
  can only exist once a billing account exists.

### 4.2 Recommended budget setup (to do in the console, after billing exists)
1. Billing → Budgets & alerts → Create budget.
2. Scope: the project (or the whole billing account if it only holds this project).
3. Amount: **$5/month** (deliberately tiny — this is a tripwire, not a forecast).
4. Thresholds: 50% and 90% actual, 100% forecasted; add the user's Gmail as
   an alert recipient (default recipients are billing admins/users only).
5. This is a **notification only** — it will not stop anything.

### 4.3 The one mechanism that DOES stop spending: spend caps
- Google added **spend cap budgets** (public preview since July 2026) for
  select services including **Cloud Run and Cloud Run functions**: when spend
  for that service in that project reaches 100% of the cap, Cloud Billing
  **pauses the service for the rest of the month**. (Sources: Firebase spend
  cap docs; exodus.elim.io / guanacostech.com, Oct 2026.)
- Limitations (from the same sources): one cap per project+service, not
  instant (acts on estimated cost), does not cover persistent resources
  (storage, BigQuery, VMs). Availability and exact behaviour must be
  **verified in the console at setup time** — this is a preview feature and
  may have changed.
- **Recommendation:** set a spend cap of **$5/month on Cloud Run** for this
  project if the console offers it; otherwise rely on the $5 alerts-only
  budget + max-instances-1 + manual monitoring. A paused service is far
  better than a surprise bill for a zero-budget project.

### 4.4 What needs the user's approval / browser access
- Creating/linking a **billing account** and adding a **payment method**:
  only the user, in his own browser, on his own Google account. No agent
  should ever handle his card details.
- Enabling APIs (Cloud Run, Artifact Registry, Cloud Build, Secret Manager):
  free to enable, but only possible in a project the user grants access to.
- Creating the budget / spend cap: needs billing-account access (his browser
  or a delegated IAM role — the browser route is simplest and safest).

---

## 5. Deployment path options (evaluated, not implemented)

### Option A — GitHub Actions → Cloud Build → Artifact Registry → Cloud Run (RECOMMENDED)
- Flow: push to GitHub → Actions workflow authenticates to GCP via
  **Workload Identity Federation** (no long-lived service-account keys) →
  `gcloud builds submit` or `docker build` + push to Artifact Registry →
  `gcloud run deploy` (or `google-github-actions/deploy-cloudrun`).
- Pros: GitHub is already the source of truth; no secrets to rotate (WIF);
  builds run on Google's infra (free-tier build minutes); fully auditable;
  rollback is a redeploy of a previous image tag or a traffic shift (§5.4).
- Cons: needs Workload Identity Federation setup (one-time, console/CLI work
  by someone with project IAM admin — the user or a delegated agent with his
  approval); needs gcloud in CI only (not on this VM).
- Cost: $0 at expected scale (build minutes + registry within free tiers, §3).

### Option B — `gcloud run deploy --source .` (deploy from source)
- Flow: one command uploads source, Cloud Build builds the Dockerfile,
  pushes to Artifact Registry, deploys.
- Pros: simplest possible path; no CI file to write; good for the first manual
  deploy from a machine with gcloud.
- Cons: not reproducible/automated; requires gcloud + auth on the deploying
  machine (this VM has neither); every deploy is a manual step; no CI checks.
- Cost: same as Option A (uses Cloud Build + Artifact Registry behind the scenes).
- Note from Google's pricing page: "When deploying from source… Cloud Run
  uses Cloud Build… images are stored in Artifact Registry. Artifact Registry
  has its own free tier… If you… exceed the Artifact Registry free tier usage,
  you will incur charges… even when your use of Cloud Run falls within the
  free tier."

### Option C — Build image locally / in GitHub Actions, push, deploy (manual)
- Flow: `docker build` → `docker push` to Artifact Registry → `gcloud run deploy --image …`.
- Pros: full control; works from any machine with Docker.
- Cons: needs Docker somewhere (not this VM); manual; image-push credentials
  to manage if not using WIF.
- Cost: $0 at expected scale (registry only).

### Registry: Artifact Registry vs Container Registry (GCR)
- **Use Artifact Registry** (`<region>-docker.pkg.dev/<project>/<repo>/<image>`).
  It is the current registry; Google's pricing page routes all new source
  deploys to it; 0.5 GB/month free, then $0.10/GB/month.
- Container Registry (`gcr.io`) is the legacy registry. Its deprecation status
  was **not independently verified from an official source in this research** —
  do not build anything new on it regardless; Artifact Registry is the
  documented current path.
- Put the registry in the **same region as the service** (asia-south1) to avoid
  cross-region pull latency/egress.

### Rollback story (same for all options)
- Every deploy creates an **immutable revision**. Rollback = send 100% of
  traffic to a previous revision — **no rebuild, one command**:
  `gcloud run services update-traffic SERVICE --to-revisions OLD_REVISION=100`
  (or Console → Cloud Run → service → Revisions → Manage Traffic).
  Source: cloud.google.com/run/docs/rollouts-rollbacks-traffic-migration.
- Gradual rollout is also native: deploy with `--no-traffic --tag green`,
  test the tagged URL (`https://green---SERVICE-….a.run.app`), then shift
  traffic 5% → 50% → 100%.
- Gotcha (documented by independent 2026 guides): after a traffic split or
  rollback, run `update-traffic --to-latest` when you want later deploys to
  receive traffic again — otherwise new deploys can sit at 0%.
- Old revisions that serve no traffic cost nothing; Cloud Run keeps up to
  1,000 revisions per service. Old images in Artifact Registry still occupy
  storage — prune tags periodically (a GitHub Actions step can do this).
- Rollback scope: a revision rollback restores the **code + config of that
  revision**, but not external state (Supabase data, secrets changed since).
  Secret/env-var changes create a new revision too.

### Other options considered and set aside
- **Cloud Deploy** (managed progressive delivery): free for single-target
  pipelines, but overkill for one service with max 1 instance; revisit if
  multi-environment promotion is ever needed.
- **Firebase App Hosting**: built on Cloud Run, but adds Firebase-plan
  coupling for no benefit — the backend is a plain FastAPI container.
- **Render / Railway / Fly.io free tiers**: not evaluated in depth — the task
  is Cloud Run; note only that they exist as fallbacks if GCP billing proves
  impossible (all of them also require an account/card or have usage limits
  that would need their own research).

---

## 6. Configuration notes for the build (from verified sources)

- **Request-based billing, min instances 0, max instances 1, 1 vCPU,
  1–2 GiB** — as specified; this is the cheapest correct shape.
- **Concurrency:** set to 1 for CPU-heavy OCR (default is 80; concurrent
  jobs on one 1-vCPU instance would contend and inflate per-job latency).
- **Timeout:** set an explicit request timeout (Cloud Run max is 60 min;
  pick a value matched to the longest real job, e.g. 300–600 s — decide at
  build time from measured timings, not from this document).
- **Health checks:** Cloud Run supports startup and liveness probes; the
  FastAPI app should expose `/health` (or `/healthz`). Probe behaviour and
  defaults were not verified from docs in this research — confirm at build time.
- **Graceful shutdown:** Cloud Run sends **SIGTERM** when stopping an
  instance (confirmed on the pricing page: "gracefully shutting down
  (handling the SIGTERM signal)"). The app must catch SIGTERM and finish the
  in-flight request. The exact default grace period was not verified here —
  confirm at build time.
- **Secrets / env vars:** use **Secret Manager** for API keys (e.g. Gemini
  key) and `--set-secrets` / env vars for non-secret config. Never bake keys
  into the image or the GitHub repo. Secret Manager's exact free allowance
  was not verified from the official page in this research (§3 table).
- **Ingress:** restrict to the OfficerPath app/supabase callers as far as
  possible; at minimum require authentication (do not use
  `--allow-unauthenticated` unless the design explicitly requires a public
  endpoint, and if so put an API key check in the app).
- **Startup cost note:** with min 0, the first request after idle pays a cold
  start (image + Python + Tesseract load). Keep the image lean (slim base,
  no unused layers) to keep this short.

---

## 7. BLOCKED / NEEDS USER — decisions and access only the user can give

Nothing in this section can be done by an agent alone. Each item needs the
user (Abdul Qadeer) in his own browser, or his explicit decision.

| # | What is needed | Why it blocks | Exact wording to ask him |
|---|---|---|---|
| 1 | **Create/link a Google Cloud billing account + add a payment method** to project `n8n-automation-483009` (or a new project if he prefers) | Cloud Run **will not deploy anything** without a linked billing account, even inside the free tier. This is the #1 blocker. | "Cloud Run free hai lekin deploy karne ke liye Google ko ek billing account + card chahiye hota hai — card se charge tabhi hoga jab free limit cross ho. Kya aap apne browser mein console.cloud.google.com khol kar billing account bana kar project se link kar dein ge? Main aap ko step-by-step bata dunga; card details mujhe kabhi mat bhejna." |
| 2 | **Confirm the billing status of the existing project** — is a billing account already linked? Was the $300 trial ever used? | Determines whether step 1 is already done and whether any trial credit exists. Cannot be checked from this VM (no gcloud, no console access). | "Aap ke GCP project 'n8n Automation' par billing pehle se linked hai ya nahi — yeh aap console mein Billing page par check kar ke bata dein. Agar $300 trial credit nazar aaye to woh bhi bata dein." |
| 3 | **Decide: reuse project `n8n-automation-483009` or create a fresh GCP project for OfficerPath?** | Reuse is fine, but a separate project isolates billing/quotas and keeps the n8n project untouched. His call. | "Backend ke liye purana 'n8n Automation' project use karun ya OfficerPath ke liye naya project banaun? Naya project saaf rahega, purana project bhi chal jayega." |
| 4 | **Approve the $5/month budget + $5/month spend cap** (alerts at 50/90/100%, cap pauses Cloud Run at $5 if available) | Budgets/caps live on his billing account; setting them is a billing decision, and a spend cap can pause the service. | "Billing account banne ke baad main $5/month ka budget alert aur (agar available ho to) $5 ka spend cap lagana chahta hun — kharcha $5 cross kare to service ruk jaye, bill surprise na aaye. Ijazat hai?" |
| 5 | **Approve region `asia-south1` (Mumbai)** instead of Singapore | Mumbai is Tier 1 (poora free tier) and Pakistan ke sab se qareeb; Singapore Tier 2 hai (mehenga). Final call his. | "Backend Mumbai region (asia-south1) mein deploy karun ya Singapore mein jahan Supabase hai? Mumbai sasta hai aur qareeb bhi — Singapore ka koi faida nahi kyunke Supabase waise bhi internet se connect hota hai. Mumbai theek hai?" |
| 6 | **Provide browser access / do the console steps** for: enabling Cloud Run, Artifact Registry, Cloud Build, Secret Manager APIs; creating the Artifact Registry repo; Workload Identity Federation for GitHub Actions | API enablement and IAM setup need console access on his Google account. The agent cannot do this from the VM. | "Jab billing ready ho to main aap ko console ke 4–5 steps bhej dunga (APIs enable karna, GitHub ko deploy ki permission dena). Aap apne browser mein woh steps kar dein ge, ya mujhe browser access dein ge?" |
| 7 | **Gemini API key — DEFERRED, do not ask again.** Per the user's 20 Nov decision, the Gemini key is a later matter ("baad ki bat hai"). | — | No question to ask. When the backend is ready for the Gemini step, the key goes into Secret Manager via his own console action at that time; until then the backend must work with the non-Gemini routes (Tesseract etc.). |

**What is NOT blocked:** writing the FastAPI code, the Dockerfile, the GitHub
Actions workflow file, and the deploy/run commands can all be prepared now
without any of the above. Only the actual first deploy needs items 1–3 and 6.

---

## 8. Unverified / open items (do not treat as fact)

- Exact **Tier 2 unit prices for asia-southeast1 (Singapore)** — the pricing
  page fetch shows us-central1 defaults only. Read in console/pricing
  calculator before choosing Singapore.
- **Secret Manager free allowance** exact figure (secondary sources say 6
  active secret versions/month).
- **Cloud Build beyond-free-tier per-minute rate** (~$0.003–0.006/min per
  secondary sources) and the **120/day vs 2,500/month** discrepancy — the
  official free-tier docs page says 2,500 build-minutes/month for
  `e2-standard-2`; older pages say 120/day. Both may be true for different
  machine types; verify in console.
- **Container Registry (GCR) deprecation status** — not verified from an
  official source here; Artifact Registry is recommended regardless.
- **Spend cap availability** for Cloud Run in this account/region (public
  preview since July 2026 per secondary sources) — verify in console.
- **Latency Mumbai vs Singapore from Pakistan / from the app's users** —
  no measurements taken; probe at deploy time.
- Whether the **$300 trial** is still available on the user's Google account.
- Cloud Run **startup/liveness probe defaults** and the **SIGTERM grace
  period default** — confirm from docs at build time.
- Real **per-job billed seconds** — the 30–60 s assumption must be replaced
  with measured timings once the backend runs.

---

## 9. Sources (all checked 2026-11-20)

1. Google Cloud — Cloud Run pricing (official): https://cloud.google.com/run/pricing
   — free tier, unit prices, Tier 1/Tier 2 region lists, billable instance time,
   source deployments. Page crawled 2026-11-20 17:10 UTC.
2. Google Cloud — Free Tier / Free Trial (official docs):
   https://docs.cloud.google.com/free/docs/free-cloud-features — Always Free
   list (Cloud Build 2,500 build-minutes/month e2-standard-2; Artifact
   Registry 0.5 GB/month); "Google Cloud's Free Tier requires a billing account."
3. Google Cloud — Cloud Run Functions (1st gen) pricing (official):
   https://cloud.google.com/functions/pricing-1stgen — "even for free tier
   usage, we require a valid billing account."
4. Google Cloud — Artifact Registry pricing (official):
   https://cloud.google.com/artifact-registry/pricing — first 0.5 GB free,
   then $0.10/GB/month.
5. Google Cloud — Rollbacks, gradual rollouts, traffic migration (official docs):
   https://cloud.google.com/run/docs/rollouts-rollbacks-traffic-migration
6. Google Cloud — n8n Cloud Run hosting docs (official n8n docs mirror):
   "even if your Cloud Run service runs for free you must have billing
   activated to deploy."
7. Exodus — "The Google Cloud free tier for a small app" (Oct 2026):
   https://exodus.elim.io/blog/google-cloud-free-tier-for-a-small-app — free
   tier as a Tier 1-priced spending discount; per-billing-account aggregation.
8. Exodus — "Google Cloud budget alerts and billing export" (Oct 2026):
   https://exodus.elim.io/blog/budget-alerts-and-the-billing-export — budgets
   don't stop spending; spend caps; cost-data lag.
9. Exodus — "Cloud Run revisions, traffic and rollbacks" (Oct 2026):
   https://exodus.elim.io/blog/revisions-traffic-splitting-and-rollbacks —
   rollback command, `--to-latest` gotcha, revision limits.
10. Guanacos Tech — "Google Cloud budget alert: thresholds, emails, spend caps"
    (2026): https://guanacostech.com/blog/google-cloud-billing-alerts-budgets-small-business
    — alerts-only budgets do not cap spending; spend cap behaviour.
11. CloudWebSchool — "GCP Billing Budgets and Alerts" (2026):
    https://cloudwebschool.com/docs/gcp/cost-management/billing-budgets-and-alerts/
    — budget creation steps, roles required, thresholds.
12. EgressCost — "GCP Per-Region Egress Pricing Matrix (2026)", live pricing
    verified 2026-09: https://egresscost.com/gcp/regions/ — Premium $0.12/GiB
    first tier, priced by destination; Singapore $0.12.
13. The Proof Desk — "Google Cloud Review 2026" (2026):
    https://theproofdesk.com/google-cloud-review — $300 trial, Always Free
    list, egress $0.12/GiB.
14. AgentDeals — "Google Cloud Run Free Tier 2026", last read 2026-11-02:
    https://agentdeals.dev/vendor/google-cloud-run — free-tier figures,
    "Free Tier requires a billing account" (citing Google's free-tier docs,
    read 2026-10-07); AI Studio Starter Tier exception note.
15. Firebase docs — "Set up spend caps for Firebase services":
    spend cap budgets pause the service at 100%; alerts-only budgets do not.

VM tooling outputs recorded in §1 are from commands run on this VM on
2026-11-20 (~22:11 PKT). No console, billing, or project state was accessed;
the existing GCP project's billing/Cloud Run status is therefore **unknown**,
not "not enabled".
