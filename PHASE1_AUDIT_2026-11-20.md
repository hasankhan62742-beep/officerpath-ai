# OfficerPath AI — Phase 1 Audit + Python Backend Implementation Plan

- **Date:** 2026-11-20 (audit run ~22:10–22:40 PKT)
- **Auditor role:** Phase 1 audit agent (read-only; no code, schema, or deploy changes made)
- **App:** OfficerPath AI v2.0.4+5400, package `com.qadeerautomations.officerpath`
- **Project dir:** `~/workspace/officerpath-ai/` (NOT a git repo locally; GitHub `hasankhan62742-beep/officerpath-ai`, main HEAD `5e820936` per task context — not re-verified here, no git available in this VM path)
- **Supabase:** project `officerpath-ai`, ref `gliebuyyjguxrwdfuakz`, `https://gliebuyyjguxrwdfuakz.supabase.co`, Free plan, Singapore (`ap-southeast-1`)
- **Scope:** Master Prompt 01, Phase 1 — audit the existing system, then plan the new Python backend (`officerpath-pdf-engine`). The on-device ML Kit parser fix work was STOPPED by the user on 20 Nov 21:58 PKT and is NOT resumed here.

## 0. What was actually verified live vs from files

| Claim | Basis |
|---|---|
| Supabase project exists, `ACTIVE_HEALTHY`, region `ap-southeast-1`, Postgres 17 (`17.12.0.000`), created `2026-11-19T14:11:47.631901Z` | **Live-verified** this session via Management API `GET /v1/projects/gliebuyyjguxrwdfuakz` (200) using the `custom.supabase` connector credential |
| Edge Functions deployed: `send-notification` ACTIVE v3 `verify_jwt=true`; `issue-code` ACTIVE v3 `verify_jwt=true`; `redeem-code` ACTIVE v3 `verify_jwt=true`; `delete-account` ACTIVE v2 `verify_jwt=true`; `payment-alert` ACTIVE v2 `verify_jwt=false` | **Live-verified** this session via `deploy_function.py --list` (python3; see note below) |
| All schema/RLS/trigger/bucket detail in §2 | **File-based only** — read from `supabase/migrations/001–014` in the working tree. The Management API token is scoped to Project Settings Read + Edge Functions Read/Write; it has **no SQL/query endpoint**, so the live database schema, live RLS policy text, live row counts, and live bucket contents could NOT be queried from this VM. See §8 "Guessed / unverified" for the exact Dashboard/SQL alternative. |
| Flutter code paths, versions, test counts | **File-based** — read from the working tree. `flutter build` / `flutter test` were NOT run (build is safety-blocked on this VM; tests were not re-run — counts quoted are from the cited reports, not this session). |
| Paper 66 failure numbers | From the four cited reports (§5), not re-measured this session. |

**Tooling note:** the task brief said to use `~/workspace/custom-connectors/custom.supabase/venv/bin/python` — that path does **not exist** in this VM (no `venv/` under the connector dir). Plain `python3 ~/workspace/custom-connectors/custom.supabase/bin/deploy_function.py --list` worked and returned the live function list above. The connector doc's `--list` path is otherwise accurate.

**No secret or key value is printed anywhere in this report** — only key/secret *names* and presence. No secret values were read.

---

## 1. Stack summary

### Flutter app (client — the whole product today)

