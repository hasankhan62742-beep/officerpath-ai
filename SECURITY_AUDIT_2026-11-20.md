# Security Audit — OfficerPath AI v2.0.0 (pre-release)

- **Date:** 2026-11-20
- **Scope:** `~/workspace/officerpath-ai/` at commit `1ba64ed0` (v2.0.0, release id 452214998 — CI re-running)
- **Method:** read-only static review of migrations, Edge Functions, app services, Android manifest, admin panel, updater, CI workflow, plus secret-pattern greps. No code was edited, no live Supabase/Firebase state was re-queried in this audit.
- **No secret values are reproduced in this report.** Key material is described by type/location only.

## Verdict

**DO NOT SHIP v2.0.0 as-is. One Critical finding must be fixed first.**

- **C1 (Critical): any signed-in user can grant themselves Premium for free** with a single direct database call, bypassing payment entirely. The app then trusts the forged value. This is a one-line exploit against the published anon key and breaks the entire v2 payment model.
- **H1 (High): the CI-built APK cannot install over any previous build** — every CI run signs with a fresh ephemeral debug keystore, so the in-app updater cannot actually update anyone. Fix with the release: pin one keystore in CI.
- **H2 (High): the admin panel cannot see any activation code** — its own audit UI is silently empty because `activation_codes` has no client policy at all. The payment↔code link is never recorded.
- M1–M5 (Medium) should be fixed in the same pass: redeem-code double-spend race, self-approved payments, unverified updater downloads, waitlist spam, and an un-gitignored file holding 11 real user emails.

Everything else audited (auth handling, secrets hygiene, Android permissions, Edge Function auth checks, admin gate, CI secret handling) is in good shape — see §9 for the verified-clean list.

---

## 1. Supabase RLS

Files: `supabase/migrations/001_schema.sql`, `002_rls.sql`, `003_triggers.sql`, `004_push_notifications.sql`, `005_waitlist.sql`.

RLS is enabled on all six tables (`001_schema.sql:75-78` profiles, activation_codes, payments, test_results; `004_push_notifications.sql:45` sent_notifications; `005_waitlist.sql:36` waitlist). No table has RLS off. No policy uses a client-supplied `user_id` — every user policy is keyed on `auth.uid()`.

### Policies (verbatim, condensed)

**profiles** (`002_rls.sql:36-61`)
- `SELECT "Users can view their own profile"` — `USING (auth.uid() = id)`
- `INSERT "Users can insert their own profile"` — `WITH CHECK (auth.uid() = id)`
- `UPDATE "Users can update their own profile"` — `USING (auth.uid() = id)` `WITH CHECK (auth.uid() = id AND (is_admin IS NOT TRUE OR public.is_admin()))`
- `SELECT/UPDATE "Admins can view/update all profiles"` — `USING (public.is_admin())`

**payments** (`002_rls.sql:64-79`)
- `SELECT/INSERT "Users can view/insert their own payments"` — `auth.uid() = user_id`
- `SELECT/UPDATE "Admins can view/update payments"` — `public.is_admin()`; no DELETE policy.

**test_results** (`002_rls.sql:85-95`)
- `SELECT/INSERT` own rows only (`auth.uid() = user_id`); `SELECT` for admins. No UPDATE/DELETE (append-only).

**activation_codes** (`002_rls.sql:101-105`)
- RLS on, **intentionally zero policies** — no client access of any kind. Only the service_role key (Edge Functions) can touch it.

**sent_notifications** (`004_push_notifications.sql:48-57`)
- `SELECT` / `INSERT` for admins only (`public.is_admin()`). No UPDATE/DELETE.

**waitlist** (`005_waitlist.sql:41-50`)
- `INSERT "Anyone can join the waitlist"` — `TO anon WITH CHECK (true)`
- `SELECT "Admins can view the waitlist"` — `public.is_admin()`. No UPDATE/DELETE.

### Finding C1 — CRITICAL — Users can set their own `plan`/`premium_until` (free Premium)

