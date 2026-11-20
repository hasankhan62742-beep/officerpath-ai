# Universal Formats — OfficerPath AI v2.0.0 (Worker 4)

Status: 19 Nov 2026. Parser `lib/services/mcq_parser.dart` md5
`3f007e77eaeb77cf260647e95d928722` at the time of writing (the v1.3
coordinator is still editing it — re-stamp the md5 whenever counts
are quoted). Project version 1.3.0+4004 (integration bumps to
2.0.0+5000). No VM `flutter build` — APK via GitHub Actions CI.

**Governing spec (19 Nov 2026 ~15:39 PKT) — AI generation is PARKED.**
This supersedes the earlier "AI only as a last resort" rule:

1. The local deterministic parser is the ONLY extraction path. The
   uploaded PDF is the ONLY source of questions, options and original
   answers. An answer is NEVER invented.
2. If a document has no identifiable answer for a question, that
   question is UNVERIFIED (answer-pending) and goes to MANUAL
   CORRECTION by the user — never to AI.
3. The AI service (`lib/services/ai_generation.dart`, Gemini) STAYS
   in the codebase, parked — no extraction flow calls it. Verified by
   test: `test/parser_first_test.dart` + `test/failure_guidance_test.dart`
   assert the upload flow contains no `generateFromText` /
   `inferAnswers` / `_runAiGeneration` / `_runAiInference` call sites
   and does not import `ai_generation.dart`.
4. The earlier "AI as a last resort" routing (paste-flow gate
   `localParseSuffices`, `_aiFromPastedText`, `_runAiGeneration`,
   `_runAiInference`) was REMOVED from `lib/screens/upload_screen.dart`
   on 19 Nov 2026 and replaced by manual correction
   (`_runManualCorrection` + `ManualCorrectionDialog`, answers saved
   with `answerSource: 'manual'`).

## Parsing order (stated explicitly)

```
PDF / TXT / DOCX / JPG-PNG / paste
  → text extraction (PDF text layer, or OCR: ML Kit → Tesseract
    eng+urd → Gemini vision, best-quality tier)
  → ligature normalisation (pdf_text_extractor._clean /
    parseTextInBackground)
  → LOCAL deterministic parser FIRST, every format
    (block → one-liner → q-only → flashcard → table, with
    answer-line > key > tick > bold > asterisk precedence)
  → parsed MCQs → preview (counts + format breakdown) → save
  → questions WITHOUT an answer → UNVERIFIED (answer-pending)
    → MANUAL CORRECTION in the app (user picks A–D; saved as
      'manual'; unanswered stay pending, never guessed)
  → 0 MCQs at all → "No MCQs found" dialog (diagnostics + next
    step + manual correction where it applies) — never AI
```

## Format table — every format, how it is handled, what proves it

