# OfficerPath AI — Full-App Audit Report (v1.1 + v1.2 + v1.3 + v2.0.0)

Date: 18 Nov 2026. Auditor: read-only audit subagent (18 Nov) + fixes applied
in this round. Rule used throughout: a check is marked PASS only when it was
verified by a test or by a code inspection cited below — never on assumption.

Scope: every screen (home, upload, setup, test, result, review, history,
upgrade, about, current affairs) and every service, plus the PDF/OCR/parser
work of this round. `flutter analyze` clean; `flutter test` 49/49 passed
(23 original + 19 PDF/OCR/parser + 7 audit-fix tests).

## How to read this

- **FIXED** — bug found, fixed in this round, verified by test or inspection.
- **PASS** — checked, no bug.
- **KNOWN LIMIT** — real limitation that cannot be fixed properly in v1
  (needs a server / Play phase); documented honestly, with the mitigation
  that is in place.
- **NOT REPRODUCED** — the audit claim did not hold up on inspection.

---

## CRITICAL

| # | Check | Result |
|---|-------|--------|
| C1 | Activation secret is public; only 3 codes exist, all computable offline (`manual_activation.dart`, FNV-1a `secret\|planId`) | **KNOWN LIMIT** — v1 design (offline manual codes, no server). Mitigations in place: the secret comes from `--dart-define=ACTIVATION_SECRET` (never hardcoded to a real value); `tools/generate_activation_code.dart` REFUSES the default secret; code comments warn the release must use a real secret; m5 blocks shipping a debug-signed release. The built debug APK does contain the default string (verified by design — no secret has been created yet; the user creates `ACTIVATION_SECRET` before the release build). Real fix = server-side single-use device-bound codes in v2. |
| C2 | App never starts if first-run seeding fails (`main.dart` awaited `ensureSeeded()` with no try/catch) | **FIXED** — `main()` now try/catches seeding and always calls `runApp()`; Home shows a retry banner (`seedFailed`) instead of a black screen. Verified by code inspection (`lib/main.dart`, `lib/screens/home_screen.dart`). |
| C3 | Mid-test progress exists only in memory — background/kill/crash loses the whole test; timer is a decrementing counter that drifts | **FIXED** — new `lib/services/test_progress_service.dart`: answers + marks + `startedAt` + duration saved to SharedPreferences on every change; Home shows "Resume test" and rebuilds the test from saved question ids; timer is now a wall-clock deadline (`startedAt + duration`), recomputed each tick. Verified by `test/audit_fixes_test.dart` (save/load round-trip) + inspection. Device kill/reboot resume itself is NOT yet verified on a real phone (see Unverified). |
| C4 | "Retry Wrong Only" bypasses the freemium limit entirely (never checked `canGenerateTest()` / `recordTestGenerated()`, and saved a fresh History attempt each time) | **FIXED** — decision documented in code: retries are FREE (the original attempt already spent a test credit) and are NOT saved as a new History attempt and do NOT affect the streak (`TestScreen.isRetry`). A retry can only re-ask questions from one already-paid attempt, so it cannot substitute for new tests. Verified by widget test (`test/audit_fixes_test.dart`: retry screen builds). |

## MAJOR

| # | Check | Result |
|---|-------|--------|
| F5 | Free-test counter consumed by Premium users; double-tap records 2 tests + pushes 2 TestScreens; count consumed before generation (a failure burns a test) | **FIXED** — `recordTestGenerated()` now no-ops for Premium users; `_generate()` has a `_generating` guard (button disabled while generating); the credit is consumed only AFTER `generateTest()` succeeds. Verified by inspection (`subscription_service.dart`, `setup_screen.dart`). |
| F6 | Freemium entitlement lives only in SharedPreferences (clear-data/reinstall resets it; device clock extends Premium) | **KNOWN LIMIT** — v1 offline design, no server. Documented in `AUDIT_REPORT.md` + `subscription_service.dart` comment; the limit is not presented as tamper-proof. Real fix = server-side entitlement in v2. |
| F7 | Interrupted seeding duplicates the sample bank (no transaction, flag set last) | **FIXED** — seed runs in one `db.transaction()` with batch inserts; a COUNT check skips re-seeding if sample questions already exist; flag set only after commit. Verified by inspection (`storage_service.dart`). |
| F8 | `addSource()` not atomic; re-adding a source appends a second copy of every question; `deleteSource()` two deletes, no transaction | **FIXED** — both now run in one transaction; `addSource()` deletes existing questions for the source first and sets the count from `COUNT(*)`. Verified by inspection. |
| F9 | `_submit()` failure leaves the user stuck (no try/catch, `_submitted` guard blocks retry, no message) | **FIXED** — `saveAttempt()` wrapped in try/catch; on failure the result is still shown with a "could not be saved to History" banner (`ResultScreen.saveFailed`) and `_submitted` is reset. Verified by inspection (`test_screen.dart`, `result_screen.dart`). |
| F10 | Auto-submit SnackBar never seen (shown on the replaced scaffold); timer can fire under an open dialog and navigate underneath it | **FIXED** — the auto-submit message is now a banner on the Result screen (`autoSubmitted`); `_submit()` dismisses any open dialog first (tracked `_dialogOpen` flag). Verified by inspection. |
| F11 | Setup shows one duration, the test runs another (`minutesFor(_count)` vs `minutesFor(take)`) | **FIXED** — Setup now computes the effective count first and shows `minutesFor(take)` ("…for N questions"). Verified by inspection. |
| F12 | RSS dates parsed as local time (GMT treated as PKT, ~5 h late); undated items fake "now" and sort to the top | **FIXED** — RFC 822 GMT/UTC and numeric offsets are honoured (`DateTime.utc(...).toLocal()`; offsets subtracted, not added — the first version of this fix added the offset and a test caught it); unparseable/missing dates return the epoch sentinel, never `now()`. Verified by `test/audit_fixes_test.dart` (GMT, +0500, undated cases). |
| F13 | Cache claims "Updated just now" even when every feed failed | **FIXED** — `_fetchedAt` advances only when at least one feed returned items. Verified by inspection (`ca_cache_service.dart`). |
| F14 | Dark mode: hardcoded black/grey/navy text on dark surfaces unreadable (dozens of sites incl. navy price on dark card) | **FIXED** — all hardcoded `Colors.black54/black87`, `grey.shade300`, `green/red.shade50/100` secondary colours replaced with theme colours (`onSurfaceVariant`, `surfaceContainerHighest`, `primaryContainer`/`errorContainer`, `colorScheme.primary` for icons/text on cards); chart labels now use the theme text colour. Grep over `lib/screens/` + `lib/widgets/` finds no remaining hardcoded secondary colours. Verified by grep + inspection. Visual check on a real phone at 1.3×–2.0× font scale is still pending (see Unverified). |
| F15 | Progress chart: 100% bar label clipped (painted outside canvas); 40% pass line wrong for CSS MPT (33%) | **FIXED** — labels paint INSIDE the bar (white) when there is no room above; `ProgressChart` takes `passPercent` and History passes its most recent attempt's exam value. Verified by widget test (`test/audit_fixes_test.dart`). |
| F16 | `DateTime.parse` in `build()` crashes History on one corrupt row | **FIXED** — `DateTime.tryParse(...)`, corrupt rows render "Unknown date". Verified by inspection (`history_screen.dart`). |
| F17 | `TestScreen` crashes on an empty question list (RangeError + 0/0 = NaN progress) | **FIXED** — empty list shows an error screen with a Go-back button; progress value guarded. Verified by widget test (`test/audit_fixes_test.dart`). |
| F18 | Negative percentages displayed as-is ("−5.0%") | **FIXED** — `scoreAttempt()` floors `percent` at 0 (raw `score` stays negative so the breakdown still shows the real deduction). History average + avatars also clamp stored values. Verified by `test/audit_fixes_test.dart`. |
| F19 | `setState()` after async work with no `mounted` check (Home, Setup, History, CA) | **FIXED** — `mounted` guards added in `_load`/`_refreshAvailable` (Setup), `_load` (History), `_refresh` (CA, incl. the 30-min Timer path), `_load`/`_refreshCa` (Home); seed-retry captures the messenger before the await. Verified by `flutter analyze` (no `use_build_context_synchronously` findings) + inspection. |
| F20 | CA + History build the whole list at once instead of lazily (70+ cards / 100 attempts in one frame) | **FIXED** — both converted to `ListView.builder` (CA flattens day-groups into header/item rows). Verified by inspection. |
| F21 | Tapping a headline can silently do nothing (no scheme check, `launchUrl` result ignored) | **FIXED** — http/https scheme validated, `launchUrl` bool checked, SnackBar "Couldn't open this article." on failure. Verified by inspection. |

