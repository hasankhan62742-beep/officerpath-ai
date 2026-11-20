# Security Fixes — OfficerPath AI v2.0.0 (post-audit fix pass)

- **Date:** 2026-11-20
- **Audit fixed:** `SECURITY_AUDIT_2026-11-20.md` (verdict: DO NOT SHIP as-is — 1 Critical, 2 High, 5 Medium, 8 Low)
- **Scope of this pass:** every finding **except C1 and H1**.
  - **C1 is OFF-LIMITS here** — fixed separately by the parent (migration 006 + `test/security_rls_test.dart`). Per project memory, migration 006 was applied live 08:16–08:20 PKT and **blocking was verified live 08:24 PKT** (test UPDATE rejected with the trigger error, 0 rows changed). Admin/service_role allow-branches still to be proven end-to-end via admin-panel grant + redeem-code smoke test.
  - **H1 (signing keystore) is OFF-LIMITS** — needs a product decision with the user first. Nothing in this pass touches the workflow build command, signing config, or version.
- **Method:** 5 parallel workers (one per fix group) + coordinator verification. Nothing was committed, pushed, released, or CI-triggered. All changes are in the working tree only.
- **Final verification (coordinator, 20 Nov):** full `flutter test` → **721 passed, 5 skipped, 0 failed** ("All tests passed!"); `flutter analyze` → **No issues found!** Live function list re-checked by the coordinator: redeem-code ACTIVE v2, send-notification ACTIVE v2, issue-code v1, delete-account v1, all `verify_jwt=True`.
- **No secret values are reproduced in this report.**

## Still to do before shipping (parent / live steps)

1. **Apply migrations 007, 008, 009, 010, 011 to the live Supabase project** (Dashboard → SQL Editor, in order). None of the five was applied live in this pass — the deploy helper only deploys functions, it does not run migrations.
2. **Re-audit checks after applying:** admin panel codes table populates + `code_id` links on approval (007); a forged `status='approved'` payments insert fails (008); live 429 after 11 redeem attempts (011); waitlist throttle + Sheet import behave as documented (009); one live password-reset smoke test (L6).
3. **Next release cut** is the live proof for M3 (checksum sidecar) and L5 (pinned actions).
4. **H1 decision** with the user (keystore) — unchanged, still open.

---

## H2 — Admin panel cannot read activation_codes (High)

**File:** `supabase/migrations/007_admin_activation_codes_select.sql` (new)

**What changed:** `DROP POLICY IF EXISTS` + `CREATE POLICY "Admins can view activation codes" ON public.activation_codes FOR SELECT USING (public.is_admin());`. No INSERT/UPDATE/DELETE policy added — codes stay writable only by the Edge Functions via service_role. Safe because only SHA-256 hashes are stored, never the plain code.

**How verified:** `grep -in "anon|authenticated"` on the file → no matches, so no policy grants SELECT to anon or authenticated. Policy name, table, and `public.is_admin()` helper match `002_rls.sql`. File re-read in full — two statements, balanced, coherent.

**Could NOT be verified:** live behaviour — the migration is not yet applied, so the panel's codes table population and `code_id` linking on approval still need the live check (step 2 above).

## M1 — redeem-code double-spend race (Medium)

**File:** `supabase/functions/redeem-code/index.ts` (~lines 175–196)

**What changed:** the claim update now appends `.select("id")` and requires exactly one returned row — `if (useError || !claimed || claimed.length !== 1)` → 409 `code_already_used`. Previously the code checked only the error; a PostgREST UPDATE matching zero rows returns success with an empty array, so two simultaneous redeems of one code could both grant Premium. Only the first claim now matches a row (`.is("used_at", null)` predicate). `issue-code` was read in full and checked — its only write is a plain `insert` into `activation_codes` (unique `code_hash`, retried up to 3× on collision); no check-then-act on a mutable row exists there, so no change was made to it.

**How verified:** code re-read after edit; deployed via the custom.supabase connector helper — `redeem-code: DEPLOYED id=03780fc9-1f30-4f56-8b0a-74c637d0a0fc status=ACTIVE version=2`, and the coordinator independently re-listed functions afterwards: redeem-code ACTIVE v2, `verify_jwt=True`.

**Could NOT be verified:** live concurrent double-redeem — no live redeem was attempted (no test code/user in scope). The fix needs no new DB object and works regardless of migration 011.

## M2 — Users can self-approve payment rows (Medium)

**File:** `supabase/migrations/008_payments_insert_constraints.sql` (new)

**What changed:** (a) the `"Users can insert their own payments"` policy is replaced with `WITH CHECK (auth.uid() = user_id AND status = 'pending' AND reviewed_by IS NULL AND reviewed_at IS NULL AND code_id IS NULL)`; (b) `CHECK (plan IN ('premium_1month','premium_2months','premium_1year'))` added as constraint `payments_plan_valid` (guarded by a `pg_constraint` check so re-runs are no-ops); (c) a `BEFORE INSERT` trigger (`force_pending_payment_status()`, SECURITY DEFINER + `SET search_path = public`) coercing `status` to `'pending'` for client inserts, bypassing service_role/admins per the 006 pattern. Forged `reviewed_by`/`reviewed_at`/`code_id` are not coerced — the policy in (a) still rejects those rows (documented in the file).

**How verified:** plan values confirmed, not assumed — `PremiumPlan.plans` in `lib/services/subscription_service.dart:97–117`, `PLAN_MAP` in `supabase/functions/issue-code/index.ts:51–53`, `admin/app.js:18–20`, and `upgrade_screen.dart:263–265` all use exactly the same three ids. No legitimate non-pending flow: repo-wide grep found exactly one client insert path, `PaymentProofService._defaultInsert` (`lib/services/payment_proof_service.dart:264`), fed by `buildProofPayload` (:157–176) which always sets `'status': 'pending'` and never sets the review fields — pinned by `test/payment_proof_test.dart:71–95`. No Edge Function inserts into payments (`delete-account` only DELETEs); `admin/app.js` only SELECTs/UPDATEs payments. All eight referenced columns checked against the `payments` table in `001_schema.sql`.

**Could NOT be verified:** live rows — the CHECK validates existing rows on apply, so if any live row holds a plan outside the three ids (only possible as a forged row), the ALTER TABLE step fails until that row is cleaned. Live rows could not be checked from here. Migration not yet applied live.

## M3 — Updater installs whatever the release serves (Medium)

**Files:** `.github/workflows/build-apk.yml`, `lib/services/app_update_service.dart`, `test/app_update_service_test.dart`