| Format | How the parser handles it | Proved by (real item) | Measured |
|---|---|---|---|
| Block (Q + 4 options + Answer line) | `_parseStandardBlock` (~line 3698); answer-line, key, tick, bold, asterisk signals | PPSC 40 MCQs; Pace 1442; MPT 140; Examveda 3159 | 40 / 1442 / 140 / 3159 parsed |
| One-liner (Q + (a)–(d) inline) | `_parseOneLiner`; inline options A–D on one line | Sir Rizwan GSA (2); synthetic tests | 2 in GSA file |
| Q-only (Q + Ans, options built from the book's own answer pool) | `_scanFlashcards` + pool builder (~lines 2450–2500); distractors are other answers in the same book, shuffled | Pak Affairs 162; Sir Tauqeer 277; US History 515; IDIOMS 1067 (glossary) | 162 / 277 / 515 / 1067 |
| Flashcard dash-inline (`Q? — Answer`) | `_scanFlashcards` shape (b) | US History; IDIOMS glossary rows | see Q-only counts |
| Flashcard answer-on-next-line (`Q?` / answer below) | `_scanFlashcards` shape (a) | Sir Tauqeer 277 | 277 |
| Flashcard "?" / ":" trailing answer | `_scanFlashcards` shape (c), `_trailingAnswerSplit` | Sir Rizwan GSA (326 "?" trailing) | 326 |
| Table row-wise | `_parseTableRowWise` (~line 1212); needs ≥3 scored+pending rows; anchor = key letter / type label / new-question start; tick/bold passed through | Table photo (ppsc123_1.jpg) 32 rows; Examveda 16; Pak Affairs 19 | 32 / 16 / 19 |
| Table column-wise | `_parseTableColumnWise` (line 964); key run ≥5; exactly 5N items | Synthetic tests (5 rows) | 5 (synthetic) |
| Table standalone key letters | `_tableKeyLetterRe` (line 495, `[A-Ea-e]`) | Table photo 32/32 keys | 32 |
| Table type labels never options | `_isTableTypeLabel` (line 563, strict) + `_isTableLabelish` (line 550, loose), excluded in `_isTableOptionLine` | Table photo (labels Adjective / Attributive / Quantitative / …) | 32 rows, labels never a 5th option (1 leak: row 27 stem — see Gaps) |
| Multi-column answer-key tables ("?" excluded, never guessed) | Key join with unknown entries excluded; MPT Q106 (key "?") excluded | MPT-CSS-2027-Solved (Q106 excluded); key_table_unknown_test 5/5 | 5/5 |
| Tick (✓/✔) correct-option signal | `_extractOption` (~line 2688); tick beats bold/asterisk, loses to key/answer-line | MPT (tick-marked); Paper 60 photo (via OCR text: 0 ticks — asterisk instead) | MPT ticks verified; synthetic ✓/✔ tests pass |
| Bold correct-option signal | Font-name "bold" → `boldOptions` (pdf_text_extractor ~lines 613–708) → parser "bold" signal | Pak Affairs 19 table rows (bold-resolved); Examveda | 19 (F3) |
| Asterisk `*` correct-option signal | `_hasAsterisk` (~line 2644), `_stripAsterisks` (~line 2656); precedence answer-line > key > tick > bold > asterisk; `*` stripped from displayed text; 2 asterisks = conflict, never picked | Paper 60 camera photo (real OCR: 19 asterisk answers); synthetic precedence + conflict tests | 19/19 verifiable (see Camera section) |
| Two-column layouts (column-split before parse) | `_orderLinesForColumns` (pdf_text_extractor ~lines 1713–1756): left column top→bottom, then right | Pace 184 pp (two-column); IDIOMS (two-column glossary); 112 Edition (two-column scans) | Pace 1442; IDIOMS 1067 |
| Per-paper answer keys | Key sections detected per paper; key join by number within the paper | Pace (11 key sections, 1115 applied); MPT (140 applied) | 1115 / 140 |
| Scanned OCR (ML Kit → Tesseract eng+urd → Gemini vision) | `lib/services/urdu_ocr.dart` tiers; `preprocessForOcr` (grayscale + autocontrast + sharpen, Tesseract only); caller keeps the read with more words | Camera photo (Gemini vision 21/21 asterisks); 3 scanned books need a phone (VM has no OCR) | Gemini 21/21 `*`; Tesseract 9/21 `*` (preprocessed) vs 7/21 raw |
| .docx | `importDocx` (docx_text_extractor) → same parse pipeline | docx_test + sample_mcq_bank.docx fixture | passing |
| JPG/PNG upload | `importImage` → OCR → parser; 1 page is enough | Camera photo; table photo; mocked-OCR tests | 24 + 32 parsed (see below) |
| Paste text | `parseTextInBackground` → `_importResult`; local parse only, no AI | 3 paste fixtures (0 MCQs locally, facts extracted) | 0 MCQs / 16+33+27 facts |
| Multi-line questions/options | `_groupTableItems` (table); block loop joins continuations | Pace; Sir Tauqeer (multi-line Q&A) | verified in counts |
| 5-option (A–E) normalisation | `_TableSink.addRow` normalises 5 options → 4; `fiveOptionNormalised` counted | Examveda (5-option book) | counted in result |

## Per-item parse-count table (measured)

Counts are `parseMcqs` / `processPdfInBackground` results. Parser
md5 at measurement: 15:16 PKT probe `6799b740…`, re-confirmed by
`test/universal_formats_test.dart` (34/34) at md5 `0d43e1de…`;
final re-measurement 19 Nov 2026 (parser md5 `90cfc4b0…`):
F3 181, F13 515, F14 328, F15 3183/1710 — all match the table below.
(The counts flipped transiently between coordinator edits during
19 Nov — F3 177, F13 514, F14 289, F15 3184 were all observed at
intermediate md5s and then restored/fixed; the table holds the
final measured values.)

| # | Item | Parsed | Skipped | Formats | Pending | Facts | Notes |
|---|---|---|---|---|---|---|---|
| F1 | PPSC_Current_Affairs_40_MCQs.pdf | 40 | 0 | block 40 | 0 | 0 | Answer-line 40, 4 parts. Matches audit. |
| F2 | Current-Affairs-June-2025-in-PDF__1.pdf | 0 | 25 | — | 25 | 1 | Questions exist, answers do not → UNVERIFIED → manual correction (was: AI inference). |
| F3 | Pak_Affairs_by_CSPs.pdf | 181 | 907 | q-only 162, table 19 | 8 | 20 | Audit v1.2 said 162; v1.3 adds 19 bold-resolved table rows. 28 parts. Answer-source map now counts each row's own source (Gap G2 FIXED Phase A, 19 Nov 2026 — the 19 are 'bold', not 'key'). |
| F4 | Ayesha_Jalal…Belknap_Press.pdf | CORRUPT | — | — | — | — | xref unreadable; fail-fast, clear message, never ANR. |
| F5 | junior_clerk.pdf | 0 | 26 | — | 1 | 2 | Admission letter; own honest message, text never previewed, never saved. |
| F6 | Current_Affairs_Jan-Nov_2026_by_Pace_GK_Academy.pdf | 1442 | 6 | block 1442 | 5 | 84 | keySections 11, keyApplied 1115 (key 1115 + bold 327). 13 parts. Matches audit. |
| F7 | 112_Edition.pdf | 0 | 0 | — | 0 | 0 | Fully scanned; OCR on a phone required (VM has no OCR). |
| F8 | Current_Affairs_Year_2026_Complete__October-January__Sir_Tauqeer_0_sw7h.pdf | 284 | 0 | q-only 284 | 0 | 18 | 9 month parts. Was 277 until 19 Nov 2026, when cross-page stitching found 7 more flashcards whose ANSWER is on the next page (coordinator-verified by disabling the crossing: count drops back to 277). First REAL-book proof of cross-page stitching. |
| F9 | IDIOMS_COMPILED_BY_Raj_Roy_Soni.pdf | 1067 | 8 | q-only 1067 | 0 | 4 | Glossary parsed as dash-inline flashcards; needs human confirmation rows are real idioms. |
| F10 | PPSC_110_Edition__1_p7sh.pdf | 0 | 0 | — | 0 | 0 | Scanned; OCR required. |
| F11 | 109_edition_by_abbaSi.pdf | 0 | 0 | — | 0 | 0 | Scanned; OCR required. |
| F12 | MPT-CSS-2027-Solved.pdf | 142 | 3 | block 140, q-only 2 | 0 | 0 | keyApplied 140; Q3 defective and Q106 (key "?") excluded, never guessed. Matches audit. |
| F13 | US_History_solved_MCQs_by_SAK.pdf | 515 | 50 | q-only 515 | 0 | 8 | 27 parts. Matches audit. |
| F14 | Sir_Rizwan_GSA.pdf | 467 | 157 | one-liner 2, q-only 465 | 1 | 0 | sources bold 2 + flashcard 465. Phase A (19 Nov 2026): 328 → 467 — the G6 walkForward fix recovered the "➢" bullet section (295/376 bullet + 172/289 numbered; ground truth 665 candidates). The +139 were swallowed as answer continuations before, never counted as skipped (skipped stays 157). One known wart: "Mercury is" parses twice (pages 30/31) — the app extractor returns 31 page objects for a 29-page PDF and the question sits on two of them; pre-existing extractor quirk, both copies kept + reported as a duplicate number. |
| F15 | Examveda_GK_Comp_Eng_Sir_Waleed_0300_1111938.pdf | 3202 | 1689 | block 3177, q-only 8, table 17 | 867 | 11 | Phase A (19 Nov 2026): 3183/1710 → 3202/1689 — the _splitOptionLine word-boundary fix (abbreviations no longer split options) + G7 2-row table recovered 19 previously-skipped real questions. Two verified book-correct: "The Mistral is" → D, "20th August is celebrated as" → B (Sadbhavana Divas). 26 parts. (Earlier note, kept for the record: audit v1.2 said 3180/1704; v1.3 first measured 3183/1710 — the 3183↔3184 flip between coordinator edits was a transient intermediate-md5 count, NOT a missing question; 3183 stood on the frozen tree.) |
| F16 | organization_Sir_Waleed_0300_1111938.pdf | 0 | 0 | — | 0 | 180 | Fact cards only. Under parked-AI: 0 MCQs, facts shown as diagnostics; nothing is generated. |
| P1 | Table photo ppsc123_1.jpg (Gemini vision OCR) | 32 | 0 | table 32 | 0 | 0 | 32/32 rows correct incl. keys (sources key 32). Re-measured 19 Nov 2026 (md5 `90cfc4b0…`): the +1 GARBAGE flashcard ("HANDWRITTEN: CS Scanned with CamScanner", Gap G-C4) and the row-27 label leak (Gap G-C5) are FIXED — the photo now parses exactly 32, nothing else. |
| P2 | Camera photo IMG_20261119_151817_041.jpg (Gemini vision OCR) | 21 | 6 | block 21 | 0 | 0 | All 21 asterisk-sourced (sources asterisk 21): the 19 verifiable asterisk answers + top-of-page Q6 + Q11 (OCR-invented — see Camera section). Re-measured 19 Nov 2026 (md5 `90cfc4b0…`): the 5 GARBAGE q-only fragments (Gap G-C1) are gone (now skipped, not parsed), Q12/Q14 wrapped asterisks resolve (Gap G-C2), Q15 options no longer truncated (Gap G-C3), pending is 0. |
| T1 | Paste fixture: Urdu Prophet facts | 0 | — | — | 0 | 16 | 15 statement + 1 colon fact. No MCQs locally. |
| T2 | Paste fixture: "Largest/Longest" list | 0 | — | — | 0 | 33 | No MCQs locally. |
| T3 | Paste fixture: "Study of X" list | 0 | — | — | 0 | 27 | Unique facts. No MCQs locally. |
| S1 | PakMCQs 500 GK (Phase A sample, 19 Nov 2026) | 373 | 3 | q-only 373 | 0 | 1 | Free PDF from pakmcqs.com.pk (63 pp). Ground truth 500 Q + 500 "Ans:" lines (pdftotext). Was 0/500 before the bare-number fix ("3 What …?" — digits + space, no dot — collapsed the book into ONE block). 125 missing: two-column reading order scrambled, stems lose '?' to column breaks. Pollution metrics all 0 (no '?' / www / bare-number fragment / empty option). 3 skipped honestly (2 footer-debris answers, 1 answer lost to scramble). See `test/regression/README.md`. |
| S2 | PPSC Foodgrains Inspector 2013 (Phase A sample, 19 Nov 2026) | 79 | 0 | block 79 | 0 | 0 | Public exam paper (archive.org, 17 pp). Ground truth 80 questions (1–80). Only gap: Q59 — its stem is absent from the PDF text layer itself (page break eats it); reported as "Q59 missing between Q58 (page 12) and Q60 (page 13)". Q52 is bare-numbered ("52 Who founded …?") and parses; its false "missing" gap was fixed. Q4 "Sec." phantom-option bug fixed (was `[60 Sec., 80 Se, "", 100 Sec.]` + answer C; now all four Sec. options + answer B). |
| S3 | Skilling Foundation 500 GK excerpt, Q1–Q20 (Phase A fixture, 19 Nov 2026) | 20 | 0 | block 20 | 0 | 0 | Excerpt copied verbatim from the freely accessible Skilling page (numbered Q + (A)–(D) + section-end ANSWERS lists every 10). All 20 answers correct via the section-end key (sources 'key'). Committed fixture: `test/regression/fixtures/skilling_gk_20.txt`. |

Two old tests asserted audit-v1.2 counts and failed on the improved
parser (both were improvements, not regressions). UPDATED this
session (19 Nov 2026, parser md5 `90cfc4b0…`):
`test/realfile_counts_test.dart` F3 162→181 (162 q-only + 19 table);
`test/examveda_scale_test.dart` 3180/1704→3183/1710 (block 3172→3160,
answer-line 3175→3162). Both pass now.

## Camera-photo robustness

The user: "Chahe camera se bnai huvi aik image ku na ho ye hr qism p
trained hona chaiye" — even a single camera photo must work.

**What exists (verified):**
- 1 page is enough: `importImage` accepts a single JPG/PNG.
- OCR tiers (`lib/services/urdu_ocr.dart`): per page, Gemini vision
  if the user picked best-quality + has a key; else Tesseract eng+urd
  if the page has Urdu or the user picked Urdu; else ML Kit. The
  caller keeps the read with more words.
- Preprocessing (`lib/services/image_preprocess.dart`,
  `preprocessForOcr`): grayscale + autocontrast + sharpen, Tesseract
  tier only, never throws (garbage/degenerate input passes through
  unchanged). Measured on the real Paper 60 photo (tesseract.js PSM 3):
  raw 7/21 asterisks → 9/21 preprocessed. No deskew/perspective
  correction — explicitly out of scope; ML Kit and Gemini tolerate
  mild skew.
- Real OCR fixtures (NOT hand-written):
  `test/fixtures/paper60_gemini_ocr.txt` (3,547 chars, 21/21 `*`) and
  `test/fixtures/table_photo_gemini_ocr.txt` (4,378 chars, 32 rows),
  produced 19 Nov 2026 by `tools/gemini_vision_ocr.py` (Gemini
  vision, model gemini-2.5-flash, photo downscaled to 1600 px).
- Noise tolerance (passing tests): garbled fragments between good
  blocks are skipped; handwritten margin notes are ignored
  ("Dot Matrix printer", "impact printer" never become questions);
  page numbers (639/640), diamond separators (♦♦♦) never become
  questions; a page of pure noise parses to 0, never crashes.

**Honest findings from the real photo:**
- **Vision OCR can invent cut-off content.** Q11's stem is the last
  printed line of the left column; its options are NOT on the page
  (verified by cropping the photo's bottom 20%). Gemini vision
  nevertheless returned "(A) SUM (B) MAX (C) MIN (D) AVG*" — plausible
  and standard, but NOT verifiable from the photo. The parser
  faithfully parses it (answer D). No test asserts Q11's answer as
  ground truth. Mitigation: in manual correction / review, answers
  whose source text was cut off at a page edge should be flagged
  UNVERIFIED — that flag does not exist yet (Gap G-M1).
- **5 false-positive questions** from facing-page debris (Q22–Q30
  fragments "Wh to e", "All follo", "Bi", "T") — Gap G-C1.
- **2 real questions pending** (Q12, Q14 — asterisk on a wrapped
  continuation line) — Gap G-C2. **2 options truncated** (Q15 A/B
  wrapped text cut at the line break) — Gap G-C3.
- Phone-only, still open: real ML Kit / Tesseract OCR on the 3
  scanned books (112/109/110 editions) and on the Paper 60 photo;
  Tesseract Urdu (Nastaliq) accuracy on real scans is unmeasured on
  a phone.

## Cross-page stitching + numbering (19 Nov 2026)

The user rule: MCQs run in number order; a question can split across
pages — the engine must follow the numbers and stitch the split into
ONE complete question, for text PDFs AND OCR/scanned pages alike.

**Stitching — PRESENT (verified by `test/cross_page_test.dart`,
7/9 pass, parser md5 `90cfc4b0…`):**
- Mechanism: `flattenPages` (`book_structure.dart:123`) joins all
  pages into ONE line stream with no page-boundary marker, and the
  block loop in `_parseImpl` (`mcq_parser.dart` ~1608+) splits blocks
  ONLY at question-start lines. A split question's lines are
  consecutive in the stream, so it stitches naturally.
- Proven: stem + options A–B on page 1, C–D + answer on page 2, plus
  a second question starting on page 2 → ONE Q7 (options Venus /
  Jupiter / Mars / Saturn, answer C, page 1) + Q8, no phantom
  question, `numberGaps` empty. Stem wrapping across the break also
  stitches. A bare page-number line ("2") between the parts is
  filtered (`isNoiseLine`, `answer_key.dart:278`). A running-head
  line ("Current Affairs") at the top of page 2 does NOT pollute the
  split question. The same split through the OCR re-parse path
  (`parseTextInBackground` with pages — what scanned books use)
  stitches identically.
- The v1.3 coordinator is ALSO implementing cross-page handling in
  `_scanFlashcards.walkForward` (`mcq_parser.dart` ~3321): a
  flashcard answer may continue onto the next page, skipping page
  furniture (footer / running header) at the break.

**Numbering diagnostics — FIXED 19 Nov 2026 (coordinator):**
- Missing numbers ARE reported WITH pages: `_computeNumberGaps`
  now takes the number → pages map, so the diagnostic names the
  bounding pages (e.g. Q8 missing between page 1 and page 2).
- Duplicate numbers ARE reported: a dedicated `numberDuplicates`
  field (`ParseResult` / `PdfImportResult`) lists duplicated
  numbers with their pages; both copies are kept, never merged.
- Preview display: the preview shows a "Numbering gaps (missing
  questions):" block AND a "Duplicated question numbers (both
  copies kept):" block (Worker-4 fix for gaps + coordinator
  extension for duplicates, both in `lib/screens/upload_screen.dart`).
