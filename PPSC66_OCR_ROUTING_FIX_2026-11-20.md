# PPSC-66 OCR Routing Fix — v2.0.2 (20 Nov 2026)

## What the owner saw (v2.0.1, his phone, 20 Nov 14:05 PKT)

He uploaded his exact 3 files and got **0 MCQs** from all three. The
"No MCQs found" dialog for `ppsc_paper_66.pdf` said:

- "Read 82 characters, but no question matched the formats"
- "Pages parhe gaye: 7 (text pages: 7, OCR pages: 0)"
- "Answer Key: nahi mili"
- "What was actually read: CamScanner" ×7

## Root cause (confirmed in code, then reproduced in a test)

`lib/services/pdf_import_service.dart`, `importPdf` (old lines ~242–248):
a page counted as a "text page" whenever its extracted text was merely
non-empty (`t.trim().isNotEmpty`), and only EMPTY pages were sent to
OCR. The PPSC-66 text layer holds exactly one word per page — the
"CamScanner" watermark — so all 7 pages counted as text pages and
**zero pages went to OCR**. The parser then received 82 chars of
watermark text and found nothing. The OCR machinery itself (ML Kit /
Tesseract / Gemini tiers) was never reached; the ROUTING decision was
broken.

Reproduction evidence (real file, `pdftotext`):

```
$ pdftotext ppsc_paper_66.pdf - | wc -c        → 91 chars total
per page (non-space chars): p1–p7 = 10 each  → "CamScanner" per page
```

Reproduction test (written BEFORE the fix, failed as expected):
`test/pdf_ocr_routing_test.dart` — "watermark-only scan" failed with
`textPages` 7 (expected 0); "same short header on every page" failed
with `textPages` 3 (expected 0). The other three tests passed pre-fix.

## The fix (generic — NO watermark word is hardcoded)

File: `lib/services/pdf_import_service.dart` — routing in `importPdf`
plus two new static helpers.

**Rule 1 — word-count bar.** A page is a text page only when its text
layer carries at least `minTextLayerWords = 10` words
(`pageTextIsContent`). A genuine question page carries a stem plus
four options (~15+ words even for a single short MCQ — counted
item-by-item from the book), so every complete question page stays a
text page. A watermark/header-only page (1–9 words) goes to OCR.

**Rule 2 — repetition = stamp.** `stampPages(pageTexts)` flags pages
whose WHOLE text layer is the same short text on at least 3 pages and
at least half the document, under 50 words. No stamp text is named —
the rule is repetition + brevity only, so it holds for "CamScanner",
"Scanned with…", a running book title, or any other stamp. A genuine
question page is never byte-identical to most other pages, and a full
page of questions is far longer than 50 words, so a real page cannot
trip this.

Pages failing either rule go to OCR exactly like empty pages, through
the existing tiers (ML Kit by default — no Gemini key, no ticked
checkbox needed). `textPages` in `PdfImportResult` (and therefore the
NoMcqsDialog "text pages / OCR pages" line) is now honest: a
watermark-only page is never reported as a text page.

Accepted edge, stated plainly: a page holding only a short stem
fragment (options on the next page, under 10 words) now goes to OCR
unnecessarily. OCR re-reads the same words off the rendered page, so
the cost is one extra OCR pass — never a lost question.

```dart
final stamps = stampPages(pageTexts);
bool isTextPage(MapEntry<int, String> e) =>
    pageTextIsContent(e.value) && !stamps.contains(e.key);
final textPages = pageTexts.entries.where(isTextPage).length;
var ocrTargets = pageTexts.entries
    .where((e) => !isTextPage(e))
    .map((e) => e.key)
    .toList();
```

No other routing site exists: the only `trim().isNotEmpty` page
decision in `lib/` was this one (verified by grep); `extractKeyText`
for PDFs goes through the same `importPdf`, so attached keys benefit
too. The extraction-only spec is unchanged — no answers are invented.

## Counts for all 3 files — before / after