**What changed:**
- **Workflow:** header comment updated (two assets now, APK + `.sha256` sidecar); new step "Compute SHA-256 of the APK" (lines 129–137): `sha256sum "officerpath-ai-${VERSION}-arm64.apk" > "officerpath-ai-${VERSION}-arm64.apk.sha256"` + `cat`; release upload (line 161) now uploads both files with the same `--clobber`. Build command, signing, version, triggers, permissions untouched.
- **App:** `AppUpdateInfo` gains `checksumUrl` / `sha256` fields; `pickApkAsset` drops the any-`.apk` fallback — only a name ending in `-arm64.apk` is picked, anything else returns null; new `pickChecksumAsset` picks the asset named exactly `<apkName>.sha256`; `parseSha256Content` parses `sha256sum` format / bare hash / uppercase / `*` marker and rejects a hash whose filename token doesn't match the APK name; pure helpers `isValidSha256Hex`, `sha256Hex`, `matchesExpectedSize`, `verifyApkBytes` (size first, then SHA-256); `checkForUpdate` GETs the sidecar over HTTPS and fills `sha256`; `downloadAndInstall` **fails closed** — missing/invalid hash returns a stream emitting a single `OtaStatus.CHECKSUM_ERROR` and never calls `OtaUpdate`. With a valid hash it passes it to `OtaUpdate().execute(..., sha256checksum: ...)`; the worker verified from the `ota_update` 7.1.0 Android source in the pub cache that its native code hashes the downloaded file (`Sha256ChecksumValidator`) and only then triggers the installer.
- **Tests:** `test/app_update_service_test.dart` (451 lines) — old fallback test now expects null for a universal-only APK; new groups for `pickChecksumAsset`, `parseSha256Content`, `isValidSha256Hex`, `sha256Hex` (known SHA-256("abc") vector), `verifyApkBytes`/`matchesExpectedSize`, `parseLatestRelease` (checksumUrl present/absent), and `downloadAndInstall` fail-closed (null/invalid checksum → single `CHECKSUM_ERROR`, plugin never touched).

**How verified:** `flutter test test/app_update_service_test.dart` → **35/35 passed** (run twice); `flutter analyze` on the touched files → No issues found (one info lint fixed and re-analyzed clean). Workflow YAML parses (`yaml.safe_load`), 11 steps (was 10).

**Could NOT be verified:** CI end-to-end — no commit/push/CI trigger per scope, so the `sha256sum` step and two-file upload are untested on a real runner; the first release cut after this lands is the live proof. The live v2.0.0 release currently has **no** `.sha256` asset, so until that next release, any update offered would fail closed at install (by design). On-device install flow: no Android device here; native hash-before-install verified only by reading the plugin source, not by observing a real install or `CHECKSUM_ERROR`. Live checksum fetch untested against GitHub (no release with a sidecar exists yet). Size check on the live path is indirect: Dart never sees the plugin-downloaded bytes, so live enforcement is the SHA-256 (any size difference changes the hash, so the hash subsumes the size check); the explicit size comparison exists only in the tested pure helpers. Error wording: `lib/widgets/update_prompt.dart` was out of scope, so a checksum refusal surfaces through its existing generic "Update download nahi ho saka" message.

## M4 — Waitlist anon INSERT unthrottled (Medium)

**File:** `supabase/migrations/009_waitlist_throttle.sql` (new)

**What changed:** (1) UNIQUE on email — **already present** in `005_waitlist.sql` (`email text not null unique`), so the file adds constraint `waitlist_email_unique` only idempotently (DO block, only if the table has no unique constraint at all). (2) A `BEFORE INSERT` trigger (`throttle_waitlist_insert()`, SECURITY DEFINER + `SET search_path = public` — SECURITY DEFINER is required here, since anon has no SELECT on waitlist and a plain trigger would count zero rows) capping global signups at **30 rows per trailing 60-second window**, raising a clear exception above the cap. A per-email cap would be vacuous (UNIQUE already allows one row per email ever), so the cap is global — the only DB-side throttle Postgres can enforce, since it cannot see the caller's IP. Also adds `waitlist_created_at_idx` so the window count stays cheap.

**Premise correction (flagged openly, not hidden):** the task stated the Sheet import uses the server key, but `docs/waitlist.md` documents it differently — generated `INSERT INTO waitlist (email, source) VALUES (...) ON CONFLICT (email) DO NOTHING;` statements pasted into the **Supabase Dashboard SQL Editor**, which runs as postgres with **no JWT, so `auth.role()` is NULL** — not service_role. The admin panel never inserts into waitlist (`admin/app.js` `loadWaitlist` is SELECT-only; the public insert is `docs/index.html:171`, anon `{email, source:'waitlist-page'}`). So the trigger bypasses **all three**: `auth.role() IS NULL` (SQL Editor import) **or** `service_role` **or** `public.is_admin()`. Without the NULL-role bypass, a bulk import of >30 addresses would have tripped the throttle mid-import.

**Honest limit (documented in the file):** concurrent transactions can both slip under the cap (only committed rows are visible), so this is a best-effort brake; the audit's Edge Function + CAPTCHA remains the real fix.

**Could NOT be verified:** live behaviour — migration not applied; throttle + Sheet import still need the live check.

## M5 — access-requests-seen.txt not gitignored (Medium)