- **Evidence:** `002_rls.sql:49-52`. The update policy's `WITH CHECK` guards **only `is_admin`**; it places no restriction on any other column. A signed-in user may update `plan` and `premium_until` on their own row.
- **Attack:** with the published anon key (shipped in every APK and in `admin/config.js`), anyone runs one PostgREST call — `PATCH /rest/v1/profiles?id=eq.<own-uuid>` with `{"plan":"premium","premium_until":"2099-01-01"}` — and is Premium. The app then trusts it end-to-end: `lib/services/subscription_service.dart:247` `refreshPlanFromServer()` reads `plan, premium_until` from the row (`:385-397`), `applyServerPremium()` (`:342`) writes it to the local cache, and `isPremium()` (`:484`) returns true. Unlimited free tests, forever, no payment, no code.
- **Also:** the `INSERT` policy (`002_rls.sql:43-45`) has the same shape — if a profile row ever failed to be created by the signup trigger, a user could insert their own row with `plan='premium'` directly.
- **Fix (do this before release):** stop letting clients write entitlement columns. The robust fix is a `BEFORE UPDATE` trigger on `public.profiles` that raises an error when `OLD.plan`/`OLD.premium_until` (or `is_admin`) change and the caller is not an admin (`NOT public.is_admin()`), plus the same guard on INSERT (force `plan='free'`, `premium_until=NULL` for non-admin inserts). Alternative: remove the broad user UPDATE policy entirely and route username / FCM-token / opt-out writes through a dedicated `SECURITY DEFINER` RPC that only touches those three columns. Either way, add a regression test that attempts the PATCH as a non-admin and asserts it fails. (A `WITH CHECK` clause alone cannot express "these columns unchanged" — that is why a trigger/RPC is needed.)

### Finding M2 — MEDIUM — Users can self-approve their own payment rows

- **Evidence:** `002_rls.sql:68-70`. The insert policy's `WITH CHECK` is only `auth.uid() = user_id` — it does not constrain `status`, `reviewed_by`, `reviewed_at`, or `code_id`. The app itself always inserts `status: 'pending'` (`lib/services/payment_proof_service.dart:172`), but RLS does not enforce it.
- **Attack:** a user inserts a payment row with `status: 'approved'` directly. The admin panel's review queue filters `status = 'pending'` (`admin/app.js`, `loadPayments`), so the forged row never appears for review — and in the user-detail view (`openUser`) it displays as a legitimately approved payment, which could induce the admin to issue a code for an unverified payment.
- **Compounding gap:** `payments.plan` has **no CHECK constraint** (`001_schema.sql`, payments table) — the plan shown to the admin is user-controlled input (e.g. claim a 1-year plan on a Rs 600 payment). `issue-code` rejects unknown plan strings, but a valid-looking wrong plan passes through.
- **Fix:** tighten the insert policy to `WITH CHECK (auth.uid() = user_id AND status = 'pending' AND reviewed_by IS NULL AND reviewed_at IS NULL AND code_id IS NULL)`, and add `CHECK (plan IN ('premium_1month','premium_2months','premium_1year'))` to `payments.plan` (migration 006). Belt-and-braces: a `BEFORE INSERT` trigger forcing `status='pending'` covers clients that omit the field.

### Finding M4 — MEDIUM — Waitlist anon INSERT is intentionally open but unthrottled

- **Evidence:** `005_waitlist.sql:41-45`, `WITH CHECK (true)` for `anon`; the public page inserts `{email, source:'waitlist-page'}` (`docs/index.html:171`). The `WITH CHECK (true)` is deliberate and documented — this is not an accidental hole — but there is no rate limit, CAPTCHA, or per-IP throttle anywhere in the path.
- **Attack:** scripted bulk inserts of unlimited unique emails (the UNIQUE constraint only blocks exact duplicates; the regex CHECK only enforces format). Result: database bloat and a polluted launch-email list.
- **Fix:** keep the policy, but front the insert with an Edge Function that rate-limits per IP and verifies a CAPTCHA/Turnstile token; or add a DB-side guard (e.g. max N inserts per minute per IP is not visible to Postgres — so the Edge Function route is the real fix). At minimum, monitor `waitlist` row growth after launch.

### Finding L1 — LOW — `SECURITY DEFINER` functions without `SET search_path`