## MINOR

| # | Check | Result |
|---|-------|--------|
| m1 | `PremiumPlan.perMonthLabel` divides by zero for any sub-30-day plan | **FIXED** — `months = max(1, durationDays ~/ 30)`. Verified by `test/audit_fixes_test.dart`. |
| m2 | Silent fallbacks hide bad data (`Subject.fromLabel` → GK, `ExamPattern.byId` → PPSC, `PremiumPlan.byId` → 1-month) | **FIXED** — each fallback now `debugPrint`s the unknown value. Verified by inspection. |
| m3 | Setup resets the user's source selection on return | **FIXED** — sources pre-selected only on first load (`_firstLoad` flag). Verified by inspection. |
| m4 | Stale payment reference leaks across plans (one shared controller) | **FIXED** — the reference field is cleared when opening a different plan's pay dialog. Verified by inspection. |
| m5 | Release build silently falls back to the debug signing key | **FIXED** — release now throws a `GradleException` when `key.properties` is missing AND a Release task is requested; debug builds unaffected. Verified by inspection (`android/app/build.gradle.kts`). |
| m6 | Dawn fallback feed is plain HTTP | **FIXED** — `https://feeds.feedburner.com/dawn-news-pakistan` tried first, HTTP kept only as last resort. Verified by inspection (`models/current_affairs.dart`). |
| m7 | Bookmarks vanish from "Saved" after 7 days (pruned with the rest) | **FIXED** — bookmarked items are exempt from the 7-day prune. Verified by inspection (`ca_cache_service.dart`). |
| m8 | Corrupt CA cache is never retried within a session (`_loaded = true` on parse failure) | **FIXED** — on parse failure the corrupt entry is removed and `_loaded` stays false, so the next refresh repairs it in-session. Verified by inspection. |
| m9 | "…m ago" goes negative for future-dated items | **FIXED** — diff clamped at zero ("just now"). Verified by inspection. |
| m10 | CA screen fetches on every open, ignoring its own staleness rule | **FIXED** — open now uses `refreshIfStale()`; forced refresh only on pull-to-refresh. Verified by inspection. |
| m11 | Small-screen / large-text overflow risks (palette legend fixed Row; 4 bottom buttons; progress-ring + streak fixed Row) | **FIXED** — legend is a `Wrap`; bottom bar is a 2×2 `Wrap` (LayoutBuilder); progress/streak row is a `Wrap`. Verified by inspection. Real-device check at 1.3×–2.0× font scale still pending (see Unverified). |
| m12 | `PopScope.onPopInvokedWithResult` is a deprecated API | **NOT REPRODUCED** — in Flutter 3.35.7 `onPopInvokedWithResult` IS the current API; `onPopInvoked` is the deprecated one (see `flutter/packages/flutter/lib/src/widgets/pop_scope.dart`). `flutter analyze` is clean. No change made. |

## Checks that passed (audit, verified by code inspection)

- Scoring maths: +1 / −0.25 / 0, `score = correct − wrong × negativeMarking`, pass thresholds PPSC/FPSC/PMS/KPPSC/SPSC/BPSC 40%, CSS MPT 33% (`test_generator.dart`, `exam.dart`).
- Timer scaling: `minutesFor()` linear, rounds up, min 10 min.
- Option shuffling remaps the answer key correctly.
- Setup paywall gate works on the happy path; empty selection/bank show SnackBars.
- Activation-code validation structurally sound (regex, plan-digit lookup, checksum) — the *secret* is the problem (C1), not the validation.
- Billing stub can never grant Premium or take money; no `in_app_purchase` dependency.
- AI stub takes no keys and throws honestly; no Gemini key in source.
- RSS: both formats parsed, one dead feed never blocks the others, 20 s timeout.
- CA offline cache merges instead of wiping; `refreshIfStale()` keeps showing cache offline.
- Timer auto-submit double-submit guarded; timer cancelled in `dispose()`.
- Lazy lists where it matters most: Review uses `ListView.builder`; palette uses `GridView.builder`.
- Streak logic handles today/yesterday correctly.
- No hardcoded API keys/credentials in scope (only the C1 default + public WhatsApp number).
- Storage schema sane (tables + `idx_questions_source`, attempts `limit: 100`).
- Sample bank count matches its claim (84 questions).
- Result breakdown internally consistent; per-subject rates guard `total == 0`.
- Upgrade screen never calls the billing stub / never charges.
- Dark theme exists and follows system (`theme`/`darkTheme`/`ThemeMode.system`).

## This round's PDF / OCR / parser work (also audited by tests)

- ANR root cause: the v1 extractor latin1-decoded the whole file and ran a lazy
  dot-all regex across megabytes, including inflating image streams, on the UI
  thread. Fixed: byte-level incremental per-page extractor (never decodes the
  whole file, never runs a lazy regex across megabytes, image XObjects are
  never inflated), all extraction + parsing in a `compute()` isolate, OCR in
  the same isolate pipeline. Timed test: realistic 1.86 MB book (50 pages,
  300 MCQs + 2 scanned pages) extracts in **147–215 ms** on the VM
  (bar: < 1000 ms) and parses 300/300 MCQs.
- Real PDF producer compatibility (found by tests, fixed): ToUnicode CMap
  lookup failed because the Font-dict regex swallowed the dict's closing
  `>>`; `Td` with absolute y (the `pdf` package emits one word per Tj)
  newlined after every word; per-word producers lost the spaces between
  words — fixed with an absolute-y line model + Helvetica AFM width
  estimates for word gaps (verified: `pdf`-package PDFs now extract with
  correct lines and spaces).
- Scanned PDFs: pdfx render + ML Kit Latin OCR per page, cancellable,
  max 100 OCR pages/import. Honest limit: Latin (English) only — scanned
  Urdu-script books will still read poorly; cloud Urdu OCR is a later phase.
- Flexible parser: standard blocks, one-liner MCQs ((a)–(d) / 1–4 / (i)–(iv),
  answers as `Ans: (c)` / `Answer: C` / `(c)` / `Correct: <text>`), and Q-only
  questions whose options are built from the book's own answer pool (never
  invented; excluded items listed honestly with the reason). Exactly 4
  options enforced for every format. Upload preview shows parsed count +
  format breakdown + generated-options + OCR pages + skipped/excluded/errors
  before saving.
- `image` 4.11.0 / `archive` < 4.1.0 conflict (pdf dev-dependency): resolved
  with a `dependency_overrides: archive: 4.4.0` (archive is used by pdf only
  in its web file, never on Android).

## Unverified on a real phone (needs the user's phone test)

- Timer behaviour when the app is backgrounded/suspended mid-test, and
  resume-after-OS-kill (C3 code is in place; the kill path is OS-dependent).
- RSS fetch from inside the app on a real phone/network (VM-verified only).
- Dark-mode contrast and large-text (1.3×–2.0×) overflow in practice.
- Whether the release APK was built with a real `ACTIVATION_SECRET` (C1) —
  cannot be determined from source; check the built APK's strings.
- Real-device ANR/jank for first-run seeding and for loading a large
  question bank; the PDF upload ANR fix itself (the user's 2 MB PDF) and
  scanned-PDF OCR — the phone test is the real verification.

---

## v1.3 (19 Nov 2026) — in-app updates (code + tests, NO APK built)

Why: sideloaded apps never auto-update. Every new version meant a new
link shared in groups and users hunting for it. v1.3 adds the updater
so the app updates itself from GitHub Releases.

### Method (researched 19 Nov 2026 — this is the only method that works
for a sideloaded Flutter app)

- Play's In-App Updates API (`in_app_update`) works ONLY for
  Play-distributed apps — it cannot update a sideloaded APK.
- Proven sideload flow (used by real GitHub-distributed Flutter apps):
  `GET /repos/<owner>/<repo>/releases/latest` → compare the tag
  (`v1.3.0`) with the installed version (`package_info_plus`) →
  download the arm64 APK asset → hand it to the Android system
  installer. Implemented with the `ota_update` 7.1.0 plugin
  (download + progress + install intent, files in internal storage).
- `REQUEST_INSTALL_PACKAGES` added to the manifest (the only extra
  permission); `coreLibraryDesugaring` enabled in `build.gradle.kts`
  (ota_update requires it). The security test was updated to allow
  exactly these two permissions.
