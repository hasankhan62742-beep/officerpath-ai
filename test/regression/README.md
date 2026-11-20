# Regression library — extraction samples (Phase A, 19 Nov 2026)

Permanent regression library for the OfficerPath AI extraction engine.
Every sample is run through the ACTUAL pipeline
(`processPdfInBackground` / `parseMcqs`) — never a stub — and every
number below is MEASURED, not claimed.

## Rules

- Committed fixtures are SMALL EXCERPTS created by the worker from
  legally accessible sources, or synthetic fixtures written by the
  worker. NEVER a whole copyrighted book.
- Full-sample PDFs are NOT committed. They live outside the repo and
  are re-downloaded from their public URLs; tests that need them
  SKIP (with the reason) when the files are absent, so CI stays green
  without the samples.
- Student tests contain questions ONLY from their own uploaded PDF.
  These samples exist to test the PARSER, never to supply questions.

## Committed fixtures (`fixtures/`)

| Fixture | Source | Ground truth | Status |
| --- | --- | --- | --- |
| `skilling_gk_20.txt` | Skilling Foundation page "500 General Knowledge Solved MCQs" (https://www.skilling.pk/500-general-knowledge-solved-mcqs-pdf-free-download/), Q1–Q20 + both ANSWERS lists, copied verbatim from the freely accessible page | 20 questions; answers 1.C 2.D 3.D 4.C 5.A 6.B 7.A 8.A 9.B 10.B 11.A 12.C 13.B 14.B 15.C 16.B 17.A 18.D 19.C 20.B | **20/20 parsed, all answers correct via section-end key** (`regression_test.dart`) |

Synthetic fixtures for the failure-loop fixes live in
`test/phase_a_gaps_test.dart` (bare-numbered Q-only lists,
"Sec." phantom options, watermark/merged-question/page-number
bleed in answer tokens, footer-debris answers, bare-number
numbering gaps).

## Full-sample PDFs (NOT in the repo — download to /tmp/phaseA_samples/)

| Sample | URL | Ground truth | Measured (19 Nov 2026) |
| --- | --- | --- | --- |
| PakMCQs 500 GK (`pakmcqs_500gk.pdf`, 949,428 B, 63 pp) | https://www.pakmcqs.com.pk/wp-content/uploads/2018/10/500-general-knowledge-question-and-answer.pdf (PakMCQs' own free PDF) | 500 questions, 500 "Ans:" lines (pdftotext) | **373 parsed, 3 skipped, 125 missing.** Pollution: 0 options with '?', 0 with 'www.', 0 with bare-number fragments, 0 empty. Was 0/500 before the bare-number fix. |
| PPSC Foodgrains Inspector 2013 (`ppsc_foodgrains_2013.pdf`, 494,343 B, 17 pp) | archive.org public exam paper (URL in `docs/extraction-audit.md` §7A) | 80 questions (1–80) | **79 parsed, 0 skipped, 0 errors.** Only gap: Q59 — its stem is absent from the PDF text layer itself (page break eats it). Q52 bare-numbered, parses; its false "missing" gap was fixed. |

## Known limitations (documented, not hidden)

- **PakMCQs 125 missing (25%)** — cause: the PDF is two-column and
  the extractor reads columns in scrambled order; some stems lose
  their '?' to a column break and some "Ans:" lines land pages away
  from their question, so those questions never form a block. Fixing
  it needs layout-aware column reordering in the extractor — out of
  Phase A scope. The 373 parsed are clean (pollution metrics all 0).
- **PakMCQs residual warts (≤ 5 of 373 correct answers)** —
  "Roger Bannister 6" (dangling question number), "George Washington
  1798 1792 No Questions Quiz 4" (scrambled-column garble), "Mona
  Lisa No Questions Quiz 2" (section-header bleed). A trailing-number
  cut would destroy legit answers ("Henry 8", "Number 13", "Apollo
  11"), so no cut is applied; these stay as-is and are visible in
  the preview for manual correction.
- **PakMCQs 1 spurious key entry** — "1917" (a year) is read as a
  key entry with no matching question and reported as unmatched; it
  is harmless diagnostics noise, not a wrong answer.

## Dataset count toward the 50–100 target

- User's own 16 files + 2 photos + 3 paste fixtures: **21**
- Phase A additions: PakMCQs 500 GK, PPSC Foodgrains 2013,
  Skilling GK excerpt: **3** (running total **24**)
- Synthetic failure-loop fixtures (in `phase_a_gaps_test.dart`):
  bare-numbered Q-only, "Sec." options, answer-token bleed
  (4 shapes), footer debris, numbering gaps: **7 fixture groups**
- Still short of 50–100. Unobtainable publisher samples (NOA, IBES,
  Emporium, Dogar/Caravan/JWT/Ilmi full books — no legal free copy
  found) are recorded as gaps in `docs/extraction-audit.md` §7;
  they were NOT downloaded.