- **Evidence:** `public.is_admin()` (`002_rls.sql:22-31`, `security definer` at line 25) and `public.handle_new_user()` (`003_triggers.sql:22`).
- **Risk:** a `SECURITY DEFINER` function without an explicit `search_path` can be influenced by search-path manipulation (standard Supabase hardening guidance). Practical risk here is low — ordinary users cannot create schemas — but it is a one-line fix.
- **Fix:** add `SET search_path = public` (or `SET search_path = ''`) to both function definitions.

### Finding L9 — LOW — Trigger failure mode for profile creation

- **Evidence:** `003_triggers.sql` `handle_new_user()` — the username-uniqueness loop (`WHILE EXISTS ...`) can raise a unique-violation on concurrent signups with the same base username; the `ON CONFLICT (id) DO NOTHING` only covers the `id` conflict, not a username conflict. A failed trigger fails the whole signup.
- **Risk:** reliability, not privilege — but combined with C1's insert-policy note, a missing profile row is the one path where a user could insert their own premium row. Fix together with C1 (and make the trigger retry/handle the username race).

---

## 2. Edge Functions

Files: `supabase/functions/{redeem-code,issue-code,delete-account,send-notification}/index.ts`. All four are deployed with `verify_jwt=true` (per project record) and all four verify the caller's JWT server-side with `auth.getUser()` before doing anything. `service_role` is used only here, read from environment secrets, never in app code.

### redeem-code — correct except one race (M1)

- Auth: JWT verified (`index.ts`, `getUser()`, 401 `unauthorized` when absent/invalid). Code format validated server-side (`CODE_RE = /^OP([123])-([A-Z2-9]{6})$/`), SHA-256-hashed, looked up by hash only; plain code never stored.
- Single-use + expiry + binding are all enforced server-side: `used_at` → 409 `code_already_used` (line 113), `expires_at` → 410 `code_expired`, `user_id` mismatch → 403 `code_not_yours`. Premium is extended from the existing `premium_until`, never shortened. Good.

#### Finding M1 — MEDIUM — Single-use claim is not atomic (TOCTOU double-spend)

- **Evidence:** `redeem-code/index.ts:138-147`. The function checks `used_at` (line 113), then claims the code with `.update({...}).eq("id", codeRow.id).is("used_at", null)` and checks **only** `useError`. A PostgREST UPDATE that matches zero rows returns success with an empty data array and **no error** — so if two requests (same code, two different users) pass the check simultaneously, the loser’s update matches zero rows, raises no error, and execution continues to grant Premium to the second user as well.
- **Attack:** submit the same code from two accounts at the same moment; both get Premium. Window is small (milliseconds) but the check-then-act pattern is not atomic, and this is the core money control.
- **Fix:** require the claim to affect exactly one row — append `.select()` to the update and fail with `code_already_used` when the returned array is empty — or move the claim into a single Postgres RPC that does `UPDATE ... WHERE used_at IS NULL RETURNING id` under row lock and returns whether the claim succeeded.

### issue-code — admin-only, correct

- Auth: JWT verified, then the caller’s `profiles.is_admin` is read with the service-role client; non-admins get 403 `forbidden_not_admin`. Input validated against an allowlist (`PLAN_MAP`); code generated with `crypto.getRandomValues`; only the SHA-256 hash is stored; plain code returned once to the admin caller and emailed via Resend (email failure never blocks the sale; `email_sent:false` is reported). No issues found. Minor note: `user_id` is accepted as any non-empty string — a garbage UUID fails on the foreign-key constraint (`server_error`), so it cannot create an orphan code; no fix needed.

### delete-account — correct

- Auth: JWT verified; deletes **only the caller** (JWT owner — no `user_id` parameter is accepted, so one user cannot delete another). Order is right: `test_results`/`payments` rows deleted first (no `ON DELETE CASCADE` on those FKs), `activation_codes` rows unlinked (not deleted, preserving the sales record), then `auth.admin.deleteUser()`; the `profiles` row follows via `ON DELETE CASCADE` (`001_schema.sql`). No admin variant by design (admins delete via Dashboard). No issues found.

### send-notification — admin-only, correct except L5

