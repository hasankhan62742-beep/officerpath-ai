# OfficerPath AI — Build Report (v1.0.0+1)

**Date:** 18 November 2026
**App:** OfficerPath AI — *"Apni book se officer tak ka rasta."*
**Package:** `com.qadeerautomations.officerpath`
**Project folder:** `~/workspace/officerpath-ai/`
**Status:** Complete Flutter v1 source. **No APK/AAB was built on this VM**
(no Android SDK / JDK here — see §6). `flutter analyze` clean,
`flutter test` 23/23 passed.

> "TestBack" was rejected by the user and appears nowhere in the app
> code, UI, or README. The folder was renamed `testback-ai/` →
> `officerpath-ai/`; the name is recorded here only as the rejected
> working name, so nobody reintroduces it.

---

## 1. What was built

A real, offline-first Flutter Android app (not a demo):

| Area | Delivered |
|---|---|
| Exam select | PPSC, PMS, CSS MPT, FPSC, KPPSC, BPSC, SPSC with verified patterns (see README) |
| Upload own book | PDF/TXT picker + paste-text import; in-app MCQ parser (`Q + A–D + Answer: X`, optional `Explanation:` / `Subject:`); pure-Dart PDF text extractor (Flate streams, no external PDF dep) |
| Built-in sample bank | 84 explained MCQs, 7 subjects × 12, tagged across 6 built-in past-paper sources; bundled sample paper (10 MCQs) |
| Prepared papers | Tick today's prepared papers/topics; test generates ONLY from those sources |
| Test setup | 25 / 50 / 100 MCQs (200 CSS MPT); timer auto-set from pattern, scales linearly (PPSC 50 → 45 min) |
| Attempt screen | One question at a time, palette, mark-for-review, skip, previous/next, countdown + auto-submit on timeout, smooth question transitions |
| Result + evaluation | Score ring, pass/fail badge, correct / wrong × −0.25 / skipped breakdown, raw + final score, %, subject-wise bars, time-per-question, weak-topic cards, full review with explanations, Retry Wrong Only |
| History | sqflite persistence (sources, questions, attempts); survives restart; accuracy trend chart (last 10 tests) + pass rate |
| Design | PRO officer-grade: deep navy `#0B1F3A` + gold `#C9A227` + white; serif headings + clean sans body; rounded cards, subtle shadows; light default, dark supported; no ads |
| Freemium + paywall | Free 5 tests total (then generation locks), max 5 books; Premium 1mo Rs 600 / 2mo Rs 1,000 / 1yr Rs 5,000 (1yr = BEST VALUE); Upgrade screen with all 3 plans |
| Manual payment | JazzCash / Easypaisa / bank transfer; in-app payment-proof flow (screenshot/reference → owner WhatsApp +92 342 7717288); activation codes `OP1/OP2/OP3-XXXXXX` (FNV-1a checksum, `tools/generate_activation_code.dart`); Play Billing is a stub only |
| Storage | On-device-first parsing; 100 MB/book cap; PDF/TXT text-based only; scanned PDF rejected with guidance (OCR = later phase); one-book-at-a-time parse queue with progress |
| Current Affairs | Home card + "Current Affairs — Rozana" screen, Pakistan \| International tabs, Dawn + BBC + Guardian RSS, offline cache, bookmarks, date filter + search, 7-day archive; FREE for all users, not counted in the 5-test limit |
| Service layer | Clearly-marked stubs for AI generation (`ai_service_stub.dart`) and Play Billing (`billing_service.dart`) so Supabase auth + Gemini can plug in later; no API keys invented or stored |

## 2. What was actually run / verified (18 Nov 2026, this VM)

Flutter 3.35.7 (Dart 3.9.2) installed at `~/flutter-real` via
`git clone --depth 1 --branch 3.35.7`. (An earlier tarball install at
`~/flutter` was broken by a git-version hack and has been removed.)