- `test/cross_page_test.dart` is now 11/11: the 9 Worker-4 tests
  plus 2 added by the v1.3 coordinator (page-1 footer must not join
  the stem — a real bug they found and fixed; flashcard split across
  a page break).

## Asterisk `*` as the correct-answer signal — PRESENT

Implemented by the v1.3 coordinator in `lib/services/mcq_parser.dart`
(verified 19 Nov 2026, md5 `f803d541…` → `3f007e77…`):
`_hasAsterisk` (~line 2644), `_stripAsterisks` (~line 2656),
`_extractOption` (~line 2688). Precedence: answer-line > key > tick >
bold > asterisk > (AI — parked; unverified instead). The `*` is
stripped from displayed option text. Two asterisked options in one
question = conflict recorded, never silently picked.
Tests: `test/asterisk_signal_test.dart` 10/10 pass, incl. the real
Paper 60 page (hand transcription fixture — 19 questions, answers
Q1=C Q2=B Q3=D Q4=C Q5=C Q6=A Q7=D Q8=C Q9=A Q10=C Q12=D Q13=D Q14=A
Q15=C Q16=D Q17=A Q18=A Q19=D Q20=C; Q11 never guessed; Q21 fragment
never parsed) and the real-OCR fixture in `test/camera_photo_test.dart`
(18 verifiable asterisk answers + top-of-page Q6).