- Auth: JWT + `is_admin` check, same pattern as issue-code. Input allowlisted (`audience` all/premium/free; `type` update_available/announcement; `version` required for updates). Opt-out enforced server-side (`notifications_enabled = true AND fcm_token IS NOT NULL`). FCM via HTTP v1 with a hand-rolled RS256 OAuth2 flow from the `FIREBASE_SERVICE_ACCOUNT` secret (never in code). Dead tokens cleared; sends logged to `sent_notifications`.

#### Finding L5 — LOW — `INVALID_ARGUMENT` treated as a dead token

- **Evidence:** `send-notification/index.ts:214-215` — `unregistered = detail.includes("UNREGISTERED") || detail.includes("INVALID_ARGUMENT")`, and unregistered tokens are then cleared from `profiles` (dead-token cleanup loop).
- **Risk:** `INVALID_ARGUMENT` can also mean a malformed message (not a dead token). A bad send could wipe valid tokens, silently unsubscribing users.
- **Fix:** clear tokens only on `UNREGISTERED` (and `NOT_FOUND`); treat `INVALID_ARGUMENT` as a send failure without clearing.

---

## 3. Secrets in code / pushed tree

Greps run over the whole project (excluding `.git`, venvs, `*.log`): patterns `service_role`, `sbp_…`, `sk-…`, `AIza…`, `-----BEGIN … PRIVATE KEY`, `CHANGE_ME_IN_RELEASE_BUILD`, and `eyJ…` JWT-shaped strings. Values are **not** reproduced here.

- **No `sbp_` tokens, no `sk-` keys, no private keys anywhere in the repo.**
- **All `service_role` hits are prose/comments/tests** (migration comments, `admin/config.example.js` warnings, `docs/`, and tests that assert the string is *absent* from shipped files). No live service_role value exists in any file.
- **`admin/config.js` — verified clean:** defines only `SUPABASE_URL` and `SUPABASE_ANON_KEY` (17 lines); the only two `service_role` mentions are comment lines 9–10 warning never to put it there. The anon key is a publishable key by design — but its safety rests entirely on RLS being correct, which is exactly why C1 is Critical. `admin/config.js` is excluded from the repo by `admin/.gitignore` (`config.js`) and was **confirmed absent from the remote GitHub tree** (only `config.example.js` is present).
- **`android/app/google-services.json` — verified client config only:** top-level keys `project_info`, `client`, `configuration_version`; `project_info` holds `project_number`, `project_id`, `storage_bucket`; the single client entry holds `client_info`, `oauth_client`, `api_key` (one `current_key` — a Firebase **Android client API key**, not a server key), and `services`. **No service-account fields, no server key, no `service_role`.** Safe to ship in the repo as intended. (Whether that Android API key has GCP-side restrictions — package name / SHA-1 — cannot be verified from the repo; see §9 "could not verify".)
- **`lib/services/supabase_config.dart` — clean:** URL and anon key come **only** from `--dart-define` (`String.fromEnvironment('SUPABASE_URL' / 'SUPABASE_ANON_KEY')`, empty defaults → offline v1 mode). Nothing hardcoded. The workflow passes them from GitHub repo secrets (see §8).
- **One live placeholder:** `lib/services/manual_activation.dart:53` — default `ACTIVATION_SECRET = 'CHANGE_ME_IN_RELEASE_BUILD'` (see L3, §4).

### Finding M5 — MEDIUM — `access-requests-seen.txt` is not gitignored

- **Evidence:** the file exists in the project root (321 bytes, 11 real requester emails) and matches **no** `.gitignore` (root `.gitignore` and `admin/.gitignore` both checked). It is currently excluded from pushes only by the custom push helper's `EXTRA_EXCLUDES` list — confirmed absent from the remote tree today, but a plain `git add . && git push`, or any other tool, would commit real users' emails to the public repo.
- **Fix:** add `access-requests-seen.txt` to the root `.gitignore` now and verify with `git check-ignore access-requests-seen.txt`. Consider moving it out of the repo tree entirely (`~/workspace/` private location).

---

## 4. App-side auth

Files: `lib/services/auth_service.dart`, `activation_service.dart`, `subscription_service.dart`, `secure_key_store.dart`, `deep_link.dart`, `lib/main.dart` (deep-link handler), `manual_activation.dart`, `billing_service.dart`.

