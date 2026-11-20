# Phone ML Kit Parse — Investigation + Fixes (20 Nov 2026)

**App:** OfficerPath AI · **Builds:** v2.0.2 (phone) → fixes target **v2.0.3**
**Date:** 20 Nov 2026 · **Status:** fixes implemented in the working tree,
full suite **867 passed / 5 skipped / 0 failed**, `flutter analyze` **0 issues**.
**No commits, no pushes, no releases** — the parent handles the v2.0.3 release.

---

## 1. What the owner's phone showed (the two rounds)

### Round 1 — v2.0.2, ML Kit (15:02–15:05 PKT)
- "Save these MCQs?" dialog with the **green no-answers notice**
  ("questions only, no answers attached") **AND** an amber validation box
  listing "Paper 66 key entry 1 — no matching question", entry 2, 21, 22, 3,
  "…aur 123 aur" — i.e. **~128 key entries, NONE matching any question**.
- He saved and took a test: exactly **1 General Knowledge question, 0/1**.
- His words: *"Un teeno ko upload krne p yhi aya, pdf se just aik mcq pick
  kia isne"* — uploading all three files gave this; from the PDF it picked
  just ONE MCQ.
- Side note (minor, **not investigated this session**): a toast said
  "Could not share the PDF — try again" on the result screen.

### Round 2 — v2.0.2, "Behtar quality (Gemini)" ticked (15:16 PKT)
- **Same result**: "Kis hisse save karein?" — Poori book **1 MCQ**.
  Parts list: English Grammar (p1, 0 MCQs, 6 pending); Advanced PPSC MCQs
  Model Papers Vol 2 (p2–3, 0, 16 pending); **"difficult I thjnk he speaks
  English. (A whether"** (p3–4, 0, 11 pending); **"to English of word: ei
  Harmless"** (p5, 0, 2 pending); **"S1. Choose the best English translation
  of the"** (p5–6, 1 MCQ, 5 pending); English Grammar Grammar and (p6–7, 0,
  2 pending); General Knowledge (p7, 0, 3 pending).
  Total: **1 MCQ + 45 pending**.
- His words: *"Ye Gemini select krne pe aya same situation hai hr traf."*
- Two new defects visible: (a) **part titles are QUESTION STEMS**, not
  headings; (b) **"S1" is a misread of "51."** — both consistent with the
  phone read being ML Kit, **not** Gemini.

### What v2.0.2 proved (routing)
v2.0.1 found 0 pages / 0 key. v2.0.2 ran OCR and found a key — the routing
fix worked. The failure moved from ROUTING to **phone OCR quality / parse
robustness on ML Kit text**. On the VM with Gemini vision OCR text, the same
PDF parses **100/100 with key answers** (gate test 7/7).

---

## 2. Reproduction — the probe (temp test, deleted after running)

A temporary probe (`test/mlkit_probe_test.dart`, **deleted** after recording;
it read `/tmp/tess66` Tesseract files that do not persist) fed noise models
over the real Gemini fixture text (`test-fixtures/ppsc66/ocr-p1.txt`…`ocr-p7.txt`)
through the **real** `importPdf` path (watermark-only text layer + stubbed
renderPage/runOcr). Clean control first, then noise:

| Probe | Input | Parsed | Key applied | Unmatched | Missing | Skipped |
|---|---|---|---|---|---|---|
| **F — clean control** | Gemini fixture text | **100** | 100 | 0 | 10 (Paper 67) | 10 |
| **A — column interleave p1–5** | left/right halves zipped | 54 | 49 | 51 | 12 | 51 |
| **B — digit misreads** | ~every 4th line-start number's first digit 1→I / 0→O / 8→B | 9 | 6 | 0 | 103 | 188 |
| **C — interleave + digit noise** | A + B | 8 | 0 | 6 | 59 | 181 |
| **D — Paper 67 heading misread** | "MODEL PAPER 67" → "MODEL PAPER 6?" | 100 | 100 | 0 | — | — |
| **E — interleave all pages** | A on every page | 26 | 20 | 26 | 30 | 120 |
| **G — real Tesseract 5.3.4 text** | psm 6, eng, on rendered p-1…p-7.png | 14 | 8 | 48 → **53** | 7 | 27 |
| **H — Tesseract text + real geometry** | TSV word boxes → table reconstruction, then column split | 14 | 8 | 53 | 7 | 27 |
| **I — table photos, image path, Tesseract text** | interjection / computer | 11 / **0** | — | — | 1 | 1 |

