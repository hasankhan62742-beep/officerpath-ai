# OfficerPath AI — Debug APK Report

**Date:** 18 November 2026, built 13:03 PKT (08:03 UTC)
**Status: ✅ DEBUG APK BUILT AND VERIFIED**

> **v1.1 REBUILD — 18 Nov 2026, 23:07–23:08 PKT (18:07–18:08 UTC).**
> The ANR fix + scanned-PDF OCR + flexible parser + full-app audit build is
> in the table below ("v1.1"). The v1.0 APKs (first table) are superseded —
> do not install them. **⚠️ DOWNLOAD LINK PENDING:** the arm64 upload to
> Muse storage needs an egress approval that timed out (`approval_expired`,
> approval_id `connector-attempt-56961ba8a0ad41d0857c4ff79d83b29cb3f91972c9d8e1209ca2334e01abd30d`).
> Re-request the upload and approve the card when it appears; until then the
> APKs exist only on this VM at the paths below. Two earlier upload attempts
> were killed by runtime restarts and left a server-side lock
> ("an equivalent connector write is already running") — that lock may also
> need to clear before a retry succeeds.

## The APK

| | |
|---|---|
| **File** | `officerpath-ai/build/app/outputs/flutter-apk/app-debug.apk` |
| **Full path (VM)** | `/home/hatch/workspace/officerpath-ai/build/app/outputs/flutter-apk/app-debug.apk` |
| **Size** | **159.8 MB** (167,559,426 bytes) |
| **MD5** | `65e8058eba8108869db38128d975fbf6` |
| **Package** | `com.qadeerautomations.officerpath` |
| **App label** | OfficerPath AI |
| **Version** | 1.0.0 (versionCode 1) |
| **minSdk / targetSdk** | 24 (Android 7.0) / 36 (Android 16) |
| **Permissions** | INTERNET (needed for Current Affairs RSS) |

## How it was built (on this VM — no Android Studio, no PC needed)

- **Flutter 3.35.7** (Dart 3.9.2) at `~/flutter-real/bin/flutter`
- **JDK 17** — Eclipse Temurin 17.0.21+9 at `~/jdk17`
- **Android SDK** at `~/Android/sdk`: platform-tools 37.0.3, platforms android-34 + android-36, build-tools 34.0.0 / 35.0.0 / 36.0.0, NDK 27.0.12077973, CMake 3.22.1
- **Gradle 8.11.1**, **Android Gradle Plugin 8.9.2**, Kotlin plugin 2.1.0
- Command (standard path, confirmed working): `flutter build apk --debug`
- SDK/NDK/CMake/build-tools were installed manually with curl because the VM's `sdkmanager` cannot reach the network (Java proxy bug); licences accepted via `licenses/android-sdk-license` (current hash `efa68a6b…` added).

## Two small project fixes made to get it building

1. `android/build.gradle.kts` — `rootProject.buildDir = "../build"` failed Kotlin-DSL type check (String vs File). Changed to `file("../build")` (same for the subprojects line). Standard Flutter template form.
2. `android/settings.gradle.kts` — AGP bumped **8.7.3 → 8.9.2**: the newest AndroidX libraries (`androidx.core:core 1.17.0`, `androidx.browser:browser 1.9.0`) require AGP 8.9.1+. Nothing else in the app changed.

## What was verified

- ✅ APK exists and is a valid Android package (`aapt2 dump badging`: package, label, SDK levels all correct).
- ✅ `flutter analyze` → **No issues found**.
- ✅ `flutter test` → **23/23 passed** ("All tests passed!") — parser, scoring (−0.25 negative marking), freemium limits, activation codes, RSS parsing.
- ✅ `flutter build apk --debug` → "✓ Built build/app/outputs/flutter-apk/app-debug.apk".

## Install on a real phone — exact steps