## Requirement A — user guidance on screen (VERIFIED, updated for parked AI)

Every "No MCQs found" / failure dialog contains all three: (1) what
went wrong in plain words, (2) the concrete next step (which format
to re-make the book in, how to upload it so it works, what the app
already tried), (3) the MANUAL CORRECTION option where it applies
(questions found without answers → "Jawab khud lagayein"). AI
generation is NEVER offered — the dialog states it ("AI se MCQs nahi
banaye jate"). Widget tests: `test/failure_guidance_test.dart`
(NoMcqsDialog incl. admission-letter + empty-text cases;
ManualCorrectionDialog: pick options → Save returns the map; partial
save; Cancel returns null; Save disabled until a pick) and
`test/dead_end_ux_test.dart` (source-level). Corrupt/docx/generic
failures show `showFileFailureDialog` (reason + next step, stays
until read) instead of a transient snackbar. The preview dialog also
offers manual correction for pending questions.

## Requirement B — every character (VERIFIED, 2 gaps)

- Ligatures normalised: PDF text layer via `_clean` →
  `_normalizeLigatures` (U+FB00–FB06 → ff/fi/fl/ffi/ffl/st/st);
  TXT/paste/OCR/DOCX paths via `parseTextInBackground`
  (`lib/services/pdf_text_extractor.dart`). Only FB00–FB06 change;
  Urdu/Arabic/math/dashes/ticks pass through untouched.
- Preserved byte-for-byte in passing tests (`test/character_handling_test.dart`):
  Urdu block + flashcard (ﷺ preserved), Arabic text, Urdu digits,
  math × ÷ √ ±, en/em dashes (– —), ticks ✓/✔, bullets (•) before a
  block, special punctuation, one hostile mixed line.
- Gaps: (B1) Arabic `؟` (U+061F) is not a question terminator —
  `_scanFlashcards` / `_trailingAnswerSplit` only recognise ASCII
  `?` (5 Urdu flashcards with `؟` parse 0/5). (B2) A trailing bullet
  line after the Answer breaks a block (parses 0, lands pending).
  (B3, fixed 19 Nov) Direct `parseMcqs()` callers used to bypass
  normalisation — the bare-number fix landed in the same area;
  integration should confirm normalisation lives in
  `parseMcqs`/`_parseImpl` or is exported as a helper.

## Official vs student marks + confidence / verification model

- A ✓ in TEXT-LAYER text is trusted (it is printed by definition).
  A ✓/✔ in OCR text from a camera photo has unknown provenance —
  it could be the student's pen. **Today the parser trusts every ✓
  it sees** (`_parseStandardBlock` → `_extractOption`, no provenance
  parameter). Per the spec, an OCR-sourced tick of unknown provenance
  must land the question UNVERIFIED until the user confirms it in
  manual correction. Tests: `test/unverified_marks_test.dart` —
  printed tick trusted (passes); pen-stroke `/` and circled-letter
  `Ⓑ` artefacts never trusted (pass — `/` goes pending; `Ⓑ` breaks
  option counting so the question is skipped, never guessed);
  provenance channel + OCR-tick-unverified + confidence +
  verification-status + original-vs-corrected + per-question preview
  are GAP tests (fail — the model does not have the fields).
- **Model gap (exact):** `lib/models/question.dart` — class
  `Question` has NO `confidence` (double 0–1), NO
  `verificationStatus` (verified / unverified / manually-corrected),
  NO `originalCorrectIndex` / `correctedCorrectIndex` separation,
  NO `markProvenance` field; class `PendingQuestion` has none of
  these either. The preview (`_importResult`, upload_screen.dart)
  shows aggregate lines only — no per-question row with confidence
  or status. `lib/services/urdu_ocr.dart:99-100` already states ML
  Kit / Tesseract give no per-page confidence the app can trust.
- What manual correction DOES today: `ManualCorrectionDialog` +
  `_runManualCorrection` let the user set answers for pending
  questions (saved with `answerSource: 'manual'`); unanswered stay
  pending. There is NO UI to correct an already-answered question,
  and no original-vs-corrected separation for that case.

## Coverage map — governing spec format list vs real proof

Spec items with real proof (item → proving item):
one-line → GSA (2) + synthetic; short/long questions → Pace, Examveda;
4 options horizontal → Paper 60 photo (2 per line); 4 options
vertical → PPSC 40, Pace; rows/columns/tables → table photo 32,
Examveda 16, Pak Affairs 19; bold correct options → F3 19;
printed ticks → MPT + synthetic; asterisk → Paper 60 photo 19;
answers after question (Answer line) → F1 40; answers after
page/section (per-paper keys) → Pace 1115, MPT 140; separate keys as
tables → MPT key table; separate keys as lists/compact sequences →
Pace key sections (11); A/B/C/D keys → Pace, MPT; full-text keys
("61. (C) 3") → MPT; scanned/image PDFs → 3 scanned books (OCR
pending on phone) + 2 photos (Gemini OCR verified); mixed
Urdu-English → Urdu fixtures + 112 scans (OCR pending); maths
symbols → Req B tests; tables inside books → table photo + Examveda.

Spec items with NO real proof yet (gaps — never claimed as covered):
OMR sheets / filled bubbles (no code exists); coloured or highlighted
correct options (no colour/highlight detection — only bold via font
name); italic correct options (no italic detection); printed crosses
(✗/✘), circles, underlines as answer marks (no code exists);
HANDWRITTEN pen/pencil ticks/circles/markings as a distinguished
input (no provenance channel — see above); 2/3/4-column option
layouts beyond 2-per-line (3/4-on-one-line unmeasured); multiple
questions per row (no dedicated test); all fonts / sizes /
orientations (landscape, rotated pages — unmeasured); diagrams /
images as question content (not interpreted — surrounding text only);
answer keys as grids (key tables verified; grids unmeasured);
full-text-only keys with no letter (unmeasured).

## Gaps left for integration (exact file/function/line)

Camera / noise (new, 19 Nov 2026) — **FIXED by the v1.3 coordinator,
verified 19 Nov 2026 (parser md5 `592d008f…`):**
`test/camera_photo_test.dart` now passes **13/13** (was 13 passed +
7 failed). The fixes:
- **G-C1 — OCR fragments become fake questions — FIXED.** Bare
  "(A)" lines no longer act as answers and the Q-only path has a
  stem-quality guard; the Paper 60 OCR tail ("Wh to e", "All follo",
  "Bi", "T", "T") no longer becomes questions.
- **G-C2 — asterisk on a wrapped option continuation line — FIXED.**
  Paper 60 Q12/Q14 now resolve from the continuation line
  ("application*", "key repeatedly*").
- **G-C3 — wrapped options truncated at the line break — FIXED.**
  Paper 60 Q15 options A/B now join their continuation lines.
- **G-C4 — colon note becomes a flashcard question — FIXED.**
  "HANDWRITTEN: CS Scanned with CamScanner" no longer parses as a
  flashcard.
- **G-C5 — previous row's type label leaks into the next question
  — FIXED.** Table photo row 27 stem is now clean
  ("Yesterday, I met ____ European").
- **G-C6 — vision OCR can invent cut-off content — FIXED (visibility),
  19 Nov 2026 (Phase A).** The parser flag existed (OCR-sourced
  answers carry `markProvenance: 'ocr'` and confidence 0.54 for
  unverified tick/bold — the comment said 0.6; the code computes
  `0.9 × 0.6 = 0.54`, comment corrected), but the user could not SEE
  it. The new `ExtractionPreviewDialog` (`upload_screen.dart`)
  shows a visible warning row on every OCR-provenance question:
  unverified tick/bold → "OCR se parha gaya … jawab UNVERIFIED
  hai"; verified OCR (asterisk/key/answer-line) → warns the answer
  may be cut off at the page edge. Pinned by
  `test/extraction_preview_test.dart` (G-C6 unverified 54% warning
  + G-C6 verified-OCR cut-off warning). Proof: Paper 60 Q11 options
  hallucinated by Gemini vision (SUM/MAX/MIN/AVG*) though not on
  the page — now shown UNVERIFIED with the warning, never trusted
  blindly. Cut-off DETECTION itself (proving a stem was cut) is
  still not implemented — the warning is by provenance, not by
  detection.

Cross-page / numbering (new, 19 Nov 2026):
- **G-X1 — missing-number diagnostic names no pages — FIXED 19 Nov
  2026 (coordinator).** `_computeNumberGaps` now takes the
  number → pages map (`Map<int, List<int>> numberPages`,
  `mcq_parser.dart` ~2788), so the diagnostic names the bounding
  pages. Pinned by `test/cross_page_test.dart` "missing-number
  diagnostic names BOTH pages" (passes 11/11).
- **G-X2 — duplicate numbers across a break are never reported —
  FIXED 19 Nov 2026 (coordinator).** A dedicated
  `_computeNumberDuplicates` (`mcq_parser.dart` ~2713) + a
  `numberDuplicates` field on `ParseResult` / `PdfImportResult`,
  rendered in the preview as "Duplicated question numbers (both
  copies kept)". Pinned by `test/cross_page_test.dart` "duplicate
  number across the break is reported" (passes).