**File:** `.gitignore` (root), line 36 (coordinator's own edit)

**What changed:** `access-requests-seen.txt` added under the Secrets section with an audit comment (M5: file holds 11 real requester emails; previously excluded from pushes only by the push helper's `EXTRA_EXCLUDES`).

**How verified:** by inspection of the push helper (`~/workspace/custom-connectors/custom.github/bin/github_release.py`): `load_gitignore_patterns()` walks the tree and reads every `.gitignore`; `_pattern_matches()` matches a slash-less pattern against the file basename, and the root `.gitignore` has base `""`, so the entry covers the file. `EXTRA_EXCLUDES` line 57 still lists it too as a second layer. `git check-ignore` was not possible — the project is not a local git repo.

## L1 — SECURITY DEFINER functions without SET search_path (Low)

**File:** `supabase/migrations/010_security_definer_search_path.sql` (new)

**What changed:** `ALTER FUNCTION public.is_admin() SET search_path = public;` and `ALTER FUNCTION public.handle_new_user() SET search_path = public;` — exact zero-arg signatures, matching their definitions in `002_rls.sql:22` and `003_triggers.sql:19`.

**How verified:** full grep of `supabase/migrations/*.sql` for `security definer` found exactly four functions: `is_admin()` (002:25, no search_path), `handle_new_user()` (003:22, no search_path), `prevent_client_premium_grant()` (006:37) and `coerce_client_profile_insert()` (006:66) — both 006 functions already have `set search_path = public` on the next line. `004_push_notifications.sql`, `005_waitlist.sql`, and `011_redeem_attempt_throttle.sql` define no functions. `set_updated_at()` (003:57) is a plain trigger function, not SECURITY DEFINER, left untouched. Post-write scan confirms: after 010, the only SECURITY DEFINER definitions without an inline `set search_path` are the two in 002/003 that 010 alters, and the two new functions added by 008/009 both set it inline — zero remain unprotected.

**Could NOT be verified:** live — migration not yet applied.

## L2 — Rate limiting on redeem-code (Low)

**Files:** `supabase/functions/redeem-code/index.ts` (~lines 39–40, 95–121); `supabase/migrations/011_redeem_attempt_throttle.sql` (new)

**What changed:** `REDEEM_ATTEMPTS_PER_HOUR = 10`, rolling 1-hour window. After JWT auth (before code validation, so code-guessing counts too), the function logs one row per attempt, counts the caller's rows in the last hour, and returns HTTP 429 `{ ok: false, error: "rate_limited" }` when the count exceeds 10. **Fail-open:** any throttle error is caught, logged (`console.error … fail-open`), and the redeem proceeds — a throttle failure can never block a legitimate redeem. `rate_limited` added to the header error list. Incidental reorder: the service-role `admin` client is now created in the throttle block (step 1b) instead of step 3; step 3's duplicate declaration was removed (no behaviour change). Migration 011 creates `public.redeem_attempts (id, user_id, attempted_at)` with RLS enabled and **zero policies** (service-role only, same pattern as `activation_codes`), plus a `(user_id, attempted_at)` index and a commented 7-day cleanup query. It is numbered 011 and does not touch 007–010.

**Why a new migration was needed:** no existing table can hold attempt bookkeeping (activation_codes is one row per issued code; profiles/payments/test_results are user data), and an in-memory counter would not be shared across Deno isolates.

**How verified:** code re-read after edit; deployed — redeem-code ACTIVE v2, `verify_jwt=True` (coordinator independently re-listed).

**Could NOT be verified:** migration 011 is **not yet applied live** — until it is, the throttle is fail-open by design: every redeem attempt will log a throttle error and proceed normally. M1 works regardless. No live 429 was observed; confirm a live 429 appears after 11 attempts once 011 is applied.

## L3 — Dead v1 offline-activation code ships in the v2 binary (Low)

**Files deleted:** `lib/services/manual_activation.dart`, `tools/generate_activation_code.dart`
**Files edited:** `lib/services/subscription_service.dart`, `lib/services/billing_service.dart` (coordinator: 2 doc-comment lines), `test/security_test.dart`, `test/subscription_test.dart`, `test/free_tests_monthly_test.dart`

**What changed:** `manual_activation.dart` (default secret `CHANGE_ME_IN_RELEASE_BUILD`, FNV-1a checksum, `buildCode`/`validateCode`/`activateWithCode`) and the minting CLI `tools/generate_activation_code.dart` are deleted. `SubscriptionService.grantPremium()` removed entirely — its only callers were the deleted file, two tests, and a doc comment; the tests now use the live v2 path `applyServerPremium(...)`. `subscription_service.dart` header docs rewritten to the v2 server-code flow. `test/security_test.dart:59–90` now asserts absence of `'CHANGE_ME_IN_RELEASE_BUILD'` (not the never-existent `'DEFAULT_ACTIVATION_SECRET'`) across **both `lib/` and `tools/`**. `test/subscription_test.dart` lost the `manual_activation` import and its 2 dead-code tests. Coordinator fixed the two stale doc comments the worker left in `billing_service.dart:7,25` ("see manual_activation.dart" → server-issued code; "`grantPremium(plan)`" → "`applyServerPremium(plan, until)`").

**How verified (grep evidence before deleting):** `ManualActivation` hits in `lib/` + `test/` were only the file itself, doc comments, and tests; `upgrade_screen.dart:222-261` uses only `ActivationService.redeemCode()` (server path); `savePendingRequest` / `getPendingRequest` / `sendProofOnWhatsApp` had zero callers outside the deleted file. Post-fix grep: `CHANGE_ME_IN_RELEASE_BUILD`, `ManualActivation`, `manual_activation`, `grantPremium`, `DEFAULT_ACTIVATION_SECRET` are absent from `lib/` + `test/` + `tools/` except the intentional guard string in `test/security_test.dart:77,82` and its explanatory comment, plus a historical note in the `subscription_service.dart` class doc naming the deleted service. Full suite green (see Verification).

**Could NOT be verified:** on-device behaviour (Keystore-backed secure storage / upgrade migration — see L7). Historical docs (`README.md`, `BUILD_REPORT.md`, `AUDIT_REPORT.md`) still describe the v1 offline codes and `tools/generate_activation_code.dart` — out of scope, left untouched; stale references, not live code.

## L4 — send-notification FCM INVALID_ARGUMENT handling (Low)

**File:** `supabase/functions/send-notification/index.ts:214–218`

**What changed:** `unregistered = detail.includes("UNREGISTERED") || detail.includes("NOT_FOUND")` — `INVALID_ARGUMENT` is deliberately **not** treated as a dead token (it can mean a malformed message); it counts as a plain send failure, so the token is kept and the send is just counted as failed. Comment added at lines 216–218.

**How verified:** code re-read; deployed — `send-notification: DEPLOYED id=3be0aa44-7b1f-4dd8-bcc9-526dbc3bfa58 status=ACTIVE version=2`, coordinator independently re-listed: send-notification ACTIVE v2, `verify_jwt=True` (other functions unchanged).

**Could NOT be verified:** live behaviour — no real FCM send was performed (that would notify real users), so the new `NOT_FOUND`-only clearing path is verified by code read + successful deploy only, not by an observed `INVALID_ARGUMENT` response.

## L5 — Pin CI actions to SHAs (Low)

**File:** `.github/workflows/build-apk.yml`

**What changed:** each action pinned to its full commit SHA, resolved from the GitHub API via `api.github.com/repos/<owner>/<repo>/commits/<tag>` and cross-checked against `…/git/ref/tags/<tag>` (all four tags are lightweight — object type `commit` — both endpoints returned the identical SHA; no SHA was guessed):

| Action | Pinned SHA |
|---|---|
| `actions/checkout` (line 56) | `11d5960a326750d5838078e36cf38b85af677262` `# v4` |
| `actions/setup-java` (line 60) | `cf277c60eb25467037889841efdb72551f06f6c3` `# v4` |
| `subosito/flutter-action` (line 68) | `1a449444c387b1966244ae4d4f8c696479add0b2` `# v2` |
| `actions/upload-artifact` (line 143) | `ea165f8d65b6e75b540449e92b4886f43607fa02` `# v4` |

Spot-check: the checkout SHA's commit is "backport fixes to releases-v4 (#2524)", 2026-07-16 — current for the v4 tag. Nothing else in the workflow changed apart from the pins, the M3 checksum step, and two comments.

**How verified:** YAML parses (`yaml.safe_load`), 11 steps (was 10); `grep` confirms zero remaining `@v4`/`@v2` references; coordinator re-read the workflow and confirmed the pins + checksum step.

**Could NOT be verified:** a CI run with the pinned SHAs — no release/commit was triggered per scope.

## L6 — Deep-link implicit-flow fallback (Low)

**Files:** `lib/services/deep_link.dart` (rewritten), `lib/main.dart:110–134`, `test/deep_link_test.dart` (rewritten)

**What changed:** `ResetPasswordLink` no longer has `accessToken`/`refreshToken` fields at all; the parser only extracts `code` (query or fragment) and `type`. `hasRecoveryToken` is now `code != null` only. Bare `access_token`/`refresh_token` in query or fragment are ignored by design. `lib/main.dart` `_handleDeepLink`: the `else if` fallback calling `auth.setSession(refreshToken, accessToken: ...)` is deleted — it only calls `auth.exchangeCodeForSession(link.code!)` when a code exists; a token-only link just opens `ResetPasswordScreen` with no session (expired-link state). Grep confirms no `setSession` call remains in `lib/` (only mentions in comments). Tests: the two old tests asserting implicit-flow tokens parse successfully are now rejection tests (fragment tokens → `hasRecoveryToken == false`, `code == null`; same for query-param tokens); added tests for PKCE code in fragment accepted, and tokens alongside a code not overriding the code. 8 tests total.

**How verified:** `flutter analyze` on the three touched files → No issues found; `flutter test test/deep_link_test.dart` → **8/8 passed**. PKCE-only is safe per the installed SDK source: `gotrue 2.26.0` (from `pubspec.lock`) defaults to `flowType = AuthFlowType.pkce`, and `resetPasswordForEmail()` always generates an S256 PKCE code challenge; `lib/main.dart` calls `Supabase.initialize` with no `authOptions`, so the PKCE default applies; `lib/services/auth_service.dart:277` calls `resetPasswordForEmail` with no flow override; `docs/supabase-setup.md` §6 says email templates keep the defaults and only require `officerpath://reset-password` in the allowed redirect list — no custom template emitting implicit tokens is configured anywhere in the repo.

**Could NOT be verified live:** the actual Supabase Auth dashboard email-template settings (a dashboard-side customization could theoretically still emit implicit tokens — the audit itself lists Auth dashboard settings as unverified), and no real end-to-end reset email was sent/clicked. If a live reset ever arrives without a code, the user will now see the expired-link screen instead of being signed in — intended fail-closed behaviour, but worth one live smoke test before release.

## L7 — Premium cache in plaintext SharedPreferences (Low)

**Files:** `lib/services/subscription_service.dart`, `test/subscription_test.dart`, `test/subscription_server_test.dart`, `test/free_tests_monthly_test.dart`, `test/upgrade_server_code_test.dart`, `test/upgrade_payment_test.dart`

**What changed:** the cached plan/premium state moved from SharedPreferences to `flutter_secure_storage` (already a dependency, `^10.3.4` — no new dependency; `lib/services/secure_key_store.dart` not edited, its `SecureStore`/`PlatformSecureStore`/`InMemorySecureStore` pattern reused as-is). New secure-store keys following the Gemini-key naming convention: `premium_is_active_v2`, `premium_plan_id_v2`, `premium_until_iso_v2`. Legacy prefs keys kept read-only for migration: `is_premium_v1`, `premium_plan_id_v1`, `premium_until_iso_v1`. New test seam `SecureStore? secureStoreOverride` + `_secureStore` getter (defaults to `PlatformSecureStore()`). `_migrateLegacyPremiumCache()`: one-time migration — if the secure store is empty but legacy prefs keys exist, copies them over and deletes the legacy keys, so upgrading v1/v2.0.0 users keep their grant and no premium state remains in SharedPreferences. All read/write paths (`applyServerPremium`, `premiumUntil`, `isPremium`, `currentPlanId`) now use `_secureStore` only (booleans stored as `'true'`/`'false'` strings; expiry still flips the flag to `'false'`). `resetForTest` also clears secure-store keys (only when a test injected one, so no platform-channel throw) and legacy prefs keys. Unchanged on purpose: the free-test monthly counter stays in SharedPreferences — it is usage accounting, not entitlement.

**Tests:** all 5 files that touch the cache inject `InMemorySecureStore` in `setUp`. New test `premium cache lives in secure storage, never SharedPreferences` (asserts prefs has none of the 3 premium keys after a grant, and the secure store holds all 3); new group `legacy SharedPreferences premium cache migrates once` (2 tests: premium grant migrates + legacy keys disappear; legacy free flag migrates to not-premium).

**How verified:** `flutter analyze` on all 8 touched files → No issues found; `flutter test` on the 6 affected files → **56 passed, 0 failed**; full suite green (see Verification).

**Could NOT be verified:** on-device behaviour — the secure-storage move is verified only via the `InMemorySecureStore` fake in tests. No real Android run confirmed `flutter_secure_storage` reads/writes the Keystore-backed cache, or that a v1.2.0 install upgrading to this build actually migrates its `is_premium_v1` prefs keys on first launch. That needs the user's phone test.

---

## Verification (coordinator, final)

- Full `flutter test` (run by the coordinator after all workers finished): **721 passed, 5 skipped, 0 failed** — "All tests passed!", exit 0. (The L3/L7 worker independently ran the full suite earlier with the same result: 721/5/0.)
- `flutter analyze`: **No issues found!**
- Coordinator spot-checks: migrations 007–011 all present; dead files gone; no dead strings in `lib/`/`test/`/`tools/` (outside the intentional guard string); `.gitignore:36` lists `access-requests-seen.txt`; workflow pins + checksum step present; live function list re-checked (redeem-code v2, send-notification v2, issue-code v1, delete-account v1, all `verify_jwt=True`); migration 006 and `test/security_rls_test.dart` untouched (timestamps predate this pass).
- Two stale `billing_service.dart` doc comments pointing at the deleted code were fixed by the coordinator (see L3).
- No fixes were claimed without evidence: every "Could NOT be verified" item above is stated plainly.

---

## TID reuse guard (2026-11-20)

**Scope:** a transaction ID (TID) could be pasted twice and both payments approved — `payments.transaction_id` had no unique constraint, `PaymentProofService.submitPaymentProof` only validated TID format, and `admin/app.js approvePayment()` called issue-code with only `{user_id, email, plan}` — issue-code never saw the TID. The only protection was the admin's own eyes checking the TID in their Easypaisa/JazzCash app.

### 1. Migration 012 — partial unique index (backstop)

**File:** `supabase/migrations/012_tid_reuse_guard.sql` (file only — **NOT applied live**; the parent applies it)

```sql
create unique index if not exists payments_tid_approved_unique
  on public.payments (transaction_id) where status = 'approved';
```

One approved payment per TID, enforced by the database. If two approved rows already share a TID live, index creation fails — there should be none (v2 just launched, admin panel shows 0 approved payments).

### 2. issue-code — payment binding + server-side approval (deployed ACTIVE v2)

**File:** `supabase/functions/issue-code/index.ts` (rewritten sections; deployed 20 Nov, id `182697d6-0834-4615-ae68-5a471f002470`, status ACTIVE, version 2, `verify_jwt=True`)

- `payment_id` is now REQUIRED in the body. The function loads that payment row with the service-role client and rejects unless it exists (`payment_not_found` 404), belongs to the given `user_id` (`payment_user_mismatch` 400), and has `status='pending'` (`payment_not_pending` 409).
- TID reuse check: if any OTHER approved payment already carries the same `transaction_id`, reject with `tid_already_used` (409).
- After creating the code, the function marks THIS payment approved itself in the same call (`status='approved'`, `reviewed_by`=admin id, `reviewed_at`=now, `code_id`=new code id). The approval update is conditional on the row still being pending, so a simultaneous second approval updates 0 rows and is reported as `payment_already_handled` (409) instead of issuing a second code. If the partial unique index rejects the update (Postgres 23505), the function reports `tid_already_used` — the code just created is left unused and no email is sent for it (its plaintext is never returned, so it is unredeemable).
- **Hardening fix from the payment-chain audit (see §4): the plan is now taken from the payment row, never the request body.** The body `plan` is accepted but IGNORED (`PLAN_MAP[payment.plan]`). A code can never be issued for a different plan than was paid for. (Admin-only function, so this was an admin-trust matter, not a user bypass; the panel always passed `payment.plan` anyway.)
- Admin-only check unchanged: caller JWT verified, then `profiles.is_admin` re-checked server-side (`forbidden_not_admin` 403). Code is hash-only (SHA-256), 7-day expiry, single-use (M1 claim already in place).

### 3. Admin panel — duplicate-TID warnings + no client-side approval

**Files:** `admin/app.js` (approvePayment, loadPayments/renderPayments), `admin/index.html` (payments hint)

- `approvePayment()` now passes `payment_id` when invoking issue-code, and no longer marks anything approved client-side — it shows the returned code (approve modal) and refreshes; on error it shows the error (`ISSUE_CODE_ERRORS` table + `serverErrorMessage` reading the `FunctionsHttpError` Response body — verified from the actual supabase-js@2 CDN UMD that `FunctionsHttpError` is constructed with the raw Response, body unconsumed, so `.json()` works) and marks nothing.
- Payments queue: `loadPayments` builds an `approvedTids` map; any row whose `transaction_id` appears on another row shows a visible "DUPLICATE TID" warning, and rows whose TID is already spent on an APPROVED payment show "TID ALREADY APPROVED" and have Approve disabled. `approvePayment()` also refuses client-side when `approvedTids[payment.transaction_id]` is set (stale-list guard; the function is the authority).
- The approve confirm dialog asks: "Have you checked the receipt (Receipt link on this row and/or WhatsApp screenshot — TID + amount + receiver number)?"

### 4. App-side duplicate check (UX only)

**File:** `lib/services/payment_proof_service.dart:submitPaymentProof`

Before inserting, `myPayments()` lists the user's own prior submissions (RLS lets a user see only their own rows) and returns a plain-language failure ("You already submitted this transaction ID…") if they already submitted that TID. The check runs BEFORE the screenshot upload, so a refused repeat never uploads a file. Fail-open: if the list cannot be loaded, submit proceeds and the server decides. Server remains the authority.

**Tests:** `test/payment_proof_test.dart` — new group "submitPaymentProof duplicate transaction ID (UX check)" (4 tests: same TID as pending refused + insert never runs; same TID as approved refused; different TID submits normally; list-load failure is fail-open). Full-suite result below.

**How verified:** migration 012 is file-only (NOT live — the parent applies it; the index backstop is therefore NOT yet live, but the issue-code checks + panel warnings ARE live via the deployed v2 function and panel). issue-code v2 confirmed ACTIVE via the Management API `--list` (same id as v1, version 2). Panel verified live (see §6).

**Could NOT be verified:** no live end-to-end double-approval race was run (needs two simultaneous approvals of one payment + a second payment sharing its TID); the index itself is unapplied, so the race backstop is code-only until migration 012 is applied live.

---

## Receipt screenshot proof — both channels (2026-11-20)

**User's final design (08:59 PKT, superseding the WhatsApp-only correction at 08:54): the receipt is sent TWICE — (a) uploaded in the app (REQUIRED) AND (b) sent on WhatsApp to 03427717288.** The admin can check either. The intermediate WhatsApp-only design was superseded; nothing from it was deleted except the "no bucket" decision — the WhatsApp step below is kept from it.

### (a) In-app upload (required)

**Migration 013 (file only — NOT applied live; parent applies it):** `supabase/migrations/013_payment_screenshot.sql`
- `alter table public.payments add column if not exists screenshot_path text;`
- Private bucket: `insert into storage.buckets (id, name, public) values ('payment-proofs', 'payment-proofs', false) on conflict (id) do nothing;`
- Storage policies on `storage.objects` for that bucket (5 MB cap, `image/jpeg`/`image/png` only): authenticated users may INSERT only under their own uid path prefix (`storage.foldername(name)`); admins via `public.is_admin()` may SELECT all objects in the bucket; owners may SELECT their own.
- **Flagged "verify live before applying":** the storage-policy SQL was written from the repo alone (bucket id/name columns, `storage.foldername()`). The bucket + policies have NOT been created live and the policy syntax has NOT been proven against the live project — the parent must verify it in the SQL editor before running it. If the bucket/policies are not applied, the app's upload fails and submit returns the plain-language upload error (fail-closed, no silent submit without a receipt).

**App — `lib/services/payment_proof_service.dart`:**
- New `PaymentScreenshotUploader` typedef + `_defaultUploadScreenshot`: uploads to the `payment-proofs` bucket at `<user_id>/<milliseconds>_<random>.jpg|png` (`uploadBinary`, `upsert: false`, content type by extension) using the user's own session, so the storage RLS policy (uid folder only) enforces the path. Returns the storage path.
- `buildProofPayload` includes `screenshot_path` (required parameter).
- `submitPaymentProof` REQUIRES `screenshotBytes` (non-empty) — missing screenshot returns a plain-language error before any upload or insert. Upload happens BEFORE the payment-row insert; upload failure returns a plain-language error, no crash. A failed insert after a successful upload leaves an orphaned file in the private bucket (harmless; the user retries with a new unique path).
- Duplicate-TID check kept (runs before the upload).

**Payment screen — `lib/screens/upgrade_screen.dart`:**
- Receipt picker via `file_picker: ^8.0.0` (already a dependency — chosen over adding `image_picker`; gallery pick covers the screenshot case): `_pickReceipt` / `_receiptBytes` (bytes preferred, else read from path), "Attach receipt screenshot (required)" button, "Receipt: <name>" label once picked, required-screenshot instruction in the "How it works" steps (step 3 changed to AND + match explanation).
- Pure helper `receiptWhatsAppUri` (see (b) below) + `_lastSubmittedTx/PlanId/Method` fallback so the WhatsApp message still carries the real TID after the field is cleared.

**Tests:** `test/payment_proof_test.dart` — payload tests updated with `screenshotPath`; "valid proof inserts" + "different TID" updated with a fake uploader; new group "submitPaymentProof receipt screenshot (required)" (missing screenshot refused; upload failure refused; upload success stores the returned path). `test/upgrade_payment_test.dart` — new group "UpgradeScreen — receipt screenshot + WhatsApp" (attach button + required instruction visible; submit without receipt shows the error; full flow with `_FakeReceiptPicker` — pick → submit → WhatsApp next-step message + button).

### (b) WhatsApp (also required — the second channel)

- After a successful submit, the screen shows a WhatsApp button opening `https://wa.me/923427717288` with a prefilled message (plan + TID + email) and an instruction to also attach the receipt screenshot in WhatsApp. The payment screen itself states plainly that the receipt screenshot must be sent on WhatsApp to 03427717288.
- Panel hint (`admin/index.html` payments paragraph + approve confirm): the receipt also arrives on WhatsApp and must be matched by TID (plus amount and receiver number) before approving.

### Panel receipt link

**`admin/app.js` renderPayments:** rows with `screenshot_path` show a "Receipt" button → `client.storage.from('payment-proofs').createSignedUrl(path, 3600)` → opens the signed URL (1h) in a new tab, visible in the approve flow. (Needs migration 013 applied live + the bucket to exist; until then no row has a `screenshot_path` and no link renders — the panel does not break.)

**How verified:** service + screen logic covered by the tests above (full-suite result below). Panel receipt link + WhatsApp button verified in the live panel's served `app.js`/`index.html` (see §6).

**Could NOT be verified:** live bucket creation, live upload from a real phone, and the signed-URL receipt link end to end — all need the parent's live apply of migration 013 + a real phone test. The in-app upload path in production is unproven until then; the WhatsApp channel is the working fallback meanwhile.

---

## Payment-chain security audit (2026-11-20)

**User's requirement:** "payment system full authentication/security — no free/fake user or hacker can break it; premium only when I approve." Re-audited the full chain end to end by reading the code (this pass, after the TID work). **Verdict: no bypass found — every step that can grant Premium requires admin approval (or a code the admin issued). One hardening fix was made (issue-code plan source, §1 above).** Step by step:

### 1. Submit — `lib/services/payment_proof_service.dart`
- Validates TID format (6–30 chars, letters/digits/spaces/dashes), plan (must be one of the 3 — `planPrice` null check), method (Easypaisa/JazzCash only); requires a signed-in account and a configured backend; requires the receipt screenshot; UX duplicate-TID check (fail-open).
- Server locks: migration 008 INSERT policy (status must be `pending`, review fields null, `code_id` null; `payments_plan_valid` CHECK on plan; BEFORE INSERT trigger forcing `pending`) + RLS own-rows-only (`Users can insert their own payments`: `auth.uid() = user_id`). A user can submit ANY TID (a claim only) — **pending ≠ premium**. Locked.
- Comment-only fix in this pass: `supabase/migrations/008_payments_insert_constraints.sql` lines 36–37 said "issue-code / redeem-code never touch the table" — now stale (issue-code UPDATEs the approved row server-side since the TID guard). Corrected the comment; no SQL changed (file already applied live).

### 2. Approve — `admin/app.js approvePayment()` + RLS
- The panel only calls issue-code; no client-side approval remains. On error it marks nothing. Reject path uses a direct client UPDATE (`status='rejected'` + reviewer) — gated by RLS "Admins can update payments" (`using (public.is_admin())`, `supabase/migrations/002_rls.sql:77-79`); a non-admin cannot update any payments row via PostgREST.
- Even a hypothetical payments UPDATE bypass would grant nothing by itself: no code path grants Premium from a payment row's status. The approve decision itself is human (WhatsApp receipt / screenshot check) — see residual risk 1.

### 3. Issue-code — `supabase/functions/issue-code/index.ts` (v2, deployed)
- Admin-only (JWT + `is_admin` re-check server-side); payment binding (exists + belongs to buyer + pending); TID reuse check; plan from the payment row (hardening fix this pass); server-side approval conditional on still-pending; code hash-only, 7-day expiry. Locked.
- Race quirk (fail-closed, no premium): if the approval update fails after the code row is created (race loser), the code is left unused and its plaintext is never returned — unredeemable. It expires in 7 days and is visible in the codes table.

### 4. Redeem-code — `supabase/functions/redeem-code/index.ts` (v2, ACTIVE)
- JWT verified; 10/hr per-user throttle (fail-open, migration 011); format + SHA-256 lookup; `used_at`/expiry/binding checks; M1 exactly-one-row claim (`.select("id")`, require exactly 1 row or 409 `code_already_used`); service-role profile update extends `premium_until` from the existing date, never shortens. Locked.
- Residual quirk (fail-closed, rare): if the profile update fails AFTER the code is marked used, the code is consumed with no premium — needs a manual admin fix (issue a new code).

### 5. Premium refresh — `lib/services/subscription_service.dart`
- `refreshPlanFromServer` reads the user's own profiles row (RLS own-row) → `applyServerPremium` checks `isServerPremium` (plan ≠ 'free' AND `premium_until` in the future); otherwise it writes premium=false and deletes the cached plan/until. `isPremium()` also checks expiry locally and flips the cache to false when expired. The C1 trigger blocks client plan changes, so the server value is trustworthy.
- `applyServerPremium` callers (grep-verified this pass): only `refreshPlanFromServer` and `UpgradeScreen._redeemCode` (after a `result.success` check — `lib/screens/upgrade_screen.dart:353-365`); the `billing_service.dart` mention is a doc comment only. `auth_service.dart:312` `upsertProfile` writes only id/username/email (no plan fields; trigger + RLS would block them anyway). Grep confirms NO `profiles` UPDATE anywhere in `lib/` and no other `payments` writes besides `payment_proof_service.dart`. Panel `profiles` writes: only `revokePremium` (`plan='free'`, `premium_until`=null) — revoke only, no grant path. Play Billing is a stub (`billing_service.dart:44-55`) that refuses every purchase — no grant path.
- `send-notification` only SELECTs profiles (id, fcm_token, plan) for audience targeting — no UPDATE, no grant path. `delete-account` deletes only the caller — no grant path.

### Residual risks that CANNOT be closed in code (stated plainly, not oversold)
1. **The admin's manual check is the ONLY verification that money reached the owner's Easypaisa/JazzCash.** A TID + screenshot can both be fabricated; Easypaisa/JazzCash offer no lookup API. The duplicate guard + required screenshot raise the cost of fraud (a fresh TID + plausible receipt each time) but cannot prove payment. Full closure = a real payment gateway (merchant account with webhook verification) — separate work, not built here.
2. **Rooted-device secure-cache tampering** gives offline premium until the next server refresh corrects it (refresh overwrites the cache from the server row). Full closure needs server-side test gating.
3. **Reinstall resets the local free-test counter** — server reconciliation takes the max (`refreshFreeCountFromServer`), so synced tests still count; unsynced offline tests are lost with the local DB (a few extra free tests after reinstall, not Premium).
4. **Redeem-code profile-update failure after code consumption** (see step 4 above) — rare, fail-closed, manual admin fix with a new code.
5. **Legacy one-time migration** copies a v1 premium flag from SharedPreferences into secure storage (deliberate carry-over for legitimate v1 premium users, acknowledged in L7).

---

## Admin panel — PWA install + new-payment alerts (2026-11-20)

**User's asks:** (2) notification WITH SOUND when a new user pays; (3) panel installable on the phone home screen like an app (no link typing).

### PWA — installable

**Files:** `admin/manifest.json` (new), `admin/icons/icon-192.png` + `admin/icons/icon-512.png` (new, generated with Python PIL — dark-navy `#0b1f3a` rounded square, gold "OP", DejaVu Sans Bold), `admin/sw.js` (new), `admin/index.html` (manifest link + `theme-color #0b1f3a`)
- Manifest: name "OfficerPath AI Admin", short name "OfficerPath Admin", `display: standalone`, `start_url: /`, `scope: /`, theme/background `#0b1f3a` (matches the panel header `--navy`), both icons listed.
- Service worker: caches the panel shell (`/`, `index.html`, `styles.css`, `app.js`, `config.js`, `manifest.json`, both icons) on install; same-origin cache-first with network fallback; NEVER caches Supabase/CDN (cross-origin requests pass through). Cache version `officerpath-admin-v1` — **bump the version in `sw.js` when the shell changes**, or the panel can serve a stale `app.js` after a deploy. Registered from `app.js` `boot()` (failure non-fatal — panel still works online).
- Verified: manifest is valid JSON; icons exist at the referenced paths with the right sizes (192×192, 512×512, real PNG bytes); live panel serves all of them (see §6). **NOT verified:** the actual "Add to Home screen" prompt / install on a real phone — needs the user's phone test (Chrome on Android shows the prompt once manifest + SW + icons are present and the site is visited twice).

### Live alert — Realtime + sound + banner (panel open)

**Files:** `admin/app.js` (subscribePaymentAlerts, showPaymentAlert, playAlertSound, ensureAudio), `admin/index.html` (banner div), `admin/styles.css` (banner style + pulse animation), `supabase/migrations/014_realtime_payments.sql` (new, file only — NOT applied live)
- Subscribes (once per login, after the admin gate passes) to Supabase Realtime `postgres_changes` on `public.payments` INSERT, filter `status=eq.pending`, channel `officerpath-payments`. On a new pending payment: banner shows "New payment — <email> — <plan> — TID <id>", a short beep plays (Web Audio API — three sine notes, no audio asset), and the payments list + pending count refresh.
- AudioContext is created/resumed on user interaction (`pointerdown` listener + before each beep) so the browser autoplay policy allows it. Sound is best-effort (try/catch — the banner still shows if audio is unavailable).
- **Banner styling (user request, 09:18 PKT): GREEN and animated — solid `var(--success)` background, white text, gentle 2-second pulsing glow (box-shadow only, never the text; slow, no fast flashing), `prefers-reduced-motion: reduce` disables the animation.** Deployed and verified live in the served CSS.
- Migration 014 adds `public.payments` to the `supabase_realtime` publication (idempotent-guarded via a `DO` block checking `pg_publication_tables` — re-running is a no-op). **NOT applied live — until the parent applies it, the subscription stays silent and nothing else breaks.**
- **Honest limit:** sound + banner only work while the panel/PWA is open — a closed web page cannot beep. The email alert below covers the closed case.

### Email alert — payment-alert Edge Function (panel closed)

**File:** `supabase/functions/payment-alert/index.ts` (new; deployed 20 Nov, id `ec81d033-dd5f-4510-951f-56a44595db53`, status ACTIVE, version 1, **`verify_jwt=False`**)
- `verify_jwt` MUST be false for this function: database webhooks carry no user JWT. Auth is a shared secret instead: header `x-webhook-secret` must equal env `PAYMENT_ALERT_SECRET` (constant-time-ish comparison; missing/wrong secret → 401; no secret configured server-side → refuse everything, fail closed).
- On a database-webhook POST: only `type=INSERT` + `table=payments` alerts (anything else → `{ok:true, ignored:true}`); queries `profiles` where `is_admin=true` for recipient emails; sends one Resend email (RESEND_API_KEY + RESEND_FROM already project secrets) with subject "New OfficerPath payment — <email> — <plan>" and body containing email, plan, method, transaction_id and the panel URL `https://officerpath-admin.pages.dev/`. Send failure is reported (500), not hidden.
- **Deploy helper change:** `~/workspace/custom-connectors/custom.supabase/bin/deploy_function.py` now supports `--no-verify-jwt` (and `payment-alert` is in `ALL_FUNCTIONS`). Verified via `--list`: payment-alert ACTIVE v1 verify_jwt=False; issue-code ACTIVE v2 verify_jwt=True; redeem-code v2; send-notification v2; delete-account v1 (all True).
- **PAYMENT_ALERT_SECRET — NOT SET YET (parent action required):** setting it via the Management API was attempted and refused — HTTP 403, token lacks `edge_functions_secrets_write`. Per the brief, a strong random value was generated and is stored ONLY in this report file (never in chat) — see the value below. **The parent must:** (1) set it in Supabase Dashboard → Edge Functions → Secrets as `PAYMENT_ALERT_SECRET`; (2) use the SAME value as the `x-webhook-secret` header when creating the webhook; (3) **delete the value from this file before any commit/push** — this report file is a working-tree file that may be pushed to the public repo, and a committed webhook secret would let anyone forge alert emails. (The function is fail-closed until the secret is set: it 401s everything, including legitimate webhooks.)
  - **Value:** [REDACTED by parent 2026-11-20 before any commit — use a fresh strong random value, the SAME value in the Edge Function secret AND the webhook header]
- **Webhook setup for the parent (Dashboard → Database → Webhooks → Create):** Name `payment-alert`; Table `public.payments`; Events INSERT only; Type HTTP Request, Method POST; URL `https://gliebuyyjguxrwdfuakz.supabase.co/functions/v1/payment-alert`; HTTP Headers: `x-webhook-secret` = the value above. Do NOT create the webhook from here — parent does that.
- **Live gate test (this pass):** POST with a wrong secret → HTTP 401 `{"ok":false,"error":"unauthorized"}`; POST with no secret → 401. **NOT verified live:** the success path (real alert email) — it needs the secret set + the webhook created first; the first real payment after that proves it end to end.

### Panel deploy (once, with everything)

Deployed via the Pages helper (`pages_deploy.py --deploy officerpath-admin ~/workspace/officerpath-ai/admin`):
- Deployment `988d6a23-f785-44ea-9a3d-da220efc758d` (production) — TID guard + WhatsApp + screenshot receipt link + PWA + Realtime alert.
- Deployment `33631139-0306-4477-b587-e4637c596774` (production) — green pulsing banner restyle (1 blob changed).
- **Live verification (production URL `https://officerpath-admin.pages.dev/`):** `/` HTTP 200 `text/html` (11,863 B); `/manifest.json` HTTP 200 `application/json` (432 B); `/sw.js` HTTP 200 `text/javascript` (1,675 B); `/icons/icon-192.png` HTTP 200 `image/png` (3,569 B, matches local); `/icons/icon-512.png` HTTP 200 `image/png` (10,663 B, matches local); `/styles.css` HTTP 200 `text/css` with `alert-pulse` + the reduced-motion override present. Served `app.js` contains `payment_id`, `postgres_changes`, `createSignedUrl`, `payment-alert-banner`/`ensureAudio`/`officerpath-payments`. Served `index.html` has the manifest link + theme-color.
- **NOT verified live:** the Realtime beep/banner firing on a real payment (needs migration 014 applied + a real payment with the panel open); the PWA install prompt on a real phone; the email alert end to end (needs the secret + webhook).

---

## Test repairs found by the full-suite run (2026-11-20)

The full suite after the TID/screenshot work did NOT pass first time (714 passed, 5 skipped, 5 failed). Three separate defects were found and fixed in this pass:

1. **Async dart:io hangs inside widget tests on this VM (root cause of the main failure).** The test "proof submission shows the pending state + proof row" (`test/upgrade_server_code_test.dart`) tapped Submit without a receipt, so after the screenshot became required it failed with "no Proof submitted text". The first repair (attach a receipt via a temp file) made the test stall for 2+ minutes. Bisected with a debug copy (print markers): the hang was exactly at `await Directory.systemTemp.createTemp(...)`. Minimal repro (`test/usc_minimal_test.dart`, since deleted): pump a bare widget, then `createTemp` — plain Dart creates the temp dir in 9 ms, but inside a widget test the call never returns (killed after 120 s; the framework's per-test timeout never fires because the test binding never delivers the async completion). Fix: the fake picker now carries the receipt bytes directly (`PlatformFile(name: 'receipt.jpg', bytes: Uint8List.fromList([1, 2, 3]), size: 3)`); the screen's `_receiptBytes()` prefers `f.bytes` when present, so no temp file is needed. Applied to both `upgrade_server_code_test.dart` (proof test) and `upgrade_payment_test.dart` (receipt-flow test). Debug files deleted afterwards.
2. **Illegal getter — `upgrade_payment_test.dart` never compiled.** `Finder get tidField => ...` inside a `group()` callback is illegal Dart (getters cannot be declared inside a function body). The file failed to load, so its whole receipt group never ran — this was pre-existing from the earlier session's edit, not from this pass. Fixed to `final Finder tidField = find.byWidgetPredicate(...)` (call sites unchanged — they pass it as a value).
3. **Duplicate-TID service tests predated the screenshot requirement.** Three tests in `test/payment_proof_test.dart` called `submitPaymentProof` without `screenshotBytes`, so they got "Please attach your payment receipt screenshot first" instead of the duplicate refusal (the screenshot is checked first). Fixed by supplying `screenshotBytes: [1, 2, 3]`; the fail-open test also needed the fake uploader (its submit proceeds to upload + insert).

**Verification (this pass):** the three touched files together: **44 passed, 0 failed** ("All tests passed!", exit 0). Full suite + analyze: see below.

---

## Verification (this pass, 2026-11-20)

- Full `flutter test`: **762 passed, 5 skipped, 5 failed.** The 5 failures are ALL parser tests — `test/table_format_test.dart` (3: computer table Q67–81, option-marker mismatch, interjection table Q230–258) and `test/ocr_table_reconstruct_test.dart` (2: interjection table regroup, computer table p.5) — expectation mismatches in the OCR table-reconstruction work that the parent's parser effort is actively changing (MEMORY.md: master directive, baseline agent, "OCR two-column split + table reconstruction in progress"). None of the 5 touches any file changed in this pass (no parser code was edited here); they are reported plainly as NOT fixed by this pass and NOT verified green. The three files this pass changed or added tests to — `test/payment_proof_test.dart`, `test/upgrade_server_code_test.dart`, `test/upgrade_payment_test.dart` — pass **44/44** ("All tests passed!", exit 0, re-run after the final import fix).
- `flutter analyze`: **15 issues, all info-level `avoid_print` in `test/ppsc66_baseline_test.dart`** (the parent's parser-baseline measurement file — its prints are diagnostic output, left alone; the file is being edited concurrently by the parent's parser work). Zero issues in any file touched by this pass (the 2 `unnecessary_import` infos this pass introduced in `test/upgrade_payment_test.dart` were removed; `dart:typed_data` is kept in `test/upgrade_server_code_test.dart` where it is needed).
- Live verification summary: issue-code ACTIVE v2; payment-alert ACTIVE v1, `verify_jwt=False`; panel deployments `988d6a23` + `33631139` (production) with all new files serving HTTP 200 with correct content types; payment-alert gate returns 401 for a wrong or missing secret.
- NOT verified live (parent steps): applying migrations 012/013/014; setting `PAYMENT_ALERT_SECRET` + creating the webhook + the real alert email; the Realtime beep/banner firing on a real payment; PWA install on a real phone; live receipt upload + signed-URL link; an end-to-end double-approval race; the C1 allow-branches (admin-panel grant + redeem smoke test — still open from the earlier pass).
