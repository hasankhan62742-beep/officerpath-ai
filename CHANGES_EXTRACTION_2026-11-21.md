# Extraction fixes — 21 Nov 2026 (on top of v2.0.2)

Scope: ONLY the upload -> OCR -> parse -> key-matching path.
Nothing else was touched (auth, premium, payments, admin, push, theme,
test generator, Android config, pubspec are byte-identical to v2.0.2).

## Files changed (exactly 2) and added (4)
| File | Change |
|---|---|
| lib/services/answer_key.dart | 4 fixes (below) |
| lib/services/pdf_import_service.dart | 4 lines: deskew before table reconstruction + 1 import |
| lib/services/ocr_deskew.dart (new) | page-tilt estimate + correction, pure Dart |
| test/format_matrix_test.dart (new) | 23 book layouts, original sample questions |
| test/unlabelled_paper_key_test.dart (new) | Paper 66 heading-lost scenarios |
| test/ocr_deskew_test.dart (new) | deskew unit tests |

## Fixes
1. **Heading not read -> "no matching question" for every key entry**
   (your phone screenshot, Paper 66 PDF). Reproduced exactly in a Dart VM:
   with the "MODEL PAPER 66" line missing, 0 questions parsed and 100 key
   entries unmatched. Now the key is adopted for the unlabelled questions
   ONLY when safe (single paper, unique question numbers, one explicit key,
   >= 80% number overlap). Two papers merged with no headings are still
   refused (their numbers repeat) — never guessed.
2. **"Answer: (B)"** was read as a key HEADING (the "(B)" was stripped as a
   label), so the document was rejected. Fixed.
3. **Key rows without punctuation**: "1 B  2 A  3 D" and "1(B) 2(A)". Fixed
   (rows need >= 3 entries so a stray "5 A" is never a key).
4. **Chapter-wise keys**: "Answers: 1-B, 2-A, ..." printed after each
   chapter with numbering restarting. Each chapter is now its own segment.
5. **Tilted table photo** (IBES photo): the OCR geometry is de-tilted before
   rows are rebuilt. Measured tilt of your photo: median 1.45 deg, max 2.6
   deg (~37 px drift vs ~45 px row pitch).

## What was verified, and how
Real Dart VM (not Flutter). Pure-Dart parser tests were run with a small
flutter_test shim:
* Format matrix: 18/24 layouts correct before, 23/24 after (the 24th,
  "(1)" question numbers, is deliberately unsupported: "(1)" is also the
  numeric option marker and reading it would corrupt numeric-option books).
* Paper 66 fixture: 100/100 answered with heading present (unchanged) and
  now also with the heading missing (was 0).
* Existing tests that can run without Flutter: 25 files / 198 tests —
  identical results before and after (the same 5 failures appear in both
  runs and come from my harness lacking android/ and tools/ folders, not
  from the code). 60 other test files need Flutter plugins and were NOT run.
* Deskew: 2 deg synthetic tilt recovered exactly, row spread 41.9 -> 0 px;
  with perspective 54.5 -> 18.9 px; straight pages untouched.

## NOT verified (you / your CI must check)
* Nothing was compiled with Flutter or run on a device. Run:
  `flutter analyze` and `flutter test` (your GitHub Actions already does).
* The IBES table photo end-to-end on a phone: only the tilt correction is
  proven; ML Kit's real word boxes were not available here. If it still
  fails, send the new preview text and I will fix from that evidence.
* Perspective-heavy photos keep ~+/-10 px residual.

## Known extraction gaps NOT fixed in this delivery
* 100-page OCR cap (50 papers ~ 350 scanned pages) and no per-page save /
  resume.
* Scanned Word (.docx with images) still unsupported.
* Gemini truncation / block (finishReason) not handled; failed pages are
  still skipped silently.
* Urdu auto-detection on-device (ML Kit Latin first).
* Key-letter vs option-text cross-check.
* Real books were not tested (copyrighted); only layouts were.
