# Phone ML Kit — real cause (v2.0.4 on the owner's phone)

**Date:** 20 Nov 2026 (investigation run 20 Nov, evening PKT)
**Build under test:** v2.0.4 (release id `452747285`, commit `5e820936`) — confirmed installed on the owner's phone 21:18 PKT.
**Scope:** PPSC Paper 66 PDF (`ppsc paper 66.pdf`, 7-page CamScanner scan, 100 MCQs + trailing key) and the Computer table photo (Q67–81, 15 rows). ML Kit path only — no Gemini key in Settings (owner's decision; his 1–11 K/s connection could not complete Gemini anyway).
**Status of this work:** investigation complete; one fix implemented in the working tree, **NOT committed, NOT pushed, NOT released**. Full suite green (886 passed, 5 skipped, 0 failed), `flutter analyze` 0 issues. Parent decides next step.

## Verdict — bottleneck is BOTH, in sequence

1. **PRIMARY: OCR fragmentation.** The phone's ML Kit read of the two-column CamScanner scan is so fragmented that only **1 of 100 questions** forms a parseable question (45 fragments detected, 146 blocks skipped). Even with the identity gate removed, only that 1 question would gain an answer — and that answer is probably wrong (see Q94 below).
2. **SECONDARY: the paper-identity gate.** The key IS detected on the phone (39 entries) but **0 are applied**, because the questions' paper label never matches the key's explicit "Paper 66" label. The gate is doing its designed job — weakening it risks cross-paper contamination, which is forbidden — so any relaxation needs a deliberate policy decision, not a unilateral code change (see §12).

Render scale is **exonerated**. The column split engages on real OCR geometry but **cannot un-merge lines** ML Kit already fused. The table reconstruction is **OCR-engine-sensitive**: it engaged on the phone (2 table rows parsed) but its columns disagreed with the option markers, so rows went pending.

## 1. Phone evidence #2 — PPSC-66 PDF (21:38–21:39 PKT, the primary evidence)

- **Parsed 1 MCQ** (Standard blocks 1, One-line 0, Q&A without options 0; Answers: 1 answer-line se). Verification: 1 verified, 0 unverified, avg confidence 100%.
- Amber box: *"Key mili, jawab kisi sawal se nahi lage — kul 45 sawal, 1 ke jawab lage, key ki 39 entries mili (0 lagi, 39 be-jawab), 44 sawal baghair jawab."*
- Validation box: "Paper 66 key entry 1 — no matching question", entries 2, 21, 22, 3, *"**…aur 122 aur.**"* (≈127 flagged in total — reconciled in §3).
- *"Scanned pages read with OCR: 7 (English OCR: device (ML Kit))."*
- *"44 question(s) ke jawab nahi mile (options hain, answer nahi)."*
- *"Key 'Paper 66' mili, lekin is PDF mein Paper 66 ke sawal nahi — key nahi lagayi."*
- *"Skipped 146 block(s) (missing options/answer)."*
- *"Not imported: 'Change of voice:' — only 2 other distinct answer(s) in this book, need 3 to build 4 options."* (twice) + *"'(B) Muzzle:'"* — the q-only pool is starved.
- *"Block 1: skipped — has 4 options but no usable answer."* (Blocks 1, 2, 3 — same.)

The 21:15 PKT run of the **same file** gave the same 1 MCQ + 44 pending but with the **green no-answers notice** (key section never opened), while the 21:38 run detected the key. Same file, same counts, different key status: **ML Kit's line segmentation varies run to run** — in one run the key heading merged with the next line (no section), in the other it stood alone (section found). That run-variance is itself evidence for the heading-merge failure mode fixed in §10.

## 2. Phone evidence #1 — Computer table photo (21:26–21:27 PKT)

File `17951489282567116625189920223603.jpg` (Q67–81, 15 rows, Sr.# | Question | A–D | Ans columns).

- **Parsed 2 MCQs** (Table rows 2, Answers: 2 key se; 2 verified, 0 unverified, avg confidence 100%).
- *"Jawab: Koi jawab key nahi mili — kul 4 sawal, 2 ke jawab lage, 2 sawal baghair jawab."* — **only 4 questions detected at all from 15 rows.**
- *"Scanned pages read with OCR: 1 (English OCR: device (ML Kit))."*
- *"Skipped 1 block(s) (missing options/answer)."*
- *"Table row 'bar and then click Header and Footer.': option markers disagree with the columns (e.g. a 'B.' marker in the A column) — the answer cannot be verified, so the row is left pending."*
- *"Block 1: skipped — has 4 options but no usable answer."*
- Paper identity: **"Paper 1 (unnumbered)"** — no title detected.
- The one shown MCQ (Q68): stem *"68 correctly view To verify or display that on the the the page, note document switch text is to positioned in print preview"* — words in wrong order (column/reading-order interleave); answer B "print layout" correct via key. Another stem: *"67 Microsoft From where Word? you can Question access Save command in"*.

**VM/Gemini control for the same photo: 15/15 parsed.** The phone's ML Kit read is badly jumbled: stems have words in the wrong order, option markers land in the wrong columns, and the reconstruction runs but its columns disagree with the markers. Same failure class as the PDF collapse.

## 3. The 39-vs-127 reconciliation (proven from code)

The two numbers count different things:

- **39 = key entries.** `documentStatusLine` (`lib/services/document_status.dart:152`) computes `keyEntries = keyEntriesApplied + unmatchedKeyEntries.length` → 0 + 39 = 39. `unmatchedKeyEntries` is built in `lib/services/mcq_parser.dart` (~3590–3602) from `segmented.keyEntries` remaining after the join.
- **127 = validation issues.** `validateParseResult` (`lib/services/parse_validation.dart`) builds issues as **39 unmatched-key warnings + 44 `answerPending` infos + 44 `questionsMissingAnswers` infos = 127**. `questionsMissingAnswers` is built 1:1 from pending via `addPending` → `noteMissingAnswer` (`mcq_parser.dart:2227–2242`; "addPending is the only way to create a pending question"), so **the validator double-counts each pending question**. `ValidationReportBox` (`lib/screens/upload_screen.dart:1624`) orders warnings first, then infos, capped at 5 shown — hence the first 5 shown are all key-entry lines.
- **True distinct issues = 83, not 127.** This is a proven minor reporting bug — **flagged here, NOT fixed in this pass** (see §11); existing tests may pin the current counts, so the parent decides.

## 4. The one "verified" question is probably WRONG (Q94)

The single parsed question (Page 5): stem *"ansrer ôf the following"* (garbled: "ansrer" for "answer", "ôf" for "of"), options A *"He exclaimed that he had suffered heavy losses"* / B *"He exclaimed that he suffered heavy"* / C *"He xclaimed with sorrow that he had oSuffered heavy losses bo"* / **D "Nono of these" (answer-line se)**.

Verified against the Gemini fixtures (`test-fixtures/ppsc66/ocr-p5.txt` lines 108–110; `ocr-p7.txt` line 29): this is Paper 66 **Q94**, whose options match verbatim — and the book's key says **94 = (C)**, while the phone's answer is **D** (from a spurious answer line). **The phone's only "verified" success contradicts the book's key.** Nothing on the phone may be treated as verified on the strength of this one question.

## 5. Check 1 — render scale: EXONERATED

`lib/services/pdf_import_service.dart:237`: `ocrRenderWidth = 1600`, JPEG quality 85 (line 427) → a letter page renders at ≈ **188 DPI**, **sharper** than the 1105px (~130 DPI) Gemini renders that scored 100/100. Low resolution is not the bottleneck; the phone's ML Kit read is bad at a resolution where Gemini reads perfectly.

## 6. Check 2 — column-split engagement (code trace)

`importPdf → render → _runOcrWithMlKit` (`pdf_import_service.dart` ~844–916) → `lib/services/urdu_ocr.dart`:

- Builds `lines` ({text, x, y, width}) and `elements` from ML Kit blocks → lines → elements.
- `reconstructTableText(elements)` runs **FIRST** — if non-null, table text is returned and the column split never runs; else `columnSplitOcrText(recognized.text, lines)`; any exception → raw `recognized.text`.
- `columnSplitOcrText`: `lines.length < 4` → raw text (fail-open).
- `splitColumnsForOcr` (`urdu_ocr.dart:125`): split = widest gap between sorted line starts in the middle third of page width; **`bestGap < 40` (px at 1600px render width) → lines returned in y-sorted order — i.e. INTERLEAVED for a two-column page, not column-split.** The split silently no-ops when ML Kit's line starts don't form a clean middle gap.
- The Tesseract tier returns a plain String (no boxes → no column split, no table reconstruction on that path).

On real Tesseract geometry (Probe C) the column split **does** engage (p1, 109 lines, at both scales). It cannot repair lines ML Kit already merged across columns — the merge happens inside ML Kit's segmentation, before the split sees the text.

## 7. Check 3 — real-OCR probes (Tesseract 5.3.4, fresh CLI text, REAL `importPdf`/`importImage` paths)

Tesseract-on-VM is a **lower bound** on parser robustness, NOT the phone's exact text — Tesseract reads this scan worse than ML Kit in places. Temp probe test created, then deleted after recording; outputs `/tmp/probeA.txt`…`/tmp/probeD.txt`; fixtures kept at `test-fixtures/ppsc66/ocr-tess-p1..p7.txt`, `ocr-tess-table-computer.txt`, `ocr-tess-table-interjection.txt`; TSV word boxes in `/tmp/tessprobe/`.

- **Probe A (PPSC-66, Tesseract text): parsed=2, pending=25, keySectionsFound=1, keyEntriesApplied=0, unmatchedKeyEntries=0, status=answerKeyDetected.** The key heading IS found on Tesseract text, but the gate withholds all entries: keyPaperReport *"Key 'Paper 6' nahi lagayi — Key carries no paper identity and the document holds 2 papers"*. The "2 papers" are ONE paper split by OCR: p1 heading read "MODEL PAPER 6" (66→6; `ocr-tess-p1.txt:1`), p6 line 133 has "Model Paper 66", p7 reads "ODEL: PAPER 67," (M dropped). Only 27 total questions detected vs the phone's 45.
- **Probe B (table photos, Tesseract text): computer parsed=1** (status misleadingly "answersFullyVerified"), **interjection parsed=14** (vs Gemini 15/30; phone ML Kit 2/—). Tesseract reads the computer photo far worse than ML Kit.
- **Probe C (real Tesseract TSV geometry):** p1 column split engages at both scales (1.0 and 1600/1105, 109 lines); p6 `reconstructTableText` does NOT misfire at either scale (738 elements, returns null — the ≥5-cell wide-row guard holds on prose); computer photo `reconstructTableText` returns **NULL** on Tesseract geometry (375 elements) — its guards (≥3 wide rows, ≥5 shared bands, ≥half elements in wide rows, serial band ≥3 bare numbers) are not satisfied by real noisy OCR boxes. On the phone, the reconstruction DID engage (2 table rows parsed — '|' lines can only come from it, since ML Kit raw text has no '|'), but its rows are jumbled (see §2). Serial-band candidates in computer TSV: only ~7 plausible numbers in the leftmost band, several misread ("7)", "9", "4").
- **Probe D (key machinery on Tesseract text):** `parseKeyEntries(p6)` = **80 entries** (1–78 all present + phantoms 97/98/99; entries 1–2 are Q98 explanation text when run on the whole blob, not the section); `parseKeyEntries(p7)` = **27** (85–96, 100 present; 79–84, 97–99 lost to misreads; phantoms 1088/1258/1335/2021 are year numbers from Paper 67 explanation text). **The entry machinery is ROBUST on noisy text — entries exist; the failure is downstream** (gate withholds / heading fails).

## 8. Check 4 — key detection on noisy text

Heading fragility **proven**: `isAnswerKeyHeading` returns true for clean "ANSWER KEY: Model Paper 66", standalone "ANSWER KEY:", colon-dropped, lowercase — but **FALSE** for merged-with-first-entry ("ANSWER KEY: 1. (B) Broke out"), merged-with-subhead ("ANSWER KEY: English Grammar"), and "KEY" misread as "KEV".

Identity-gate mechanism (`mcq_parser.dart` ~3870–3881): `papersWithQuestions` from `segmented.questionLines`; for each `explicitKeyPapers` entry not in it → *"Key 'Paper 66' mili, lekin is PDF mein Paper 66 ke sawal nahi — key nahi lagayi."* The key heading survived (explicit "Paper 66") but the questions' paper label differs (paper heading misread as "Paper 6" / unnumbered) → **MISMATCH → all 39 entries withheld → applied=0, unmatched=39.**

This also explains the 21:15 vs 21:38 difference: in the 21:15 run the heading merged (no section at all → green notice); in the 21:38 run it stood alone (section found, gate withheld). The v2.0.2 phone run's ~128 key entries vs v2.0.4's 39 is the same run-variance in ML Kit segmentation, not a code regression — the key entry count is whatever survives that run's line breaks.

## 9. Check 5 — table photos: proven vs unknown

**Proven:** the phone's ML Kit element geometry is jumbled in a way the reconstruction cannot repair — proven by the phone's own diagnostic output (jumbled stems + marker/column disagreement, §2). The reconstruction is OCR-engine-sensitive: it returns null on real Tesseract geometry of the same photo (Probe C) yet engaged on the phone's ML Kit geometry.

**Unknown:** the exact element boxes the phone's ML Kit produced for PPSC-66 and for the table photo. No fix for the table path is possible without the phone's actual ML Kit element data.

## 10. The fix — merged-heading opener (in working tree, NOT committed)

**What:** `lib/services/answer_key.dart` — new `keyHeadingRemainder(line)` + `_looksLikeKeySubhead` (≥3 chars, ≤45, title-cased, no trailing `./?/!`, single letter rejected) + hook in `segmentLines` right after the `isAnswerKeyHeading` block: opens the section, feeds the remainder back as the first content line, applies the explicit-paper rule unchanged. `isAnswerKeyHeading` itself is **UNCHANGED** (its 5 other callers in `book_structure.dart`/`mcq_parser.dart` use it to exclude key sections — untouched).

**Scope:** this fixes the 21:15 run's failure mode (key section never opens) only. It does NOT change the 21:38 run's outcome (key detected but 0 applied — that needs question-parse robustness + a policy decision on the identity gate, §12).

**Before/after (new tests, `test/answer_key_test.dart`):** before the fix, both merged tests failed (Expected <1>, Actual <0> for `keySectionsFound`); prose test passed. After the fix, all tests in the file pass. Probe A/B numbers **unchanged** post-fix (as predicted — Tesseract heading is standalone, hook never fires; gate still withholds).

### The regression the fix caused — and its repair (also in working tree)

First version of `keyHeadingRemainder` broke **17 tests** (full suite 868 passed, 5 skipped, 17 failed; log `/tmp/full_suite_after_fix.log`). Failures: 12 `parser_signals_test`, 2 `universal_formats_test`, 1 `realfile_v12_test` (F1 PPSC 40/40: Expected <40>, Actual <2>), 1 `examveda_scale_test` (3212/1688), 1 diagnosis (Pace REAL FILE 6). Diagnosed root cause (from the regex + failure pattern): the core regex alternative `answers?` matched the bare word **"Answer"** (`s?` optional), so lines like **"Answer: Option C"** — the standard per-question answer line in Examveda/Pace books — matched the core, and the remainder "Option C" passed `_looksLikeKeySubhead` (title-cased words) → a spurious key section opened mid-document, swallowing the answer line and subsequent question lines. `_keyCoreRe` is safe only because it is whole-line anchored (`$`); the prefix version removed that protection.

**Repair:** the bare `answers?` alternative was dropped in favour of the **plural** `answers` (and `correct\s*answers` likewise requires the 's'). A merged heading always carries the key word ("Answer Key"), the sheet word, or the plural ("Answers", "Correct Answers"); a lone singular "Answer:" is an answer line, never a heading. **Accepted trade-off, documented in the code comment:** a merged bare-"Answers:" heading ("Answers: 1. C") is now handled (plural matches); a merged bare-"Answer:" heading is hypothetical and stays unhandled — the proven "Answer: Option C" false positive outweighs it. A regression test pins the false positive: *"per-question 'Answer: Option C' line never opens a key section"* (2 questions, 0 key sections, 0 applied).

**After the repair:** affected files pass (110 tests); **full suite 886 passed, 5 skipped, 0 failed** (baseline 882 + 4 new tests: 3 merged-heading + 1 regression); **`flutter analyze`: 0 issues.**

## 11. Flagged, NOT fixed — validator double-count (§3)

`validateParseResult` counts each pending question twice (once as `answerPending`, once as `questionsMissingAnswers`): 127 shown vs 83 true distinct issues. Fix sketched: dedupe in `validateParseResult`. **Not fixed in this pass** — parent to decide; existing tests may pin the current counts.

## 12. Still unknown — and what would settle it

1. **The phone's exact ML Kit text and element boxes for PPSC-66.** Without them, every statement about the phone path is inferred from its diagnostic output, not observed directly. **Evidence that would settle it:** an OCR-diagnostics export from the app (raw ML Kit text + element boxes per page) for the PPSC-66 PDF and the Computer table photo.
2. **Whether the table reconstruction can ever work on phone ML Kit geometry.** Needs the same diagnostics export (§1) — the reconstruction's guards were tuned on Tesseract geometry, where they return null on this photo.
3. **Gate-refinement policy decision (for the parent, NOT implemented):** explicit key + all questions unattributed (no paper label) + number overlap → **NEEDS REVIEW** with a preview flag (preview + Save is the existing confirmation path), rather than MISMATCH / silent withhold. This touches the strict paper rule and gate tests — do NOT implement unilaterally.

## 13. Verification

- Full suite: **886 passed, 5 skipped, 0 failed** (`flutter test`; post-repair tail in `/tmp/full_suite_after_repair.log`; the pre-repair 17-failure log is `/tmp/full_suite_after_fix.log`).
- `flutter analyze`: **No issues found!**
- Gate tests untouched and passing: `paper_66_67_regression` 7/7, `table_title_pending` 4/4, `parse_validation` 6/6, `paper_identity` 12/12. No gate test was weakened.
- Files changed (working tree only): `lib/services/answer_key.dart` (merged-heading opener + regex repair), `test/answer_key_test.dart` (4 new tests).

## 14. Key numbers, one table

| Case | Phone (v2.0.4, ML Kit) | VM control (Gemini) | VM probe (Tesseract) |
|---|---|---|---|
| PPSC-66 PDF | 1 parsed, 44 pending, 146 blocks skipped; key 39 found, 0 applied | 100/100, 100 key applied | 2 parsed, 25 pending; key found, 0 applied (gate) |
| Computer table photo (15 rows) | 2 parsed, 4 detected | 15/15 | 1 parsed |
| Interjection table photo | — | 30 (fixture) | 14 parsed |

**Bottom line for the parent:** the phone's ML Kit read of this scan is the bottleneck, not the parser — the parser recovers 100/100 from a clean read of the same pages. The merged-heading fix removes one real failure mode (the vanishing key), but the phone will still parse ~1 question from this PDF until the OCR read itself improves or the questions survive it. The next evidence needed is the phone's raw ML Kit text/boxes, via an in-app diagnostics export.