- **Session handling is via `supabase_flutter`, not hand-rolled:** `AuthService` wraps `Supabase.instance.client.auth` (`signUp` / `signInWithPassword` / `signInWithIdToken` (Google) / `signOut` / `resetPasswordForEmail` / `updateUser`); session persistence comes free with the SDK. No custom token storage exists.
- **No passwords logged or stored:** grep for `print`/`debugPrint` of tokens, passwords, `accessToken`, `refreshToken` across `lib/` found no logging of credentials. Passwords are passed only to Supabase Auth calls and never written to SharedPreferences, sqflite, or logs.
- **Gemini key:** stored only in platform secure storage via `flutter_secure_storage` (`secure_key_store.dart`, key name `gemini_api_key_v1`); the file's own contract is "never in SharedPreferences, never in sqflite, never in a log, never sent anywhere except directly to Google's Gemini API". Verified by code read.
- **Deep link:** `deep_link.dart` parses `officerpath://reset-password` (PKCE `code` first, else `access_token`/`refresh_token` from the fragment); `lib/main.dart` exchanges the code via `auth.exchangeCodeForSession()` or falls back to `auth.setSession()` (see L7). Tokens are not logged.
- **Billing:** `billing_service.dart` is a stub that never grants Premium — no money path exists in-app.
- **Premium state:** `isPremium()` reads a SharedPreferences cache written by `applyServerPremium()` (server data) or `grantPremium()` (billing/v1 path only) — see L8.

### Finding L3 — LOW — Dead v1 offline-activation code ships in the v2 binary

- **Evidence:** `lib/services/manual_activation.dart` — FNV-1a checksum over the secret + plan, default secret `'CHANGE_ME_IN_RELEASE_BUILD'` (line 53), with the file's own warning that the default is public in the repo. The v2 Upgrade screen no longer calls it — verified: `lib/screens/upgrade_screen.dart:222-261` uses only `ActivationService.redeemCode()` (server path), and the only other references are unit tests and a deprecation comment. `SubscriptionService.grantPremium()` (`subscription_service.dart:512`) is still public and still writes the premium cache.
- **Risk:** unreachable from the UI today, but the forgeable path (anyone can compute v1 codes offline from the public default secret) remains compiled into the shipped app; any future wiring mistake re-opens free Premium.
- **Fix:** delete `manual_activation.dart` (and `tools/generate_activation_code.dart`) from the v2 tree, or gate them behind a build flag that is off for v2. Update the two unit tests that exercise it.

### Finding L7 — LOW — Deep-link implicit-flow fallback

- **Evidence:** `lib/main.dart` `_handleDeepLink` — PKCE `code` exchange is tried first (good); the fallback accepts raw `access_token`/`refresh_token` from the URL fragment via `auth.setSession()`.
- **Risk:** low — the custom scheme is app-scoped and fragments are not sent to servers — but implicit-flow tokens can linger in OS intent logs. Prefer PKCE-only once the Supabase reset-email template is confirmed to emit PKCE codes.

### Finding L8 — LOW (accepted residual, note only) — Premium cache is plaintext on device

- **Evidence:** `subscription_service.dart:484-497` — `isPremium()` trusts a SharedPreferences boolean + expiry. A rooted phone can flip it; the next successful `refreshPlanFromServer()` overwrites it from the server, but an offline rooted device keeps Premium until then.
- **Risk:** accepted v1 honest limit (rooted-device tampering); no fix required for launch, but it is why server-side checks matter for anything beyond the free-test counter.

### Finding L4 — LOW — Security test guards the wrong string

- **Evidence:** `test/security_test.dart:59-70` ("no hardcoded Gemini key or default activation secret") asserts no file contains `'DEFAULT_ACTIVATION_SECRET'` — but the actual default in the code is `'CHANGE_ME_IN_RELEASE_BUILD'` (`manual_activation.dart:53`). The test passes while guarding a string that does not exist.
- **Fix:** assert absence of `'CHANGE_ME_IN_RELEASE_BUILD'` in `lib/` (and in `tools/`).

---