| Layer | Technology / facts |
|---|---|
| Framework | Flutter, Dart SDK `>=3.7.0 <4.0.0`, Flutter `>=3.35.0`; `version: 2.0.4+5400` (`pubspec.yaml`) |
| Local storage | sqflite (`officerpath.db`, schema v4) + SharedPreferences; see §3.3 |
| PDF text layer | Hand-rolled PDF text extractor (`lib/services/pdf_text_extractor.dart`, 1,954 lines — own parser, CMap/font handling, no `pdf` text-extraction dependency) run in a background isolate via `compute()` |
| PDF rendering | `pdfx: 2.11.0` (Android PdfRenderer wrapper); pages rendered to JPEG at 1600 px wide, quality 85 |
| On-device OCR | ML Kit Latin (`google_mlkit_text_recognition: 0.16.0`, `TextRecognitionScript.latin`); Tesseract `eng+urd` (`tesseract_ocr: ^0.6.0`, bundled `assets/tessdata/`, PSM 3); Gemini vision (user's own key, see below) |
| Parser | `lib/services/mcq_parser.dart` (5,713 lines) + `answer_key.dart` (1,358), `book_structure.dart` (844), `paper_identity.dart` (387), `parse_validation.dart` (254), `document_status.dart` (202), `extraction/` registry (2 files) |
| Backend client | `supabase_flutter: ^2.9.0`; URL + anon key **only** from `--dart-define` (`SUPABASE_URL` / `SUPABASE_ANON_KEY`); empty values = offline v1 mode (`lib/services/supabase_config.dart`) |
| Auth | Supabase Auth: email/password + Google (`google_sign_in: ^7.0.0`); PKCE deep link `officerpath://reset-password` (`app_links`); password reset via Supabase email |
| Push | Firebase Cloud Messaging (`firebase_core: ^4.0.0`, `firebase_messaging: ^16.0.0`); `android/app/google-services.json` holds client config only (no server key) |
| Payments | Manual only — Easypaisa/JazzCash, user pays in their own wallet app, submits TID + receipt screenshot; **no in-app payment SDK** (`billing_service.dart` is a stub that never grants Premium) |
| Updates | Self-update via GitHub Releases + `ota_update: 7.1.0`; `REQUEST_INSTALL_PACKAGES`; APK picked by `-arm64.apk` name |
| Other deps | `file_picker`, `path_provider`, `share_plus`, `pdf` (result export), `archive`, `image` (preprocessing), `http`/`xml` (RSS), `flutter_secure_storage`, `crypto`, `intl`, `url_launcher`, `package_info_plus` |
| Tests | 93 test files in `test/`; last agent-reported full runs: v2.0.3 **867 passed / 5 skipped / 0 failed**, v2.0.4 **882 passed / 5 skipped / 0 failed** (`flutter analyze` 0 issues) — quoted from `PHONE_MLKIT_PARSE_2026-11-20.md` and `MLKIT_ROBUSTNESS_2026-11-20.md`, not re-run here |
| Admin panel | Static web app in `admin/` (`app.js` ~782+ lines, `index.html`, `config.js` — local only, gitignored; `config.example.js` in repo), hosted at `https://officerpath-admin.pages.dev/`; uses Supabase JS client with anon key; gate = sign-in + `profiles.is_admin` check; RLS is the real enforcement |
| CI | `.github/workflows/build-apk.yml` — `flutter build apk --debug` on release/tag; secrets via GitHub repo secrets as `--dart-define`; **no keystore step** (H1 from the security audit — every CI build signs with a fresh ephemeral debug keystore; the permanent keystore now exists at `~/workspace/officerpath-ai-keystore/` per memory, but whether CI uses it was not verified in this audit) |

### Supabase (server — auth, money, sync only; NO parsing)

- Postgres 17, Free plan, Singapore. Auth (email + Google), PostgREST, Storage (1 private bucket), Realtime (payments only), Edge Functions (5, Deno/TypeScript, all `verify_jwt=true` except the webhook receiver `payment-alert`).
- **There is no server-side PDF/OCR/parsing of any kind today.** All parsing is on-device in Dart. That is the gap the Python backend fills.
- Keep-alive: `lib/services/keep_alive.dart` — daily cron ping of `GET /rest/v1/profiles?select=id&limit=1` + a lightweight `profiles` select on app launch (Free plan pauses after 1 week of inactivity).

### Gemini (client-side only, user's own key)

- Model: `gemini-3.5-flash-lite` — the ONLY model id in the app (`lib/services/gemini_config.dart:23`); endpoint `generativelanguage.googleapis.com/v1beta/models/<model>:generateContent`; 120 s timeout per call (`gemini_client.dart`); vision OCR `maxOutputTokens` 2048, temp 0.0; vision image width 1000 px.
- Key stored **only** in `flutter_secure_storage` under key name `gemini_api_key_v1` (`secure_key_store.dart`); never in SharedPreferences/sqflite/logs; sent only to Google. Key is per-user (Option A — the user enters their own free key in Settings; the owner pays Rs 0). **There is no server-side Gemini key anywhere in the current system.**
- Known live facts: `gemini-2.5-flash-lite` returns HTTP 404 (tested 19 Nov 2026 — must not be used); Gemini vision OCR on Paper 66 pages was **blocked by the recitation filter** on p3 (6 blocks) and p5 (2 blocks) during the VM baseline — a server-side Gemini route will hit the same filter on copyrighted past-paper text and needs a mitigation plan (§7, risk R7).

---

## 2. Supabase schema inventory (from migration files 001–014)

> Source: `supabase/migrations/*.sql` in the working tree. Live application of each file is **unverified from this VM** (see §0/§8). Per the task brief, migrations 001–014 are stated applied; per `SECURITY_FIXES_2026-11-20.md` (written earlier on 20 Nov), migrations 007–011 were *not yet applied live* at that time, while memory records 012–014 applied live and 006's C1 block verified live 08:24 PKT. The coordinator must confirm 007–011 live status in the Dashboard before the backend relies on them.

### 2.1 Tables

**`public.profiles`** (001 + 004) — one row per Auth user, auto-created by trigger.
| Column | Type / constraint |
|---|---|
| `id` | uuid PK, FK `auth.users(id)` ON DELETE CASCADE |
| `username` | text UNIQUE NOT NULL (auto-derived from chosen name or email prefix, suffixed `ali1, ali2…` on collision) |
| `email` | text NOT NULL |
| `plan` | text NOT NULL DEFAULT `'free'`, CHECK `IN ('free','premium')` |
| `premium_until` | timestamptz, nullable |
| `is_admin` | boolean NOT NULL DEFAULT false |
| `created_at` / `updated_at` | timestamptz NOT NULL DEFAULT now() (`updated_at` maintained by trigger) |
| `fcm_token` | text, nullable (004) |
| `fcm_token_updated_at` | timestamptz, nullable (004) |
| `notifications_enabled` | boolean NOT NULL DEFAULT true (004) |

**`public.activation_codes`** (001) — single-use Premium codes; **only the SHA-256 hash is stored, never the plain code**.
| Column | Type / constraint |
|---|---|
| `id` | uuid PK DEFAULT gen_random_uuid() |
| `code_hash` | text UNIQUE NOT NULL |
| `plan` | text NOT NULL (values `premium_1month` / `premium_2months` / `premium_1year` per issue-code `PLAN_MAP`; no DB CHECK on this column — noted gap) |
| `months` | int NOT NULL CHECK `IN (1, 2, 12)` |
| `user_id` | uuid FK `auth.users(id)`, nullable (code may be unbound at issue) |
| `issued_by` | uuid FK `auth.users(id)` |
| `issued_at` | timestamptz NOT NULL DEFAULT now() |
| `expires_at` | timestamptz NOT NULL (7 days from issue, per issue-code) |
| `used_at` | timestamptz, nullable |
| `used_by` | uuid FK `auth.users(id)`, nullable |

**`public.payments`** (001 + 008 + 012 + 013) — manual-payment proofs.
| Column | Type / constraint |
|---|---|
| `id` | uuid PK DEFAULT gen_random_uuid() |
| `user_id` | uuid NOT NULL FK `auth.users(id)` |
| `email` | text NOT NULL |
| `plan` | text NOT NULL; CHECK `plan IN ('premium_1month','premium_2months','premium_1year')` (008, constraint `payments_plan_valid`) |
| `method` | text NOT NULL CHECK `IN ('easypaisa','jazzcash')` |
| `transaction_id` | text NOT NULL |
| `status` | text NOT NULL DEFAULT `'pending'` CHECK `IN ('pending','approved','rejected')` |
| `created_at` | timestamptz NOT NULL DEFAULT now() |
| `reviewed_by` / `reviewed_at` | uuid FK / timestamptz, nullable |
| `code_id` | uuid FK `activation_codes(id)`, nullable (set on approval — the payment↔code audit link) |
| `screenshot_path` | text, nullable (013; storage path `<uid>/<unique>.jpg` in the `payment-proofs` bucket) |
| Index | `payments_tid_approved_unique` — UNIQUE on `transaction_id` WHERE `status='approved'` (012; partial — pending/rejected TIDs may repeat) |

**`public.test_results`** (001) — cloud backup of finished tests; local sqflite `attempts` is the source of truth.
| Column | Type |
|---|---|
| `id` | uuid PK DEFAULT gen_random_uuid() |
| `user_id` | uuid NOT NULL FK `auth.users(id)` |
| `book_title` | text, nullable |
| `exam` | text, nullable |
| `score` / `total` | int, nullable |
| `created_at` | timestamptz NOT NULL DEFAULT now() |

**`public.sent_notifications`** (004) — audit log of admin push sends (one row per send, not per device).
| Column | Type / constraint |
|---|---|
| `id` | uuid PK DEFAULT gen_random_uuid() |
| `title` / `body` | text NOT NULL |
| `audience` | text NOT NULL CHECK `IN ('all','premium','free')` |
| `notification_type` | text NOT NULL CHECK `IN ('update_available','announcement')` |
| `version` | text, nullable |
| `sent_by` | uuid FK `auth.users(id)` |
| `sent_at` | timestamptz NOT NULL DEFAULT now() |
| `recipient_count` | int NOT NULL DEFAULT 0 |

**`public.waitlist`** (005 + 009) — public waitlist emails.
| Column | Type / constraint |
|---|---|
| `id` | uuid PK DEFAULT gen_random_uuid() |
| `email` | text NOT NULL UNIQUE; CHECK regex `^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$` |
| `created_at` | timestamptz NOT NULL DEFAULT now(); index `waitlist_created_at_idx` (009) |
| `source` | text NOT NULL DEFAULT `'waitlist-page'` |

**`public.redeem_attempts`** (011) — per-user redeem rate-limit log.
| Column | Type |
|---|---|
| `id` | uuid PK DEFAULT gen_random_uuid() |
| `user_id` | uuid NOT NULL FK `auth.users(id)` ON DELETE CASCADE |
| `attempted_at` | timestamptz NOT NULL DEFAULT now() |
| Index | `redeem_attempts_user_time_idx (user_id, attempted_at DESC)` |

### 2.2 RLS policies (all tables have RLS enabled)

| Table | Policy (from 002 + 007 + 008) |
|---|---|
| profiles | SELECT own (`auth.uid() = id`); INSERT own (`auth.uid() = id`); UPDATE own WITH CHECK (`auth.uid() = id AND (is_admin IS NOT TRUE OR is_admin())`); SELECT all for admins; UPDATE all for admins |
| payments | SELECT own; INSERT own — tightened by 008 to `WITH CHECK (auth.uid() = user_id AND status='pending' AND reviewed_by IS NULL AND reviewed_at IS NULL AND code_id IS NULL)`; SELECT all for admins; UPDATE for admins; **no DELETE policy** |
| test_results | SELECT own; INSERT own; SELECT all for admins; **no UPDATE/DELETE (append-only)** |
| activation_codes | **Zero client policies** in 002 (client-inaccessible by design); 007 adds ONE admin-only SELECT (`USING (public.is_admin())`); no INSERT/UPDATE/DELETE for clients — writes only via Edge Functions with service_role |
| sent_notifications | SELECT admins only; INSERT admins only; no UPDATE/DELETE (append-only) |
| waitlist | INSERT `TO anon WITH CHECK (true)` (deliberate, public signup); SELECT admins only; no UPDATE/DELETE |
| redeem_attempts | RLS enabled, **zero policies** — service_role only |

### 2.3 Functions & triggers (Postgres)

| Object | Purpose |
|---|---|
| `public.is_admin()` | SECURITY DEFINER, `SET search_path = public` (010); returns true iff caller's `profiles.is_admin` |
| `public.handle_new_user()` | SECURITY DEFINER trigger on `auth.users` INSERT; creates `profiles` row with unique username; `SET search_path = public` (010) |
| `public.set_updated_at()` | Trigger fn; maintains `profiles.updated_at` (plain, not security definer) |
| `public.prevent_client_premium_grant()` + trigger `trg_prevent_client_premium_grant` (006) | BEFORE UPDATE on profiles: raises unless caller is service_role or admin when `plan`/`premium_until`/`is_admin` change — **the C1 fix, verified blocking live 08:24 PKT 20 Nov** |
| `public.coerce_client_profile_insert()` + trigger (006) | BEFORE INSERT on profiles: coerces `plan='free'`, `premium_until=NULL`, `is_admin=false` for non-admin/non-server inserts |
| `public.force_pending_payment_status()` + trigger (008) | BEFORE INSERT on payments: coerces `status='pending'` for client inserts |
| `public.throttle_waitlist_insert()` + trigger (009) | BEFORE INSERT on waitlist: caps global signups at 30 per trailing 60 s for anon (bypasses service_role/admin/no-JWT Dashboard); best-effort, not a hard limiter |
| Realtime | `payments` added to `supabase_realtime` publication (014) — admin panel live alert + sound |
| Extensions | `pgcrypto` (for `gen_random_uuid()`) |

### 2.4 Storage buckets

| Bucket | Properties |
|---|---|
| `payment-proofs` (013) | **Private**; 5 MB cap; MIME allowlist `image/jpeg`, `image/png` only. Policies on `storage.objects`: INSERT by authenticated users only under their own uid folder (`storage.foldername(name)[1] = auth.uid()::text`); SELECT by admins (all) and by owners (own folder); **no UPDATE/DELETE** (receipts immutable). Used for payment receipt screenshots only. |
| *(no other buckets)* | **There is no bucket for user PDFs/books, no bucket for parsed output, no bucket for OCR images.** The app never uploads a book anywhere — books live only on-device. The backend must create whatever bucket(s) it needs (see §7). |

### 2.5 Edge Functions (live-verified deployed; source in `supabase/functions/`)

| Function | Version (live) | verify_jwt | What it does (from source) |
|---|---|---|---|
| `redeem-code` | v3 | true | JWT verified; code format `OP([123])-([A-Z2-9]{6})`, SHA-256 lookup; enforces single-use (atomic claim — `.select("id")` must return exactly 1 row, M1 fix), expiry, user binding; extends `premium_until` from existing date, never shortens; rate-limited 10 attempts/hour/user via `redeem_attempts` (011), fail-open. Secrets: auto-injected Supabase URL/anon/service-role |
| `issue-code` | v3 | true | Admin-only (`profiles.is_admin` re-checked server-side); allowlisted plans (`premium_1month`→OP1/1mo, `premium_2months`→OP2/2mo, `premium_1year`→OP3/12mo); `crypto.getRandomValues` code; stores hash only; checks TID not already used on an approved payment (012); marks the payment approved + sets `code_id`; emails plain code once via Resend (`RESEND_API_KEY`, `RESEND_FROM` secrets; failure never blocks the sale, reported as `email_sent:false`). Note: Resend delivers only to the account owner's own address until `abdulqadeerml.com` is verified in Resend |
| `delete-account` | v2 | true | JWT owner only (no `user_id` param); deletes `test_results`/`payments` rows, unlinks (not deletes) `activation_codes`, then `auth.admin.deleteUser()`; `profiles` follows via ON DELETE CASCADE |
| `send-notification` | v3 | true | Admin-only; allowlisted audience (`all`/`premium`/`free`) and type (`update_available`/`announcement`); respects `notifications_enabled` + non-null `fcm_token`; FCM HTTP v1 with hand-rolled RS256 OAuth2 from `FIREBASE_SERVICE_ACCOUNT` secret; dead-token cleanup (clears on `UNREGISTERED` — L5 note: `INVALID_ARGUMENT` was also treated as dead, fix status unverified here); logs to `sent_notifications` |
| `payment-alert` | v2 | **false** | Database-webhook receiver (webhook on `payments` INSERT); auth by shared-secret header `x-webhook-secret` (`PAYMENT_ALERT_SECRET` Edge Function secret); emails admin via Resend with buyer/plan/method/TID + panel link; never approves or issues a code. Webhook itself is Dashboard-created (Database → Webhooks → HTTP POST to `…/functions/v1/payment-alert`) — its live existence was **not** verified in this audit |

**Edge Function secrets (names only, values never seen):** `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` (auto-injected), `RESEND_API_KEY`, `RESEND_FROM`, `FIREBASE_SERVICE_ACCOUNT`, `FIREBASE_PROJECT_ID` (optional), `PAYMENT_ALERT_SECRET`. Whether each is actually set in the Dashboard was **not** verified here (security audit §9 lists this as unverifiable from files).

### 2.6 User-record relationships

```
auth.users (1) ──< profiles (1:1, id = auth.users.id, ON DELETE CASCADE)
auth.users (1) ──< payments (1:N, user_id; reviewed_by; code_id → activation_codes.id)
auth.users (1) ──< activation_codes (1:N as user_id [buyer]; issued_by [admin]; used_by)
auth.users (1) ──< test_results (1:N, user_id)
auth.users (1) ──< sent_notifications (1:N as sent_by)
auth.users (1) ──< redeem_attempts (1:N, user_id, ON DELETE CASCADE)
payments (N:1) ──> activation_codes (code_id; set by issue-code on approval)
waitlist — standalone (email only, no user link)
profiles.fcm_token / notifications_enabled — push targeting (send-notification filters on these)
```

Money flow (the only revenue path): user pays in Easypaisa/JazzCash app → submits `payments` row (`pending`, TID, screenshot) → admin checks TID + amount + date in own wallet app + receipt → admin panel calls `issue-code` → code emailed to buyer (Resend) + `payments.status='approved'` + `code_id` linked → buyer enters code in app → `redeem-code` → `profiles.plan='premium'`, `premium_until` set. **Premium is granted ONLY by this path** (C1 trigger blocks all client-side grants; admin/service_role allow-branches still unproven end-to-end per memory).

Free-test accounting: **3 tests per calendar month** for free users (`SubscriptionService.freeTestLimit = 3`); counted from the user's `test_results` rows created in the current month (server) with a local fallback; Premium = unlimited. The count is enforced in-app, not by a DB constraint — a backend must not silently change this.

---

## 3. Workflow map (app, as built today)

### 3.1 Upload → processing → storage → test creation

```
User picks file (file_picker: PDF / TXT / DOCX / JPG / PNG camera photo)
        │
        ▼  lib/screens/upload_screen.dart (~2,410 lines)
        │  toggles: [_urduBook] "Urdu book" · [_bestQualityOcr] "Behtar quality (Gemini)"
        │  file bytes read; sourceId/sourceLabel assigned
        ▼
PdfImportService.importPdf / importImage / importDocx / resultFromTextParse
        │  (lib/services/pdf_import_service.dart, 916 lines)
        ├─ importPdf:
        │   1. compute(processPdfInBackground) — hand-rolled text-layer extraction
        │      (pdf_text_extractor.dart) → per-page text map
        │   2. Page classification: text page iff ≥10 words AND not a repeated
        │      stamp (same short text on ≥3 pages and ≥half the doc, <50 words)
        │   3. Non-text pages → OCR, one page at a time, cancellable:
        │      render via pdfx (1600 px wide JPEG q85) → ocrPage() tiers (§4)
        │      OCR cap: maxOcrPagesPerImport = 100 (rest need a split book)
        │   4. If any OCR ran → compute(parseTextInBackground) re-parse with
        │      per-page text + ocrPages provenance
        ├─ importImage: same OCR tiers on the single image (page 1, ocrPages=[1])
        ├─ importDocx: ZIP/XML paragraph extraction → same parser
        ├─ extractKeyText: SEPARATE key file (PDF/image/DOCX/TXT) run through the
        │   SAME import path; only .text kept; MCQ parse discarded; entries via
        │   parseKeyEntries → applyAttachedKey (answer_key.dart)
        └─ TXT/paste: plain-text parse, no OCR
        ▼
parseMcqsFromPages(pages, …) — mcq_parser.dart:576
        │  book_structure (parts/papers) → per-block parse → answer resolution
        │  (precedence: explicit answer line > key > tick > bold > star > AI)
        │  → ParseResult: questions / answerPending / skipped / errors /
        │     keySectionsFound / keyEntriesApplied / unmatchedKeyEntries /
        │     conflicts / parts / keyPaperReport / numberGaps|Duplicates
        ▼
Upload screen preview (ExtractionPreviewDialog + status line)
        │  document_status.dart — 7 statuses (NO ANSWER KEY DETECTED /
        │  ANSWER KEY DETECTED / EXTRACTED BUT UNMATCHED / PARTIALLY MATCHED /
        │  FULLY VERIFIED / CONFLICTING / MANUAL REVIEW REQUIRED); counts line;
        │  Gemini failure line when best-quality was ticked but ran on 0 pages
        │  User may: save all / save selected parts / page-range select /
        │  manually correct pending answers / attach a separate key file
        ▼
StorageService.addSource(source, questions) — ONE sqflite transaction
        │  (storage_service.dart): delete old questions for source → insert
        │  source row → batch-insert questions → recount from COUNT(*)
        │  Local tables: sources / questions / attempts (schema v4, §3.3)
        ▼
Test creation (test_generator.dart + test_screen.dart)
   questions grouped BY SUBJECT (never interleaved; shuffle WITHIN subject only);
   canonical order GK → Pakistan Affairs → Islamic Studies → English → Urdu →
   Maths → Everyday Science → Computer/IT → Current Affairs → Other;
   exam patterns PPSC 100Q/90min/−0.25, FPSC 100/100min, CSS MPT 200Q/200min;
   free limit 3/month enforced pre-test; attempt saved locally (attempts)
   AND synced as ONE row to Supabase test_results (cloud backup)
```

**What never leaves the phone today:** the PDF bytes, the rendered page images, the OCR text, the parsed questions. The ONLY Supabase writes in the whole upload→test flow are: `test_results` insert (one row per finished test) and the free-test count read. **Books are not synced, not backed up, not shared between devices.** A reinstall loses local books/history (Supabase account + Premium survive).

### 3.2 Supabase client configuration

- `main.dart`: `Supabase.initialize(url, publishableKey: anonKey)` only when `SupabaseConfig.isConfigured` (both dart-defines non-empty); failure never kills startup (offline mode). Auth gate at startup: live session → Home, else Auth screen.
- Call sites (grep-verified): `auth_service.dart` (sign-up/in incl. Google `signInWithIdToken`, reset password, profile fetch/upsert, `delete-account` invoke); `subscription_service.dart` (`profiles` select, `test_results` count + insert); `activation_service.dart` (`redeem-code` invoke); `payment_proof_service.dart` (`payments` insert + list, `payment-proofs` storage upload); `push_service.dart` (`profiles` FCM token/opt-out upserts); admin panel `admin/app.js` (all tables + signed URLs + Realtime on payments).
- **No Supabase Storage use for books; no Supabase Realtime use in the app** (Realtime is admin-panel-only, on `payments`).

### 3.3 Local sqflite schema (v4, `officerpath.db`)

| Table | Columns |
|---|---|
| `sources` | `id TEXT PK, title, kind, question_count INT DEFAULT 0, added_at TEXT, is_built_in INT DEFAULT 0` |
| `questions` | `id INTEGER PK AUTOINCREMENT, text, option_a..d, correct_index INT, subject, source_id, source_label, explanation DEFAULT '', page INT DEFAULT 0, part TEXT DEFAULT '', answer_source TEXT DEFAULT '', answer_verified INT DEFAULT 0, confidence REAL DEFAULT 0, mark_provenance TEXT DEFAULT '', original_correct_index INT NULL, bold_options TEXT DEFAULT ''`; index `idx_questions_source(source_id)` |
| `attempts` | `id INTEGER PK AUTOINCREMENT, exam_id, exam_name, book_title, total_questions, correct, wrong, skipped, score REAL, percent REAL, passed INT, duration_seconds INT, attempted_at TEXT, per_subject_json DEFAULT '{}', wrong_question_ids_json DEFAULT '[]'` |

Also: 84-question built-in sample bank seeded once (flag `sample_bank_seeded_v1`); mid-test progress in SharedPreferences (resume support, wall-clock deadline).

### 3.4 Other app subsystems (for the untouched list, §6)

- **Current Affairs:** free RSS (Dawn via FeedBurner, BBC World, Guardian World) fetched in-app, two tabs, cached (`ca_cache_service.dart`, `rss_service.dart`); free, outside the 3-test limit; in-app fetch on a real phone unverified.
- **AI generation (user-key Gemini):** `ai_generation.dart` (606 lines) — generate MCQs from book text + answer inference, validated before save (exactly 4 options, answer among them, no dupes, distractors from the book's own facts); caps: free 2 AI books/day, Premium 10/day (`GeminiConfig`); `ai_service_stub.dart` still throws `UnimplementedError` for the v1 paths (dead code — upload flow uses the real `ai_generation.dart`). Governing spec (19 Nov): extraction-only — never invent an answer; AI generation is parked for the parse path.
- **In-app updater:** GitHub Releases latest → `-arm64.apk` asset → `OtaUpdate().execute()` → system installer via FileProvider (`android/.../AndroidManifest.xml` + `res/xml/filepaths.xml`, fixed v2.0.3). Known gaps: no SHA-256/size verification of the downloaded APK (M3, open); CI signing key continuity (H1, open/partially addressed by the permanent keystore — CI usage unverified here).
- **Push:** FCM token stored in `profiles.fcm_token`; admin sends via `send-notification`; opt-out via `notifications_enabled`.

---

## 4. OCR map (all existing OCR integration)

### 4.1 The three tiers and routing

Per scanned page, `ocrPage()` in `pdf_import_service.dart` runs tiers in order and keeps the best text so far; a tier that throws never kills the page:

| Tier | Engine | When | Method label |
|---|---|---|---|
| 1 — ML Kit (default) | `google_mlkit_text_recognition`, Latin script only | Always first, for every OCR page | `English OCR: device (ML Kit)` |
| 2 — Tesseract | `tesseract_ocr`, `eng+urd`, PSM 3, on preprocessed (grayscale/contrast/sharpen) bytes | Only when `urduBook` OR the ML Kit text contains Urdu script; kept only if it yields more words, or adds Urdu the ML Kit text lacks | `Urdu OCR: device (Tesseract)` |
| 3 — Gemini vision | `GeminiVisionOcr` → `GeminiClient.generateText`, model `gemini-3.5-flash-lite`, prompt: "Transcribe ALL text EXACTLY as printed, line by line, reading order (left column first, then right column)… unreadable words as `[?]`", temp 0.0, maxOutputTokens 2048, image resized to 1000 px wide | Only when user ticked "Behtar quality (Gemini)" AND a `GeminiVisionOcr()` was passed (upload_screen passes it iff ticked) AND a key exists in secure storage; replaces text when non-empty | `Urdu OCR: best quality (Gemini)` |

Honest limits recorded in code: Tesseract on dense ~130 DPI Nastaliq scans is partially readable, NOT reliable for clean Urdu MCQs; ML Kit returns plain text with **no style info** (bold cannot be detected from a photo; circled/highlighted marks only count when OCR reads them as text); a page that reads poorly is flagged (`poorOcrPages`, `assessOcrQuality`: good ≥20 words of ≥3 letters, poor ≥5, else unreadable) and the preview offers re-scan/Gemini instead of storing garbage silently.

**Gemini failure honesty (v2.0.3+):** `PdfImportResult` carries `geminiRequested`, `geminiPages`, `geminiFailure` (`noKey` / `noInternet` / `quota` / `badKeyOrModel` / `badResponse` / `unknown`). Before v2.0.3 a Gemini failure was swallowed by bare `catch (_)` and the ML Kit result was presented as if Gemini had run. The preview now states plainly when Gemini ran on 0 pages and why.

**Routing decision helper (pure, tested):** `chooseOcrMethod({pageHasUrdu, userPickedUrdu, userPickedBestQuality, hasGeminiKey})` in `urdu_ocr.dart` — Gemini iff best-quality + key; else Tesseract iff Urdu; else ML Kit.

### 4.2 Geometry: column split + table reconstruction (the phone-only signal)

Both run inside `_runOcrWithMlKit` on ML Kit line/element boxes — they are **the only place column geometry exists** in the system:

- `reconstructTableText(elements)` (urdu_ocr.dart) runs **first**: groups elements into visual rows by vertical overlap, splits cells at wide horizontal gaps (≥0.6 text heights), clusters cell starts into column bands (shared by ≥3 rows), requires ≥3 rows × ≥5 cells, ≥5 shared bands, table rows ≥ half the page's elements; emits one `|`-separated line per logical row (serial-number band starts new rows; serial-less rows append as continuations). Returns null when not table-like. **If it fires, the column split is skipped.**
- `columnSplitOcrText(rawText, lines)` otherwise: lines sorted top-to-bottom, split at the widest gap between line starts whose midpoint sits in the middle third of page width (0.3–0.7), gap ≥40 px; no clear gap → raw text unchanged (single column). Needs ≥4 lines.
- **Critical:** neither runs for Tesseract text (no boxes are passed — Tesseract returns plain text) nor for Gemini text (the prompt *asks* for left-column-first order, but nothing enforces it). The VM baselines that parse 100/100 use Gemini text whose order was prompt-enforced; the phone path depends entirely on the ML Kit boxes + these two functions.

### 4.3 Existing APIs / dependencies the backend must be aware of

- **Google Gemini Developer API** (client-side, user key): `generateContent` v1beta; also used for AI generation + answer inference (same client, different prompts/caps). Free tier 500 Flash-Lite req/day shared per project — the reason the app never uses a shared server key today.
- **Supabase** (Auth / PostgREST / Storage / Realtime / Edge Functions) — §2.
- **Firebase Cloud Messaging** (HTTP v1, service-account OAuth2, server-side only in `send-notification`).
- **Resend** (email for activation codes + payment alerts; `RESEND_API_KEY`/`RESEND_FROM`).
- **GitHub Releases API** (updater check; `api.github.com/repos/hasankhan62742-beep/officerpath-ai/releases/latest`).
- **RSS feeds** (Dawn/FeedBurner, BBC, Guardian — free, no key).
- **No other OCR/API vendors.** EasyOCR was tested and rejected (19 Nov: p.24 key 39/100, silent wrong answers, ~8–11 min/page — see `ocr-comparison/EASYOCR_VS_GEMINI.md`). UTRNet (92.97% real lines) is the named next candidate if a non-Gemini Urdu route is ever required; Cloud Vision Urdu test still pending (needs the user's GCP billing-linked project).

---

## 5. Failure analysis — Paper 66 (and the table photos)

### 5.1 The file

`~/workspace/user/files/ppsc_paper_66.pdf` — 7-page CamScanner scan, 5.9 MB, **no text layer** (pdftotext returns only "CamScanner"). "MODEL PAPER 66, TEHSILDAR / CONSOLIDATION OFFICER / HILL TORRENT OFFICER / READER TO MEMBERS BOARD OF REVENUE (BS-16) – 2021, English Morning", 100 MCQs, pages 521–527 of "Papers of 2021". Two-column throughout; `(A)–(D)` in a 2×2 grid, very often `(D) None of these`. **No asterisk/bold/tick marks on questions** — answers ONLY in the trailing key: p6 after Q100, headed `ANSWER KEY: Model Paper 66`, entries `1. (B) Broke out` … `78. …`; continues top of p7, `79. (B) Develop` … `100. (C) He couldn't believe`, in 3 narrow columns, **including two Urdu-script answers (Q83, Q84)**. "MODEL PAPER 67" (General Knowledge – Evening, Q1–Q10) starts mid-p7, so the PDF holds TWO papers. Some numbers clipped at the left edge on p1 (Q1, Q3–Q9 have no number in OCR). Q48's options split across columns. Running headers/footers read as text.

### 5.2 Results table (from the cited reports — not re-measured this session)

| Input | OCR | Parsed | Key applied | Unmatched | Notes |
|---|---|---|---|---|---|
| Paper 66, VM, Gemini vision text | Gemini (prompt-ordered) | **100/100** (gate test 7/7) | 100 | 0 | Baseline `PPSC66_BASELINE_2026-11-20.md` §3 (after heading fix; original baseline was 0/110 because the key heading `ANSWER KEY: Model Paper 66` was not recognised — §5.1 of that report) |
| Paper 66, phone v2.0.2, ML Kit | ML Kit | **1/100** | 0 | **~128** | Phone round 1; saved + took test: 1 GK question, 0/1 |
| Paper 66, phone v2.0.2, "Gemini" ticked | ML Kit (Gemini never ran — see §5.3) | **1 MCQ + 45 pending** | 0 | — | Phone round 2; parts list shows question stems as titles, "S1." = misread "51." |
| Paper 66, phone **v2.0.4**, ML Kit (evening re-test, ~21:18 PKT) | ML Kit | **1/100** | 0 | **39 key entries found, 0 matched; 146 blocks skipped** | **v2.0.4 IS installed on his phone (confirmed ~21:18 PKT).** The v2.0.4 recovery fixes did NOT lift the phone result: still 1 MCQ. Computer table photo on the same re-test: **4 questions, 2 answered, stems jumbled, option markers in wrong columns** — direct evidence the column/table geometry is failing on the phone, not just the numbers. |
| Paper 66, VM probe, column interleave only | synthetic | 54 | 49 | 51 | Interleave alone halves the parse |
| Paper 66, VM probe, digit misreads only (25%) | synthetic | 85 (v2.0.4 probe; earlier probe measured 9 — discrepancy recorded honestly in MLKIT_ROBUSTNESS §1, unexplained) | 85 | 1 | After v2.0.4 recovery: **98** |
| Paper 66, VM probe, combined interleave+digit | synthetic | 8 | 0 | 6 | Close to the phone's 1 |
| Paper 66, VM probe, full phone-like (A+B+B2) | synthetic | 32 → **52** after v2.0.4 fixes | 48 | 50 | Residual loss is interleave (geometry), not numbers |
| Paper 66, VM probe, real Tesseract 5.3.4 text | Tesseract psm 6 eng | 14 → **20** after v2.0.4 | 14 | 71 | Lower bound, harsher than ML Kit is likely to be |
| Interjection table photo, VM (Gemini fixture) | Gemini text | **30** | — | — | Control |
| Interjection table photo, phone ML Kit | ML Kit | (not separately reported; computer photo 2/15 — see below) | — | — | — |
| Computer table photo, phone | ML Kit | **2/15** | — | — | `PHONE_MLKIT_PARSE` §2 probe I: 0/15 on Tesseract text (plain-text tables cannot work; depends on ML Kit element boxes + `reconstructTableText`) |

### 5.3 Which stage fails — with evidence

**Stage 1 — OCR read (FAILS on the phone; this is the primary failure).** The phone's ML Kit read destroys the raw material before the parser ever sees it. Evidence: (a) the VM probe reproduces the phone's collapse (100 → 8) from *synthetic* digit-noise + column-interleave applied to the *same* Gemini text that parses 100/100 clean — same parser, same PDF, only the OCR text degraded; (b) the phone's parts list shows the OCR damage directly ("S1." for "51.", question stems as part titles, "difficult I thjnk he speaks English. (A whether"); (c) digit misreads are the documented mechanism — 1→I, 0→O, 5→S, 8→B — which kill question numbers (the block splitter needs a number to start a block) and option markers (`(B)`→`(8)`, `(D)`→`(0)`; Tesseract on P66 showed `(0)` 26×, `(8)` 15×). The v2.0.4 recovery work (category separation: digits-only in number slots, letters-only in option markers, Urdu preserved exactly; sequence validation demoting decoded numbers that break neighbour order) lifts the synthetic models substantially (digit-noise 85→98, option-markers 23→100, combined 32→52) with **0 wrong answers in every model** — but the combined/interleave model stalls at 52, and **the phone's actual ML Kit text was never captured**. Critically, the **v2.0.4 phone re-test (evening 20 Nov, confirmed installed ~21:18 PKT) still gives 1/100 on PPSC-66** (key found: 39 entries, 0 matched; 146 blocks skipped) — the VM probe gains did **not** transfer to the phone. The phone's real ML Kit read is therefore worse than the synthetic noise models (long runs of destroyed numbers/markers, not isolated corruptions — the hypothesis already recorded in MLKIT_ROBUSTNESS §1), or the geometry stage is failing first. Either way, v2.0.4 does not fix the phone result.

**Stage 2 — Column geometry (FAILS on the phone; proven by the v2.0.4 re-test).** `splitColumnsForOcr` is verified wired and running for rendered PDF pages (`pdf_import_service.dart:780`), and `reconstructTableText` is verified not to false-fire on question pages — but their *effectiveness on the phone's real ML Kit boxes* is now **disproven, not merely unproven**: the v2.0.4 evening re-test's computer table photo gave 4 questions with 2 answered, **stems jumbled and option markers in wrong columns** — exactly the signature of column/table geometry failing on real ML Kit boxes. The probe's interleave model simulates the failure the split is supposed to prevent, not the split itself; model A stays at 55 after all v2.0.4 fixes, and the MLKIT_ROBUSTNESS report explicitly declines a text-level rejoin (no column geometry in text; merging risk = fabrication under the extraction-only spec). The computer table photo (2/15 on v2.0.2; 4 questions/2 answered on v2.0.4) fails here: tables depend entirely on ML Kit element boxes, and plain-text OCR cannot carry them.

**Stage 3 — Parse (WORKS on clean text; collapses on noisy text — consequence, not cause).** On clean Gemini OCR text the parser yields 100/100 with key answers (gate test 7/7, `paper_66_67` suite). The parser's own pre-existing defects were real but secondary and are fixed in-tree: key heading `ANSWER KEY: Model Paper 66` not recognised (word `Model` broke the match — baseline root cause 1, 0/110 before the fix); `MODEL PAPER 66/67` not recognised as paper headings (everything labelled "Paper 1" — baseline root cause 2); numberless stems (Q1, Q3–Q9, edge-clipped) vanishing silently (baseline root cause 3 — now at least surfaced as pending); key/explanation lines becoming fabricated `q-only` questions marked `verified=true` (baseline root cause 4 — the most dangerous failure mode; guards added). The v2.0.4 probe shows the parser now *recovers* isolated digit/option-marker corruption; it cannot recover long runs of destroyed numbers/markers or interleaved stems — that is an input-quality ceiling, not a parser-logic gap.

**Stage 4 — Key matching (SYMPTOM, not cause).** The ~128 unmatched key entries are explained, not a key-parser failure: the true key has exactly 100 entries (1–100); whole-document key regex on *clean* text yields only 102 distinct numbers, so 128 cannot come from clean text. Demonstrated mechanisms (probe G, Tesseract text): digit misreads create phantom numbers ("1"→"14.", "81"→"28)", "100"→"499°"); `"(B)"→"1)"` splits create phantom entries (e.g. "86. 1) Wat are YOU" creates entry 1 with garbage); numbers lost ("79."→".(B)"); commas as separators ("13, (B)" — fixed §6.5 of the phone report); page/year numbers leaking in (521–527, 2021/2024); Paper 67 Explanation/Associated-Information numbered items adding key-shaped numbers. **With only 1 question parsed, even correct key entries have nothing to attach to** — unmatched=128 is the symptom of the question-parse collapse. The key-entry machinery itself works on clean text (78 entries p6 + 22 entries p7, including the Urdu Q83/Q84, letters intact).

**Stage 5 — Paper-identity gate (NOT the failure).** `decideKeyMatch` (VERIFIED/HIGH apply; NEEDS REVIEW/UNVERIFIED/MISMATCH withheld with reason in `keyPaperReport`) is unchanged and unweakened through all fix sessions; gate tests green (paper_66_67 7/7, paper_identity 12/12). A misread "MODEL PAPER 67" heading was tested as a hypothesis (probe D) and does **not** explain the 128 (counts stay 100/100). Paper 66 answers cannot contaminate Paper 67 by this gate.

**Contributing cause — Gemini silent fallback (fixed in code, v2.0.3; key is a LATER matter).** In phone round 2 the user ticked "Behtar quality (Gemini)" and got the identical ML Kit result. Code-proven cause: `upload_screen.dart` always passes a non-null `GeminiVisionOcr()` when ticked, but `ocrPage` caught the failure with bare `catch (_)` and discarded it (`ocrMethods[page] = "ML Kit"`). Leading hypothesis for *why* Gemini failed: the v2.0.1 uninstall wiped secure storage, so the Gemini key is very likely gone and was never re-entered (instant `noKey` failure fits the prompt completion time; a 120 s × 7 page timeout would have taken ~14 min). Alternative: 0–5 K/s internet at test time (would also time out). Both are now distinguishable on-device (`geminiRequested`/`geminiPages`/`geminiFailure` in the result + preview line). **Update from memory (20 Nov evening): the user has said the Gemini key is a LATER matter ("baad ki bat hai") — do NOT keep asking him about it.** The v2.0.4 evening re-test ran on ML Kit, not Gemini. Consequence for the backend plan: decision D1(a) (forward the user's own key per-request) is deprioritised until he raises it himself; the backend must be viable on a server key (D1(b), funded) or a non-Gemini OCR route (D1(c)) — see §7.2.

**Not a failure:** routing (v2.0.1 found 0 pages/0 key; v2.0.2 ran OCR and found a key — routing fix worked); the DB v3→v4 migration (proven working on the phone — user saved + took a test in v2.0.2); the update-time crash (separate FileProvider defect, fixed in code v2.0.3, proof pending phone re-test of the in-app updater).

### 5.4 Bottom line of the failure

The Paper 66 phone failure is an **input-quality failure at the OCR-read stage (Stage 1), compounded by proven column-geometry failure on the phone (Stage 2)**. The parser and the key matcher are proven correct on clean text and proven to recover isolated OCR corruption on the VM; they cannot recover text in which question numbers, option markers, and column order are simultaneously destroyed. The decisive new fact is the **v2.0.4 phone re-test (20 Nov evening): still 1/100, 39 key entries found with 0 matched, 146 blocks skipped; computer table 4 questions / 2 answered with jumbled stems and misplaced option markers** — the VM probe gains (digit-noise 85→98, option-markers 23→100) did not transfer to the phone. That is exactly the problem a server-side backend with a better OCR engine (Gemini vision with a server key, or a stronger OCR stack with real geometry) is positioned to solve — provided it receives the page *images*, not the phone's already-degraded ML Kit text, and provided the Gemini-key question is settled on the user's terms (key is a later matter; do not keep asking).

---

## 6. Production functionality that must remain untouched

These work today and the backend must not break, bypass, or duplicate them. (Anything the backend changes here needs the user's explicit approval first.)

1. **Auth & accounts** — email/password + Google sign-in, unique usernames, forgot-password (PKCE deep link), delete-account, session handling via `supabase_flutter`. No backend involvement in auth decisions.
2. **Premium & payments (the money path)** — manual Easypaisa/JazzCash proof → admin review (TID + amount + date in the owner's wallet app, receiver = his Easypaisa/JazzCash numbers) → `issue-code` → `redeem-code`. The C1 trigger (006), TID-reuse guard (012), payments insert constraints (008), and the "Premium ONLY when he approves" rule are inviolable. The backend must never write `profiles.plan`/`premium_until`/`is_admin`, never insert/update `activation_codes`, never approve a payment, never issue a code.
3. **Free-test accounting** — 3 tests/month for free users, counted from `test_results`; Premium unlimited. The backend must not change the limit, the counting, or the enforcement point without approval.
4. **Local-first books & history** — sqflite `sources`/`questions`/`attempts`, sample bank seeding, resume-mid-test, per-subject grouping + canonical subject order, exam patterns (PPSC/FPSC/CSS MPT), result PDF/PNG export + share. The backend must not migrate local data to the server silently or delete local data.
5. **Admin panel** — login gate, payments review queue, code issuing, user detail, waitlist view, sent-notifications log, Realtime payment alert + sound, receipt signed-URL viewing. Backend tables (if any) must not collide with the panel's queries.
6. **Push notifications** — FCM token storage, opt-out, `send-notification` (audiences all/premium/free; update announcements). Backend must not send pushes.
7. **In-app updater** — GitHub Releases check + APK install flow. Backend must not touch the release process or signing.
8. **Current Affairs RSS** — free, outside the test limit. No backend involvement.
9. **Waitlist** — public anon insert + throttle (009) + admin-only read. Backend must not read or write waitlist emails.
10. **Extraction-only spec + paper-identity rule** — the uploaded PDF is the ONLY source; never invent an answer; a key applies only to the paper with the SAME title; unverified answers get manual correction (original vs corrected kept separate). The backend must implement the same rules server-side, not weaken them.
11. **Privacy rules** — no CNIC/roll numbers or third-party phone numbers stored or displayed; Gemini key only in secure storage, never in logs; no tracking SDKs; receipt screenshots private bucket only.
12. **The on-device parse path itself** — the phone's ML Kit/Tesseract/Gemini import must keep working exactly as-is (offline-first). The backend is an *additional* route, not a replacement, until the user says otherwise. In particular: do not remove or rewire `pdf_import_service.dart`, `mcq_parser.dart`, `answer_key.dart`, or the v2.0.4 category-separation recovery.

---

## 7. Implementation plan — `officerpath-pdf-engine` (Python backend)

### 7.1 Design principles

1. **Additive only.** The backend adds a server-side parse route; it does not modify the app's local flow, the money path, or any existing table's semantics. Every new object lives in its own namespace (new tables, new bucket, new Edge Function if needed) so a rollback is a delete, not a migration reversal.
2. **Images in, structured MCQs out.** The backend must receive page *images* (or the PDF and render it server-side) — never the phone's ML Kit text. The Paper 66 lesson is that degraded text cannot be recovered downstream.
3. **Extraction-only, same rules as the app.** No invented questions/answers; same answer-precedence (answer line > key > tick > bold > star > AI — with AI last and only where the spec allows); same strict paper-identity gate (key applies only to same-title paper); same 7 document statuses; same "unmatched, never discarded silently" reporting.
4. **The phone stays the source of truth for storage.** The backend returns a parse result; the app saves it into sqflite exactly as it saves a local parse. The backend never writes the app's local DB and never writes `questions` anywhere server-side unless the user explicitly approves a cloud book bank later (deferred by the user on 20 Nov — "upload fix FIRST, bank later").
5. **Cost-bounded.** Free-tier-first: Supabase Free limits (500 MB DB, 500k Edge Function invocations/mo, 50k MAU), Gemini free-tier limits (500 Flash-Lite req/day shared per project — a server key does NOT scale; see decision D1). Every design choice must state its cost.
6. **No secrets in the repo.** Server keys live only as Supabase Edge Function secrets / host env vars, never in code, logs, or the report.

### 7.2 Open decisions (need the user/coordinator before building)

| # | Decision | Options / recommendation |
|---|---|---|
| D1 | **Whose Gemini key does the server use?** | (a) User's own key forwarded per-request — preserves the Rs 0 model but means the key transits the server (must never be logged/stored; needs user consent per key); (b) one server key (owner's) — simple, but free tier 500 req/day shared will cap at ~70 seven-page books/day and a paid key costs ~$0.0004/page OCR + generation costs; (c) no Gemini on the server — use only open OCR (Tesseract/UTRNet) + the ported Dart parser, accepting lower Urdu quality. **Recommend: start with (a) optional + (c) fallback, decide (b) only after measuring volume.** Do not build a paid-key path without the user's explicit funding approval. **Constraint from the user (20 Nov evening): the Gemini key is a LATER matter ("baad ki bat hai") — do NOT keep asking him about it. In practice this deprioritises (a) until he raises it himself; the backend must be demonstrably viable via (b) or (c) first.** |
| D2 | **Hosting** | (a) Supabase Edge Function (Deno/TS) calling out — but the task asks for a *Python* backend, so (b) a small Python service (FastAPI) on a free host (Render free tier / Fly.io free / Cloudflare Workers with Python is not a fit) fronted by a Supabase Edge Function proxy, or (c) Python run as a Supabase Edge Function is not supported — needs a separate host. **Recommend: FastAPI on Render free tier (sleeps; ~50 s cold start is acceptable for a minutes-long parse) behind an Edge Function that only verifies the JWT and forwards.** Confirm the host with the user (cold-start + sleep behaviour must be disclosed). |
| D3 | **Sync or async jobs?** | A 7-page Gemini-vision parse takes minutes (7 × up to 120 s worst case) — it cannot be a single synchronous HTTP call from the phone. **Recommend async: upload → job id → poll/webhook → result.** This drives the whole schema below. |
| D4 | **What does the app send?** | (a) The whole PDF (up to 100 MB app limit — too large for a free host + Edge Function 6 MB payload limits); (b) rendered page JPEGs, one per page, uploaded directly to Storage (resumable, per-page retry). **Recommend (b): app renders pages (it already renders at 1600 px for OCR) and uploads JPEGs to a new private bucket; the backend fetches them by signed URL.** Page cap: mirror the app's 100 OCR pages/import. |
| D5 | **Result format** | Must be consumable by the existing Dart `Question`/`PdfImportResult` shapes with minimal app changes. **Recommend: backend returns the app's `ParseResult` JSON shape (questions + answerPending + key diagnostics + parts + statuses) — i.e. port the Dart parser's *output contract*, not its internals, in phase 1; port the parser itself in phase 2 if needed.** |

### 7.3 New Supabase objects (all additive; nothing in §2 changes)

**New tables** (proposed names — coordinator to confirm; all RLS enabled, no client UPDATE/DELETE):

`public.pdf_jobs` — one row per backend parse job.
| Column | Type / notes |
|---|---|
| `id` | uuid PK DEFAULT gen_random_uuid() |
| `user_id` | uuid NOT NULL FK `auth.users(id)` ON DELETE CASCADE |
| `source_label` | text (book title as shown in the app) |
| `page_count` | int NOT NULL |
| `status` | text NOT NULL DEFAULT `'queued'` CHECK `IN ('queued','uploading','processing','done','failed','cancelled')` |
| `ocr_engine` | text (e.g. `'gemini-vision'`, `'tesseract'`, `'hybrid'`) — which engine actually ran, for honest reporting |
| `error` | text, nullable (user-facing reason, never a stack trace or key material) |
| `result_summary` | jsonb, nullable (counts only: parsed/skipped/key applied/unmatched/parts — the full result lives in Storage, not the DB, to stay under the 500 MB Free limit) |
| `created_at` / `updated_at` / `completed_at` | timestamptz |
| Indexes | `(user_id, created_at DESC)`; partial index on `status IN ('queued','processing')` for the worker queue |

`public.pdf_job_pages` (optional in phase 1 — only if per-page retry/status is needed; otherwise fold into `pdf_jobs` as a jsonb manifest) — one row per page image.
| Column | Type / notes |
|---|---|
| `id` | uuid PK DEFAULT gen_random_uuid() |
| `job_id` | uuid NOT NULL FK `pdf_jobs(id)` ON DELETE CASCADE |
| `page_number` | int NOT NULL |
| `storage_path` | text NOT NULL (path in the new bucket) |
| `ocr_status` | text CHECK `IN ('pending','done','failed')` |
| `ocr_text` | text, nullable — **only if** the coordinator approves storing OCR text server-side; otherwise keep OCR text in the result file only (privacy + DB size) |
| Unique | `(job_id, page_number)` |

**RLS for the new tables:** users SELECT/INSERT own `pdf_jobs` rows only (`auth.uid() = user_id`); users may UPDATE own rows only for `status='cancelled'` (cancellation — enforce by policy or by a narrow RPC; do not allow client edits to `status`/`result_summary`); admins SELECT all; **no client DELETE**. The backend (service_role via Edge Function or direct Postgres) bypasses RLS for status/result writes. `pdf_job_pages`: same ownership via join to `pdf_jobs` (use a `SECURITY DEFINER` helper or denormalise `user_id` onto the page row — recommend denormalising `user_id` to keep the policy simple and auditable).

**New bucket:** `pdf-job-pages` (private) for uploaded page JPEGs + `pdf-job-results` (private, or a prefix in the same bucket) for result JSON files. Same policy pattern as `payment-proofs`: INSERT only under own uid folder; SELECT owner + admin; signed URLs with short expiry for the backend to fetch and the app to download results; **no UPDATE/DELETE for clients**. Lifecycle: delete page images when the job completes/fails (or after 7 days via a scheduled cleanup — Free plan has no pg_cron; use an Edge Function invoked by an external cron, or delete eagerly on completion). File-size cap per page (e.g. 5 MB, matching the receipt bucket's precedent) and per-job page cap 100.

**New Edge Function (one):** `pdf-job-submit` (verify_jwt=true) — the app's only entry point to the backend. It verifies the JWT, checks the user exists, enforces a per-user quota (see §7.5), creates the `pdf_jobs` row, returns `{job_id, upload_urls}` (signed upload URLs per page) — and nothing else. It must NOT accept a Gemini key in the request body unless D1(a) is chosen AND the key is handled as transient-only (never stored/logged; forward in-memory only). **Do not** put job-processing logic in the Edge Function; it only mints the job and hands off to the Python service (via a signed callback / queue row the Python worker polls).

**What the backend must NOT touch:** `profiles` (no writes at all), `activation_codes` (no reads/writes), `payments` (no reads/writes — including `status`, `code_id`, `screenshot_path`), `test_results` (no writes — the app syncs results itself), `waitlist`, `sent_notifications`, `redeem_attempts`, the `payment-proofs` bucket, Realtime publication membership, existing triggers/policies, Auth settings. The backend reads `profiles` only if needed to confirm the user/premium state for quota (read-only, via service_role, and only the `id`/`plan` columns).

### 7.4 Phased implementation plan

**Phase 1A — Contract & skeleton (no OCR yet).**
1. Coordinator confirms D1–D5 + live status of migrations 007–011 (§8).
2. Create `pdf_jobs` (+ `pdf_job_pages` if agreed) and the `pdf-job-pages` bucket + policies via a new migration file `015_pdf_jobs.sql` (Dashboard SQL Editor, same as 001–014; do NOT use the Management API for schema — it has no SQL endpoint).
3. Write `pdf-job-submit` Edge Function (JWT verify + quota check + job row + signed upload URLs). Deploy via the existing `deploy_function.py` helper; verify with `--list`.
4. Python service skeleton (FastAPI): `GET /health`, `POST /jobs/{id}/process` (service-role authenticated, called by the worker loop or by `pdf-job-submit` via a signed internal token — never by the app directly). Worker loop: claim one `queued` job (row-lock / `status` transition with `WHERE status='queued'` + returning row, the same atomic-claim pattern as the redeem-code M1 fix), download page images, run the pipeline, write the result JSON to Storage, update the job row to `done`/`failed` with counts.
5. App change (minimal, one screen): upload screen gains "Server parse (beta)" option that uploads page JPEGs and polls `pdf_jobs` status; the result JSON is converted into the existing `PdfImportResult`/`Question` shapes and flows through the *unchanged* preview → save → sqflite path. **No changes to `mcq_parser.dart`, `answer_key.dart`, or the local import path in this phase.**

**Phase 1B — OCR + parse (the actual engine).**
1. OCR stage: per page, Gemini vision first (key per D1) with the app's exact prompt (left-column-first, `[?]` for unreadable) + per-page timeout 120 s; on Gemini failure (no key/quota/recitation block — see risk R7) fall back to Tesseract `eng+urd` (Python: `pytesseract` or a Tesseract binary; PSM 3) and record the per-page engine honestly in the result (`ocrMethods` map, same shape as the app's).
2. Geometry stage: port `splitColumnsForOcr` + `reconstructTableText` to Python, operating on OCR *word boxes* — this requires an OCR engine that returns boxes (Gemini vision does not return boxes; Tesseract TSV/hOCR does; ML Kit is not available server-side). **Decision point:** if Gemini-only, column order comes from the prompt (as the VM baseline does) and tables need a dedicated table path (see risk R8); if Tesseract is in the loop, its boxes feed the ported geometry functions. Record which path each page took.
3. Parse stage: **port the Dart parser's output contract first** — implement `parseMcqsFromPages` semantics in Python against the same fixtures (`test-fixtures/ppsc66/ocr-pN.txt` + `test/ppsc66_baseline_test.dart` expectations: 100/100 Paper 66 + 10/10 Paper 67 pending, 0 false positives). Long-term, consider transpiling/sharing the Dart parser rather than maintaining two parsers (see risk R9) — do NOT start a second hand-written parser without that decision.
4. Key stage: same `parseKeyEntries` + `decideKeyMatch` rules (title-matched only, no cross-paper application, unmatched entries reported, never discarded); same 7 document statuses; same `keyPaperReport` lines.
5. Verification gate (must pass before any user sees it): the Paper 66 fixture suite (Gemini text → 100/100), the Tesseract-text probe (≥ the v2.0.4 phone-parser numbers: 20 parsed on Tesseract text), and the table-photo fixtures (interjection 30, computer 15 on Gemini-fixture text). Plus a live end-to-end run on the real `ppsc_paper_66.pdf` through the deployed backend, judged by the same counts.

**Phase 1C — Hardening & rollout.**
1. Quotas + abuse limits (§7.5); per-job cost logging (pages × engine, for the owner's visibility — counts only, no content).
2. Cleanup job for page images + stale jobs; result retention policy (e.g. results kept 30 days, then deleted; the app already saved what it needs locally).
3. Admin visibility: read-only view of `pdf_jobs` (counts by status, per-user usage) — either a small addition to the existing admin panel (new tab, SELECT-only on the new tables) or a Dashboard-only view; no new admin powers.
4. Rollout: owner-only beta first (his 3 files: PPSC-66 PDF + interjection + computer photos + Paper 60 camera test), then all users; keep the on-device path as the default until the server path beats it on his phone proof. **No "complete" claim until his phone proves it on his three files** (the standing OfficerPath gate from 20 Nov).

### 7.5 Quotas, costs, and abuse controls

- **Per-user quota (propose; needs user approval):** free users e.g. 3 server parses/month (mirrors the 3 free tests/month — do not pick a different number silently); Premium unlimited within a fair-use cap (e.g. 50 jobs/month, then manual review). Enforce in `pdf-job-submit` by counting the user's `pdf_jobs` rows in the current month (same pattern as the free-test count from `test_results`).
- **Per-job caps:** 100 pages (mirrors `maxOcrPagesPerImport`); per-page image cap 5 MB; reject larger uploads at the signed-URL step.
- **Cost accounting:** log per job `{pages, gemini_pages, tesseract_pages, status}` in `result_summary`; no OCR text or key material in logs. If D1(b) (server key) is chosen, add a hard daily cap in the worker (e.g. stop Gemini calls after N pages/day, fail jobs honestly with "daily limit reached — try the on-device parse") and surface the spend to the owner weekly.
- **Abuse:** JWT required for every step; signed upload URLs short-lived (15 min) and scoped to the job's folder; no anon access to the new tables/bucket; rate-limit job creation per user (e.g. max 5 queued jobs).

### 7.6 Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | **Two parsers drift.** A Python re-implementation of a 5,713-line Dart parser will diverge (the v2.0.4 category-separation fixes alone are subtle: paren-only digit markers, `(?!\d)` decimal guard, `:` exclusion for misread numbers, raw-vs-cleaned first-line guard). | Port the *output contract + fixtures* first; keep the Dart parser as the reference implementation; run the same fixture suite against both; long-term prefer sharing the parser (transpile, or run the Dart parser server-side via Dart on the server) over a parallel Python rewrite. |
| R2 | **Server Gemini key cost/rate limits.** Free tier 500 req/day shared; a 100-page book = 100 requests. | D1 decision; per-day caps; honest failure when capped; never silently fall back to a worse engine without reporting it (same honesty rule as the app's `geminiFailure`). |
| R3 | **Free-plan ceilings.** 500 MB DB, 500k Edge invocations/mo, Storage bandwidth; page images + results add up. | Results in Storage, counts only in DB; eager deletion of page images; retention policy; monitor DB size weekly. |
| R4 | **Uploads from weak connections.** The owner's test internet was 0–5 K/s; a 7-page JPEG upload will be slow and may fail mid-way. | Per-page uploads with retry; resumable/parallel page uploads; job stays `uploading` until all pages arrive; no partial processing. |
| R5 | **Recitation filter (Gemini).** The VM baseline hit Gemini's recitation block on Paper 66 p3 (6×) and p5 (2×) — verbatim match against an indexed PPSC paper. A server Gemini route will hit the same blocks. | Mitigation plan required in Phase 1B: prompt variants (tested on p5: rephrased prompt worked), page crops (tested on p3: 7 crop calls), and a Tesseract fallback for blocked pages — with per-page engine recorded honestly. Do not promise Gemini-only. |
| R6 | **Privacy of uploaded books.** Books may be copyrighted commercial material; uploading them to a server bucket creates a copy the owner is responsible for. | Private bucket, owner+admin only, eager deletion after processing, no human review of content without cause, retention policy in writing; the bundled-book-bank copyright line from 20 Nov still applies (no publisher books bundled without permission). |
| R7 | **The backend becomes a second money-adjacent surface.** A quota bypass (e.g. forging job rows to get unlimited server parses) must not become a Premium bypass. | Quota is a *convenience* limit, not an entitlement control: server parses must never grant Premium, never write `profiles`/`payments`/`activation_codes`; the free-test limit (3/month) is enforced separately in-app and is unaffected by parse quota. |
| R8 | **Tables without boxes.** Gemini vision returns text, not word boxes, so the ported `reconstructTableText` has no input on Gemini pages. | Decide in Phase 1B: Tesseract-box path for tables, or a Gemini prompt that returns pipe-separated table rows, or both with a per-page record. Do not claim table support until the interjection/computer fixtures pass server-side. |
| R9 | **Scope creep into the book bank.** The user deferred the bundled book bank ("upload fix FIRST, bank later"). | The backend stores *job results transiently*, not a book bank. Any persistent server-side question bank is a separate, user-approved phase with its own copyright review. |
| R10 | **Cold starts / free-host sleep.** Render free tier sleeps; a parse job may wait ~50 s+ before starting. | Async jobs absorb this (polling, not a blocking call); set honest status text ("queued — server waking up"); do not pick a paid host without approval. |

### 7.7 What the backend needs from the coordinator/owner before Phase 1A starts

1. Decisions D1–D5 (§7.2), especially the Gemini-key model and the host.
2. Live confirmation of migrations 007–011 (see §8) — the backend's quota logic should not assume them.
3. Confirmation of the per-user server-parse quota numbers (§7.5).
4. A test corpus: the three owner files (PPSC-66 PDF, interjection photo, computer photo) + Paper 60 photo — the acceptance set for Phase 1B.
5. Whether OCR text may be stored server-side (`pdf_job_pages.ocr_text`) or must live only in the transient result file.

---

## 8. Guessed / unverified — do not treat as fact

1. **Live DB schema ≠ migration files.** All schema/RLS/trigger detail in §2 comes from the migration *files*. The Management API token cannot run SQL, so it is unverified whether every file 001–014 is applied live, in order, with no Dashboard edits since. In particular, `SECURITY_FIXES_2026-11-20.md` (earlier 20 Nov) says 007–011 were *not yet applied live* at writing time, while the task brief states 001–014 applied — these conflict and only a live check resolves it. **Alternative:** Dashboard → SQL Editor, run: `select tablename from pg_tables where schemaname='public';` + `select policyname, tablename, cmd from pg_policies where schemaname='public' order by tablename;` + `select trigger_name, event_object_table from information_schema.triggers where trigger_schema='public';` + `select id, name, public from storage.buckets;` Compare against §2.
2. **Live row counts / live users / live payments.** Not queried (no SQL access). Counts in this report (18 merged emails, 13 requesters, 2 admin users) are quoted from memory/reports, not verified this session.
3. **Edge Function secrets actually set.** Secret *names* are known from function source; whether `RESEND_API_KEY`, `RESEND_FROM`, `FIREBASE_SERVICE_ACCOUNT`, `PAYMENT_ALERT_SECRET` are set in the Dashboard is unverified. **Alternative:** Dashboard → Edge Functions → Secrets (names only, never values) + a live `issue-code`/`payment-alert` smoke test.
4. **Database webhook for `payment-alert` exists live.** The function is deployed (ACTIVE v2, `verify_jwt=false`); the Dashboard webhook (Database → Webhooks → `payments` INSERT → function URL + secret header) is a manual Dashboard step whose live existence was not verified. **Alternative:** Dashboard → Database → Webhooks list; then submit a test payment proof and confirm the admin email arrives (per memory, the alert email is still UNPROVEN live).
5. **Migrations 012–014 live behaviour** (TID unique index, receipt upload + signed URL, Realtime beep/banner, PWA install, C1 admin/service_role allow-branches) — recorded as applied/verified in memory for 012–014, but the *behaviours* (receipt upload, Realtime alert, PWA) are still listed as unproven live in memory. Not re-verified here.
6. **CI signing key usage.** The permanent keystore exists (`~/workspace/officerpath-ai-keystore/`, per memory) and v2.0.4 was released with a matching fingerprint, but whether the GitHub workflow now restores that keystore (vs the old ephemeral debug keystore) was not verified in this audit — the workflow file was not re-read line-by-line this session.
7. **Test counts (882/5/0) and `flutter analyze` 0 issues** — quoted from the v2.0.4 report; `flutter test` was not re-run in this audit.
8. **GitHub main HEAD `5e820936`** — from the task brief; the local tree is not a git repo, so it could not be confirmed here.
9. **Gemini pricing figures** (`~$0.0004/page`, free tier 500 req/day) — from `gemini_config.dart` comments (Nov 2026 estimates); not re-checked against Google's current pricing this session.
10. **The phone's actual ML Kit text for Paper 66** — never captured. Every statement about *why* the phone fails rests on synthetic/Tesseract noise models that reproduce the collapse, not on the phone's real OCR output. The backend's acceptance test must therefore be the real files through the real backend, not the noise models.

---

## 9. Sources read for this audit

- `~/workspace/officerpath-ai/PHONE_MLKIT_PARSE_2026-11-20.md`
- `~/workspace/officerpath-ai/MLKIT_ROBUSTNESS_2026-11-20.md`
- `~/workspace/officerpath-ai/PPSC66_BASELINE_2026-11-20.md`
- `~/workspace/officerpath-ai/SECURITY_AUDIT_2026-11-20.md`
- `~/workspace/officerpath-ai/SECURITY_FIXES_2026-11-20.md` (head + M1/M2 sections)
- `~/workspace/officerpath-ai/lib/services/pdf_import_service.dart` (full, 916 lines)
- `~/workspace/officerpath-ai/lib/services/urdu_ocr.dart` (full, 618 lines)
- `~/workspace/officerpath-ai/lib/services/storage_service.dart` (full, 398 lines)
- `~/workspace/officerpath-ai/lib/services/supabase_config.dart`, `gemini_config.dart`, `gemini_client.dart` (grep + config full), `keep_alive.dart`, `payment_proof_service.dart` (head + payload sections), `subscription_service.dart` (grep), `test_progress_service.dart` (head), `ai_generation.dart` (head), `ai_service_stub.dart` (grep)
- `~/workspace/officerpath-ai/lib/main.dart` (full), `lib/screens/upload_screen.dart` (grep: import call sites, save path), `lib/services/pdf_text_extractor.dart` (grep: entry points), `lib/services/mcq_parser.dart` (grep: entry points), `pubspec.yaml` (full)
- `~/workspace/officerpath-ai/supabase/migrations/001_schema.sql` through `014_realtime_payments.sql` (full text of 001–002, 003–005, 006–014)
- `~/workspace/officerpath-ai/supabase/functions/{redeem-code,issue-code,delete-account,send-notification,payment-alert}/index.ts` (headers + key logic greps)
- `~/workspace/officerpath-ai/admin/app.js` (grep: table/bucket usage)
- `~/workspace/custom-connectors/custom.supabase/CONNECTOR.md` + `bin/deploy_function.py` (`--list`, live)
- Management API `GET /v1/projects/gliebuyyjguxrwdfuakz` (live, 200)

## 10. Audit limitations

- Read-only by design: no code, schema, or deploy changes; no live writes of any kind.
- No `flutter build` / `flutter test` run (build safety-blocked; tests not re-run).
- No SQL access to the live database (connector scope); schema is file-based — see §8.1 for the exact live verification queries.
- No secret values were read, printed, or stored; no credentials were requested.
- The local tree is not a git repo, so working-tree-vs-remote diffing was impossible; file contents are as found on disk on 20 Nov 2026 ~22:10 PKT.