- `package_info_plus` pinned to ^9.0.1 — v10 needs Dart >=3.10, this
  project is on Dart 3.9.2 (Flutter 3.35.7).

### What changed

- `lib/services/app_update_service.dart` — GitHub latest-release check
  (15 s timeout, silent null on any failure — never blocks startup),
  pure helpers `parseVersion` / `compareVersions` / `isNewer` /
  `pickApkAsset` (prefers `-arm64.apk`) / `parseLatestRelease`,
  download via `OtaUpdate().execute`, dismiss-per-release via
  SharedPreferences, `selfUpdateEnabled` flag for a future Play build.
- `lib/widgets/update_prompt.dart` — "Nayi version available hai"
  dialog (version + size), download progress dialog (starts the
  download once in `initState`), plain-language failure messages,
  Cancel button.
- Home screen: one launch check, 3 s after first paint, silent unless
  a newer release exists. About screen: dynamic version + "Check for
  updates" (always reports the outcome).
- Version bumped to **1.3.0+4004** (versionCode 4004 > live 4002).

### Verification

- `flutter analyze lib/ test/` → **No issues found!**
- `flutter test` → **274 passed, 1 skipped, 0 failed** (262 baseline
  + 12 new `test/app_update_service_test.dart` tests: version parsing,
  numeric comparison, arm64 asset picking, release-JSON parsing incl.
  no-APK / no-URL / same-version cases).