## 5. Android permissions

File: `android/app/src/main/AndroidManifest.xml`. Every declared permission, with justification:

| Permission | Verdict |
|---|---|
| `INTERNET` | Expected (Supabase, Gemini, RSS, GitHub update check). |
| `REQUEST_INSTALL_PACKAGES` | Expected for the GitHub-sideload updater; Android still prompts the user once for "Install unknown apps". Must be removed for any future Play build (Play forbids self-updates) — the code already gates on `PLAY_BUILD` (`app_update_service.dart`). |
| `WRITE_EXTERNAL_STORAGE` (`maxSdkVersion="28"`) | Expected, correctly capped — result-PDF save on Android 9 and below only; Android 10+ uses MediaStore and never prompts. |
| `POST_NOTIFICATIONS` | Expected (FCM, Android 13+ runtime permission, asked once after first login). |

**No red flags:** no `CAMERA` (camera photos go through the system picker / `file_picker`, not a camera API — no `image_picker` dependency in `pubspec.yaml`), no location, contacts, SMS, or `MANAGE_EXTERNAL_STORAGE`. Also verified: `android:allowBackup="false"` (secure-storage/entitlement data never backed up), cleartext traffic off (`network_security_config.xml`: `cleartextTrafficPermitted="false"`), deep-link intent filter correctly scoped to `officerpath://reset-password`, `MainActivity` exported only as the launcher. A test (`test/security_test.dart:129`) pins this exact permission list. **No findings in this area.**

---

## 6. Admin panel

Files: `admin/app.js` (782 lines), `admin/config.example.js`, `admin/config.js` (verified in §3), `admin/index.html` (not re-read in full; login form + views referenced from `app.js`).

- **Admin gate:** login is `signInWithPassword` only — **no signup form exists**. After sign-in, `checkAdmin()` queries the caller's `profiles.is_admin` and, on any failure or `false`, signs the user out and shows access-denied. Data loading (`loadAll()`) runs only after the gate passes. Real enforcement is RLS (admin policies via `is_admin()`), so the panel gate is defence-in-depth, as its header comment states.
- **XSS:** user-controlled values (username, email, transaction id, book title, exam, scores) are rendered exclusively through the `esc()` HTML-encoder (`app.js:48-56`); toasts and code display use `textContent`; the mailto link uses `encodeURIComponent`. No unescaped `innerHTML` interpolation of user data was found.
- **Plain codes:** shown once in the approval modal (`showApproveModal`), never stored or re-displayed; code rows are listed by hash prefix only.

### Finding H2 — HIGH — The panel cannot read `activation_codes` at all

- **Evidence:** `admin/app.js` queries `activation_codes` from the anon client in four places — `loadStats()` lines 219-220 (issued/used counts), `openUser()` line 339 (codes for a user), `approvePayment()` lines 467+ (lookup of the newest unused code to link `code_id`), `loadCodes()` line 742 (codes table). The table has **zero client policies** (§1), so RLS filters every one of these selects to an empty result (no error is raised — RLS returns zero rows, not a 403).
- **Impact:** the dashboard permanently shows "0 codes issued / 0 used"; the codes table is always empty; user detail always says "No codes issued"; and — most importantly — `approvePayment()` never links the issued code to the payment (`code_id` stays null), so there is **no audit trail connecting an approved payment to the code that was issued for it**. An admin cannot detect a mis-issued or duplicated code.
- **Fix:** add an admin-only `SELECT` policy on `activation_codes` — `CREATE POLICY "Admins can view activation codes" ON public.activation_codes FOR SELECT USING (public.is_admin());` (migration 006). This is safe: only the SHA-256 hash is stored, never the plain code, so admins still cannot recover a code from the table. Do **not** add INSERT/UPDATE/DELETE policies for clients. Then verify in the live panel that the codes table populates and `code_id` is set on approval.

---

## 7. In-app updater

File: `lib/services/app_update_service.dart`.

