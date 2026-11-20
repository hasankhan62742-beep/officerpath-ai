# OCR two-column fix — camera-photo path (2026-11-20)

## Diagnosis (one paragraph)

The owner photographed a two-column book page (Paper 60, Data Entry
Operator, Q1–Q21, answers marked `*`) and the app parsed only 3 MCQs,
left 8 without answers, and skipped 18 blocks. The cause was the
camera OCR path, not the parser: `lib/services/pdf_import_service.dart`
`_runOcrWithMlKit` returned `RecognizedText.text` — ML Kit's raw
concatenation in its own block order — which interleaves the two
columns, so question stems got separated from their options and
asterisk answers got detached (Q11's stem sits at the bottom of the
left column while its options sit at the top of the right column, so
it could never parse). The parser's contract
(`lib/services/urdu_ocr.dart:111-113`) is "already-column-split OCR
text, left column first, then right" — the camera path never fulfilled
it, even though `splitColumnsForOcr` (same file, line 124) already
implemented the split and had tests, with zero production callers.

## What changed

- `lib/services/urdu_ocr.dart` — new pure helper `columnSplitOcrText`
  (after `splitColumnsForOcr`): sorts the ML Kit line boxes
  top-to-bottom (stable — same-row lines keep ML Kit's order) and
  splits them into left/right columns via `splitColumnsForOcr`
  (logic not duplicated). Fewer than 4 lines → returns the raw text
  unchanged (fail-open).
- `lib/services/pdf_import_service.dart` — `_runOcrWithMlKit` only
  (no other line in the file touched): walks `recognized.blocks` →
  `lines`, collects each non-empty line as
  `({text, x: box.left, y: box.top, width: box.right - box.left})`,
  passes them through `columnSplitOcrText`, and falls back to
  `recognized.text` if extraction throws or yields <4 lines.
  Temp-file handling and `recognizer.close()` are exactly as before.
  Note: in `google_mlkit_text_recognition` 0.16.0 `TextLine.boundingBox`
  is a non-nullable `Rect`, so there is no null-box case to skip; the
  try/catch around extraction is the fail-open guard.
- `test/ocr_two_column_test.dart` — new, 7 tests (see below).
- No other files touched. No commit, push, release, version bump, or
  CI trigger. Boundaries respected: `upload_screen.dart`,
  `test_screen.dart`, `result_screen.dart`, `question.dart`,
  `test_generator.dart`, `mcq_parser.dart`, `storage_service.dart`
  and all payment/admin-panel files untouched.

## Tests

New file `test/ocr_two_column_test.dart` — **7/7 passed** (plus the 10
existing `test/urdu_ocr_test.dart` tests still pass, 16/16 combined
before the marks test was added):

1. Interleaved left/right lines mimicking the photo come back left
   column first, then right (exact full-output assertion).
2. Q11-style case: stem in the left column, its options in the right
   column — the stem now comes BEFORE its options, and `(D) AVG*`
   stays attached.
3. Same-row lines keep ML Kit's order (stable y-sort).
4. Answer marks survive the split: synthetic two-column lines
   carrying `*` and `✓` marks (`(D) AVG*`, `(D) Slide Show Menu*`,
   `(C) Tools Menu ✓`) — the split output still carries each mark on
   its own option, in the right column and after its stem.
5. Single-column input in reading order is unchanged.
6. Out-of-order single-column lines are reordered top-to-bottom.
7. Fallback: 0, 1, or 3 lines return the raw text unchanged.

Full suite + analyze: see the phase-2 line below (one run covers
the final code).

## Table reconstruction (phase 2 — 20 Nov 2026, this session)

Four table photos in total. The camera path detects a table-like
page FIRST (before the column split — a table spans the full width
and splitting it would destroy the rows) and rebuilds it from ML
Kit ELEMENT boxes into `'|'`-separated lines, the exact shape the
parser's table pass already consumes for PDF text.

### What changed

- `lib/services/urdu_ocr.dart` — `reconstructTableText` (lines
  283–549, rebuilt for the wrapped-row variants): visual rows by
  y-overlap → cells by x-gaps → column bands from MULTI-CELL rows
  only (a centred heading must not become a band) → LOGICAL-row
  grouping: a row is new when it carries a serial number in the
  serial band (the leftmost band with ≥3 bare-number cells — the
  numbers themselves are ignored, the book misnumbers rows), or,
  with no serial band, when it has ≥5 cells; a visual row without
  a serial CONTINUES the previous logical row, appending each cell
  to its same-band cell (stems and options wrap over 2–4 visual
  lines in these books). A header row ("Sr.# | Question | A | B |
  C | D | Ans") has no serial but follows a title, not a data row,
  so it still starts a new row. One-cell rows: title at page top;
  a tail merges into the SAME band's cell (not necessarily the
  first — an option can wrap on its own line) when immediate,
  within 20 px of the band start, and not heading-shaped; a
  heading-shaped line is its own line even when it starts exactly
  on a band; other lettered 1-cell rows (footer "Page 5 of 71",
  "Scanned with CamScanner") are own lines; bare numbers are
  dropped. New pure helper `_looksLikeHeading` (lines 194–232:
  ≤5 words, ≤45 chars, title-cased ignoring small words and `/`,
  never ending in `.`/`?`/`!` — the trailing-punctuation rule is
  what saves a capitalised tail like "MS Word?" from being read as
  a heading).
- `lib/services/pdf_import_service.dart` — unchanged in this phase:
  `_runOcrWithMlKit` (lines 782–784) already tries
  `reconstructTableText` first and column-splits only when it
  returns null.
- `test/ocr_table_reconstruct_test.dart` — 7 tests (was 5): new
  interjection (Q230–257) and computer-p5 (Q67–81) groups, with
  synthetic element data mimicking the photos.
- `test/ocr_table_parser_test.dart` — the adjective-table
  integration (6 questions, keys correct) now loads and passes; it
  was blocked by the sibling agent's dangling import in
  `lib/services/answer_key.dart:59`, which that sibling fixed
  (~09:51 PKT, now `import '../models/question.dart';`).

### Test results (phase 2)

- Standalone harness `/tmp/ocr_harness.dart` (the pure functions
  extracted verbatim from `urdu_ocr.dart`, run with plain `dart`):
  **ALL 59 CHECKS PASSED** — the 31 earlier checks still pass (no
  regression) plus 28 new ones (interjection exact output, 8-cell
  rows, misnumbering, heading guard, computer-p5 exact output,
  7-cell rows, "MS Word?" merge).
- `flutter test test/ocr_table_reconstruct_test.dart`: **7/7
  passed** (adjective, Sr.# p1, prose-null, too-few-null,
  interjection, computer-p5).
- `flutter test test/ocr_two_column_test.dart
  test/ocr_table_parser_test.dart test/urdu_ocr_test.dart`:
  **18/18 passed** (7 + 1 + 10).
- `flutter analyze` on the four OCR files
  (`lib/services/urdu_ocr.dart`, `test/ocr_table_reconstruct_test.dart`,
  `test/ocr_table_parser_test.dart`, `test/ocr_two_column_test.dart`):
  **No issues found.**
- OCR total in Flutter: **25/25 passed.**

### Sr.# parser probe — verdict (temp test, deleted after running)

The earlier static prediction (0 questions for the Sr.# layout,
`_optionRe` rejecting "A. Latin") was WRONG. A temporary probe fed
the exact reconstructed `'|'` lines for all four tables into the
existing `parseTableFormat` and printed the outcome:

- Sr.# p1 ("Computer Most Important Questions"): **3/3 questions**,
  correctIndex 0/2/1, options stripped of their "A." markers
  ("Latin", "German", …), `answerSource='key'`. The table pass
  strips the markers itself.
- Computer p5 (Q67–81): **3/3 questions**, correctIndex 0/0/2,
  `answerSource='key'`; footer lines produce nothing.
- Interjection (Q230–257): **9/9 questions**, every correctIndex
  correct, `answerSource='key'`; all four section headings produce
  nothing (skipped cleanly). One parser note:
  "Table Sr.# out of sequence (162 after 253) — out-of-sequence row
  numbers cannot be trusted, so those rows carry no number for key
  matching. They can still be answered by hand." The misnumbered
  rows keep their Ans-column answers, but lose their number for
  key matching.
- Adjective (re-probed): **6/6 questions, 0 pending.**
- Wart, parser-side (out of bounds for this task — needs a
  decision in `mcq_parser.dart`): the Sr.# tables yield **1
  spurious PENDING question** — the title line ("Computer Most
  Important Questions") paired with the header row's A–D as
  options. Adjective and interjection tables: 0 pending.
- Subject: Sr.# / computer / interjection rows come out
  `Subject.gk` (default); only the adjective/article table maps
  to `Subject.english` via the title/label rule. Parser-side,
  existing behaviour, not changed here.

Full suite (`flutter test`, 20 Nov 2026 ~10:10 PKT, expanded
reporter, 3 min 54 s): **784 passed, 5 skipped, 13 failed.**
None of the 13 is in the OCR files — every OCR test passed in
the run (0 failures across `ocr_two_column_test`,
`ocr_table_reconstruct_test`, `ocr_table_parser_test`,
`urdu_ocr_test`). The 13: 7 in the new
`paper_66_67_regression_test` (the PPSC-66/67 gate — it asserts
the baseline fixes wave 2 has not implemented yet, so those fail
by design until then), 2 in `universal_formats_test` + 1 in
`realfile_counts_test` (real-file documented counts), 1 in
`examveda_scale_test`, 1 in `failure_guidance_test`, 1 in
`phase_a_gaps_test`. The 5 upgrade-test failures from the 09:35
run are gone. One earlier full run hung (flutter_tester idle at
~1% CPU after 13 min while sibling runs contended for the VM)
and was killed; the re-run with the expanded reporter completed
in under 4 minutes.
Full `flutter analyze`: **20 issues, all info-level
`avoid_print` in `test/ppsc66_baseline_test.dart`** (the baseline
agent's file); zero errors, zero warnings, nothing in the OCR
files.

## Tesseract verdict (stated limitation)

`TesseractOcr.extractText` in `tesseract_ocr` 0.6.0 is the package's
only API and returns a plain `Future<String>` — no line coordinates,
no TSV/word boxes. So the same column-split fix **cannot** be applied
to the Tesseract path. It stays as-is: PSM 3 does its own page
segmentation internally, but the app cannot reorder it. This matters
less than it sounds for this photo: the page is Latin-only, so the
Tesseract tier does not even run for it (it only runs when the page
has Urdu or the user picked Urdu) — ML Kit is the tier that read this
page, and that is the tier now fixed.

## The bold limit (verified from the ML Kit API)

ML Kit returns plain text plus geometry only. Verified in
`google_mlkit_text_recognition` 0.16.0: `RecognizedText` carries
`text` + `blocks`; `TextBlock`/`TextLine`/`TextElement` carry `text`,
`boundingBox` (`Rect`), `cornerPoints`, `recognizedLanguages`, and
(`TextElement` only) `confidence` and rotation angle. **There is no
font, weight, or style field anywhere — bold print cannot be detected
from a camera photo.** Bold-marked answers in photos therefore fall
to the existing no-answers notice / manual-answer / answer-key flows,
exactly as the owner specified. No bold detection from pixels was
attempted.

## NOT verified

- ML Kit runs only on a real device. The synthetic-line tests prove
  the wiring and the ordering; the proof is the owner's phone re-test
  with the same photo (IMG_20261119_151817_041.jpg) in the next build
  (v2.0.1): Q11 and the other cross-column questions should parse
  with their `*` answers attached. Perspective skew or ML Kit merging
  lines across the gutter could still weaken the split on a tilted
  photo — the re-test is what will show that.
- The Gemini path was left alone (its prompt already asks for
  left-column-first order).
- Table photos: ML Kit's real segmentation on a device is unverified
  for all four table photos — the proof is the owner's phone re-test
  with the exact photos (Adjective/Article table, Computer p.1,
  Interjection Q230–257, Computer p.5): headings, multi-line wraps
  and the Ans column must survive a real camera read, including
  perspective skew.
- Clipped-serial limit (reconstruction, documented in the code):
  a data row whose serial number was clipped off the page edge (or
  missed by ML Kit) looks exactly like a wrap continuation of the
  row above, so it merges into that row instead of starting a new
  one. Nothing in the geometry can tell the two apart.
- A capitalised stem tail with no trailing punctuation (e.g.
  "Quaid-e-Azam" as a wrap tail) can be misread as a heading and
  emitted as its own line instead of merging — a split stem, not a
  corrupted option cell; the guard errs on the heading side.
- The spurious pending title question on Sr.# tables (see the probe
  verdict above) is parser-side and unfixed here.