| Check | Result |
|---|---|
| `flutter pub get` | OK — 54 dependencies resolved (incl. `http`, `xml`, `url_launcher`, `file_picker`, `sqflite`, `shared_preferences`) |
| `flutter analyze` | **No issues found!** (16.5 s) — 0 errors, 0 warnings, 0 infos. Fixes made along the way: `CardTheme` → `CardThemeData`, `zlib` import (`dart:io`), `utf8.decode(allowMalformed:)`, `DropdownButtonFormField.initialValue`, `withValues(alpha:)`, an extra `)` in the test screen, unused variable |
| `flutter test` | **23/23 passed** (see §3) |
| `flutter build apk` / AAB | **NOT run — no Android SDK and no JDK on this VM** (`flutter doctor`: "Unable to locate Android SDK"). No APK/AAB exists. Do not claim one does. Build steps are in README §"Build — Android Studio" |
| In-app run on a device/emulator | **NOT verified** — no Android device/emulator on this VM |
| RSS live fetch | Verified from this VM with `curl` (see §5), **not** yet verified inside the app on a device |

## 3. Verification of the two non-negotiable MCQ rules

### Exactly 4 options (A–D), always

- **Built-in bank:** test asserts all 84 MCQs have exactly 4 options —
  **84/84, 0 violations** (`test_generator_test.dart`).
- **Sample asset:** bundled `ppsc-sample-paper.txt` parses to
  **10 MCQs, 0 skipped, all with 4 options** (`sample_asset_test.dart`).
- **Parser:** `mcq_parser.dart` drops any block without 4 options + an
  `Answer:` line and reports the skipped count before saving
  (tested: 3-option and 5-option blocks are rejected;
  `mcq_parser_test.dart`).
- **Generator:** option shuffle keeps the same correct-answer text
  (tested).

### Negative marking −0.25, always in exam mode

- **Scoring test 1:** 7 correct / 2 wrong / 1 skipped → raw 7.0,
  deduction 0.50, final **6.50, 65%, PASS** — passed.
- **Scoring test 2:** 4 correct / 6 wrong → raw 4.0, deduction 1.50,
  final **2.50, 25%, FAIL** — passed (negative marking flips the result
  vs raw 40%).
- Result screen shows correct / wrong × −0.25 / skipped / raw / final /
  % / pass-fail separately; review shows a −0.25 chip on each wrong
  answer.
- **No practice mode in v1** — every test is exam mode, so scores can
  never be confused with a no-negative-marking mode.

### Test inventory (23 tests, all passed)

| File | Tests | Covers |
|---|---|---|
| `mcq_parser_test.dart` | 2 | Parsing, answers, explanations, subjects; numeric answers (1–4) |
| `pdf_extractor_test.dart` | 2 | Flate-stream text extraction; empty text for text-less PDF |
| `test_generator_test.dart` | 6 | Bank 84/84 4-options; ONLY ticked sources used; shuffle keeps answer; both scoring cases; time scaling |
| `subscription_test.dart` | 7 | Exact freemium numbers (5 free, 600/1000/5000); lock after 5; premium removes limits; activation codes round-trip all 3 plans; code grants premium; billing stub never grants/charges; parse queue serial |
| `sample_asset_test.dart` | 1 | Sample paper 10 parsed / 0 skipped |
| `rss_parser_test.dart` | 3 | RSS 2.0 parse (title/link/summary/RFC822 date, HTML stripped); Atom parse (Dawn via FeedBurner, link-less skipped); Dawn fallback URL wired |
| **Total** | **23** | **23 passed, 0 failed** |

## 4. Differentiators — implementation status

| # | Differentiator | Status in v1 |
|---|---|---|
| 1 | Apni Book Se Test (own book, not fixed bank) | ✅ Implemented — upload/paste + parser; hero card on Home ("APNI BOOK SE TEST") |
| 2 | Aaj Tayyar Papers only | ✅ Implemented — ticked sources only (test-verified) |
| 3 | AI MCQ generation + cache/reuse | ⚠️ **Architecture + stub only** — `ai_service_stub.dart` is clearly marked; generation itself is **v2**. No AI call is made in v1. The cache (sqflite) and the "generate once, reuse" rule are in place for when it lands |
| 4 | Real commission pattern + timer + negative marking | ✅ Implemented — verified patterns, timer, auto-submit, −0.25 (test-verified) |
| 5 | Smart evaluation (weak topics, time/Q, trend, wrong-only retry) | ✅ Implemented — subject bars, time analysis, weak-topic cards, accuracy trend chart, Retry Wrong Only |
| 6 | On-device-first privacy | ✅ Implemented — nothing uploaded in v1; book stays on the phone; only MCQ text stored |
| 7 | Freemium built-in | ✅ Implemented — Free 5 tests / 5 books; Premium 600 / 1,000 / 5,000 PKR; manual activation; Play Billing stub only |