- **G-X3 — LIVE REGRESSION, FIXED 19 Nov 2026 (coordinator).**
  `_scanFlashcards.walkForward` crashed with `RangeError`
  (`mcq_parser.dart:3324`, `block[startIdx]` out of range) on
  prose-only input, introduced by the coordinator's in-progress
  cross-page work. Full-suite impact went +606 ~3 -28 (md5
  `e1c9738c…`) → +632 ~3 -2 (md5 `76dd7ee4…`) → **+634 ~3, ALL
  PASSED** (same md5) once the crash path and the F8 expectation
  were fixed. Keep as a regression test: the prose-only fixture in
  `test/parser_first_test.dart` "(c)" now passes again.

Earlier gaps (still open unless noted):
- **G1 — column-wise table drops tick/bold — FIXED 19 Nov 2026
  (Phase A).** `_parseTableColumnWise` now computes `tickIndex` /
  `boldIndex` from the option cells and passes them to `addRow`
  (row-wise already did); a key-less column-wise row that is only
  tick/bold-marked is now answered instead of pending, and
  key-vs-tick conflicts are recorded. Pinned by
  `test/phase_a_gaps_test.dart` (2 tests).
- **G2 — table answer-source mislabel — FIXED 19 Nov 2026 (Phase
  A).** `_parseImpl` now increments `answerSources` per row's own
  `answerSource` instead of `'key'` for every table row. Proof:
  F3's 19 table rows now count as bold=19 (parsed still 181).
  Pinned by `test/phase_a_gaps_test.dart` (1 test).