Controls on Gemini text: interjection **30**, computer **15**.

**Reading of the table:**
- Column interleave alone halves the parse (100 → 54); digit noise alone
  collapses it (100 → 9); combined (the phone's likely reality) → **8**,
  close to the phone's **1**. The probe reproduces the collapse.
- Probe D: a misread Paper 67 heading does **not** explain the 128 —
  counts stay 100/100. (Side finding: Paper 67's 10 questions then get
  mislabelled "Paper 66 Q1–Q10" and go pending because the key entries
  were already consumed.)
- Probe I: Tesseract destroys table geometry (rows merged, serials lost);
  the phone's ML Kit + `reconstructTableText` element-box path is what must
  carry tables — plain-text fallback cannot. Computer photo 0/15 on
  Tesseract text is a property of the OCR text, not of the table parser.

---

## 3. The 128 key entries — explained (not guessed)

The Paper 66 key has exactly **100 entries (1–100)**. The phone found **128**.
Whole-document key regex on **clean** text yields only **102 distinct
numbers** (1–100 + 1258 + 1335), so 128 cannot come from clean text.
Demonstrated mechanisms that create NEW distinct numbers (probe G,
Tesseract text — the key section shows them directly):

1. **Digit misreads create phantom numbers**: entry 1 misread as "14.",
   81 as "28)", 100 as "499°".
2. **"(B)"→"1)" splits create phantom entries**: e.g. "86. 1) Wat are YOU"
   creates entry 1 with garbage value "Wat are YOU | speak as he told him"
   — which then attached to Q1 as "matches no option".
3. **Numbers lost**: "79." → ".(B)" (entry never starts).
4. **Commas instead of periods**: "13, (B)", "41, (D)", "44,(C)",
   "52, (B)", "56, (D)" — not entries before the comma fix (§6.5).
5. **Page/year numbers leaking in**: 521–527, 2021/2024.
6. **Paper 67 Explanation / Associated-Information blocks**: numbered
   items inside them ("1. (A) Possessed: …", "1. Oldest University in
   Europe: … established in 1088", "1258. This was a devastating event…")
   are key-shaped and add distinct numbers.

**The key insight: unmatched=128 is a SYMPTOM of the question-parse
collapse, not (only) a key problem.** With only 1 question parsed, even
correct key entries have no questions to attach to. The phone's amber-box
order (1, 2, 21, 22, 3) is consistent with a column-interleaved key read.
The entries are **not** assumed invalid and are **not** discarded — they are
reported as unmatched, and the key-entry comma fix (§6.5) recovers more of
them. What the phone still needs is the *questions* to survive OCR noise
so the entries have something to match.

---

## 4. Column-split wiring — VERIFIED

`_runOcrWithMlKit` (`lib/services/pdf_import_service.dart:780`) **does** run
for rendered PDF pages, not just camera photos: `ocrPage` uses
`runOcr ?? _runOcrWithMlKit` for both the injected-renderer and the
real-renderer paths. Inside it: `reconstructTableText(elements)` runs
**first**; if non-null it returns the table text and the column split is
skipped; otherwise `columnSplitOcrText(recognized.text, lines)`; any
failure falls back to raw `recognized.text`.

`splitColumnsForOcr` (`lib/services/urdu_ocr.dart:125`): needs ≥4 lines;
split = widest gap between line starts whose midpoint sits in the middle
third of page width (0.3–0.7); gap must be ≥40; no clear gap → lines
returned unchanged (single column).

**Verdict:** the split is wired and runs on PDF pages. The split itself is
not the phone's failure — the failure is OCR noise destroying question
numbers/options before the parser ever sees them. Probe H confirms the
split is a no-op on Tesseract TSV lines (they already span both columns)
and that `reconstructTableText` did NOT false-fire on question pages
p1/p6/p7.

---

## 5. Gemini silent fallback — the reason the Gemini retry looked identical

### Confirmed from code
`upload_screen.dart:188/207/747` passes
`visionOcr: _bestQualityOcr ? GeminiVisionOcr() : null` — so visionOcr is
**always non-null when best quality is ticked**; the null case only happens
when the user does NOT tick it. `GeminiVisionOcr.run` → `GeminiClient`
→ `GeminiKeyStore.readKey()` (key `gemini_api_key_v1` in secure storage);
null key → `GeminiException(noKey)`; no network / 120 s timeout →
`noInternet`; 429 → `quota`; 404/400/401/403 → `badKeyOrModel`;
empty/blocked → `badResponse`.

In `ocrPage` the exception was caught by bare `catch (_)` and **DISCARDED**
— no record anywhere; `ocrMethods[page]` = "ML Kit". The preview dialog
DID show the OCR method ("Scanned pages read with OCR: 7 (ML Kit).") but
nothing said Gemini was requested and failed; the poor-OCR line even
suggested trying Gemini when he already had.

### The two hypotheses, distinguished
1. **No key on the phone (leading):** the owner UNINSTALLED and reinstalled
   for v2.0.1 — uninstall **wipes secure storage**, so the Gemini key is
   very likely gone and was never re-entered. Timing supports this: with a
   key present and dead internet, 7 pages × 120 s timeout would have taken
   ~14 minutes; the import completed promptly → instant `noKey` failure.
2. **Internet too weak (possible):** 0.00–5.08 K/s at test time — a Gemini
   call would time out. This would also have been swallowed silently.

Both are now **distinguishable on the phone** (see §6.1): the dialog says
which one happened.

### Fix (§6.1)
`ocrPage` (both `importPdf` and `importImage`) now catches
`GeminiException` specifically, records the first failure kind
(`geminiFailureKind`) and counts pages Gemini actually read
(`geminiPages`). `PdfImportResult` gains `geminiRequested` (bool),
`geminiPages` (int), `geminiFailure` (`GeminiFailureKind?`). When best
quality was ticked but Gemini ran on 0 pages, the result now says so with
the reason. The preview shows the Gemini line (§7).

---

## 6. What was fixed (before → after)

### 6.1 Gemini silent fallback → honest status
`lib/services/pdf_import_service.dart` — see §5. New tests
`test/gemini_fallback_test.dart` (4 tests): noKey / noInternet recorded
with `geminiPages: 0`; working vision counts 7 pages; not-ticked never
attempted. Uses `_ThrowingVision` / `_WorkingVision` subclasses of
`GeminiVisionOcr` overriding `run`.

### 6.2 Centralized answer pipeline + 7 statuses (Master Directive §2–§3)
New `lib/services/document_status.dart`:
- `DocumentAnswerStatus` — the directive's 7 statuses:
  NO ANSWER KEY DETECTED / ANSWER KEY DETECTED / ANSWERS EXTRACTED BUT
  UNMATCHED / ANSWERS PARTIALLY MATCHED / ANSWERS FULLY VERIFIED /
  CONFLICTING ANSWERS / MANUAL REVIEW REQUIRED.
- `keyDetected(result)` — section found OR entry applied OR unmatched
  entry. This is the one check before the dialog may say "no answers
  attached".
- `classifyDocumentStatus(result, {hasBlockingErrors})` — pure function;
  blocking errors → MANUAL REVIEW REQUIRED; conflicts → CONFLICTING
  ANSWERS; key detected + 0 applied + unmatched → ANSWERS EXTRACTED BUT
  UNMATCHED; applied>0 + no missing + no unmatched → FULLY VERIFIED;
  applied>0 → PARTIALLY MATCHED; key heading with no entries → ANSWER KEY
  DETECTED; no key + all answered → FULLY VERIFIED; **no key otherwise →
  NO ANSWER KEY DETECTED** (the status is about *key* detection — inline
  asterisk/bold answers do not count as a key; see §9 for why this
  wording matters).
- `documentStatusLabel` (Roman Urdu) and `documentStatusLine` — the single
  accurate-counts line: total questions, matched, key entries
  found/applied/unmatched, missing, conflicting. Total and missing count
  **both** lists: `questions` (answered) **and** `answerPending`
  (answerless) — see §9.
- `geminiFailureLine` — total failure → "Behtar quality (Gemini) chali
  nahi — \<reason\>. Ye result on-device OCR (ML Kit) se hai, Gemini se
  nahi."; partial → "Gemini sirf X/Y pages par chali — \<reason\>. Baaki
  pages ML Kit se parhe gaye."; null when not requested or no failure.

### 6.3 Save dialog correction (Master Directive §6)
`lib/screens/upload_screen.dart` — `_importResult` computes the status
once (with `validation.hasErrors`) and adds the status line + Gemini line
to the summary; passes `answerStatus` to `ExtractionPreviewDialog`. The
dialog shows `NoAnswersNoticeBox` **ONLY** when status ==
NO ANSWER KEY DETECTED **and** pending questions exist; otherwise shows
the new amber `AnswerStatusBox` with the status line — **never both**
(the phone's contradiction: green "no answers attached" + amber "128
unmatched" at the same time). `NoMcqsDialog` got the same gating, the
Gemini + status lines in diagnostics, and its 'Answer Key:' line now uses
`keyDetected()` (it previously said "nahi mili" when a key was found
without a heading). Widget tests in `test/extraction_preview_test.dart`
(2 tests): key-detected case shows AnswerStatusBox, no NoAnswersNoticeBox;
genuine no-key case shows the notice. The phone-case fixture models the
real import shape exactly (1 parsed + 1 pending + 5 unmatched entries).

### 6.4 Parts-title bug — question stems never become titles
`lib/services/book_structure.dart`:
- New `_misreadNumberStartRe`
  (`^[A-Za-z]?[0-9IlOSBZ$§]{1,3}[.\)\:\-]\s` — catches "S1.", "$1.",
  "I2.") and `_optionMarkerAnywhereRe`
  (`\([A-Da-d08][\)\s]` — catches "(A", "(8)", "(0)" mid-line;
  "(BS-16)" does NOT match); both added to `_isExcludedLine`.
- Lowercase-start guard added to `_isStrongHeading`'s subject-phrase
  branch only (real headings are Title-Case / ALL-CAPS; paper / month /
  chapter branches untouched). This is what let "difficult I thjnk he
  speaks English. (A whether" through: it contains bare `'english'` from
  `_subjectPhrases` with no guard against option markers or lowercase
  sentence fragments.
- Question-span marking now also starts from misread-number lines (inner
  loop break extended the same way); page-prefix rule now tolerates one
  leading non-alphanumeric symbol ("§22 Advanced…" is a running header,
  not a heading).

**Before → after (probe H, Tesseract parts):**
- Before: `["English Grammar (8) Unusual/openly" (0), "§22 Advanced PPSC
  MCQs Model Papers (Volume 2)" (7), "$1. "2 Choose the best English
  t i ye" (3), "(BS-16) — 2021 General Knowledge-Evening" (4)]` — a
  near-perfect reproduction of the phone's Gemini-ticked parts (same Q51
  stem as a title, same collapse).
- After: `["(BS-16) - 2024 English Morning" (10), "(BS-16) — 2021 General
  Knowledge-Evening" (4)]` — both real paper subtitles, no stems.
- New tests `test/noisy_part_titles_test.dart` (2 tests — phone stems +
  Tesseract stems never become titles; real headings survive).

### 6.5 Key-entry comma separator (OCR noise)
`lib/services/answer_key.dart` — `_keyEntryStartRe` separator class now
`[\.\)\:\-,]` and lookahead now `(?=\s|[A-Ea-e]\b|\(|$)` — recovers
Tesseract's "13, (B)", "41, (D)", "44,(C)" entries; the lookahead still
blocks thousands separators ("138,000" → "138," followed by "0" fails)
and decimals ("43.75%").
**Probe G before → after:** key map **56 → 61 entries** (5 more entries
recovered from the garbled key text); unmatched 48 → 53 (more entries
read, still unmatched — the questions had collapsed, so matching could
not improve on this input). New test in `test/answer_key_test.dart`
(1 test).

### 6.6 Update-time crash — missing FileProvider (PROVEN crash path)
**Owner's report (screenshot 14:59 PKT, sent 15:31 PKT):** the in-app
updater in v2.0.1 showed v2.0.2 and downloaded it; immediately an Android
System notification: "App Error — OfficerPath AI crashed for its own
reasons." His words (15:33 PKT): *"App chal ri hai lekin update krne p
jb download mukml huva ye error aa gya"* — the app runs fine; the crash
happened **exactly when the download completed**. Timeline: crash 14:59;
his 15:02–15:16 screenshots show v2.0.2 RUNNING — the app recovered on
relaunch. No crash-reporting service exists (by design), so **no stack
trace is available remotely — none is invented here**.

**Evidence chain (all verified from code):**
- ota_update 7.1.0 (`pubspec.yaml:50`) downloads via OkHttp to
  `dataDir/files/ota_update/<filename>`; on completion validates the
  checksum, then `handler.post(() -> executeInstallation(...))`.
- The app is not a system app (no INSTALL_PACKAGES) and
  `usePackageInstaller` is false (our code never passes it), so on
  Android 7+ it takes `installUsingActionInstallPackage`, whose FIRST
  line is `FileProvider.getUriForFile(context, androidProviderAuthority,
  downloadedFile)` — with **NO try/catch anywhere up the chain**
  (`executeInstallation` and the posted Runnable are uncaught).
- The authority defaults to `<package>.ota_update_provider` =
  `com.qadeerautomations.officerpath.ota_update_provider`.
- **Neither the app's `android/app/src/main/AndroidManifest.xml` nor the
  plugin's own manifest declares any `<provider>`** (grep confirmed: zero
  `<provider` in the app tree; the plugin's example manifest DOES declare
  it, and the plugin README §128 instructs adding it).
- `FileProvider.getUriForFile` throws `IllegalArgumentException`
  ("Couldn't find meta-data for provider…") when the provider is
  undeclared → uncaught on the main thread → native crash → exactly the
  Android "App Error" notification at 14:59 PKT, right after the download
  completed.
- **Consistency check:** the crash happens BEFORE `startActivity(intent)`,
  so the install intent never fires — which fits: the user then installed
  v2.0.2 from the GitHub link sent at 14:56 PKT, and it was running by
  15:02 PKT.
- The Dart side is well-guarded (`downloadAndInstall` fails closed on
  missing checksum; the download dialog's `.listen(_onEvent, onError: …)`
  handles stream errors; `main.dart` startup is fully try/catch-guarded)
  — the crash is native, in the plugin's install step, not in Dart code.

**Fix (v2.0.3, in the working tree):**
- `android/app/src/main/AndroidManifest.xml`: added the `<provider`
  exactly as the plugin README specifies
  (`sk.fourq.otaupdate.OtaUpdateFileProvider`,
  authorities `${applicationId}.ota_update_provider`, exported=false,
  grantUriPermissions=true, `FILE_PROVIDER_PATHS` → `@xml/filepaths`).
- New `android/app/src/main/res/xml/filepaths.xml`:
  `<files-path name="internal_apk_storage" path="ota_update/"/>`
  (matching the plugin's example; the download goes to
  `files/ota_update/`). Both XML files parse.
- The `InstallResultReceiver` is deliberately NOT declared: it is only
  used by the PackageInstaller (silent-install) path, which the app does
  not use.
- `lib/services/app_update_service.dart`: `downloadAndInstall` now never
  throws synchronously — `OtaUpdate().execute()` throws
  `OtaUpdateException` for a filename containing '/', which from the
  download dialog's `initState` would break the dialog instead of showing
  an honest error. It now fails closed with a single DOWNLOAD_ERROR event.
- Regression tests in `test/app_update_service_test.dart` (3 tests):
  manifest declares the provider with the right authority + filepaths
  resource; filepaths.xml covers `ota_update/`; `downloadAndInstall`
  never throws for a bad filename.

**Upgrade-path audit (the rest of the crash brief):**
- DB v3→v4 migration: runs inside `ensureSeeded()`, which `main()` wraps
  in try/catch; **proven working on the phone** — the user saved + took a
  test in v2.0.2 (1 GK question, 0/1), which exercises the v4 schema.
- L7 secure-storage migration (`_migrateLegacyPremiumCache`,
  subscription_service.dart:231): plain read-copy-delete, runs only inside
  subscription flows (not on the startup path), no throw path that could
  kill startup.
- Download failure on flaky internet → DOWNLOAD_ERROR event, handled as a
  message, not a crash. `OtaUpdate().execute()` sync throw (only for a
  '/' filename — ours never contains one) is now guarded (§6.6).
- **Do NOT claim the crash is fixed until the provider is in place and CI
  builds green; the phone re-test of the in-app updater is the final
  proof.**

---

## 7. Master Directive — how each part was addressed

1. **Universal answer detection** — audited against existing coverage:
   separate ABCD keys, answer columns inside MCQ tables, bold, stars,
   checkmarks, embedded answers, end-of-PDF keys, separate key
   PDFs/images, Urdu + English keys, multi-column answer tables were
   already implemented (asterisk 21/21, table formats, key attach). This
   session's gaps on noisy OCR text: the comma separator (§6.5) and the
   parts-title / number fixes (§6.4). **Honest limit: bold cannot be
   detected from a camera photo** (ML Kit returns plain text, no style
   info); circled/highlighted options are only recognised when OCR reads
   the mark as text. Nothing new was invented to pretend otherwise.
2. **Single source of truth** — `document_status.dart` (§6.2): OCR,
   extraction, key matching, storage and the Save dialog all read the SAME
   status from the SAME `PdfImportResult`. Nothing infers "answers exist"
   on its own.
3. **Correct status classification** — the 7 statuses (§6.2), one per
   import, pure function of the result. The phone case (1 parsed, 128
   unmatched, 0 matched) classifies as ANSWERS EXTRACTED BUT UNMATCHED.
4. **Paper 66 reprocessing** — reprocessed on the original pages via the
   probe (§2–§3): clean Gemini text still 100/100 with key answers
   (gate test); noisy text reproduces the phone collapse; the 128 entries
   are explained, not discarded (§3).
5. **Strict paper identity protection** — `decideKeyMatch` unchanged and
   not weakened: VERIFIED/HIGH apply; NEEDS REVIEW / UNVERIFIED / MISMATCH
   withheld with the reason in `keyPaperReport`. Paper 66 answers cannot
   contaminate Paper 67 (gate test 7/7).
6. **Save dialog correction** — §6.3: accurate counts in one status line;
   the green notice is forbidden whenever a key was detected.
7. **Testing and verification** — full suite + analyze (§8); no test
   weakened; no cosmetic warning-message edits; no errors hidden; no
   validation bypassed. Two real bugs were found *by* verification and
   fixed (§9) instead of being papered over.

**Constraints held:** extraction-only spec (never invent answers);
zero-cross-matching; gate tests untouched and green (paper_66_67 7/7,
table_title_pending 4/4, parse_validation 6/6, paper_identity 12/12).

---

## 8. Verification

- **Full suite (own run, log `/tmp/officerpath_v203_test2.log`):**
  **867 passed, 5 skipped, 0 failed** — TEST_EXIT=0, "All tests passed!".
  Baseline was 843/5/0 (v2.0.2); **+24 is exactly the new tests:**
  document_status 12 (10 + 2 new), gemini_fallback 4, noisy_part_titles 2,
  extraction_preview +2, answer_key +1, app_update_service +3.
- **`flutter analyze` (log `/tmp/officerpath_v203_analyze.log`):**
  **0 issues**, exit 0.
- **Gate tests in the full run:** paper_66_67 7/7, table_title_pending 4/4,
  parse_validation 6/6, paper_identity 12/12 — all green.
- **Probe file deleted:** `test/mlkit_probe_test.dart` was removed after
  recording its results (it read `/tmp/tess66` files that do not persist);
  the counts in §2 are the record. Final full-suite count (867) is
  post-deletion.

---

## 9. Two bugs the verification itself caught (honest account)

**Bug 1 — first full run: 864 passed, 5 skipped, 1 failed.**
`no_answers_test.dart`: "no-answers notice shows when pending questions
exist". Cause: my first version of `classifyDocumentStatus` returned
PARTIALLY MATCHED for "no key + some inline answers", which hid the green
notice — but the pre-existing test (encoding the owner's 09:08 requirement)
expects the notice whenever pending questions exist. Fix: the status is
about **key** detection — a mixed no-key result is NO ANSWER KEY DETECTED
(the counts line still reports the inline answers honestly). The old test
was **not** weakened; my classifier was corrected, and the correction is
pinned by a new test ("no key, mixed inline answers → NO ANSWER KEY
DETECTED").

**Bug 2 — same test still failed after Bug 1's fix.**
Root cause, deeper: in a real import, unanswered questions live in
`answerPending` (as `PendingQuestion`), **not** in `questions`
(`mcq_parser.dart` puts each question in exactly one list). My classifier
computed `missing` from `questions` only, so a 1-answered + 1-pending
import looked "fully verified" (missing = 0). Fix: total and missing now
count **both** lists (`questions` + `answerPending`), in
`classifyDocumentStatus` and `documentStatusLine`. Pinned by a new test
("real import shape: pending lives in answerPending, not questions").
After this fix the targeted run was 33/33 green, then the full suite
867/5/0.

A related fixture fix: my own preview phone-case fixture double-counted
one question (in both `questions` as -1 and `answerPending`); it now
models the real import shape exactly (1 parsed + 1 pending + 5 unmatched).

---

## 10. What still needs the owner's phone (exact steps)

The VM proves the code; only his phone proves the outcome. No "ho gaya"
until he confirms.

1. **Install v2.0.3** (parent to send the link once CI is green).
   **Re-test the in-app updater first if possible** — the FileProvider fix
   (§6.6) is only proven when an in-app update completes without the
   "App Error" notification. If the updater still crashes, install from
   the link instead and report it.
2. **Re-enter the Gemini key in Settings** (the v2.0.1 uninstall wiped
   secure storage — the key is almost certainly gone). Without it,
   "Behtar quality (Gemini)" silently does nothing (now honestly reported,
   §5–§6.1).
3. **On good internet**, re-upload the same 3 files with "Behtar quality
   (Gemini)" ticked: PPSC-66 PDF, interjection table photo, computer table
   photo. Expected on Gemini text: PPSC-66 **100 MCQs + Paper 67's 10
   pending**, interjection **30**, computer **15** (VM counts).
4. **Also re-test without Gemini ticked** (ML Kit only) and report the
   counts — the parse-robustness fixes (§6.4–§6.5) improve noisy text,
   but the phone's ML Kit read is still the unproven variable; the
   dialog now shows the honest status line either way.
5. **Paper 60 camera test** (the column-split acceptance check) — still
   pending from before.
6. What to watch in the dialog now: if a key is detected but nothing
   matches, the dialog must show the **amber status box with accurate
   counts** ("Key mili, jawab kisi sawal se nahi lage — kul N sawal, …")
   and **never** the green "no answers attached" notice alongside it. If
   Gemini was ticked and did not run, a plain line must say so with the
   reason.

---

## 11. Known limits / not done

- **Phone ML Kit text is still unproven.** All noisy-input numbers are
  from Tesseract / synthetic noise models on the VM, not from the phone's
  actual ML Kit output. If the phone's ML Kit text is worse than the
  models, counts will be lower; the dialog now reports that honestly
  instead of hiding it.
- **Table photos on plain-text OCR cannot work** (probe I: computer 0/15
  on Tesseract text). Tables depend on the phone's ML Kit element boxes
  + `reconstructTableText`. If the phone still fails the table photos,
  the next step is capturing the actual ML Kit element data from the
  phone — no speculative fallback was invented.
- **"Could not share the PDF — try again" toast** (round 1 side note):
  not investigated this session; still open.
- **Bold / circled / highlighted options from camera photos:** ML Kit
  returns plain text with no style info — bold cannot be detected from a
  photo, and circled/highlighted marks only work when OCR reads them as
  text. Stated plainly, not worked around.
- **No crash stack trace exists** for the update-time crash (no
  crash-reporting service, by design). The FileProvider root cause is
  proven from code + the plugin's own documentation + exact timing, not
  from a trace.

---

## 12. Files changed (working tree only — no commits)

**New:** `lib/services/document_status.dart`;
`test/document_status_test.dart` (12 tests);
`test/gemini_fallback_test.dart` (4); `test/noisy_part_titles_test.dart` (2);
`android/app/src/main/res/xml/filepaths.xml`.

**Changed:** `lib/services/pdf_import_service.dart` (Gemini status fields);
`lib/screens/upload_screen.dart` (status computation, dialog + NoMcqsDialog
gating); `lib/services/book_structure.dart` (parts-title fix);
`lib/services/answer_key.dart` (comma separator);
`lib/services/app_update_service.dart` (never-throw guard);
`android/app/src/main/AndroidManifest.xml` (FileProvider);
`test/extraction_preview_test.dart` (+2 tests, phone-case fixture fix);
`test/answer_key_test.dart` (+1 test);
`test/app_update_service_test.dart` (+3 tests).

**Deleted (after recording):** `test/mlkit_probe_test.dart` (temp probe).

**Unchanged on purpose:** `decideKeyMatch` / zero-cross-matching;
extraction-only spec; all gate tests; `test/no_answers_test.dart`
(the pre-existing test that caught Bug 1 — not weakened).