## 5. Current Affairs — feeds, verification, cache

**Feeds wired (free publisher RSS, no key, no cost):**

| Feed | URL | Role |
|---|---|---|
| Dawn (Pakistan) | `https://dawn.com/feeds/home` (+ fallback `http://feeds.feedburner.com/dawn-news-pakistan`) | National |
| BBC World | `https://feeds.bbci.co.uk/news/world/rss.xml` | International |
| Guardian World | `https://www.theguardian.com/world/rss` | International |

NewsAPI.org was **deliberately not used** (100 req/day, 24h delay,
$449/mo paid). Native Flutter fetches RSS directly with `http` — no
CORS problem (browser-only issue). Parser handles RSS 2.0 and Atom.

**Live-fetch verification — curl from this VM, 18 Nov 2026 ~11:40 PKT:**

| Feed | Result |
|---|---|
| Dawn direct (`dawn.com/feeds/home`) | **FAILED** — HTTP 000, connection failed from this VM |
| Dawn via FeedBurner | **OK — HTTP 200, 296 KB, Atom, Pakistan headlines present** (this is why the fallback URL is wired first in practice) |
| BBC World | **OK — HTTP 200, ~22 KB, 28 items** |
| Guardian World | **OK — HTTP 200, ~147 KB, 45 items** |

**Offline-cache behaviour:** first successful fetch is cached in
SharedPreferences (JSON, 7-day prune). The CA screen **never shows
empty after the first fetch** — if the network fails, cached headlines
show with the last "Updated HH:MM, date". First-ever open needs
internet; until then the screen shows a clear loading/empty state, not
fake headlines.

**Also implemented:** Home card (top 3 Pakistan headlines + FREE badge,
tap → CA screen), Pakistan | International tabs, auto-update on open +
pull-to-refresh + 30-min refresh while open, headline + source +
published time + 1-line summary only, tap opens the **original article
in the phone browser** (no full text copied), bookmarks, date filter
(All 7 days / Today / Yesterday) + search, 7-day archive grouped by day.
**Daily CA Quiz (10 MCQs) is Phase 2** — shown as a labelled
coming-soon card; no headlines are invented. **CA is FREE for all
users — not counted in the Free 5-test limit** (stated in-app on the
Home card and CA screen).

## 6. Pricing, storage & profit math (as confirmed)

- **FREE:** 5 tests total, max 5 books. **PREMIUM:** 1mo **Rs 600** /
  2mo **Rs 1,000** (Rs 500/mo) / 1yr **Rs 5,000** (Rs 417/mo, BEST VALUE).
  Cheaper than Pak Imtehan (600 / 1,200 / 5,900) and MockCSS (Rs 2,000/mo).
- **Storage:** 1,000 MCQs ≈ **200–300 KB** as text. Original PDF stays
  on the phone; v1 uploads nothing. Limits: 100 MB/book, PDF/TXT,
  text-based only, max 5 books (Free), one-at-a-time parsing queue.
- **Profit:** generate MCQs once per book, cache/reuse — never call
  Gemini per test. Gemini Flash $0.75 in / $3.75 out per 1M tokens
  (to 31 Dec 2026, doubling 1 Jan 2027) → one 100-MCQ generation ≈
  **Rs 14**; even 100 tests/user/year ≈ Rs 14 AI cost vs Rs 5,000
  revenue. Manual JazzCash/Easypaisa keeps 100% in v1; Google Play fee
  later ~15% (Rs 5,000 → Rs 4,250 net; Rs 1,000 → Rs 850 net).

## 7. Distribution & Play Store facts (verified, do not misstate)

- **v1 = direct signed release APK (sideload)** via WhatsApp / Drive /
  website; users enable "Install unknown apps". **No Play account yet.**