- **G3 — bare-number table options eaten — FIXED 19 Nov 2026.**
  Was `lib/services/answer_key.dart` `isNoiseLine` (lines 281–282);
  the coordinator fixed it; `test/universal_formats_test.dart`
  "table options that are bare numbers" now passes. Keep as a
  regression test.
- **G4 — Arabic `؟` not a question terminator — FIXED 19 Nov 2026.**
  `test/character_handling_test.dart` "Urdu flashcard with Arabic ؟"
  now passes (15/15 in that file).
- **G5 — trailing bullet after Answer breaks a block — FIXED 19 Nov
  2026.** `test/character_handling_test.dart` "trailing bullet line
  after the Answer" now passes.
- **G6 — flashcards require a number prefix — FIXED 19 Nov 2026
  (Phase A).** Root cause: `_scanFlashcards.walkForward` only broke
  on lines ENDING with `?`, so it swallowed the next dash-inline
  flashcard ("Who wrote Hamlet? — Shakespeare") as an answer
  continuation, polluting the previous answer and losing the middle
  question. Now it breaks on ANY `?`/`؟` in the line. Verified: 6
  flashcards per shape (dash-inline, answer-on-next-line,
  trailing-answer) now parse 6/6 with exact answers. A 3-item list
  is still honestly EXCLUDED (the pool needs 3 distinct distractors
  per question; only 2 others exist) — governing-spec behaviour,
  not a bug. Pinned by `test/phase_a_gaps_test.dart` (4 tests).
