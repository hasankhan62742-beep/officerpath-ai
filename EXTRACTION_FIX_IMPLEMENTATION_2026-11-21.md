# OfficerPath AI v2.0.5 — Extraction Fix Implementation Report

**Date:** 21 Nov 2026 · **Base:** v2.0.4 (commit `5e820936`) → **v2.0.5+5500** (versionCode **7500**)
**Source:** user's Drive zip `officerpath-ai-2.0.2-extraction-fix.zip` (Drive id `11LJnJSbJOGev92uBqIRC2vq5znMKalGL`, 27.4 MB, **truncated** — recovered 266/267 entries; only loss 1 test-fixture JPG). The zip contained the changelog `CHANGES_EXTRACTION_2026-11-21.md` + 3 new test files, but **no lib code** — all 5 fixes below were **re-implemented from the changelog description, guided by the 3 new tests**, on top of v2.0.4. The fixes' author never compiled on Flutter/device (says so in the doc) — CI + tests are the verification gate; the user's phone remains the acceptance check.

## Verdict (VM results only — NOT phone-proven)

- **All 5 fixes implemented. None left unimplemented.**
- New tests: **29/29 green** (was 21 passed / 6 failed at baseline).
- `flutter analyze`: **0 issues**.
- Full suite: **914 passed / 5 skipped / 1 failed** — the single failure is a **pre-existing, date-dependent history-UI test, unrelated to this work** (see §6). All v2.0.3/v2.0.4 gate tests green.
- **NOT verified:** no `flutter build` on the VM (safety block — CI builds the APK), no Flutter device run. CI + the user's phone remain the acceptance check. Never claim a fix is proven on a phone.

## 1. The 5 fixes — what changed

### Fix 1 — Heading not read → key adopted when provably safe
**File:** `lib/services/answer_key.dart` — new `adoptOrphanExplicitKeys` (~line 1456); `lib/services/mcq_parser.dart` — wired in `_parseImpl` (~line 2193), report text (~lines 3881, 3891–3896).
- Conditions (all must hold): exactly ONE explicit key; the key's named paper has no question lines; every question line is in ONE segment, the default paper ("Paper 1" — no paper headings read anywhere); question numbers unique (no number twice); **≥80%** of the key's entry numbers appear among the questions.
- Entries are MOVED into the questions' segment (adopted entries overwrite existing bare-key entries in the target — explicit key carries verified identity, bare key is positional only), so the segment-local join applies them unchanged.
- Wiring order: AFTER `keyMatchDecisions` + the withheld-removal loop — the decision map is untouched; an orphan explicit key's decision is VERIFIED because number+title agree, both derived from the same label.
- Report: `keyPaperReport` gains a Roman-Urdu adoption note with the overlap %; the "Key 'X' mili, lekin is PDF mein X ke sawal nahi — key nahi lagayi" line is suppressed for adopted labels.
- Refusals preserved: two papers merged with no headings are refused by the uniqueness check (numbers repeat); a key covering a different paper's numbers is refused by the 80% check.

### Fix 2 — "Answer: (B)" read as a key HEADING
**File:** `lib/services/answer_key.dart` (~lines 615–627, 706–712).
- Root cause: `isAnswerKeyHeading` stripped a trailing "(…)" as a label, turning "Answer: (B)" into "Answer:" which matched the key-word regex; `keyHeadingRemainder` also accepted "(B)" as a key subhead.
- Fix: the trailing-paren strip now skips parens whose content is a single option letter/digit (A–E, 1–4); `_looksLikeKeySubhead` now rejects a fragment that is just a parenthesised single letter/digit.

### Fix 3 — Key rows without punctuation ("1 B 2 A 3 D", "1(B) 2(A)")
**File:** `lib/services/answer_key.dart` — new shared regex `_bareKeyEntryRe` (~line 832); second pass in `parseKeyEntries` (~line 860); `_isKeyOnlyLine` extension (~line 557).
- Bare pairs ("1 B" / "1(B)") count only when the blob holds **≥3** of them (a stray "5 A" is never a key); the letter must be followed by whitespace/comma/semicolon/end, so "1 Bravo" is never letter B.
- Pairs sitting INSIDE a separator entry's value span are ignored (e.g. "1. (B) 2 Brothers" — the "2 B" is answer text, not an entry).
- A separator-less row counts as a key-only line only when the whole line is ≥3 such pairs, contiguously.