- Flow: `checkForUpdate()` fetches `https://api.github.com/repos/hasankhan62742-beep/officerpath-ai/releases/latest` over HTTPS, picks the asset ending in `-arm64.apk` (falls back to any `.apk`), compares the tag with the installed version. `downloadAndInstall()` (lines 187-192) passes the `browser_download_url` straight to `OtaUpdate().execute()` and hands the file to the Android installer. No signature check by the app is possible for a regular app — Android's same-signer rule is the install gate — but see H1: the signer identity is ephemeral per CI run, so that gate currently provides no continuity at all.

### Finding M3 — MEDIUM — Downloaded APK is never verified

- **Evidence:** `app_update_service.dart:187-192` — no hash, checksum, or size check; `assetSize` is parsed (line 153) and stored but **never compared** after download; `pickApkAsset()` falls back to any `.apk` asset if no `-arm64.apk` exists.
- **Attack:** if the GitHub repo/release is compromised (stolen PAT, compromised maintainer session) or a wrong asset is attached, the app downloads and installs it with no verification beyond Android's same-signer check — which H1 renders meaningless.
- **Fix:** publish a SHA-256 for the APK (a `.sha256` release asset, or a checksum in the release body), fetch it over the same HTTPS API response, verify the downloaded file's hash before calling the installer, and fail closed on mismatch. Also drop the any-`.apk` fallback (require the `-arm64.apk` name exactly) and compare the downloaded size against `assetSize`.

### Finding H1 — HIGH — No stable signing key (CI builds are effectively unsigned-for-update-purposes)

- **Evidence:** `.github/workflows/build-apk.yml` builds `flutter build apk --debug` with **no keystore step**; the header comment itself records "No keystore / signing config: the owner's release keystore does not exist yet, so this builds DEBUG." On a fresh GitHub-hosted runner the Android SDK generates a **new random debug keystore** on first build, so every CI run signs with a different key.
- **Impact:** (1) v2.0.0 **cannot install over v1.2.0** — Android rejects it with a signature mismatch ("App not installed"); users must uninstall first, losing on-device books and history. (2) Future CI builds cannot install over v2.0.0 either, so the in-app updater's core promise is broken for every release until this is fixed. (3) Security: with no stable signing identity, Android's same-signer check cannot bind an update to the publisher, which compounds M3.
- **Fix (before launch):** generate one keystore now (debug or, preferably, the real release keystore per `docs/release-signing.md`), store the base64 keystore + store/key passwords as GitHub repo secrets, add a workflow step that restores it and signs the APK, and add a CI check that the produced APK's signature fingerprint matches the expected one. Until then, tell users the v2 install requires uninstalling v1 first — do not let the in-app updater promise a seamless update it cannot deliver.

---

## 8. CI workflow

File: `.github/workflows/build-apk.yml` (147 lines). Triggers: `release published` + tag push `v*`. Permissions: `contents: write` only — the minimum needed for `gh release upload`. Actions are pinned to major versions (`checkout@v4`, `setup-java@v4`, `flutter-action@v2`, `upload-artifact@v4`).

- **Secrets handling — clean:** `SUPABASE_URL` / `SUPABASE_ANON_KEY` appear only as `${{ secrets.… }}` interpolations in the build command; they are never echoed, printed, or written to a file by any step. GitHub automatically masks secret values in logs, and neither `flutter build` nor Gradle logs `--dart-define` values. `GITHUB_TOKEN` is passed via `env:` to `gh release upload` only. **No secret-leakage finding.**
- **Note:** the build step passes secrets as CLI arguments, so they exist briefly in the runner's process table — negligible on an ephemeral single-tenant runner.

### Finding L6 — LOW — Actions pinned to major versions, not SHAs

- **Evidence:** `actions/checkout@v4`, `actions/setup-java@v4`, `subosito/flutter-action@v2`, `actions/upload-artifact@v4`.
- **Fix:** pin each action to its full commit SHA (supply-chain hardening). Low priority for launch.

---

## 9. Verified clean (no findings)