- **G7 — table minimums — FIXED 19 Nov 2026 (Phase A).** Row-wise
  minimum 3 → 2 rows; column-wise key-run minimum 5 → 3; stem cap
  200 → 400 chars; row-wise buffer 3 lines/200 chars → 4 lines/400
  chars. Failure-loop guard: the ≥2 change made the F16
  organisation file parse 2 fake MCQs (bold-anchored fact rows, no
  key), so a small-table guard was added — a table of <3 rows is
  accepted ONLY when EVERY row is key-anchored, otherwise its lines
  fall through to normal handling (F16 back to 0 parsed). Pinned by
  `test/phase_a_gaps_test.dart` (5 tests + guard test).
- **G8 — upload preview omits table/flashcard counts — FIXED 19 Nov
  2026 (Phase A).** `_importResult` summary lines now include
  `• Table rows: N`, `• Flashcards: N`, and an OCR-unverified
  count. Pinned by `test/extraction_preview_test.dart` (G8 counts
  render + G8 source check).
- **G9 — direct `parseMcqs()` bypasses ligature normalisation —
  FIXED 19 Nov 2026 (Phase A).** `_normalizeLigaturesLocal`
  (FB00–FB06, same mapping as the extractor) is now applied in
  `parseMcqs` (raw text) and `parseMcqsFromPages` (per page).
  Verified by probe: direct `parseMcqs` previously stored
  "oﬃcial" with U+FB03; now "official". Pinned by
  `test/phase_a_gaps_test.dart` (2 tests).