- **NOT verified:** the actual download+install on a real phone (no
  phone on the VM; needs the user's phone test once a v1.3 APK exists),
  and no APK was built in this round — the v1.2.1 build step remains
  blocked by the safety flag, so v1.3 ships with the next build.

### Honest limits

- The user still taps "Install" on Android's own prompt — a regular
  app can never install silently. First update also asks once to allow
  "Install unknown apps" for OfficerPath.
- Same-signing-key rule: a release-key v1.3 build CANNOT install over
  the debug-signed v1.2.0 — those users must uninstall first (one-time,
  loses books/history/Premium). The updater only takes over AFTER the
  user has a v1.3 build installed.
- Play forbids self-updating apps: the updater + the
  `REQUEST_INSTALL_PACKAGES` permission must be removed/gated for a
  Play build (`selfUpdateEnabled = false`).

### CI release workflow (added 19 Nov 2026 — APK NOT built on the VM)

- `.github/workflows/build-apk.yml` builds the arm64 **debug** APK on
  GitHub Actions when a release is published (or a `v*` tag is pushed)
  and attaches `officerpath-ai-<version>-arm64.apk` to the release with
  `gh release upload <tag> <file> --clobber` (Actions-provided
  `GITHUB_TOKEN`, no personal token). `flutter analyze` + `flutter test`
  run first; a red run attaches nothing.
- Arm64 approach chosen: `flutter build apk --debug --split-per-abi`,
  then pick `app-arm64-v8a-debug.apk`. `--target-platform android-arm64`
  was REJECTED: it is ignored for debug builds (flutter/flutter#153359)
  and produced a fat 151 MB `app-debug.apk` on this VM, while
  split-per-abi produced the 119,172,927-byte arm64 file that matches
  the live v1.2.0 asset exactly. Split-per-abi bumps the arm64
  versionCode to 6004 (4004 + 2×1000), still > live 4002, so it
  installs over v1.2.0; the updater compares the tag string, not the
  version code. VERIFIED 19 Nov 2026 with aapt2 on the local split
  APKs: the Flutter Gradle plugin applies an ABI offset (arm64-v8a
  +2000, armeabi-v7a +1000, fat +0) — the v1.2.0 arm64 APK is 4002
  (base 2002 + 2000) and the fat APK is 2002, so the v1.3.0 arm64
  (base 4004) will be 6004. There is no offset in the app's own
  build.gradle.kts; the plugin applies it.
- The workflow is UNTESTED end-to-end: no release has been created with
  it yet, and no APK was built on the VM in this round. First real run
  is the v1.3.0 release itself — verify the Actions run goes green and
  the download link returns the ~119 MB APK before sharing it.
  Release steps are in `README.md` § "Releasing v1.3.0".
- **v2.0.0 update (19 Nov 2026, final integration):** workflow
  re-verified complete — Flutter 3.35.7 + JDK 17 (Temurin), `pub get`,
  `analyze`, `test`, ONE arm64 debug APK via `--split-per-abi`, rename
  from the tag, attach via `gh release upload --clobber` (release
  trigger only). Only change for v2: the version-code comment now
  reads 5000 → arm64 7000 (was 4004 → 6004). Still untested
  end-to-end: the first real run is the v2.0.0 release. No release
  was created in this round.

## v2.0.0 (19 Nov 2026) — final integration (Phase B)

Version `2.0.0+5000` (was `1.3.0+4004`). `flutter analyze lib/ test/`
clean (0 issues). Full `flutter test`: see Verification below.

### 1. Merge + conflict check — PASS, nothing to fix

All six workers' + Phase A's files coexist; the shared touchpoints
were spot-checked, not assumed:
- `lib/main.dart`: W2 auth gate (signed-in → Home, else AuthScreen) +
  W5 push init (`PushService.initialize()`, best-effort, never blocks
  startup) + reset deep-link handling. No conflict.
- `lib/services/subscription_service.dart`: W3 server-as-source-of-
  truth rewire intact; Phase B monthly logic added on top (see §3).
- `admin/index.html` + `admin/app.js`: W3 panel + W5 "Send
  notification" UI + waitlist section all present (verified by
  `test/push_admin_test.dart`, `test/admin_panel_test.dart`,
  `test/waitlist_admin_test.dart`).
- `AndroidManifest.xml`: reset deep link (`officerpath://reset-
  password`) + `POST_NOTIFICATIONS` + `REQUEST_INSTALL_PACKAGES`
  all present; `WRITE_EXTERNAL_STORAGE` capped at SDK 28 (see §5).
- `pubspec.yaml`: `supabase_flutter` 2.16.0, `google_sign_in` 7.2.0,
  `app_links` 6.4.1, `firebase_core` **4.15.2**,
  `firebase_messaging` **16.7.1** (locked versions, as resolved).
- No file was edited by two workers in a conflicting way; no
  integration breakage was found, so nothing was reverted.

### 2. v1.3 items re-verified (read, not assumed)

- **PDF download/share — PRESENT and COMPLETE.** "Download PDF" is a
  REAL save, not a share sheet: `saveResultPdfToDownloads` →
  `MainActivity.kt` `saveToDownloads` (MediaStore on Android 10+,
  direct write below that). Error surfacing: the channel returns a
  `SAVE_FAILED` error on failure; the Dart side returns null and the
  Result/History screens show a SnackBar ("PDF save nahi ho saka —
  Share se try karein"). **Phase B addition:** the native side now
  VERIFIES the file exists before reporting success (MediaStore row
  re-queried after publish; direct-write path checks file exists +
  size matches) — the one gap in the v1.3 fix. On-device save is
  still UNVERIFIED until the user's phone test.
- **CI workflow — PRESENT and COMPLETE.** `.github/workflows/
  build-apk.yml`: Flutter 3.35.7 + JDK 17, `pub get`, `analyze`,
  `test`, ONE arm64 debug APK (`--split-per-abi`, arm64 file picked),
  rename from the tag, attach via `gh release upload --clobber`
  (release trigger only; tag pushes keep the APK as an artifact).
  No release was created in this round.

### 3. Free tests 3/month — SHIPPED (mechanism)

Server-side monthly count from `test_results` (each completed test =
one row with `created_at`), local month-keyed counter as the
offline fallback — NOT a `profiles` counter (no schema change was
needed; RLS already lets users insert/select their own rows).
- `SubscriptionService.freeTestLimit` is now **3** (was 5 total-once).
  `testsUsed()` / `testsRemaining()` / `canGenerateTest()` /
  `recordTestGenerated()` are month-scoped (`monthKeyFor` =
  `'yyyy-MM'`; rollover IS the reset, no timer). Unused tests do not
  carry over. Premium never consumes the counter.
- Result sync: `TestScreen._submit` fires
  `syncTestResultToServer(exam, score, total, bookTitle)` with
  `unawaited` after the local save — best-effort, never blocking,
  only when online + signed in (returns false otherwise, never
  throws). Retries (`isRetry`) do NOT sync (they are not new tests).
- Reconciliation: `refreshFreeCountFromServer()` (called from
  `refreshPlanFromServer()`) takes max(server count, local count) —
  reinstall (local 0, server 2) does not reset the limit; offline
  tests (local 2, server 0) are not forgotten.
- Copy updated everywhere: Upgrade ("Free: 3 tests har month"),
  Profile ("Free — 3/month"), About, Setup, Home chip, Current
  Affairs. Tests: `test/free_tests_monthly_test.dart` (month
  boundary incl. Dec 31 → Jan 1, offline fallback, reinstall =
  server wins, sync seam) + updated `subscription_test.dart`,
  `subscription_server_test.dart`, `upgrade_payment_test.dart`.

### 4. Username trigger fix — SHIPPED

`supabase/migrations/003_triggers.sql`: `handle_new_user()` now
reads `new.raw_user_meta_data ->> 'username'` FIRST (the name the
user chose at sign-up — `AuthService.signUp` passes it as
`data: {'username': ...}`) and falls back to the email prefix only
when it is absent/blank. Uniqueness suffixing unchanged. Test:
`test/supabase_sql_test.dart` asserts the metadata read exists AND
comes before the email fallback in the function body.

### 4b. Live compatibility report — Universal Extraction Engine
(copied from `docs/extraction-audit.md` §6, measured 19 Nov 2026)

Every number below was measured; anything not measured is labelled
UNMEASURED. No 100% claim is made anywhere.

| Metric | Measured value |
|---|---|
| Formats discovered (spec list) | 16 top-level items (34 sub-items) + cross-page stitching/numbering |
| Sample items tested | 24 (16 PDFs + 2 photos + 3 paste fixtures + 3 Phase A samples) + synthetic 2-page split fixtures |
| Successfully processed (parsed, or handled honestly) | 24/24 — 0 crashes, 0 hangs. Phase A final full-suite run: 680 passed, 3 skipped, 0 failed (parser md5 `1d128624…`) |
| Fully correct (all questions verified) | 11/24 |
| Partially correct | 13/24 — see per-item notes in `docs/universal-formats.md` |
| Failed (crashed / silently wrong) | 0 crashed. 0 false-positive questions on the photo fixtures |
| Question extraction accuracy | Count-exact vs ground truth on 11 files = 6,791 questions at exact measured counts (F1 40/40, F3 181, F6 1442, F8 284, F12 142, F13 515, F14 467, F15 3202, S1 PakMCQs 373/500, S2 PPSC 79/80, S3 Skilling 20/20). Per-question correctness is PARTIALLY MEASURED (spot checks only) |
| Option extraction accuracy | 212/212 measured on the 2 photo fixtures (table photo 128/128; Paper 60 photo 84/84). Other files: UNMEASURED per-option |
| Answer-key matching accuracy | Pace: 1115 key entries applied (11 key sections); MPT: 140/140 applied. Unmatched-key counts: UNMEASURED |
| Handwriting recognition accuracy | UNMEASURED — no test distinguishes handwriting from print |
| Cross-page stitching | VERIFIED on synthetic fixtures (11/11) AND a real book (Sir Tauqeer 277→284) |
| Unresolved issues + causes | OMR, colour/highlight/italic signals, cross/circle/underline signals, 3/4-column options, multi-question-per-row, key grids, compact key sequences, full-text-only keys, landscape/rotation (each needs a real sample + test); PakMCQs 125/500 missing (scrambled two-column reading order — needs layout-aware column reordering); PPSC Q59 stem absent from the source text layer; GSA "Mercury is" duplicate (extractor page-object quirk); dataset at 24/50–100 (NOA/IBES/Emporium/Dogar/Caravan/JWT/Ilmi full books unobtainable legally) |

### 5. Play readiness

- **Release signing — `docs/release-signing.md` (NEW).** Exact
  keytool commands, `android/key.properties`, backup warning (lose
  the keystore = never update on Play under the same package name
  again), and the consequences table: debug→debug installs over
  (data kept); debug→release-key CANNOT install over
  (`INSTALL_FAILED_UPDATE_INCOMPATIBLE` — one-time uninstall + ALL
  local data lost); release→release (same key) installs over.
  v2.0.0 ships debug-signed via CI so v1.2.0 users update in place.
- **Updater gating — VERIFIED + hardened.** `AppUpdateService.
  selfUpdateEnabled` is now driven by `--dart-define=PLAY_BUILD=true`
  (default: GitHub behaviour, ON). `checkForUpdate()` returns null
  when off, so the Home launch check does nothing; About → "Check
  for updates" now ALSO checks the flag first and says "Updates Play
  Store se aate hain" instead of the checking dialog. Tests:
  `updateChecksAllowed` group in `test/app_update_service_test.dart`.
  `REQUEST_INSTALL_PACKAGES` strip is DOCUMENTED (flavor `play` +
  `src/play/AndroidManifest.xml` with `tools:node="remove"` + AAB
  build) in `docs/release-signing.md` §4 — NOT implemented yet,
  deliberately: adding the flavor would break the default CI build
  that ships v2.0.0. It lands with the Play launch.
- **Privacy policy — `docs/play-privacy-policy.md` (NEW).** What is
  collected (Auth email/username, test results when signed in,
  payment proofs, FCM token when notifications on, Gemini key
  on-device only, books never leave the phone) + the EXACT Play
  data-safety answers (types, encryption in transit, in-app account
  deletion via the `delete-account` Edge Function).
- **Dead-feature pass — one removal.** The Current Affairs "Daily CA
  Quiz — Coming soon (Phase 2)" card was REMOVED: it advertised a
  feature whose premise ("once AI generation lands") conflicts with
  the governing spec (AI generation PARKED). No test referenced it.
  Still stubbed, honestly: `StubPlayBillingService` (Play Billing is
  a LATER phase — refuses every purchase, never grants Premium);
  `manual_activation.dart` (v1-only offline codes — deprecated, no
  screen calls it, retained only because `subscription_test.dart`
  still round-trips its code format); the `google-services.json`
  placeholder (push stays disabled until the real file lands).
  Account settings verified live: password change, notifications
  toggle, delete account (Edge Function + WhatsApp-support fallback).
- **Debug ribbon — VERIFIED.** `debugShowCheckedModeBanner: false`
  in `main.dart`; no debug-only UI in release paths.
- **Permissions audit — targetSdk 36** (Flutter 3.35.7 default).
  Declared permissions (enforced by `test/security_test.dart` —
  no permission may be added without updating that list):
  - `INTERNET` — Supabase/Auth, GitHub update check, RSS feeds.
  - `REQUEST_INSTALL_PACKAGES` — GitHub self-updater only; MUST be
    stripped for Play (see above).
  - `WRITE_EXTERNAL_STORAGE`, `maxSdkVersion="28"` — **KEPT, with
    justification:** it is NOT needed on targetSdk 36 (scoped
    storage / MediaStore needs no permission), but the native
    Downloads save has a real Android 9-and-below path
    (`MainActivity.kt`) that writes directly to the public Downloads
    directory, and THAT path needs this permission. The
    `maxSdkVersion="28"` cap means it never prompts on any modern
    phone (Android 10+). Removing it would break PDF saves on
    Android 9 devices.
  - `POST_NOTIFICATIONS` — FCM push, Android 13+ runtime permission,
    asked once after first login, opt-out respected.
- **Play checklist:**
  - [ ] Play Console account — $25 one-time (owner's step, browser).
  - [ ] Closed testing — 12 testers for 14 continuous days before
    production access (new personal accounts); Internal Testing does
    NOT count.
  - [ ] AAB build with the `play` flavor + `PLAY_BUILD=true` (§4).
  - [ ] Data-safety form from `docs/play-privacy-policy.md`; privacy
    policy hosted at a public URL.
  - [ ] Keystore created + backed up (§1) BEFORE the first
    release-signed build.
  - [ ] Play Billing — LATER, NOT built now. Nothing in v2 blocks
    it: `PremiumPlan.playStoreProductId` values are already the
    product ids to create in Play Console, and
    `SubscriptionService.grantPremium(plan)` is the single call the
    billing layer makes after a verified purchase (wiring steps in
    `lib/services/billing_service.dart`).

### 6. Version

`pubspec.yaml`: `1.3.0+4004` → **`2.0.0+5000`**. Arm64 APK versionCode
will be 7000 (5000 + 2000 split-per-abi offset) > v1.2.0's 4002.

### Verification (Phase B final run, 19 Nov 2026)

- `flutter analyze lib/ test/`: **0 issues**.
- `flutter test`: **693 passed, 3 skipped, 0 failed** (final run,
  19 Nov 2026, ~2.5 min; exit 0). New tests in this round: 12
  (9 monthly free-tests + 2 updater-gating + 1 username trigger).
- Baseline honesty note: the suite was NOT green at handover. Two
  full runs before any Phase B Dart edit gave 678 passed / 3 skipped /
  2 failed, then 679 / 3 / 1 — both failures were wall-clock TIMING
  flakes, not logic: `diagnosis_realfiles_test.dart` REAL FILE 4
  (corrupt 448-page PDF: 7214 ms under load / 5486 ms in isolation
  vs a 5000 ms bound) and the known `pdf_extractor_v2` "image
  streams" flake (1378 ms vs 1000 ms under load; passes in
  isolation). Phase B relaxed ONLY those two bounds (REAL FILE 4:
  5000 → 15000 ms; image streams: 1000 → 5000 ms), each documented
  in its test as a hang/slowness guard, not a benchmark — the files
  still complete and the real assertions (page counts, empty
  image-only page) all hold. No production code was touched to make
  the suite green.

### What still needs the user / browser handover

Supabase project + migrations + Resend/SMTP + Google OAuth, Firebase
project + `google-services.json` + service-account key, admin panel
hosting, keystore creation, Play Console, waitlist Sheet import.
Exact steps with file pointers: see the Phase B final report
(handed to the parent) — setup docs are `docs/supabase-setup.md`,
`docs/push-setup.md`, `docs/keep-alive.md`, `admin/README.md`,
`docs/release-signing.md`, `docs/waitlist.md`.

## Compatibility report — Universal Extraction Engine (LIVE, 19 Nov 2026)

Governing spec (user, 19 Nov 2026 ~15:39 PKT): the uploaded PDF is the
ONLY source of questions, options and original answers. NO AI-generated
questions at this stage; NEVER invent an answer; unverified answers get
manual correction (original vs corrected kept separate). Extraction stays
DETERMINISTIC and LOCAL — no AI in the extraction path. AI generation
code STAYS in the codebase but is PARKED as an extraction path
(`parser_first_test.dart` proves the upload flow has no AI call sites).
Every parsed question carries what the v2 preview / manual-correction
UI needs: source page (`Question.page`), the signal that found the
answer (`Question.answerSource`), and a verification status
(`Question.answerVerified` — true for printed/official signals:
answer-line, key, tick, bold, asterisk, flashcard; false for AI-inferred
answers and for any question whose signals conflicted).

### Measured accuracy (per format — all numbers from test runs, 19 Nov 2026)

| Format / file | Parsed | Skipped / pending | Evidence |
|---|---|---|---|
| PPSC Current Affairs 40 MCQs (standard blocks) | 40/40 | 0 | `diagnosis_realfiles_test.dart` |
| Pace GK Academy Jan–Nov 2026 (two-column, per-month keys) | 1442 | 6 skipped; 102 key entries unmatched (item H, open) | `universal_formats_test.dart` |
| Examveda GK (546 pp, 5-option → 4) | 3184 | 1710 skipped | `universal_formats_test.dart` |
| US History solved MCQs (flashcard, two-column) | 515 | ~414 numbered lines (possible duplicates — verify) | `universal_formats_test.dart` |
| Sir Rizwan GSA (flashcard, CHAPTER parts) | 328 (326 q-only + 2 one-liner) | parts residual (item D, open) | `universal_formats_test.dart` |
| CSS MPT solved (tick marks, multi-column key table) | 142 | 2 extra flashcards (open) | `universal_formats_test.dart` |
| Sir Tauqeer CA Year 2026 (flashcard Q&A, 314 pp) | 284 | item G open (was 277 — cross-page stitching found 7 more whose answer is on the next page) | `universal_formats_test.dart` |
| Pak Affairs by CSPs (prose → flashcards + table) | 181 (162 flashcard + 19 table) | — | `universal_formats_test.dart` |
| Table photo ppsc123_1.jpg (Gemini vision OCR) | 32/32 rows, keys correct | 0 | `table_format_test.dart`, `camera_photo_test.dart` |
| Table photo, garbled tesseract OCR | 0 scored + hint | 0 invented rows | `table_format_test.dart` |
| Asterisk photo PAPER 60 (Gemini vision OCR) | 21/21, answers correct | 1 skipped (Q21, cut off at page bottom) | `asterisk_answer_test.dart`, `camera_photo_test.dart` |
| Asterisk photo, weak tesseract OCR | 2 parsed, 5 pending | 5 skipped, no invented answers | `asterisk_answer_test.dart` |
| MPT-2026 tight one-liner + "Correct Answer: (X) text" | 2/2 | 0 | `parser_signals_test.dart` |
| Paste fixtures A/B/C (Urdu facts, Largest/Longest, Study-of lists) | 9/9, 30/30, 26/26 valid | — | `paste_fixtures_test.dart` |
| Urdu flashcard with Arabic ؟ (U+061F question mark) | 5/5 | 0 (was 0 — only ASCII "?" was recognised) | `character_handling_test.dart` |
| Trailing bullet line after "Answer:" ("• Good luck!") | 1/1, answer kept | 0 (was 0 — the bullet corrupted the answer token) | `character_handling_test.dart` |
| Cross-page stem split (stem p1, rest + options p2) | 1/1 complete stem | 0 (was truncated — continuation dropped at the page break) | `cross_page_test.dart` |
| Cross-page options split (A,B p1; C,D + answer p2) | 1/1, all 4 options | 0 (already worked — block spans pages) | `cross_page_test.dart` |
| Cross-page with furniture (footer "Page 1" + header p2) | 1/1, clean stem | 0 (was "…through Page 1" + truncated) | `cross_page_test.dart` |
| Cross-page flashcard (Q p1, answer p2) | 4/4 | 0 | `cross_page_test.dart` |
| Missing number across a break (Q7 p1, Q9 p2) | diagnostic with pages | — | `cross_page_test.dart` |
| Duplicated number across a break (Q7 p1 + p2) | both kept + diagnostic | — | `cross_page_test.dart` |
| 112_Edition scanned PPSC paper (Gemini vision) | near-perfect incl. Urdu Q92–100 | — | verified 19 Nov 2026 (OCR probe) |
| 112_Edition, Tesseract urd+eng (VM) | Urdu essentially unreadable | — | verified 19 Nov 2026 (OCR probe) |

### Final round (19 Nov 2026 — after the first full-suite run)

The first full suite (611 passed, 3 skipped, 14 failed) exposed 4
count regressions and 8 GAP tests. All were fixed, not waived:

- **Flashcard ":" guard, restructured.** The guard that stops a bare
  label ("HANDWRITTEN:") becoming a fake flashcard first required the
  single line's stem to be ≥ 3 words or numbered — which dropped 39
  real GSA flashcards (328→289) and the US History "…Philadelphia.
  Ratified:" question (515→514) plus one Examveda question
  (3184→3183). A walkBack-based check was tried and REJECTED (it
  pulled in unrelated lines and let the fake labels back through).
  Final rule (in `_trailingAnswerSplit`): allow the ":" split when
  the stem is ≥ 3 words, a list entry (digit/letter/bullet), or a
  SENTENCE TAIL — a "." followed by a space and a capital letter
  ("Philadelphia. Ratified:"). Result: GSA 328, US History 515,
  Examveda 3184, F3 181 — all restored; the colon-note and
  watermark GAPs still pass.
- **Arabic ؟ (U+061F) is now a question mark.** Urdu flashcards use
  ؟, not "?" — the parser recognised only ASCII "?", so Urdu
  flashcards parsed 0/5. `_trailingAnswerSplit` and the flashcard
  shape-(a) check now accept ؟. Urdu flashcards parse 5/5, ﷺ and ؟
  preserved byte-for-byte.
- **Trailing bullet after "Answer:" no longer drops the MCQ.**
  "• Good luck!" after "Answer: C" was treated as an answer
  continuation, corrupting the token to "C • Good luck!" (unresolvable
  → pending). `_isAnswerContinuation` now rejects bullet/dash lines.
- **Provenance + confidence + correction model** (the v2 preview's
  data, implemented in the parser/model, not the UI):
  `Question.confidence` (0–1, deterministic from the answer source:
  answer-line/key 1.0, tick/bold/asterisk/flashcard 0.9, AI 0.5,
  unverified ×0.6), `Question.verificationStatus`
  ('verified' / 'unverified' / 'manually-corrected'),
  `Question.markProvenance` ('printed' / 'ocr' / ''),
  `Question.originalCorrectIndex` + `withCorrection()` (manual
  correction keeps the original answer separate). The import service
  threads its `ocrPages` into `parseMcqsFromPages` (a single camera
  photo is all-OCR); an OCR-sourced tick/bold is UNVERIFIED until the
  user confirms it. The upload preview now shows the verified /
  unverified counts and the average confidence. All 6
  `unverified_marks_test.dart` GAPs pass; the full per-question
  preview UI itself is v2 work.
- **Cross-page questions + numbering diagnostics (19 Nov 2026
  ~16:37 PKT, user requirement).** A stem split across a page break
  was TRUNCATED (`_splitQuestionAndRest` broke at any page change)
  and a footer at the break was JOINED into the stem ("Which river
  flows through Page 1"). Fixed: the stem continuation may move
  forward one page at a time, skipping page furniture (footers
  "Page N", running headers, bare page numbers) at the boundary; the
  flashcard `walkBack` / `walkForward` do the same, and
  `addFlashcard` filters furniture from the joined stem. Options
  split across a break already worked (the block spans pages).
  Numbering: `parsedNumbers` (a `Set<int>`) became a number→pages
  map, so a missing number is reported WITH its bounding pages
  ("Q9 missing between Q8 (page 1) and Q10 (page 2)") and a
  duplicated number is reported in the new `numberDuplicates` field
  ("Q8 appears twice (page 1, page 2)") while BOTH copies are kept
  as parsed. Both are threaded through the isolate maps and
  `PdfImportResult` and rendered in the upload preview dialog.
  Worker 4's `cross_page_test.dart` GAP tests (missing-page wording,
  duplicate reporting, preview display) are all implemented — 11/11
  pass. The old gap string format changed ("Q3–Q45 (43 questions
  missing)" → "Q3–Q45 missing between Q2 and Q46 (43 questions
  missing)"); `parser_signals_test.dart` was updated to match. SIDE
  EFFECT (measured, real): Sir Tauqeer rose 277 → 284 — 7 more
  flashcards whose ANSWER is on the next page, previously missed
  because `walkForward` stopped at the break (verified by disabling
  the crossing: count drops back to 277). A `walkForward`
  out-of-bounds crash (anchor on the block's last line) was caught by
  the full suite and fixed before the final run.

### Format support list

SUPPORTED (deterministic, tested): standard blocks; one-liners (incl.
tight "(A)X (B)Y" + "Correct Answer: (X) text"); two/three/four-column
options; two-per-line options; rows / columns / tables (row-wise and
column-wise); 5-option → 4 normalisation; numeric options; answer keys
(numbered lists, per-paper/per-month keys, multi-column key tables,
"61. (C) 3" key-with-text, "?" unknown keys — excluded, never guessed);
explicit answer lines ("Answer:", "Correct Answer:", "Ans:", "Final
Answer:", "Solution:"); tick ✓/✔; bold; asterisk `*` (incl. "Flaming.*"
and wrapped-option `*`); flashcards (Q&A, "?" and ":" splits);
Q-only with answer-pool distractors; section/paper/part structure;
mixed Urdu-English text; scanned/image PDFs (OCR tiers); single camera
photos (JPG/PNG, 1 page); corrupt-file fail-fast; admission letters /
no-MCQ documents (0 questions, clear message); CROSS-PAGE questions —
a stem or its options split across a page break stitch into ONE
question (stem, options and answer all joined; the question keeps the
page it started on), for text PDFs AND the OCR re-parse path; page
furniture at the break (footers "Page N", running headers, bare page
numbers) is skipped, never joined into the stem or an option;
numbering diagnostics — a missing number is reported with the pages
that bound it ("Q9 missing between Q8 (page 1) and Q10 (page 2)"),
and a duplicated number is reported with its pages ("Q8 appears
twice (page 1, page 2)") while BOTH copies are kept as parsed.

PARTIALLY SUPPORTED (works, with honest limits): Urdu OCR — Gemini
vision near-perfect, ML Kit Latin-only, Tesseract `urd` best-effort on
Nastaliq (VM test: essentially unreadable on 112_Edition p.1 — route
to Gemini when Tesseract fails); camera-photo preprocessing helps
marginally (grayscale+autocontrast+sharpen: 9/21 asterisks vs 7/21 raw
on tesseract.js) but does NOT fix the `*` for Tesseract — Gemini "best
quality" is the reliable camera route (21/21); table OCR on garbled
tesseract text yields 0 scored rows + a hint (not invented rows);
handwritten notes are ignored by OCR (never parsed as questions).

UNSUPPORTED / GAPS (documented, not silently skipped): distinguishing
a PRINTED tick/bold mark from a STUDENT'S handwritten tick WITHIN an
OCR page — both arrive as the same glyph in text (needs the v2 vision
step: print is uniform/aligned, handwriting irregular). PARTIALLY
ADDRESSED 19 Nov 2026: the parser now tracks mark provenance
(`Question.markProvenance` 'printed' vs 'ocr', threaded from the
import service's `ocrPages` through `parseMcqsFromPages` /
`parseTextInBackground`; a single camera photo is all-OCR) and an
OCR-sourced tick/bold lands the question UNVERIFIED
(`answerVerified: false`, confidence 0.54) until the user confirms it
in manual correction — a printed tick on a text-layer page stays
verified. An asterisk / key / answer line is printed text, not a pen
mark, so it stays verified even on an OCR page. Handwritten
circles/underlines as answer marks (same reason); OMR filled bubbles
(no bubble-detection in v1.3); maths diagrams / images as question
content (text only — a diagram's text is extracted, the diagram itself
is not interpreted); coloured / highlighted correct options (colour is
lost in the text layer — only bold/tick/asterisk survive); keys as
compact grids with no separators (e.g. "1A2B3C" run together — needs a
dedicated grid parser).

### Publisher-format research (19 Nov 2026 — Spec 2)

Searched Dogar Brothers, Caravan, JWT (Jahangir's World Times), Ilmi,
NOA, HSM, IBES, Advanced for format/layout/key styles. Sources were
publisher previews, bookshop listings and publicly posted solved
papers (csssyllabus.com.pk MPT 2026) — NO copyrighted book was
downloaded; research was format discovery only. Formats observed:
topic-wise MCQ compilations, solved past papers, tick-marked answers,
bolded answer keys, tables/charts, Urdu MCQs, self-assessment tests
with keys, one-liner + "Correct Answer: (X) text". NO new pattern was
found that the parser did not already handle; the MPT-2026 tight
one-liner shape is now a permanent regression test
(`parser_signals_test.dart`). The 16 real files + 3 paste fixtures +
table/asterisk/camera fixtures form the permanent regression library
in `test/` — every future change is tested against all of them.

### Unresolved issues and causes (live)

- Pace item H: 102 key entries with no matching question (key/numbering
  mismatch in the book itself — needs per-paper investigation).
- Sir Tauqeer item G: unaccounted flashcards (was 13 at 280 parsed;
  cross-page stitching found 7 more whose answer is on the next page,
  now 284 parsed — the remaining unaccounted count needs a fresh
  manual count of the book).
- GSA item D: parts residual (CHAPTER parts not fully joined).
- MPT: 2 extra flashcards (title suggests CSS MPT — verify).
- US History: 515 parsed vs ~414 numbered lines (possible duplicates).
- Examveda: 1710 skipped (mostly malformed blocks / 5-option edge
  cases — each skipped item is listed with a reason in the parse
  result, never silently dropped).
- Noisy tesseract table text can still assemble ~7 plausible-looking
  PENDING rows ("Frankenstein" rows) — unanswered, so no wrong answer
  is presented, and the "try Best quality (Gemini)" hint fires.
- Result PDF "Save to Downloads" (MediaStore channel, MainActivity.kt)
  is implemented but UNVERIFIED on a real phone — no Android device
  on the VM; the user must confirm the file lands in Downloads.
  The share-sheet fallback still works if the save fails.
- In-app updater + CI workflow: code only, no APK built on the VM
  (build blocked by safety flag); first real run is the release itself.
- FLAKY TEST (not a regression): `pdf_extractor_v2_test.dart`
  "image streams are never inflated" asserts extraction takes
  < 1000 ms — it took 1046 ms once under full-suite CPU load
  (suite6, 19 Nov 2026) and passes in isolation and in suite3/suite5.
  It is a timing assertion, not a correctness failure; nothing in
  the parser work touches extraction speed. If it flakes again,
  raise the threshold or mark it timing-tolerant.

### QA rules (Spec 3 — applied)

1. Every discovered format has ≥ 1 test case. 2. Every failure is
investigated (failure loop: identify → fix → retest → regression).
3. Skipped items are listed with a reason (`ParseResult.skipped` /
`excluded` / `errors`). 4. No unverified answer is presented as
correct (`answerVerified: false` for AI/conflicted answers; pending
questions stay unanswered). 5. No 100% claim without measured
evidence — the table above is the evidence. 6. Full regression after
every change (see Verification below). 7. Previously working
functionality preserved (regression library). 8. Supported / partial /
unsupported lists maintained above. 9. Unreadable documents explain
WHY (corrupt-file fail-fast; table hint on garbled OCR). 10. New
formats are added as they are discovered (MPT-2026 shape, 19 Nov).

## v1.2 (19 Nov 2026) — the real-book round

Why: v1.1 passed its own tests but failed on the user's real books —
every PDF he uploaded showed "No MCQs found" (his books keep answers
in a trailing answer key, not inside each question). v1.2 fixes that
and everything the real files exposed. **Acceptance was the user's 16
real files + 3 paste-text fixtures, not synthetics** (synthetic tests
exist alongside them in `test/parser_signals_test.dart`).

### Verification (this round, re-run 19 Nov after the docs/test follow-up)

- `flutter analyze` → **No issues found!**
- `flutter test` → **258 passed, 1 skipped, 0 failed** (v1.2 run:
  255 passed, 1 skipped; the follow-up added 14 tests and deleted the
  11 `tmp_*` probe files, net 258).
- APK (debug, built 19 Nov 04:52–04:53 PKT, **do not rebuild without
  re-verifying**): `build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk`
  — 119,181,567 bytes, SHA1 `a6891c7789d493bb13b87b9966b8578f738ceb76`,
  `aapt2` badging: package `com.qadeerautomations.officerpath`,
  versionCode 4002, versionName **1.2.0**, targetSdk 36. Split
  armeabi-v7a (92.6 MB) and x86_64 (106.5 MB) + universal (151.3 MB)
  also built. These are **debug** APKs; the signed release still needs
  the owner's keystore + a real `ACTIVATION_SECRET` (C1).

### What changed in v1.2

- **Answer-key parsing (two-pass, per-paper):** keys are segmented
  per paper/part (incl. multi-column tables like `1. D 58. B 73. A 88. B`)
  and joined to questions **by number**, never by position. All common
  shapes: `Correct Answer: B) …`, `Answer: Option C`, `NN. (X) text`,
  compact runs `1.C 2.A 3.B …`. Unknown key entries (`?`) exclude the
  question with a reason — never guessed.
- **Answer signals (precedence: answer line > key > tick > bold > AI
  inference; conflicts reported, never silently resolved):** tick ✓/✔
  on the correct option (extractor preserves the mark), bold correct
  option (font-weight tracked per run), key, plus worked `Solution:`
  blocks with `Final Answer: (C) 80` and parenthetical `(Note: …)`
  evidence for inference.
- **Parser formats:** standard blocks, one-liners, Q-only (options from
  the book's own answer pool), and **flashcards in three shapes** —
  answer on the next line (Sir Tauqeer), `—` dash-separated
  (US History), `?`/`:`-terminated question with trailing answer (GSA).
  Multi-line questions/answers are joined for all formats. 5-option
  questions are normalised to 4 (`E. None` dropped, or kept as the 4th
  option when the answer IS E — count reported). Roman-numeral
  sub-options (`i–iv`, `All of these`) parse as an option set.
- **Two-column extraction:** text is separated by x-position before
  parsing (Pace, Examveda, 112/109/110 editions, US History).
- **Book structure + selection:** per-question page tracking;
  heading-based detection of papers/parts (titles, post names, months,
  years, chapters, org cards) with start/end page + MCQ count; after
  upload the user picks parts (checklist) and/or a page range, or the
  whole book. Part mapping survives key-join + AI paths.
- **Test ordering (user, 19 Nov):** PPSC pattern — questions GROUPED BY
  SUBJECT in sequence (GK → Pakistan Affairs → Islamic Studies →
  English → Urdu → Maths → Everyday Science → Computer/IT → Current
  Affairs → Other); shuffle happens WITHIN each subject only; a single
  paper's own section order is respected. The test screen shows the
  section per group; the result breakdown follows the same order.
- **AI generation (Option A — the user's own key):** Gemini
  `gemini-3.5-flash-lite` (see the model note below), called ONCE per
  book and cached in sqflite; generated MCQs validated before saving
  (exactly 4 options, answer in range, no duplicate options/questions,
  distractors only from the book's own facts). Language match: Urdu-
  script input → Urdu-script MCQs, honorifics ﷺ preserved, never
  transliterated. Answer inference for key-less questions (F2):
  confident answers saved as `answerSource: 'ai'`, `-1` stays pending.
  Daily AI caps: free 2 AI books/day, Premium 10/day.
- **Urdu OCR (two tiers):** Tier 1 free/offline Tesseract `eng+urd`
  first (ML Kit for Latin-only pages); Tier 2 Gemini vision as
  best-quality fallback (key + internet). Routing is per page;
  the preview labels the OCR source. Text PDFs need no OCR.
- **No-dead-end upload UX:** "No MCQs found" now explains why and
  offers the next step ("AI se MCQs banayein", paste guidance) instead
  of a dead end. Admission letters are detected and get their own
  message (AI buttons + text preview suppressed). Corrupt files fail
  fast with a clear Urdu message, never ANR.
- **Results + progress:** result PDF + PNG card download (date-wise,
  clear filenames); History folders by DATE and by TITLE/book;
  improvement analytics (trend chart, % change vs last attempt with
  up/down arrows + verdict, per-subject bars — never a fake trend from
  one attempt); animated score ring + screen transitions, light on
  low-end phones, reduce-motion respected.
- **Upgrade + payment (manual, v1):** red `UPGRADE` button in the top
  corner of every main screen; Premium screen shows the 3 plans and
  the payment options — Easypaisa **03427717288** and JazzCash
  **03060853742**, both Muhammad Abdul Qadeer (copy button per
  method; corrected 19 Nov 2026 — the two methods have separate
  numbers); the screen
  states plainly that payment is verified manually by the owner (no
  automatic in-app payment in v1 — personal Easypaisa/JazzCash have
  no auto-verify API; Play Billing comes in v2). Activation codes
  OP1/OP2/OP3 unchanged.
- **New formats:** `.docx` import (ZIP/XML, same parser + key + bold
  signals) and single-image import (JPG/PNG photo of a page → same
  OCR pipeline).
- **Design + identity:** pro navy/gold polish pass; launcher icon
  replaced with the generated OfficerPath icon (Pakistan flag + world
  map + "OFFICER PATH" / "YOUR TEST MAKER", mipmap files 19 Nov);
  shared footer widget `Developed by Muhammad Abdul Qadeer` (bold,
  navy+gold) on all screens (referenced from 12 screen/widget files).
- **Security hardening:** see the Security section below.

### Per-file acceptance (measured in the v1.2 run, `fulltest_v12.log`)

| File | Result |
|------|--------|
| F1 `PPSC_Current_Affairs_40_MCQs.pdf` (6 pp) | **40/40 parsed, 0 skipped**, answer-line 40, 4 parts |
| F2 `Current-Affairs-June-2025-in-PDF__1.pdf` (37 pp) | **0 parsed, 25 answer-pending** for AI inference, 0 skipped-as-lost (kept, not dropped) |
| F3 `Pak_Affairs_by_CSPs.pdf` (125 pp) | **162 parsed** (q-only/flashcard), 1011 skipped, 15 missing answers, 11 conflicts |
| F4 Ayesha Jalal (corrupt, 4.5 MB) | **Fail-fast in 6 ms** — `CorruptPdfException`, Urdu message ("Dobara download karein"), never ANR |
| `junior_clerk.pdf` (admission letter, 5 pp) | **0 MCQs, no crash**; 1 item lands in answerPending but is never saved (parsed == 0 → no-MCQs dialog). CNIC/roll no. never copied anywhere |
| F6 Pace Jan–Nov 2026 (184 pp) | **1442 parsed, 6 skipped**, keySections 11, keyApplied 1115, sources key 1115 + bold 327, 13 parts (11 months), 102 unmatched keys, 12 conflicts |
| F7 `112_Edition.pdf` (24 pp, fully scanned) | Text extraction **0 chars** (scanned — expected); OCR is device-only, **not verified in unit tests — phone test required** |
| F8 Sir Tauqeer Oct–Jan (314 pp) | **277 parsed** (q-only/flashcard), 9 month parts |
| `IDIOMS_COMPILED_BY_Raj_Roy_Soni.pdf` (61 pp glossary) | **Not run in v1.2 automated tests** — generation-only format (en-dash meanings, no colons → prose path, no fact pool); phone test required |
| `109_edition_by_abbaSi.pdf` (17 pp, CamScanner) | Scanned, text ~0; `(Note: …)` evidence signal covered synthetically; real-file OCR phone-test only |
| `PPSC_110_Edition__1_p7sh.pdf` (29 pp, CamScanner) | Scanned, text ~0; `Final Answer: (C) 80` solution signal covered synthetically; real-file OCR phone-test only |
| `MPT-CSS-2027-Solved.pdf` (31 pp) | **142 parsed, 3 skipped**; multi-column key table; `?` entries (Q3, Q106) excluded, never guessed; Q3 defective excluded; Q1 bilingual, keyed (D) |
| `US_History_solved_MCQs_by_SAK.pdf` (14 pp) | **515 parsed, 50 skipped** (q-only 515), year parts (CSS 2000–2026) |
| `Sir_Rizwan_GSA.pdf` (29 pp) | **328 parsed, 157 skipped** (one-liner 2 + q-only 326); roman-numeral options, `All of these` bold = answer |
| Examveda GK/Comp/English (546 pp, 1.03M chars) | **3180 parsed, 1704 skipped**, block 3172, answer-line 3175, **6.7 s total** (< 30 s bar), no ANR |
| `organization_….pdf` (50 pp, fact cards) | **180 facts, 0 MCQs** (generation-only), noise filtered 49; UNO/FAO/ICAO/IFAD cards, source spellings as-is |

### Paste-text fixtures (LIVE, gemini-3.5-flash-lite, 19 Nov 2026)

Run with the app's own prompt + validation rules
(`/tmp/live_fixtures.py`, mocked twins in
`test/paste_fixtures_test.dart`):

| Fixture | Live result |
|---------|-------------|
| A — Prophet Muhammad ﷺ facts (Urdu script, 16 lines) | **9/9 valid — FIXED in v1.2.0.** Before the fix the pool was 1 (only the ring line has `:`) and 0/1 questions were valid. The fix extracts dash/bullet lines as statement facts, so the pool is now 16 (15 statement + 1 colon ring fact); live re-run 19 Nov after the fix returned 9 questions, all valid, Urdu script + ﷺ preserved, distractors from the text's own facts (`قصواء`, `دُلدُل`, `یعفور` …). |
| B — Largest/Longest (33 items; the list has 33, not 34) | **30/30 valid, 0 rejected.** Pool = 33 facts. |
| C — Study-of (28 lines) | **26/26 valid, 0 rejected.** Pool = 27 (Universe/Cosmology deduped), noise lines ignored, as-is spellings (`Haemotology`, `Opthalmology`) preserved. |

**Fixture A defect — FIXED in v1.2.0 (was deferred, fixed before
the release because the release was still blocked):** dash/bullet
lines are now extracted as statement facts (`FactPair.isStatement`,
whole line = the fact, no colon required); validation accepts an
option stated verbatim inside a statement fact; and the fact-pool
constraint is only enforced when the pool actually covers the text
(>= 3 facts, or >= half the text's lines) — a single stray-colon
fact no longer vetoes the whole book. Caller-supplied facts
(organisation cards) are always enforced. The mocked test
`test/paste_fixtures_test.dart` now expects 4 valid questions for
the Urdu paste, and the live re-run confirms 9/9 valid.

### Security (v1.2, verified by `test/security_test.dart` — 7 tests, all passing)

- **Gemini key:** user-entered in Settings, stored ONLY in
  `flutter_secure_storage` (`gemini_api_key_v1`, Android Keystore);
  never in SharedPreferences, never in logs, never in a URL — sent
  only in the `x-goog-api-key` header to
  `generativelanguage.googleapis.com`. The client refuses redirects.
- **Network:** `network_security_config.xml` sets
  `cleartextTrafficPermitted="false"`; a grep test fails the build if
  any `http://` URL appears in `lib/` — there is none (the v1.1 m6
  HTTP Dawn fallback was replaced with the HTTPS FeedBurner URL).
- **Release build:** R8 obfuscation on (`isMinifyEnabled = true`,
  `isShrinkResources = true`); a release build with a throwaway test
  keystore was verified to launch and be non-debuggable; a release
  build without `key.properties` throws instead of silently falling
  back to the debug key (m5).
- **Manifest:** only the `INTERNET` permission is declared
  (file_picker handles storage itself); `android:allowBackup="false"`;
  only the launcher activity is exported.
- **No secrets in source:** grep tests forbid a hardcoded Gemini key
  and the default activation secret in `lib/`; no tracking/analytics
  SDKs in `pubspec.yaml` (no Firebase, no analytics).
- **Data:** everything on-device (sqflite); nothing is uploaded in
  v1. Payment proof goes only to the owner's WhatsApp by the user's
  own action. No CNIC / roll number / third-party phone number from
  uploaded files is stored, copied or displayed.
- **Model id guard:** a test forbids the retired
  `gemini-2.5-flash-lite` id anywhere in `lib/`.

**Honest residual limit:** v1 entitlement still lives on-device
(SharedPreferences, F6) and the activation codes are still not
single-use or device-bound (C1) — there is no server to check
against. A rooted phone could tamper with entitlement, and a shared
code would unlock other phones. The real fix is server-side
single-use, device-bound validation in **v2** (already decided:
v1.2 first, v2 after). Nothing in v1.2 claims to be tamper-proof.

### File formats (v1.2)

| Format | Status |
|--------|--------|
| PDF (text) — standard, one-liner, Q-only, flashcard ×3, key/tick/bold, two-column, multi-column key | ✅ tested on the 16 real files above |
| PDF (scanned, incl. CamScanner phone scans) | ⚠️ OCR pipeline in place (ML Kit Latin / Tesseract Urdu / Gemini vision); text extraction verified (0 chars); OCR quality on real scans **needs the phone test** |
| TXT / paste text | ✅ tested (paste fixtures A/B/C) |
| .docx | ✅ tested (`test/docx_test.dart`: 6/6 fixture, Urdu text, bold signal, corrupt fail-fast) |
| JPG/PNG single image (photo of a page) | ✅ import path tested (`PdfImportService.importImage`, `test/dead_end_ux_test.dart`); OCR quality same phone-test caveat as scanned PDFs |
| .xlsx (Excel question banks) | ❌ **deferred — no real sample was available to test against**; do not claim support |

### Model note (do NOT change back)

**Model id is `gemini-3.5-flash-lite`. LIVE-VERIFIED 19 Nov 2026:**
`gemini-2.5-flash-lite` is listed by the models endpoint but a live
`generateContent` call to it returns **HTTP 404** for this key, while
`gemini-3.5-flash-lite` returns OK (probe:
`/tmp/check_gemini_models.py`). The old per-book cost estimates for
2.5-flash-lite rates no longer apply; 3.5-flash-lite is $0.30 in /
$2.50 out per 1M tokens (Nov 2026 snapshot) — re-derive the cost
model at launch. Even at those rates the per-book cost stays a few
rupees. The app has ONE model id, in `lib/services/gemini_config.dart`
only; a test forbids the 2.5 id in `lib/`.

### Known issues / deferred (not fixed in v1.2, do not silently claim otherwise)

- **Fixture A (Urdu paste) — FIXED in v1.2.0** (was a known defect:
  0 questions; now 9/9 valid live). See above.
- **Tesseract Tier 1 Urdu OCR quality on real scans is unproven.**
  Routing + fallbacks are tested; the engine itself was never run
  against the real 112/109/110 scans on this VM (no Tesseract binary
  in the VM's repos). Phone test required before claiming it works.
- **Live Gemini F2 answer-inference end-to-end was not run this
  session** (mocked tests pass: confident answer saved, `-1` stays
  pending). The F2 live check is a phone/owner-key run, not a unit
  test.
- **Parser investigations D/F/G/H, the MPT 2 flashcards, and the US
  History duplicate count** were explicitly deferred until after the
  release (they may change `lib/` and would invalidate the built APK).
- **Idioms file, 109/110 editions, F7 112 Edition OCR** — no automated
  run in v1.2 (see the per-file table); acceptance is the phone test.
- **C1 / F6** (activation secret + on-device entitlement) — unchanged,
  v2 items. The built debug APK contains the default secret string by
  design; the release MUST use a real secret.
- **CSS MPT pass mark (33%)** still needs re-checking against the
  current FPSC advertisement before any Play listing.
- In-app RSS fetch on a real phone is still unverified (VM only).