- Play Console account is **US $25 one-time** (not free), no annual or
  per-app fee, prepaid cards not accepted. **Internal Testing ALSO needs
  the $25 account.** Internal Testing can stay invisible to the public
  (max 100 testers, opt-in link only, not in search). New personal
  accounts (after 13 Nov 2023) need a closed test with **12 testers for
  14 continuous days** before production access; internal testing does
  NOT count toward that.

## 8. File list

```
pubspec.yaml, analysis_options.yaml, .gitignore, README.md, BUILD_REPORT.md
lib/main.dart
lib/theme/app_theme.dart
lib/models/exam.dart, question.dart, current_affairs.dart
lib/data/sample_bank.dart
lib/services/mcq_parser.dart, pdf_text_extractor.dart, test_generator.dart,
  storage_service.dart, ai_service_stub.dart, subscription_service.dart,
  billing_service.dart, manual_activation.dart, parse_queue.dart,
  rss_service.dart, ca_cache_service.dart
lib/screens/home_screen.dart, upload_screen.dart, setup_screen.dart,
  test_screen.dart, result_screen.dart, review_screen.dart,
  history_screen.dart, upgrade_screen.dart, about_screen.dart,
  current_affairs_screen.dart
lib/widgets/progress_chart.dart
test/mcq_parser_test.dart, pdf_extractor_test.dart, test_generator_test.dart,
  subscription_test.dart, sample_asset_test.dart, rss_parser_test.dart
assets/sample_books/ppsc-sample-paper.txt
tools/generate_activation_code.dart
android/ (applicationId com.qadeerautomations.officerpath, MainActivity.kt,
  build.gradle.kts with key.properties release signing + debug fallback,
  adaptive-icon placeholder, launch background)
```

## 9. Exact next steps

### A. Build the signed release APK (user / Android Studio)

1. Install Android Studio + Flutter plugin; open this folder
   (SDK API 35 + JDK 17 come with it).
2. `flutter pub get`
3. Create the release keystore + `android/key.properties` (see README).
4. Choose a long random activation secret. Mint test codes to check it:
   `dart tools/generate_activation_code.dart OP1|OP2|OP3`
5. `flutter build apk --release --dart-define=ACTIVATION_SECRET=<secret>`
6. Verify the APK exists and check its size:
   `ls -lh build/app/outputs/flutter-apk/app-release.apk`
7. Install on a real phone, run through: upload the sample paper →
   tick a paper → generate a 25-MCQ test → attempt → result → review →
   history → Current Affairs (online once, then offline) → Upgrade
   screen → activate with a minted code.
8. Share the APK via WhatsApp / Drive / website.

### B. Before any Play Store listing

- Replace the placeholder app icon (green square + white "O") with a
  real officer-grade icon.
- Re-check the **CSS MPT pass mark (33%) against the current FPSC ad**.
- Build with a real `ACTIVATION_SECRET` (never ship the default).
- Play Console account: US $25 one-time (prepaid cards not accepted).
- `flutter build appbundle --release --dart-define=ACTIVATION_SECRET=...`
- Internal Testing (max 100 testers, invisible to public) first; then a
  closed test with **12 testers / 14 continuous days** before production.
- Wire real Google Play Billing at publish time (the v1 stub refuses
  everything) and add server-side activation-code validation (v2).

### C. v2 (after first paying users)

- Gemini AI MCQ generation from uploaded books (generate once, cache,
  reuse) — stub already in place.
- Daily CA Quiz (10 MCQs from real fetched headlines) — coming-soon card
  already in place.
- OCR for scanned/image PDFs.
- Supabase auth + cloud sync; single-use, device-bound activation codes.

## 10. Honest limits (v1)

- No APK/AAB built on this VM (no Android SDK/JDK); no on-device run
  verified here; in-app RSS fetch not yet verified on a device.
- AI MCQ generation is a stub — v2.
- Activation codes are not single-use or device-bound (no server yet).
- App icon is a placeholder; replace before listing.
- CSS MPT pass mark (33%) needs re-checking against the current FPSC ad.
- Sample bank (84 MCQs) is demo-quality; the real value is the student's
  own uploaded books.