1. **Transfer the APK** to the phone: send `app-debug.apk` via WhatsApp / Google Drive / USB cable / Bluetooth (file is ~160 MB — use Wi-Fi/Drive, not mobile data if possible).
2. On the phone, tap the APK file. If Android blocks it, tap **Settings → Allow from this source** ("Install unknown apps") for that app (WhatsApp/Drive/Files), then go back and tap Install.
3. Tap **Install**, then **Open**.
4. **Test flow:**
   - Pick an exam (PPSC / FPSC / CSS MPT / PMS …) → pick 25/50/100 questions.
   - **Book upload:** tap "Upload Book" → choose a text PDF or TXT past-paper file (or paste MCQs). Tick the paper(s) you prepared today → **Generate Test**.
   - **Attempt:** timer runs (e.g. 90 min for 100 MCQs), palette + mark-for-review work, auto-submit at 0:00.
   - **Result:** correct / wrong × −0.25 / skipped breakdown, pass/fail vs 40%, subject-wise evaluation, Retry Wrong Only, history chart.
   - **Current Affairs:** open the Current Affairs tab — Pakistan | International headlines should load (needs internet). Tap a headline → it must open the original article (Dawn/BBC/Guardian).
   - **Free limit:** after 5 generated tests the free tier locks — Premium screen shows Rs 600 / Rs 1,000 / Rs 5,000 plans (activation is manual for now — no payment inside the app yet).
5. If the app crashes or a screen is blank, note the exact step + take a screenshot — that is the real-phone feedback needed before the release build.

## Honest limits — read before sharing

- **This is a DEBUG APK, not a signed release and not on the Play Store.** It is for testing on your own phone only. Do not distribute it as the final app.
- **No release/AAB was built** — that needs a keystore + ACTIVATION_SECRET which only you must create/keep (next step after this debug APK is tested).
- **AI MCQ generation is a STUB in v1** — the app extracts MCQs already present in the uploaded book (parser only). True LLM generation from prose is v2.
- **In-app RSS fetch is NOT yet verified on a real phone** — Dawn/BBC/Guardian feeds were verified by curl from this VM, but the phone's in-app fetch still needs your check (step 4 above).
- **CSS MPT pass mark (33% in the app) still needs re-check** against the current FPSC advertisement before any Play listing.
- **App icon is a placeholder** (green square + white "O") — proper navy+gold icon still to be made.
- **Activation codes are not single-use / device-bound** (no server yet) — manual JazzCash/Easypaisa activation only.
- APK is large (~160 MB) because it is a debug build with all 4 CPU architectures bundled; the release build will be smaller.

## Split per-ABI debug APKs (built 18 November 2026, 14:16 PKT)

The 160 MB universal APK was too big for the file-sharing service (rejected with HTTP 413), so the same code was rebuilt with `flutter build apk --debug --split-per-abi` — one APK per CPU architecture, same app, same version 1.0.0. No source code changed; `flutter analyze` / `flutter test` were not re-run (nothing to re-test).

| APK | Size | MD5 | versionCode |
|---|---|---|---|
| `app-arm64-v8a-debug.apk` | **80,246,125 bytes (76.5 MiB)** | `8db149805308fadc06c3452e399e43e2` | 2001 |
| `app-armeabi-v7a-debug.apk` | 59,982,177 bytes (57.2 MiB) | `0acb402fc8987fbf92c99bbfd427e515` | 1001 |
| `app-x86_64-debug.apk` | 66,534,531 bytes (63.5 MiB) | `b834f5a56a8e500fbd51efbd9b9d2232` | 4001 |
| `app-debug.apk` (universal, for comparison) | 167,559,426 bytes (159.8 MiB) | `65e8058eba8108869db38128d975fbf6` | 1 |

All three in `officerpath-ai/build/app/outputs/flutter-apk/`. Verified via `aapt2 dump badging`: arm64-v8a APK is package `com.qadeerautomations.officerpath`, label "OfficerPath AI", targetSdk 36, native-code `arm64-v8a` (the other two likewise match their own ABI).

**Which one to download — arm64-v8a.** Practically every Android phone sold since ~2016–2017 uses a 64-bit ARM chip (arm64-v8a): Samsung, Xiaomi, Oppo, Vivo, Infinix, Tecno, Google Pixel, etc. So a normal phone user downloads **only `app-arm64-v8a-debug.apk` (76.5 MiB)**. The `armeabi-v7a` APK is only for old 32-bit phones, and `x86_64` is for emulators / rare Intel-based devices — almost nobody needs those. If the arm64 APK refuses to install with "app not compatible", try the armeabi-v7a one instead.

## v1.1 rebuild (18 Nov 2026, 23:07–23:08 PKT) — ANR fix + OCR + flexible parser + full audit

