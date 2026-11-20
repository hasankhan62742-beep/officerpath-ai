# OfficerPath AI

**Apni book se officer tak ka rasta.**

A real Android app for competitive-exam aspirants in Pakistan (PPSC, PMS,
CSS MPT, FPSC, KPPSC, BPSC, SPSC). Upload your own MCQ book / past papers,
tick the papers you prepared today, and the app builds a timed mock test
**only from those papers** — in the real commission pattern, with negative
marking and a full evaluation afterwards.

- Package: `com.qadeerautomations.officerpath`
- Version: 2.0.0+5000
- Offline-first at its core — books, parsing and tests work without an
  account. v2 adds an optional account + cloud backup (Supabase Free).
  No ads, no tracking SDKs.
- **v2.0.0 (19 Nov 2026):** Supabase Free backend, login, server-side
  single-use Premium codes, admin panel, push notifications, the
  universal extraction engine, and Free = **3 tests per calendar
  month**. See [## v2.0.0 (19 Nov 2026)](#v200-19-nov-2026--supabase-backend-login-server-codes-admin-panel-push-extraction-engine)
  below. The v1.2.0 live app keeps Free = 5 tests total-once; v2 does
  NOT backport that.
- **v1.3 (19 Nov 2026):** in-app updates for the GitHub-sideloaded app
  — the app checks the latest GitHub Release on launch (and from About
  → "Check for updates"), downloads the arm64 APK and hands it to the
  Android installer with a progress bar. Play's In-App Updates API does
  NOT work for sideloaded apps, so this is a custom check
  (`AppUpdateService`) + the `ota_update` plugin. Same-signing-key rule:
  a release-key build cannot update over the debug-signed v1.2.0 —
  those users uninstall once. Play forbids self-updates, so a Play
  build passes `--dart-define=PLAY_BUILD=true`, which flips
  `AppUpdateService.selfUpdateEnabled` off (see
  `docs/release-signing.md` §3). **Code + tests only — no APK
  built yet** (the v1.2.1 build step is blocked; see AUDIT_REPORT.md).
- **v1.2 (19 Nov 2026):** the real-book round — answer-key parsing
  (two-pass, per-paper), tick/bold/key answer signals, flashcard
  formats, two-column extraction, book structure + part/page selection,
  PPSC subject-grouped test order, AI MCQ generation from the user's
  own Gemini key (`gemini-3.5-flash-lite`), two-tier Urdu OCR
  (Tesseract free/offline first, Gemini vision best-quality), no-dead-end
  upload UX, `.docx` + JPG/PNG import, results download + history
  folders + improvement analytics, red top-corner UPGRADE button with
  Easypaisa/JazzCash manual payment, security hardening, new launcher
  icon + footer credit. Full per-file results in `AUDIT_REPORT.md`
  § v1.2. **Debug APKs built** (`build/app/outputs/flutter-apk/`,
  arm64 119.2 MB, SHA1 `a6891c7789d493bb13b87b9966b8578f738ceb76` —
  see `AUDIT_REPORT.md` § v1.2); the shareable
  download link is a **GitHub Release** (parent's step — never a
  Muse link). Signed release still needs the owner's keystore + a real
  `ACTIVATION_SECRET`.
- **v1.1 (18 Nov 2026):** ANR fix (PDF work in an isolate), on-device OCR for
  scanned PDFs (Latin/English only — Urdu-script scans still read poorly),
  flexible parser (one-liner MCQs + Q-only questions), and the full-app audit
  (`AUDIT_REPORT.md`: 4 critical + 17 major + 12 minor findings fixed, except
  the two honest v1 limits). Debug APKs rebuilt — see `APK_REPORT.md`.

## What makes it different from fixed-bank apps (Imtehan / PakPrep / MockCSS / Pak Imtehan)

1. **Apni Book Se Test** — tests come from *your* uploaded book / past
   papers, not a fixed bank. Hero feature on the Home screen.
2. **Aaj Tayyar Papers** — you tick only the papers/topics prepared today;
   the test is generated ONLY from those sources.
3. **AI MCQ generation + cache** — real in v1.2 (Option A: the user
   enters their own free Gemini key in Settings; model
   `gemini-3.5-flash-lite` — do NOT change back to 2.5-flash-lite, it
   returns HTTP 404 live). MCQs are generated ONCE per book and
   cached/reused — never per test. Every generated item is validated
   before saving (exactly 4 options, distractors only from the book's
   own facts); language matches the input (Urdu-script in → Urdu-script
   MCQs, honorifics preserved). Daily caps: free 2 AI books/day,
   Premium 10/day.
4. **Real commission pattern** — exact pattern + timer + negative marking
   per exam (see below), not generic quizzes.
5. **Smart evaluation** — weak topics, time-per-question, accuracy trend,
   wrong-question revision deck (retry wrong-only).
6. **On-device-first privacy** — your original book stays on your phone;
   only extracted MCQ text is stored.
7. **Freemium built-in** — Free 3 tests per month (v2); Premium unlimited.

## Exam patterns (verified)

| Exam | MCQs | Marks | Time | Negative | Pass |
|------|------|-------|------|----------|------|
| PPSC | 100 | 100 | 90 min | −0.25 | 40% |
| FPSC (BS-16/17) | 100 | 100 | 100 min | −0.25 | 40% |
| CSS MPT | 200 | 200 | 200 min | −0.25 | 33%* |
| PMS / KPPSC / SPSC / BPSC | 100 | 100 | 90 min | −0.25 | 40% |

Short tests scale time linearly (e.g. PPSC 50 MCQs → 45 min). Test sizes:
25 / 50 / 100 MCQs (200 for CSS MPT).

\* CSS MPT pass mark is 33% in code — **re-check against the current FPSC
advertisement before Play Store listing.**

## MCQ rules (non-negotiable, enforced)

- **Every MCQ has exactly 4 options (A–D)** — never 3, never 5. The
  built-in bank, the paste import and the upload parser all enforce it;
  questions that do not parse to 4 options + an Answer line are skipped
  and reported before saving.
- **Negative marking in exam mode:** correct +1, wrong −0.25, skipped 0.
  The result shows correct count, wrong × −0.25, skipped, raw score,
  final score, % and pass/fail vs the exam's pass mark. Review shows the
  −0.25 chip on every wrong answer. There is **no practice mode in v1**,
  so scores are never confused.

## Built-in sample bank

84 explained MCQs (7 subjects × 12: GK, Pakistan Studies, Islamiat,
Current Affairs, English, Everyday Science, Maths/Computer), tagged
across 6 built-in past-paper sources — so the app works with no upload.
Plus a bundled sample paper (`assets/sample_books/ppsc-sample-paper.txt`,
10 MCQs) you can import to try the upload flow.

## Freemium + manual payment (v2 — server codes; v1 was offline codes)

| Plan | Price (PKR) |
|------|-------------|
| FREE | 3 tests per calendar month, max 5 books |
| Premium — 1 month (starter) | Rs 600 |
| Premium — 2 months | Rs 1,000 (Rs 500/mo) |
| Premium — 1 year **BEST VALUE** | Rs 5,000 (Rs 417/mo) |

(v1: FREE was 5 tests total-once. v2: 3/month, resets monthly.)

Payment in v1 is **manual only**: JazzCash / Easypaisa / bank transfer.
The student sends the payment screenshot/reference in-app (or to the
owner's WhatsApp), and the owner sends back an **activation code**:

- `OP1-XXXXXX` = 1 month, `OP2-XXXXXX` = 2 months, `OP3-XXXXXX` = 1 year
- 6-char checksum = FNV-1a hash of `secret|planId`
- Owner mints codes with `tools/generate_activation_code.dart`
  (`dart tools/generate_activation_code.dart OP2`).
- **Release APKs must be built with a real secret:**
  `flutter build apk --release --dart-define=ACTIVATION_SECRET=...`
  (default in code is `CHANGE_ME_IN_RELEASE_BUILD`).

Honest limits: codes are NOT single-use or device-bound in v1 (no server).
The owner issues one per paying student and tracks them in a sheet;
server validation is v2. **Google Play Billing is a stub only**
(`lib/services/billing_service.dart`) — it always refuses and never
charges. Never claim it works in v1.

## Storage architecture — the 1 GB / 10 GB book worry

- **On-device-first:** MCQs are parsed on the phone. The original PDF
  stays on the student's phone only; **nothing is uploaded in v1**.
  Only extracted MCQ text is stored: **1,000 MCQs ≈ 200–300 KB**.
- v1 limits (enforced in code): max **100 MB per book file**,
  **PDF / TXT / .docx / JPG-PNG** (v1.2: `.docx` books and single-page
  photos import through the same parser + OCR pipeline). **v1.1: scanned/image PDFs are now OCR'd on-device** (pdfx render
  + ML Kit Latin text recognition, per-page progress, cancellable, max 100
  OCR pages per import) — **Latin (English) only; scanned Urdu-script books
  still read poorly, cloud Urdu OCR is a later phase.**
- Max **5 books** on Free (unlimited on Premium). Parsing runs in a
  background isolate (`compute()`), so the UI never blocks — the old
  `ParseQueue` (UI-thread wrapper) was deleted in v1.1.

## Profit design (why the price works)

MCQs are generated **once per book and cached in sqflite** — a test
shuffles cached MCQs, it never calls the AI again. Model:
`gemini-3.5-flash-lite`, Nov 2026 rates **$0.30 input / $2.50 output
per 1M tokens** (snapshot — re-check at launch): one 100-MCQ
generation ≈ **$0.021–0.029 (~Rs 6–8)**; one scanned Urdu page via
Gemini vision ≈ $0.0004 (~Rs 0.11); answer inference ≈ $0.00002
per question. The free tier (500 Flash-Lite requests/day, SHARED per
project) does NOT scale for a server key — which is why v1.2 uses
the **user's own key (Option A): the owner pays Rs 0**.
Manual JazzCash/Easypaisa in v1 keeps 100% (no store cut); Google Play
fee later is ~15% on subscriptions (Rs 5,000 → Rs 4,250 net).

## Current Affairs — Rozana (FREE, not counted in the 3/month test limit)

Daily headlines from **free publisher RSS** — no API key, no cost
(NewsAPI.org deliberately NOT used: 100 req/day, 24h delay, $449/mo paid):

- **Pakistan:** Dawn — `https://dawn.com/feeds/home`
  (fallback `http://feeds.feedburner.com/dawn-news-pakistan`)
- **International:** BBC World — `https://feeds.bbci.co.uk/news/world/rss.xml`
  and The Guardian World — `https://www.theguardian.com/world/rss`

Native Flutter fetches RSS directly with `http` (no CORS problem — that
is browser-only). Parser handles RSS 2.0 (`<item>`) and Atom (`<entry>`).

- Home card + dedicated screen with **Pakistan | International** tabs.
- Auto-update on open + pull-to-refresh + 30-min refresh while open;
  "Updated HH:MM, date" header.
- **Offline cache** (SharedPreferences JSON, 7-day prune) — the screen
  never shows empty after the first fetch.
- Each item: headline + source + published time + 1-line summary only.
  Tap opens the **original article in the phone browser** — no full text
  is copied.
- Bookmarks, date filter (All 7 days / Today / Yesterday) + search,
  7-day archive grouped by day.
- **Daily CA Quiz (10 MCQs) is Phase 2** — shown as a labelled
  coming-soon card. It is NOT faked: no headlines are invented.

## Distribution (v1)

**GitHub Releases (v1.2)** — the APK is published as a release asset
on the owner's GitHub (`hasankhan62742-beep/officerpath-ai`), e.g.
`github.com/hasankhan62742-beep/officerpath-ai/releases/download/v1.2.0/…-arm64.apk`
— a permanent direct-download link, no expiry, no login needed.
**Never a Muse link** (the v1.1 Muse link expires 21 Nov 2026).
Cloudflare Pages cannot host the APK (25 MB per-file limit).
Users enable "Install unknown apps" for the browser that opens the
link. **No Play Store account yet.** Play facts (verified): Internal Testing ALSO needs the $25 Play
Console account (US $25 one-time, no annual/per-app fee, prepaid cards
not accepted); it can stay invisible to the public (max 100 testers,
opt-in link only, not in search); new personal accounts (after
13 Nov 2023) need a closed test with **12 testers for 14 continuous
days** before production access — internal testing does NOT count.

## Releasing v1.3.0 (CI — no VM build needed)

The arm64 APK is built by GitHub Actions
(`.github/workflows/build-apk.yml`) and attached to the release
automatically. Do NOT build the release APK on the VM.

1. Push the workflow file to `main`:
   `git add .github/workflows/build-apk.yml && git commit -m "CI: build arm64 APK on release" && git push`
2. Create the GitHub release **v1.3.0** on the website
   (`github.com/hasankhan62742-beep/officerpath-ai/releases/new`):
   tag `v1.3.0`, title `v1.3.0`, no asset — CI attaches it.
   (Creating the release also creates the tag, so no separate tag push
   is needed. A bare `v*` tag push only builds + tests; it does not
   attach anything, because no release exists yet at push time.)
3. Wait for the Actions run ("Build arm64 APK") to go green and attach
   `officerpath-ai-1.3.0-arm64.apk` to the release. CI runs
   `flutter analyze` + `flutter test` first — a red run attaches
   nothing, so check the run log before sharing the link.
4. Verify the download link works before sharing it:
   `https://github.com/hasankhan62742-beep/officerpath-ai/releases/download/v1.3.0/officerpath-ai-1.3.0-arm64.apk`
   (expect HTTP 200 and ~119 MB, the arm64 split APK).
5. **Honest note for existing users:** v1.2.0 installs have NO updater
   code, so those users must open the new link once and install v1.3.0
   themselves. From v1.3.0 onward, updates arrive in-app (launch check
   + About → "Check for updates").

## Project structure

```
lib/
  main.dart                 App entry, theme, seeds sample bank
  theme/app_theme.dart      Navy #0B1F3A + gold #C9A227, serif headings
  models/                   exam.dart, question.dart, current_affairs.dart
  data/sample_bank.dart     84 explained MCQs
  services/
    mcq_parser.dart         Q + A-D + Answer (+ Explanation) text parser
    pdf_text_extractor.dart Pure-Dart PDF text extractor (Flate streams)
    answer_key.dart         Two-pass per-paper key segmentation + join
    book_structure.dart     Parts/months/years/chapters + page tracking
    test_generator.dart     Random test from ticked sources + scoring
                            (PPSC subject-grouped order, shuffle within subject)
    storage_service.dart    sqflite: sources / questions / attempts
    ai_generation.dart      AI MCQ generation + answer inference (v1.2, real)
    gemini_client.dart      Minimal Gemini generateContent client
    gemini_config.dart      ONE model id: gemini-3.5-flash-lite + guardrails
    secure_key_store.dart   Gemini key in flutter_secure_storage only
    urdu_ocr.dart           OCR routing: ML Kit / Tesseract / Gemini vision
    docx_text_extractor.dart  .docx (ZIP/XML) → paragraphs/pages
    ai_usage_caps.dart      Daily AI caps (free 2, Premium 10 AI books/day)
    ai_service_stub.dart    Old AI stub — unused by v1.2 generation
    subscription_service.dart  Free/Premium limits, plans
    billing_service.dart    Play Billing STUB (always refuses)
    manual_activation.dart  OP1/OP2/OP3 activation codes (FNV-1a)
    rss_service.dart        RSS/Atom fetch + parse (Dawn/BBC/Guardian)
    ca_cache_service.dart   CA offline cache (7-day prune), bookmarks
  screens/                  home, upload, setup, test, result, review,
                            history, upgrade, about, current_affairs,
                            book_selection, ai_settings
  widgets/progress_chart.dart  Accuracy trend (CustomPaint, no dep)
assets/sample_books/ppsc-sample-paper.txt
tools/generate_activation_code.dart
test/                       36 test files, 258 tests (19 Nov 2026)
```

## Build — Android Studio (recommended)

1. Install Android Studio (latest stable) + Flutter plugin.
2. Open this folder. Android Studio downloads the Android SDK
   (API 35) and JDK 17 automatically.
3. `flutter pub get`
4. Create your release keystore once (keep the file + passwords safe):
   ```bash
   keytool -genkey -v -keystore ~/officerpath-release.keystore \
     -alias officerpath -keyalg RSA -keysize 2048 -validity 10000
   ```
   Create `android/key.properties` (never commit it):
   ```
   storePassword=<your store password>
   keyPassword=<your key password>
   keyAlias=officerpath
   storeFile=<absolute path to officerpath-release.keystore>
   ```
5. Mint your activation secret and build the signed release APK:
   ```bash
   flutter build apk --release \
     --dart-define=ACTIVATION_SECRET=<a long random secret>
   ```
   Output: `build/app/outputs/flutter-apk/app-release.apk`
   (For Play Store later: `flutter build appbundle --release` with the
   same `--dart-define`.)
6. Share the APK via WhatsApp / Drive / your website. Users enable
   "Install unknown apps" for the browser/WhatsApp that opens it.

## Build — this VM (what was actually verified here)

Flutter 3.35.7 at `~/flutter-real`, JDK 17 Temurin at `~/jdk17`, Android SDK
at `~/Android/sdk` (platforms 34/35/36, build-tools 34/35/36, NDK 27).
Debug APKs (split + universal) were built on this VM — see `APK_REPORT.md`
for the exact commands, sizes and MD5s. Verified here (19 Nov 2026):

- `flutter analyze` → **No issues found!**
- `flutter test` → **258 passed, 1 skipped, 0 failed** (v1.2 run: 255
  passed, 1 skipped; docs/test follow-up: +14 tests, −11 `tmp_*`
  probes; see `AUDIT_REPORT.md` § v1.2 for the per-file results)

**Build quirks that will bite the next rebuild** (all learned the hard way
in v1.1 — see `APK_REPORT.md` § v1.1 for detail): set
`GRADLE_USER_HOME=$HOME/.gradle` (Java's `user.home` is `/root`); refresh
the JDK truststore from `/run/hatch/cell-anchors/hatch-egress-ca.pem`
(the egress proxy's MITM CA rotates) in the same command as the build;
extract the live proxy password from `$https_proxy` into
`~/.gradle/gradle.properties` per build. Toolchain in v1.1: Gradle 8.14.1,
AGP 8.13.0.

## v2.0.0 (19 Nov 2026) — Supabase backend, login, server codes, admin panel, push, extraction engine

- **Supabase Free backend (Rs 0):** Auth (email + Google), Postgres
  (`profiles`, `activation_codes`, `payments`, `test_results`,
  `waitlist`, push tables), Row Level Security on every table, and
  Edge Functions (`redeem-code`, `issue-code`, `delete-account`,
  `send-notification`). Migrations in `supabase/migrations/001–005`.
  Setup + handover steps: `docs/supabase-setup.md`. The app runs
  fully offline when no `--dart-define` Supabase values are supplied.
- **Login:** email/password + Google sign-in, forgot/reset password
  via deep link (`officerpath://reset-password`), profiles with a
  unique username (chosen at sign-up; the signup trigger copies
  `user_metadata.username` first, email prefix as fallback).
  The built-in Supabase Auth email is 2/hour and team-only, so custom
  SMTP (Resend) is REQUIRED from day one — see
  `docs/supabase-setup.md` §5.
- **Server activation codes:** Premium is granted ONLY by single-use
  codes issued by the admin (Edge Function `issue-code`, SHA-256 hash
  stored, plain code emailed once) and redeemed in-app
  (`redeem-code`). The server `profiles` row is the source of truth
  for the plan; the on-device cache is only the offline fallback.
  Manual payment stays Easypaisa **03427717288** / JazzCash
  **03060853742** (owner WhatsApp +92 342 7717288); plans Rs 600 / 1
  month, Rs 1,000 / 2 months, Rs 5,000 / 1 year.
- **Free = 3 tests per calendar month** (user decision 19 Nov 2026),
  replacing v1's 5-total-once. Mechanism shipped: local month-keyed
  counter (`free_tests_month_v2`, resets on month rollover) +
  best-effort server count from `test_results` — each finished test
  syncs one row on completion (never blocking, only when online +
  signed in); reconciliation takes the higher of local/server, so a
  reinstall does not reset the limit and offline tests are not
  forgotten. No `profiles` counter was needed. See
  `lib/services/subscription_service.dart` +
  `test/free_tests_monthly_test.dart`.
- **Admin panel (static, Cloudflare Pages):** `admin/` — login gate,
  dashboard stats, payments review, code issue/revoke, signups chart,
  waitlist view + CSV export, "Send notification". Deploy:
  `admin/README.md`. No secrets in the panel code (config.js holds
  only the public URL + anon key).
- **Push notifications (FCM, free):** `PushService` + migration 004 +
  `send-notification` Edge Function. Setup: `docs/push-setup.md`.
  Delivery on a real phone is UNVERIFIED until the phone test.
- **Waitlist = Google Form (user decision 19 Nov 2026):** NO GitHub
  Pages, NO FormSubmit page is deployed. The Form's Sheet IS the list;
  at v2 the Sheet emails are imported into the `waitlist` table —
  steps at the top of `docs/waitlist.md`. The admin panel already
  shows the waitlist.
- **Extraction engine (Phase A, 19 Nov 2026):** all 8 gaps fixed
  (G1, G2, G6, G7, G8, G9, G-M3, G-C6); modular format registry
  (`lib/services/extraction/format_registry.dart` +
  `layout_patterns.dart`); per-question preview with confidence +
  verification status; dataset regression library at 24/50–100
  (`test/regression/`). **AI generation is PARKED as an extraction
  path — the honest note:** the uploaded PDF is the ONLY source of
  questions and answers; the app NEVER invents an answer; an
  unverified answer goes to manual correction (original kept
  separate). The AI service stays in the codebase but no extraction
  flow calls it. Per-format measured accuracy: `AUDIT_REPORT.md`
  § "Compatibility report" (live, 19 Nov 2026) — no 100% claim.
- **OCR: Tesseract + Gemini, both kept** (user decision 19 Nov 2026).
  EasyOCR was tested the same day and is NOT viable (39/100 keys on
  the real page vs Gemini 99/100; see
  `ocr-comparison/EASYOCR_VS_GEMINI.md`).
- **Migration note — v1.2.0 codes do NOT carry into v2:** v1 offline
  activation codes were computable offline and cannot be verified by
  the server. Premium already paid is honoured by the admin
  RE-ISSUING a server code (admin panel → issue code for that user);
  the user redeems it in the v2 app. Local books + history on the
  phone survive the update (same debug signing key); the v1 free-test
  count does not carry over — v2 starts the new month at 0.
- **Releasing v2.0.0:** same CI flow as v1.3.0 (## Releasing v1.3.0
  above) with tag `v2.0.0` — GitHub Actions builds the arm64 debug
  APK and attaches `officerpath-ai-2.0.0-arm64.apk`. Version code:
  pubspec 5000 → arm64 APK 7000 (> v1.2.0's 4002, installs over it).

## v1.3 fixes (19 Nov 2026) — table format, asterisk, camera photos, PDF download, verification status

- **Table-format MCQs** ("Adjective and its Types", "Article and its
  Types"): a new `table` format in the parser handles row-wise and
  column-wise tables (Question | A | B | C | D | key letter | type
  label), multi-line questions, section headings, 5-option rows and
  no-key rows (answer-pending, never dropped). Verified on the real
  CamScanner photo: 32/32 rows with the right key answers.
- **Asterisk `*` answer signal** (Dogar-style): a `*` after the
  correct option is now an answer signal in block and one-liner
  formats (precedence: answer line > key > tick > bold > asterisk).
  The `*` is stripped from the displayed option. Verified on the real
  DATA ENTRY OPERATOR PAPER 60 photo: 21/21 answers correct.
- **Camera-photo robustness**: a single JPG/PNG photo is a book
  (1 page is enough); preprocessing (grayscale + contrast + sharpen)
  before Tesseract; the parser skips OCR debris gracefully (garbled
  fragments, handwritten notes, watermarks never become questions);
  wrapped options keep their full text (incl. a `*` on the
  continuation line). All 20 camera-photo tests pass.
- **Result PDF really downloads**: "Download PDF" now writes the PDF
  into the phone's Downloads folder (MediaStore on Android 10+, no
  permission; direct write below that) via a native channel in
  `MainActivity.kt`. "Share PDF" is a separate action (share sheet).
  History-screen downloads do the same, with the share sheet as
  fallback. The on-device save still needs the user's phone test.
- **Verification status (governing spec)**: every parsed question
  carries `answerVerified` — true for printed/official signals,
  false for AI-inferred answers and for signal conflicts. The
  extraction path is DETERMINISTIC and LOCAL: the uploaded PDF is
  the only source; AI generation is PARKED as an extraction path
  (the code stays, but the upload flow has no AI call sites).
- **Provenance + confidence + correction model (v2 preview data)**:
  every question carries a confidence score (0–1, from the answer
  source), a verification status (`verified` / `unverified` /
  `manually-corrected`), a mark provenance (`printed` / `ocr`), and
  `originalCorrectIndex` + `withCorrection()` so manual correction
  keeps the original answer separate. An OCR-sourced tick/bold is
  UNVERIFIED until the user confirms it (it could be the student's
  pen). The upload preview shows verified/unverified counts and the
  average confidence.
- **Cross-page questions + numbering (19 Nov 2026)**: a question
  split across a page break stitches into ONE question (stem, options
  and answer joined; page furniture at the break is skipped, never
  joined into the stem). A missing number is reported with its
  bounding pages, and a duplicated number is reported with its pages
  while both copies are kept — both shown in the preview diagnostics.
- **Urdu ؟ question mark**: Urdu flashcards use ؟ (U+061F), not
  "?". The parser now accepts it (5/5 Urdu flashcards parse).
- **Trailing bullet after "Answer:"** no longer drops the MCQ
  ("• Good luck!" after "Answer: C" used to corrupt the answer
  token).
- **Compatibility report**: live per-format accuracy table in
  `AUDIT_REPORT.md` § "Compatibility report" (supported / partial /
  unsupported lists + unresolved issues with causes).

## Honest limits (v1.2)

- Demo-quality sample bank (84 MCQs) — real value comes from the
  student's own uploaded books.
- **AI generation is PARKED as an extraction path (governing spec,
  19 Nov 2026).** The code stays in the codebase, but the uploaded
  PDF is the only source of questions — the upload flow has no AI
  call sites (`parser_first_test.dart` proves it). Pasting the full
  Urdu fact list (Prophet Muhammad ﷺ facts) generated questions
  live-verified 19 Nov (9/9 valid) BEFORE the spec; that path is now
  parked, not deleted. Largest/Longest (12/12) and Study-of (26/26)
  were also verified live before parking.
- **Tesseract Tier 1 Urdu OCR quality on real scans is unproven.**
  Routing + fallbacks are tested, but the engine was never run against
  the real 112/109/110 scans on this VM. Phone test required before
  claiming it works; Gemini vision is the best-quality fallback.
- **Live Gemini F2 answer-inference end-to-end was not run this
  session** (mocked tests pass). The F2 live check needs the owner's
  key on a phone, not a unit test.
- **Model id is `gemini-3.5-flash-lite` — do NOT change it back to
  `gemini-2.5-flash-lite`:** live-verified 19 Nov, 2.5-flash-lite
  returns HTTP 404 for this key while 3.5-flash-lite works.
- Activation codes are not single-use / device-bound (no server yet).
- Scanned books (112/109/110 editions) and the idioms glossary have
  no automated run in v1.2 — acceptance is the phone test.
- `.xlsx` (Excel question banks) is **not** supported — no real sample
  was available to test against.
- CSS MPT pass mark (33%) must be re-checked against the current FPSC ad.
- In-app RSS fetch not yet verified on a real device (no device/emulator
  in this VM); feed endpoints were verified reachable via curl (see
  BUILD_REPORT.md). First app open needs internet for headlines; after
  that the offline cache covers 7 days.