### Fix 4 — Chapter-wise keys ("Answers: 1-B, 2-A, ..." after each chapter, numbering restarting)
**File:** `lib/services/answer_key.dart` — new `_chapterHeadingRe` / `_chapterHeadingLabel` (~lines 403, 409); wired into `segmentLines` (~line 1016) after the month-heading check, before the inKey check — each chapter is its own key-join segment.
- Whole-line "Chapter N" only (a stem merely mentioning a chapter is never one; titled headings like "Chapter 1: Grammar" are NOT split — same conservatism as paper headings, noted as a known limitation).
- **Chapter is deliberately NOT a paper-kind label** (`_isPaperKindLabel` unchanged): a chapter-grouped book is still one paper, so its per-chapter bare keys stay HIGH CONFIDENCE instead of NEEDS REVIEW (same as the Pace per-month bare keys).

### Fix 5 — Tilted table photo: deskew
**New file:** `lib/services/ocr_deskew.dart` (96 lines) — `estimateSkewDegrees` (least-squares slope of y on x; <6 elements → 0; (near-)zero horizontal spread → 0; |θ| < 0.05° snapped to exactly 0) + `deskewElements` (y -= (x − pivot)·tan θ, pivot = leftmost element's x; 0° returns elements unchanged). Record type is exactly the test's `({String text, double x, double y, double width, double height})`, same shape ML Kit elements are converted to.
**Wiring:** `lib/services/pdf_import_service.dart` (import line 15; lines 902–908, in `_runOcrWithMlKit`, immediately before `reconstructTableText(elements)`; skew==0 passes elements through untouched).
- **Design note:** the changelog's author used a median-based estimator; this implementation uses OLS — the synthetic-grid tests pass either way.
- **Follow-up (not done):** the column-split path was NOT deskewed — the changelog scoped wiring to table reconstruction only. A tilted two-column page still relies on the column split's own tolerance.

## 2. New tests — baseline (v2.0.4 code) vs after (v2.0.5)

| File | Baseline | After |
|---|---|---|
| `test/format_matrix_test.dart` (23 tests, F07 skipped by design) | 19 passed / 4 failed — F10 inline "Answer: (B)" (0 questions), F15 key "1 B 2 C" rows (0), F17 key rows "1(B) 2(C)" (0), F20 chapter-wise "Answers:" (7 questions). F16 ("1.B 2.C") PASSED on v2.0.4. | **23/23 green** |
| `test/unlabelled_paper_key_test.dart` (3) | heading-present PASSED (100/100), heading-NOT-read FAILED (0 answered), two-papers-merged PASSED (refused, 0 answered) | **3/3 green** |
| `test/ocr_deskew_test.dart` (3) | Failed to load — compile error, `lib/services/ocr_deskew.dart` did not exist | **3/3 green** |
| **Combined** | **21 passed / 6 failed** | **29/29 green** |

Baseline log: `/tmp/baseline_new_tests.log`. After-fixes log: `/tmp/new3.log`.
Probe findings (temporary probe tests, since deleted): F10 — "Answer: (B)" was treated as a key heading (3 key sections, empty entries), so questions lost their answer lines and were skipped as blocks; F15/F17 — `parseKeyEntries` returned `{}` (no separator after the number); F20 — keyEntries were `{Paper 1: {1:B, 2:A, 3:D, 4:C, 5:B, 6:A, 7:D, 8:"C Chapter 2"}}` — the "Chapter 2" line landed in the key buffer and polluted entry 8's value, chapters 2/3 entries were dropped by putIfAbsent (first wins), and chapter 1 consumed entries 1–7 → 7 questions parsed, 17 pending. (Changelog claimed 18/24 on v2.0.2; v2.0.4 measured 19/23.)

Each fix was verified individually before the full run: F10 ✓, F15/F16/F17 ✓, F20 ✓, unlabelled 3/3 ✓, deskew 3/3 ✓.

## 3. Full suite — before / after

| | Passed | Skipped | Failed |
|---|---|---|---|
| v2.0.4 baseline (parent-verified 20 Nov) | 882 | 5 | 0 |
| **v2.0.5 (this run, 21 Nov ~03:22 PKT)** | **914** | **5** | **1** |

Full log: `/tmp/fulltest_v205.log` (exit code 1 — the single failure below). Analyze log: `/tmp/analyze_v205.log` (0 issues, 22.9s).
Note on arithmetic: 882 + 29 new tests = 911, but the run reports 914 passed (920 total vs 887). The +4 is not explained by the new files alone and the v2.0.4 log is not on this VM to diff file-by-file; it does not affect the conclusion — the only failure is §6 and every gate test below is green.

**Gate tests — all 0 failures in the full run:** `paper_66_67_regression_test`, `table_title_pending_test`, `ocr_category_recovery_test` (ML Kit robustness / category separation), `key_match_wiring_test`, `answer_key_test`, `mlkit_robustness_test`, plus all 3 new test files.

## 4. Preserved v2.0.3/v2.0.4 behaviours (verified by the full suite, not just the new tests)

Category separation (`decodeOcrNumber` — digits only in number slots, letters only in option markers, Urdu preserved exactly), sequence validation, the 7-status document taxonomy, the strict key rule (key applies only to its own paper, same title; orphan keys apply to nothing — Fix 1's adoption is the single, explicitly-gated exception and it only fires when the key is provably the questions' own key), and the no-answers notice rules. Where a changelog fix overlapped an existing v2.0.3/v2.0.4 fix, the newer behaviour was kept unless a new test proved it wrong — no such conflict was found; F16 already passed on v2.0.4 before Fix 3.

## 5. Version bump

`pubspec.yaml`: `2.0.4+5400` → **`2.0.5+5500`**. versionCode derivation verified first: pubspec build number + 2000 (arm64 split-per-abi offset) → 5500 + 2000 = **7500** (v2.0.4 was 7400, confirmed by aapt2 on the released APK).

## 6. The one failure — pre-existing, date-dependent, OUT OF SCOPE (not fixed)

`test/history_groups_test.dart` — "groupAttemptsByDate buckets are Today / Yesterday / This Week / calendar date":
- Expected `'1 Nov 2026'`, actual `'01 Nov 2026'`.
- Mechanism: the test builds its expectation from `now.subtract(Duration(days: 20)).day` — **un-padded** ("1"). The implementation, `lib/widgets/history_groups.dart:86`, formats with `DateFormat('dd MMM yyyy')` — **zero-padded** ("01").
- Why it passed on 20 Nov and fails on 21 Nov: on 20 Nov, 20 days ago was 31 Oct (two-digit day — `dd` and `d` agree). Today (21 Nov), 20 days ago is 1 Nov (single-digit day — the padding difference shows). It fails on any run date where (today − 20 days) falls on days 1–9 of a month, and passes otherwise. It is **not** caused by this work: `history_groups.dart` imports only `dart:convert`, `intl`, and `models/question.dart` — it does not import any file touched here (`answer_key.dart`, `mcq_parser.dart`, `pdf_import_service.dart`, `ocr_deskew.dart`), and `question.dart` was not touched either. The test file is byte-identical to the v2.0.2 snapshot copy.
- **Not fixed** because it is outside this task's strict scope (upload → OCR → parse → key-matching path only; history UI is a different area) and the task forbids touching files outside that path. **Suggested fix for the parent to approve:** change `DateFormat('dd MMM yyyy')` → `DateFormat('d MMM yyyy')` at `lib/widgets/history_groups.dart:86` (matches the test's expectation and the `d MMM yyyy` convention already used in `profile_screen.dart:70`). Until then, **CI will show this same 1 failure** on the v2.0.5 release build.