All "after" numbers are from the real import entry points with the
OCR tier stubbed (ML Kit cannot run on the VM); the stub returns the
real Gemini vision OCR text of each file (see "How the photos were
tested"). Full counts were verified item-by-item, not re-baselined
blindly.

### 1. ppsc_paper_66.pdf (7-page CamScanner scan)

| | Before (v2.0.1, owner's phone) | After (test, stub OCR = Gemini fixture text) |
|---|---|---|
| text pages | 7 | **0** |
| OCR pages targeted | 0 | **7 (all)** |
| parsed | 0 | **100** (Paper 66, all with key answers) |
| key entries applied | 0 | **100** |
| key sections found | 0 | **1** |
| Paper 67 (p7, no key in PDF) | — | **10 pending, never fabricated** |
| false positives | — | **0** |

The 100/100 + key 100 matches the already-verified Paper 66/67 gate
(`test/paper_66_67_regression_test.dart`, 7/7). The OCR text used is
the existing fixture `test-fixtures/ppsc66/ocr-p1.txt` … `ocr-p7.txt`
(Gemini `gemini-3.5-flash-lite`, the app's own OCR prompt).

### 2. Interjection table photo Q230–257

| | Before (v2.0.1, owner's phone) | After (test, stub OCR = fresh Gemini vision OCR of the photo) |
|---|---|---|
| parsed | 0 | **30** |
| answerless / pending | — | **0** |
| skipped | — | **0** |

30, not 28: Q230–Q257 is 28 numbers, but the book inserts two extra
misnumbered rows (162, 164 after 253), so the photo holds 30 physical
rows — all 30 parse with answers from the Ans column (verified
item-by-item in a probe run). The parser emits its usual note that
the out-of-sequence numbers cannot be trusted for key matching.

### 3. Computer table photo Q67–81 (p5/71)

| | Before (v2.0.1, owner's phone) | After (test, stub OCR = fresh Gemini vision OCR of the photo) |
|---|---|---|
| parsed | 0 | **15** |
| answerless / pending | — | **0** |
| skipped | — | **0** |

## How the photos were tested (and what that proves — and does not)

- **Routing is not the photos' problem.** The upload screen already
  routes JPG/PNG to `PdfImportService.importImage`, which ALWAYS OCRs
  (no text-layer decision exists on that path). The photos failed on
  the phone somewhere inside ML Kit OCR → table reconstruction →
  parse, not in routing.
- **Image path + parser: PROVEN on VM.** `importImage` with a stub OCR
  returning fresh Gemini vision OCR text of each photo
  (`test-fixtures/ppsc66/ocr-table-interjection-gemini.txt`,
  `ocr-table-computer-gemini.txt`, generated 20 Nov with the app's own
  model + prompt) parses 30/30 and 15/15 with 0 pending. So when OCR
  text is good, the image path and the table parser work.
- **Table reconstruction on real OCR geometry: TESTED — Tesseract
  boxes are not a valid stand-in for ML Kit.** Tesseract 5.3.4 was
  installed on the VM and run (TSV word boxes) on both photos at
  1200px wide: interjection 554 words, computer 486 words.
  `reconstructTableText` on those boxes produced mangled rows
  (interjection: 15 lines, rows merged across the page; after
  dropping rule-fragments and conf<30 words: 22 lines, parsed 2
  garbage questions; computer: 11 lines, parsed 1 garbage
  question). Root cause is the INPUT, not the reconstruction logic:
  Tesseract at this resolution reads the printed table RULES as
  '|' words with tall boxes (up to 75px vs 10px median height —
  tall boxes merge rows in the y-overlap grouping), merges words
  across column gutters ("Aslamhastaken"), and misreads small print
  heavily (119/554 interjection words conf<30). ML Kit on the phone
  returns text-only elements at full camera resolution and does not
  return rules as text — so Tesseract-on-VM cannot judge the phone
  path either way. Reconstruction on CLEAN geometry remains proven
  (synthetic elements: 9/9 interjection, 3/3 computer p5, from the
  20 Nov OCR work). Reconstruction on real phone ML Kit geometry is
  phone-unverified — the owner's v2.0.2 re-test is the proof.
- **On-device ML Kit read quality: NOT verifiable on the VM.** If the
  phone's ML Kit read of either photo is poor (faint watermark,
  small print, photo angle), the parse still fails no matter how good
  the routing is. The owner's phone re-test on v2.0.2 is the proof.
- **No speculative fallback was added.** When `reconstructTableText`
  returns null, the code column-splits the page — which would destroy
  a table (stems left, options right). A "table-like" guard was
  considered and REJECTED: the obvious signal (lines starting with a
  bare number) also fires on genuine two-column question pages, so
  the guard would risk regressing the proven Paper 60 two-column
  path. Do not add such a guard without real ML Kit element data from
  a failing phone photo.

## Regression tests (new file `test/pdf_ocr_routing_test.dart`, 5 tests)

1. Watermark-only scan → all 7 pages OCR'd; parsed 100,
   keyEntriesApplied 100, keySectionsFound 1, Paper 67's 10 pending.
2. Genuine short text page (one complete MCQ, ~17 words) is NOT sent
   to OCR; only the empty page is (`textPages` 1, `ocrPages` [2]).
3. Same 10-word header repeated on all 3 pages → all 3 OCR'd
   (repetition rule; no watermark word named).
4. Interjection photo through `importImage` → 30 parsed, 0 pending.
5. Computer photo through `importImage` → 15 parsed, 0 pending.

No existing test was weakened. New Gemini OCR fixture texts for the
photos are committed as test data alongside the existing PPSC-66
fixtures (they are test inputs, not user data).

## Verification

- New tests: 5/5 pass (`test/pdf_ocr_routing_test.dart`).
- Full suite: **843 passed, 5 skipped, 0 failed** ("All tests
  passed!", second full run, exit 0). Before this change
  (parent-verified 20 Nov 12:06 PKT): 838 passed, 5 skipped,
  0 failed — exactly +5 new tests, no other count moved, no
  existing test weakened. NOTE: the first full run after the fix
  showed 842 passed / 1 failed; the immediate re-run with NO code
  change passed 843/5/0. That single failure was flaky, not a
  regression — but it could not be identified from the truncated
  first-run output, so if it recurs, capture the full log and name
  the test before concluding anything.
- `flutter analyze`: **0 issues**.

## Still unverified on a real phone

1. The whole fix end-to-end: install v2.0.2, upload the real
   `ppsc_paper_66.pdf` — expect "OCR pages: 7" in the preview and
   100 MCQs (Paper 66) + 10 pending (Paper 67). If ML Kit's read is
   much worse than the Gemini fixture text, counts will be lower —
   that is an OCR-quality result, not a routing result.
2. Both table photos on the phone (ML Kit read + table
   reconstruction on real element geometry).
3. The Paper 60 two-column photo re-test (acceptance check from
   20 Nov) — unaffected by the routing change by construction (a
   camera photo goes through `importImage`, which always OCRs), but
   it is still the acceptance check for the column-split fix.
4. A genuine text PDF with a very short page (stem-only page under
   10 words) — expect one extra OCR pass, same questions.