**What changed (see `AUDIT_REPORT.md` for the full audit):**
- **ANR fixed:** PDF extraction + parsing now run in a `compute()` isolate (never on the UI thread); the extractor was rewritten byte-level/incremental — it never decodes the whole file, never runs a lazy regex across megabytes, and never inflates image streams. Timed test: realistic 1.86 MB book (50 pages, 300 MCQs + 2 scanned pages) extracts in **147–215 ms** on the VM and parses 300/300. Real-producer compatibility fixed (ToUnicode CMaps, per-word Tj + word-gap spaces via AFM widths).
- **Scanned PDFs now work:** pages with no text layer are rendered (pdfx) and OCR'd on-device (ML Kit Latin) into the same parser, with per-page progress + Cancel, max 100 OCR pages/import. **Honest limit: Latin (English) only — scanned Urdu-script books will still read poorly; cloud Urdu OCR is a later phase.**
- **Flexible parser:** standard blocks, one-liner MCQs (`(a)–(d)` / `1–4` / `(i)–(iv)`, answers as `Ans: (c)` / `Answer: C` / `(c)` / `Correct: <text>`), and Q-only questions whose options are built from the book's own answer pool (never invented; excluded items listed with the reason). Upload preview shows parsed count + format breakdown before saving.
- **Full-app audit (AUDIT_REPORT.md):** 4 critical + 17 major + 12 minor findings — all fixed except the two honest v1 limits (C1 activation-secret design, F6 SharedPreferences entitlement — both need a server in v2). Highlights: test resume after OS kill (wall-clock deadline + saved progress + Home "Resume test"), Retry Wrong Only is now free and not counted as a new test, freemium counter no longer charged to Premium users / double-taps / failed generations, seeding + source saves are transactional, RSS GMT dates fixed, dark-mode colours fixed, lists are lazy (`ListView.builder`), and the release build now refuses to sign with the debug key.
- **Verification:** `flutter analyze` clean; `flutter test` **49/49 passed** (23 original + 19 PDF/OCR/parser + 7 audit-fix tests), run 3× consecutively.
- **Build toolchain changed (this is why the APKs are bigger):** Gradle **8.11.1 → 8.14.1**, AGP **8.9.2 → 8.13.0** (ML Kit's Android plugin requires AGP 8.13.0; Gradle 8.13.0's dist 404s — 8.14.1 is the first 8.13+ dist that exists), SDK Platform **35 installed** (pdfx needs it). APKs grew ~13 MB each (pdfx + ML Kit native libs).

| APK (v1.1) | Size | MD5 | versionCode |
|---|---|---|---|
| `app-arm64-v8a-debug.apk` | **94,033,497 bytes (89.7 MiB)** | `fc3fd2d52bf4fd3a76c7c1bfe97cb627` | 2001 |
| `app-armeabi-v7a-debug.apk` | 69,483,799 bytes (66.3 MiB) | `b6a2d08c81647ab363a820da1577d078` | 1001 |
| `app-x86_64-debug.apk` | 80,881,572 bytes (77.1 MiB) | `fcaf8ab29ab7fcfd144658d48bfed5e4` | 4001 |
| `app-debug.apk` (universal) | 180,904,346 bytes (172.5 MiB) | `79d6024b34e7958765d0bda193c1c207` | 1 |

All in `officerpath-ai/build/app/outputs/flutter-apk/`. Verified via `aapt2 dump badging`: package `com.qadeerautomations.officerpath`, label "OfficerPath AI", versionName 1.0.0, targetSdk 36, compileSdk 36.

**Build-environment notes (new in v1.1 — read before the next rebuild):**
- **Set `GRADLE_USER_HOME=$HOME/.gradle`.** Java's `user.home` is `/root`, so without it the Gradle wrapper looks in `/root/.gradle` and re-downloads the distribution every time (that was the first build failure).
- **Refresh the JDK truststore from the live CA in the SAME command as the build.** The egress proxy's MITM CA rotates (same subject, new key); the runtime keeps the current one at `/run/hatch/cell-anchors/hatch-egress-ca.pem`. Before building: `keytool -delete -alias hatch-egress-ca-live ...; keytool -importcert -alias hatch-egress-ca-live -file /run/hatch/cell-anchors/hatch-egress-ca.pem ...` (storepass `changeit`). A stale CA gives `PKIX path validation failed: signature check failed` on every Maven download.
- **Proxy password rotates between exec calls** — extract it live from `$https_proxy` into `~/.gradle/gradle.properties` (`systemProp.http/https.proxyPassword`) in the same command as the build, and kill any running Gradle daemon first (`pkill -f 'Gradle[D]aemon'` — note the bracket trick, a plain `pkill -f GradleDaemon` kills your own shell).
- The old arm64 download link (v1.0, expires 20 Nov 2026 14:17 PKT) is superseded — do not share it for the v1.1 test.