## 7. What was NOT verified

- No `flutter build` on the VM (safety block) — the APK is built by GitHub Actions CI only.
- No Flutter device run — the user's phone remains the acceptance check (his three files + the Paper 60 photo re-test).
- No live Supabase/Cloud Run interaction — this change is parser-only; Phase 1 engine repo untouched.

## 8. Files changed (v2.0.5)

- `lib/services/answer_key.dart` — Fixes 1 (adoption), 2 (answer-line heading), 3 (bare key rows), 4 (chapter segments).
- `lib/services/mcq_parser.dart` — Fix 1 wiring + report text.
- `lib/services/pdf_import_service.dart` — Fix 5 deskew wiring (import + 7 lines).
- `lib/services/ocr_deskew.dart` — NEW (Fix 5).
- `pubspec.yaml` — version `2.0.5+5500`.
- `test/format_matrix_test.dart`, `test/unlabelled_paper_key_test.dart`, `test/ocr_deskew_test.dart`, `CHANGES_EXTRACTION_2026-11-21.md` — copied in from the recovered zip (unchanged).
- Temporary probe files `test/_probe_test.dart`, `test/_probe2_test.dart` were created for diagnosis and **deleted** before the version bump.
- **No fix left unimplemented.** No gate test was modified or weakened. No push, commit, or release was done — that is the parent's job after independent verification.