- **G-M1 — confidence / verification status / original-vs-corrected
  fields — FIXED 19 Nov 2026 (parser md5 `90cfc4b0…`).**
  `lib/models/question.dart` now has `confidence` (double,
  defaulted from `confidenceForSource(answerSource)`),
  `verificationStatus` (derived getter — 'verified' /
  'manually-corrected' / 'unverified'), `originalCorrectIndex`
  (kept when a manual correction overwrites the answer), and
  `markProvenance` (see G-M2). `answerVerified` (bool) from the
  earlier partial fix is still there. `test/unverified_marks_test.dart`
  now passes 10/10.
- **G-M2 — provenance channel for marks — FIXED 19 Nov 2026.**
  `lib/services/mcq_parser.dart` carries `markProvenance`
  ('printed' default; 'ocr' when the mark came from OCR text,
  ~lines 395/411, 1572, 2702–2724): OCR-sourced ticks land the
  question UNVERIFIED at confidence `0.9 × 0.6 = 0.54` (earlier
  notes said 0.6; the code computes 0.54 — comment corrected
  Phase A) until the user confirms in manual correction.
- **G-M3 — no UI to correct an already-answered question — FIXED
  19 Nov 2026 (Phase A).** New public `CorrectAnswerDialog`
  (`upload_screen.dart`): shows `Book ka jawab: C (key se)`, radio
  options, Save disabled until a DIFFERENT option is picked (an
  unchanged answer is never marked manually-corrected). Uses
  `Question.withCorrection` (keeps `originalCorrectIndex`, source
  'manual', verified, confidence 1.0). Per-row `Jawab theek karein`
  button in the new `ExtractionPreviewDialog` opens it; the
  correction applies in place and survives Save. The old
  `ManualCorrectionDialog` (pending-only) is intact. Pinned by
  `test/extraction_preview_test.dart` (Save-disabled logic +
  correct-in-place flow incl. `Pehla jawab` + `manually-corrected`).
- **G-M4 — no per-question confidence/status in the preview —
  FIXED 19 Nov 2026.** `lib/screens/upload_screen.dart` ~lines
  313–330: the preview shows verification + per-question confidence
  (average confidence line) and flags unverified questions for
  review.
- **Phone-only verification still open:** real ML Kit / Tesseract /
  Gemini-vision OCR on the 3 scanned books and the Paper 60 photo;
  the 2 skipped paste-flow widget tests (sqflite has no VM
  implementation — same precedent as `test/upgrade_payment_test.dart:16`).

## Test inventory + numbers (19 Nov 2026, final — parser md5 `1d128624…`)

- `flutter analyze lib/ test/` — 0 issues.
- **Full suite, one command (`flutter test`): +680 ~3, ALL PASSED**
  (680 passed, 3 skipped, 0 failed), parser md5 `1d128624…`,
  ~5 min 35 s. The 3 skips: 2 sqflite phone-only widget tests in
  `parser_first_test.dart` + 1 pre-existing skip in
  `result_export_test.dart:153` (VM flutter_tester hangs at teardown
  after any `toImage` call — probe-verified). Baseline at Phase A
  start (frozen tree, md5 `76dd7ee4…`): 634 passed, 3 skipped,
  0 failed; Phase A added 46 tests net (gaps 29, registry 6,
  preview 8, regression 3) and the count shifts below are all
  verified improvements, pinned with comments in the tests.
- Phase A test files: `test/phase_a_gaps_test.dart` **29/29**
  (G6×4, G9×2, G2×1, G1×2, G7×6 incl. bare-marker table guard,
  PPSC "Sec."×3, PakMCQs bare-number×2 + answer-token×7,
  PPSC numbering×2); `test/extraction_registry_test.dart` **6/6**;
  `test/extraction_preview_test.dart` **8/8** (G8, G-M3, G-C6);
  `test/regression/regression_test.dart` **3/3** (Skilling 20/20,
  PPSC 79/80, PakMCQs 373/500). All probe files used during the
  failure loop were deleted after use; the regression library is
  the permanent record (`test/regression/README.md`).
- W4 files (unchanged counts except where noted): `My files` —
  `universal_formats_test.dart` 34/34 (GSA + Examveda expectations
  updated Phase A: GSA 328→467, Examveda 3183/1710→3202/1689);
  `parser_first_test.dart` 12 passed + 2 skipped (sqflite
  phone-only widget tests); `failure_guidance_test.dart` 11/11;
  `character_handling_test.dart` 15/15; `asterisk_signal_test.dart`
  10/10; `camera_photo_test.dart` 20/20 (G-C1..G-C5 FIXED, and the
  Phase A table-guard regression re-proved green);
  `unverified_marks_test.dart` 10/10 (G-M1, G-M2, G-M4 FIXED —
  confidence, verification status, original-vs-corrected,
  provenance, per-question preview all present).
- `test/cross_page_test.dart`: **11/11 pass** — split block
  question, split stem, bare page-number footer, running head,
  OCR re-parse path, missing-number diagnostic, page-named
  diagnostic (G-X1 FIXED), duplicate detection (G-X2 FIXED),
  preview display of `numberGaps`/`numberDuplicates`, plus 2 tests
  added by the v1.3 coordinator (page-1 footer must not join the
  stem; flashcard split across a page break — the coordinator's
  `walkForward` cross-page path).