- **RLS on, everywhere.** All six tables have RLS enabled; no `USING (true)` except the deliberate, documented waitlist anon INSERT; no policy trusts a client-supplied `user_id`.
- **`activation_codes` is client-inaccessible by design** (zero policies) — the right call; the only problem is the panel's reads against it (H2).
- **Edge Function auth is uniformly correct.** All four functions verify the JWT with `getUser()` first; `issue-code` and `send-notification` re-check `is_admin` server-side; `delete-account` can only delete the caller; `redeem-code` enforces single-use/expiry/binding server-side (modulo the M1 race).
- **No live secrets in the repo.** No `sbp_`/`sk-`/private-key material; `service_role` appears only in comments/docs/tests; `admin/config.js` holds only the publishable anon key and is absent from the remote tree; `google-services.json` holds no service-account or server secret; `supabase_config.dart` is `--dart-define`-only.
- **Auth is SDK-native.** No hand-rolled sessions, no password/token logging, no plaintext credential storage; Gemini key in `flutter_secure_storage` only.
- **Android surface is minimal.** Four justified permissions; cleartext off; backups off; no camera/location/contacts/SMS.
- **Admin panel gate + output encoding are correct.** `is_admin` checked before any data loads; no signup form; `esc()` used consistently.
- **CI secrets do not leak.** No echo of secrets; minimal `contents: write` permission.

### Could not be verified from the files (needs a live check, not a code fix)

- That the five migrations on the **live** Supabase project match the files exactly (they were verified in the Table Editor on 19 Nov 2026, but RLS could have been altered from the Dashboard since).
- Supabase Auth dashboard settings (email-confirmation required? JWT expiry? password rules?).
- Whether the Firebase Android API key in `google-services.json` has GCP-side restrictions (Android package name / SHA-1).
- That the Edge Function secrets (`SUPABASE_SERVICE_ROLE_KEY`, `RESEND_API_KEY`, `FIREBASE_SERVICE_ACCOUNT`) are actually set in the Supabase dashboard.
- Live behaviour of the panel's `activation_codes` reads (inferred from RLS semantics: filtered selects return empty, not an error).

---

## 10. Fix list (in order)

| # | Severity | Fix | Where |
|---|---|---|---|
| C1 | Critical | Block client writes to `plan` / `premium_until` / `is_admin` (trigger or RPC; add regression test) | Migration 006, `002_rls.sql` |
| H1 | High | Pin one signing keystore in CI; verify APK signature fingerprint in the workflow | `.github/workflows/build-apk.yml`, repo secrets |
| H2 | High | Add admin-only `SELECT` policy on `activation_codes` | Migration 006 |
| M1 | Medium | Make the redeem-code claim atomic (check affected rows / RPC) | `supabase/functions/redeem-code/index.ts` |
| M2 | Medium | Constrain `payments` insert (`status='pending'`, null review fields) + `CHECK` on `plan` | Migration 006, `002_rls.sql` |
| M3 | Medium | Publish + verify SHA-256 of the APK before install; drop any-`.apk` fallback | `app_update_service.dart`, workflow |
| M4 | Medium | Rate-limit / CAPTCHA the waitlist insert (Edge Function) | `docs/index.html`, new function |
| M5 | Medium | Add `access-requests-seen.txt` to `.gitignore` (and consider moving it out of the repo) | `.gitignore` |
| L1 | Low | Add `SET search_path` to `is_admin()` and `handle_new_user()` | `002_rls.sql`, `003_triggers.sql` |
| L3 | Low | Delete dead `manual_activation.dart` + generator from the v2 tree | `lib/services/`, `tools/` |
| L4 | Low | Fix `security_test.dart` to assert absence of `CHANGE_ME_IN_RELEASE_BUILD` | `test/security_test.dart` |
| L5 | Low | Clear FCM tokens only on `UNREGISTERED`/`NOT_FOUND` | `supabase/functions/send-notification/index.ts` |
| L2 | Low | Add per-IP/per-user attempt limiting to `redeem-code` | Edge Function |
| L6 | Low | Pin CI actions to commit SHAs | `.github/workflows/build-apk.yml` |
| L7 | Low | Prefer PKCE-only deep links once the email template is confirmed | `lib/main.dart`, Supabase Auth settings |
| L8 | Low | Accepted residual — document rooted-device cache tampering as known | Docs only |

**Re-audit after the fix:** re-run the C1 exploit attempt as a non-admin (must fail), confirm the admin panel's codes table populates and `code_id` links on approval, and confirm the CI APK installs over the previous build before shipping.
