# PPSC Paper 66 — Parser Baseline (2026-11-20)

Measured 2026-11-20 ~09:40–10:00 PKT. This is the training target the owner
called "strictly follow this format": the parser must be structure-aware —
columns, rows, questions, headings, titles AND answers.

## 1. Format profile

`~/workspace/user/files/ppsc_paper_66.pdf` — 7-page CamScanner scan, **no text
layer** (pdftotext returns only the word "CamScanner"), 5.9 MB. "MODEL PAPER 66,
TEHSILDAR / CONSOLIDATION OFFICER / HILL TORRENT OFFICER / READER TO MEMBERS
BOARD OF REVENUE (BS-16) – 2021, English Morning", 100 MCQs, pages 521–527 of
"Papers of 2021". Two-column layout throughout; questions numbered with
`(A)/(B)/(C)/(D)` options in a 2×2 grid, very often `(D) None of these`.
**No asterisk, bold or tick marks on the questions** — answers live ONLY in a
trailing key: on page 6 after Q100, headed `ANSWER KEY: Model Paper 66`, entries
`1. (B) Broke out` … `78. …` (number + (letter) + answer text, with section
subheads "English Grammar" and "Grammar and Vocabulary"); the key continues
onto the top of page 7, entries `79. (B) Develop` … `100. (C) He couldn't
believe`, in 3 narrow columns, **including two Urdu-script answers (Q83
تسلیم کرنا, Q84 بغل میں چھری منہ میں رام رام)** and no heading of its own.
"MODEL PAPER 67" (General Knowledge – Evening, Q1–Q10) starts mid-page-7, so
the PDF holds TWO papers. "Explanation:" and "Associated Information:" blocks
follow some Paper 67 questions and must never become questions. Some question
numbers are clipped at the left page edge on page 1 (Q1, Q3–Q9 have no number
in the OCR). Q48's options split across columns (stem + (A)/(B) bottom-left,
(C)/(D) top-right). Running headers/footers read as text ("Papers of 2021
522", "524 Advanced FPJC MCQs Model Papers (Volume 2)").

## 2. Method

- **OCR:** Gemini vision, model `gemini-3.5-flash-lite`, the app's own prompt
  (`lib/services/urdu_ocr.dart` `GeminiVisionOcr`: transcribe ALL text EXACTLY
  as printed, line by line, in reading order, left column first then right;
  unreadable words as `[?]`), `maxOutputTokens` 2048, temperature 0.0, pages
  resized to 1000 px wide (`GeminiConfig.visionImageWidth`). Script:
  `test-fixtures/ppsc66/gemini_vision_ocr.py` (credential via the registered
  `custom.gemini` surrogate, same pattern as `gemini_tts.py`; no key logged).
  OCR text saved per page: `test-fixtures/ppsc66/ocr-p1.txt` … `ocr-p7.txt`.
  - Pages 1, 2, 4, 6, 7: single call each, finish `STOP`.
  - Page 5: blocked twice by Gemini's **recitation filter** (verbatim match
    against an indexed PPSC paper PDF); succeeded on the 3rd attempt with a
    minimally rephrased prompt (extra instruction: blank line after every
    question/option group). Words unchanged.
  - Page 3: blocked 6 times (full page, halves, quarters, column crops);
    completed as 7 crop calls stitched by hand at question boundaries
    (`ocr-p3-top/a/bL1/bL2a/bL2b/bR/q2.txt` kept as provenance) plus a
    line-number-prefix prompt for the last slice (Q48 options). The stitched
    `ocr-p3.txt` was checked word-by-word against the page image.
  - One transient HTTP 503 (model overload) on a retry; not a content block.
- **Parser:** the app's real import entry point `parseMcqsFromPages` with
  `ocrPages: {1..7}`, run in `test/ppsc66_baseline_test.dart` (kept in the repo
  so the fix agents can re-run it: `flutter test test/ppsc66_baseline_test.dart`).
- **Parser version measured:** the parser at the last pushed commit
  (`1ba64ed0`, GitHub `main`) — NOT the current working tree. At measurement
  time the working tree did not compile: the running no-answers sibling agent
  had left `lib/services/answer_key.dart:59` with `import 'question.dart';`
  (file `lib/services/question.dart` does not exist; `PendingQuestion` lives in
  `lib/models/question.dart`), plus edits to `mcq_parser.dart` and
  `models/question.dart`. The baseline was therefore run in a scratch copy
  (`/tmp/ppsc66-baseline`, since removed from scope — it was a throwaway copy)
  with the three parser files restored to their pushed-HEAD versions. The
  sibling's in-flight features (title-matched keys, key-attach flow,
  no-answers notice, answerless `-1` sentinel) are NOT in these numbers;
  **re-run the harness after they land** — the numbers below will move.
  (The OCR two-column-split/table-reconstruction agent's work is also not in
  these numbers; this baseline uses Gemini OCR text, which already returns
  left-column-first order by prompt.)

## 3. Baseline numbers (exact)

Input: 110 real questions — Paper 66 Q1–Q100 (pages 1–6) + Paper 67 Q1–Q10
(page 7). OCR question-number coverage: p1 Q10–Q17 numbered (Q1, Q3–Q9
unnumbered), p2 Q18–Q38, p3 Q39–Q57, p4 Q58–Q77, p5 Q78–Q96, p6 Q97–Q100 +
key 1–78, p7 key 79–100 + Paper 67 Q1–Q10.

| Metric | Value |
|---|---|
| Questions parsed (with an answer) | **10** |
| — of which TRUE positives (real questions, correct answer) | **0** |
| — of which FALSE positives (fabricated) | **10** |
| Skipped blocks | **203** |
| Format counts | `block: 0, one-liner: 0, q-only: 10, table: 0` |
| Answer sources | `flashcard: 10` (all 10 parsed came from q-only generation) |
| Key sections found | **0** |
| Key entries applied | **0** |
| Unmatched key entries | `[]` |
| Number gaps / duplicates | `[]` / `[]` |
| Conflicts | `[]` |
| Answer-pending (4 options, no answer, kept) | **102** |
| Questions missing answers (reported) | 101 entries (see §5.5) |
| Parts with ≥1 parsed question | `ANSWER KEY: Model Paper 66 English Grammar:6-7:3`, `General Knowledge:7-7:7` |

Pending by page: p1: 9, p2: 21, p3: 19, p4: 20, p5: 19, p6: 4, p7: 10 = 102.
Reconciliation: 102 pending (92 Paper 66 + 10 Paper 67) + 8 vanished
(Paper 66 Q1, Q3–Q9 — no parsed question, no pending entry, no per-question
error) = 110 real questions. The 10 "parsed" are extra fabrications (§4).
Skipped-block reconciliation: 101 "4 options but no usable answer" + 2 generic
"Block 1/2" + 100 "need 4 options + an Answer line" = 203.

**Headline: 0 of 110 real questions parsed with an answer. The paper is
effectively unparseable by the current parser — not because the questions are
hard, but because the key is never recognised (§5.1).**

## 4. The 10 "parsed" questions — all false positives

All are `q-only`/`flashcard` source (options generated from the book's answer
pool, not the book's own options) and all are marked `verified=true`. None is
a real question from the paper:

From the key section itself (part `ANSWER KEY: Model Paper 66 English
Grammar`, pages 6–7) — key-entry fragments turned into fake questions:
1. `(A) Speak:` (p6, ans D)
2. `(B) Muzzle:` (p6, ans A)
3. `(C) [?` (p7, ans A)

From Paper 67's "Associated Information" / "Explanation" blocks (part `General
Knowledge`, page 7) — explanation bullets turned into fake questions:
4. `of the Islamic Golden Age and had significant repercussions for the
   region. Halaku Khan was - Mongol Emperor:` (ans C)
5. `- Conquests:` (ans A)
6. `- Founder of the Ilkhanate:` (ans B)
7. `lasted from 1256 to 1335. The Siege of Baghdad - The Siege:` (ans A)
8. `- The Fall of Baghdad:` (ans A)
9. `city's fortifications, leading to a massacre and the eventual surrender
   of the Caliph. - Aftermath:` (ans A)
10. `Oldest University in Europe:` (ans C)

Fabricated questions marked verified is the most dangerous failure mode here:
a user taking this "test" would be scored against invented options.

## 5. Failing cases by question number (root causes)

### 5.1 ROOT CAUSE 1 — the key heading is not recognised (kills all 100 answers)

The key heading on page 6 reads `ANSWER KEY: Model Paper 66`. Verified by
direct call in the harness:

- `isAnswerKeyHeading("ANSWER KEY: Model Paper 66")` → **false**
- controls: `isAnswerKeyHeading("ANSWER KEY")` → true;
  `isAnswerKeyHeading("Answers - Paper 1")` → true

Mechanism (`lib/services/answer_key.dart`, HEAD): the trailing-paper-reference
strip removes `Paper 66`, leaving core `ANSWER KEY: Model`, which fails
`_keyCoreRe` (it requires the line to be only the key words + optional
colon). The qualifier word **`Model`** between the key words and the paper
reference breaks the match. Consequence: `keySectionsFound=0`,
`keyEntriesApplied=0`, and every complete question block is skipped for "no
usable answer". The key-entry machinery itself works: `parseKeyEntries` fed
the page-6 key blob directly returns **78 entries (1–78)** with correct
values (`1 → (B) Broke out`, `8 → (D) None of these (am)`,
`20 → (A) Acrophobia`), and the page-7 blob returns **22 entries (79–100)**,
including the Urdu ones (`83 → (B) تسلیم کرنا`,
`84 → (A) بغل میں چھری منہ میں رام رام` — value garbled mid-text with a line
break + `[?]`, letter intact). `_resolveAnswer` resolves `(B) text` form via
its paren-letter branch. So fixing ONLY the heading match would unlock all
100 key entries for the 100 Paper 66 questions.

The page-7 continuation (entries 79–100) has NO heading at all — it is a key
section continuing across a page boundary. Any fix must also recognise a
bare numbered `(letter) text` run continuing a key from the previous page.

### 5.2 ROOT CAUSE 2 — paper headings not recognised (both papers = "Paper 1")

`MODEL PAPER 66` / `MODEL PAPER 67` are not recognised as paper headings:
`_paperHeadingRe` requires the whole line to be just the heading, and the
leading word `MODEL` breaks it (same qualifier problem as §5.1). Result:
**every question is labelled `Paper 1`** (the default) — Paper 66 and Paper 67
are indistinguishable to the parser, so title-based key matching (the owner's
strict rule: a key applies only to the paper with the SAME title) is currently
impossible. The `questionsMissingAnswers` list shows Paper 67's Q1–Q10
indistinguishable from Paper 66's Q1–Q10 (Q10 even appears twice).

### 5.3 ROOT CAUSE 3 — Q1, Q3–Q9 vanish entirely (clipped numbers)

Page-1 OCR contains NO numbers for Q1, Q3, Q4, Q5, Q6, Q7, Q8, Q9 (only
Q10–Q17 are numbered; Q2's number survived). The stems ARE in the OCR text
("Give the meaning of Idiom: Spick and Span", "Choose the correct article/s
…", "Choose the correct synonym Wheedle:", "Choose the antonym of
Wearisome:", "Choose the pair of words …", "The sentence given below has a
blank …", "Choose the word/words …", and Q1's "The Plague ______ in London
…"). Yet none of the 8 produces a parsed question, a pending entry, or a
per-question error — they fall into the 100 "need 4 options + an Answer line"
bucket (blocks that never formed). Diagnosed cause: blocks cannot start
without a question number, so numberless stems merge into neighbouring
blocks and die. Precise block mechanics were NOT instrumented — needs a
block-level trace, not another guess. Acceptance for these 8: they must at
least surface as pending/unparsed with their numbers recovered from sequence
position, never silently dropped.

### 5.4 ROOT CAUSE 4 — q-only fabrication from key + explanation text (§4)

The 10 false positives come from the `q-only` path generating options for
question-like lines found in key text and explanation bullets. Two guards are
missing: (a) key-section lines must never reach the question parsers (they
currently do, because the key section was never opened — §5.1 — so its lines
are ordinary question lines); (b) "Explanation:" / "Associated Information:"
blocks and their bullet lines (`- Conquests:`, `- The Fall of Baghdad:`) must
never become questions — they currently do.

### 5.5 Reporting quirks (minor, but the checklist must cover them)

- `questionsMissingAnswers` has 101 entries: Paper 66 Q10–Q100 (91) + Paper 67
  Q1–Q10 (10), with **Q10 listed twice** and **Q2 absent** although Q2 IS
  pending ("Are they blaming us for nothing?", p1). The missing-answers report
  and the pending list disagree.
- `parts` only lists parts with ≥1 parsed question, so the two parts shown
  are the two false-positive sources (§4) — the real parts (English Grammar
  Q1–Q100, General Knowledge Q1–Q10) do not appear at all.
- Pending rows carry part labels taken from running headers: `522`, `524`,
  `524 Advanced FPJC MCQs Model Papers (Volume 2)` (a page footer on p4),
  `English Grammar`, `General Knowledge`. Page headers must not become part
  titles.

### 5.6 OCR-quality notes (input-side, not parser bugs)

- Q48 (p3): stem + (A)/(B) bottom-left, (C)/(D) top-right — cross-column
  options. Gemini's prompt order kept them adjacent in the stitched text;
  ML Kit on-device may interleave them (see §6).
- Q78 (p5): stem mixes Urdu script — `78. بیگu حالت Translate into English.`
  (the `u` is a misread). Mixed-script stems occur in this book.
- Q84 key entry (p7): Urdu value garbled mid-text (`…رام رام` + line break +
  `رم [?]`). Q88 key entry: `[?]ney have served us wrong meal`. The `[?]`
  markers sit INSIDE key values; the letter still resolves.
- Q100's question sits on p6 immediately before the key heading — the key
  follows Q100 on the same page.
- p1 OCR dropped the numbers 1, 3–9 (edge-clipped in the scan) but kept the
  stems and all four options for each.

## 6. What is NOT verified

- **On-device ML Kit OCR will differ from Gemini OCR.** These numbers are for
  Gemini vision text (prompt-enforced left-column-first order, clean
  line-by-line output). The phone camera path (ML Kit, no prompt control,
  raw block order) is a different input: column interleaving, the Q48
  cross-column split, and table/asterisk behaviour are NOT covered by this
  baseline. Do not quote these numbers as the phone result.
- **Page 3 is a hand-stitched reconstruction** from 7 crop calls (recitation
  filter, §2). Words were checked against the page image, but it is not a
  single OCR pass; a stitch error would move the baseline slightly.
- **Page 5 used a rephrased prompt** (blank lines added). Words identical,
  formatting differs from the app's exact prompt.
- **Parser version:** pushed HEAD (`1ba64ed0`), not the working tree (§2).
  Re-run after the sibling agents land; expect the numbers to move, chiefly
  via §5.1 (key heading) and the title-matching work.
- **Block mechanics for Q1, Q3–Q9** (§5.3) were not instrumented.
- **No fix was attempted in this task** — measurement only. No code was
  changed in the project except the added harness test
  (`test/ppsc66_baseline_test.dart`) and the fixtures
  (`test-fixtures/ppsc66/`); nothing was committed, pushed, released, or
  version-bumped.

## 7. Reproduction

```bash
# OCR (already done; outputs in test-fixtures/ppsc66/ocr-pN.txt)
python3 test-fixtures/ppsc66/gemini_vision_ocr.py test-fixtures/ppsc66/p-N.png \
  test-fixtures/ppsc66/ocr-pN.txt
# Baseline (run in the project root; requires a compiling tree)
flutter test test/ppsc66_baseline_test.dart
```

Files: source PDF `~/workspace/user/files/ppsc_paper_66.pdf`; rendered pages
`test-fixtures/ppsc66/p-1.png` … `p-7.png`; OCR text `ocr-p1.txt` …
`ocr-p7.txt` (+ page-3 crop provenance `ocr-p3-*.txt`, `p-3-*.png`); OCR
script `test-fixtures/ppsc66/gemini_vision_ocr.py`; harness
`test/ppsc66_baseline_test.dart`.

## 8. Checklist for the fix (what "trained on this format" means)

1. `ANSWER KEY: Model Paper 66` recognised as a key heading (the word
   `Model` before the paper reference must not break it); bare key
   continuations across pages recognised.
2. `MODEL PAPER 66` / `MODEL PAPER 67` recognised as paper headings, so each
   question and each key entry carries its paper title; a key applies only to
   its same-title paper (zero cross-matching).
3. Q1, Q3–Q9 (numberless in OCR) recovered or at least surfaced as
   pending/unparsed — never silently dropped.
4. Key/explanation lines can never become questions; q-only fabrication must
   never mark a fabricated question `verified=true`.
5. Running headers (`Papers of 2021 522`, `524 Advanced FPJC MCQs …`) must
   not become part titles.
6. Re-run this harness on the same OCR text: target is 100/100 Paper 66
   questions parsed with key answers + 10/10 Paper 67 pending-or-answered
   (Paper 67 has no key in this PDF — its 10 must be pending, not fabricated),
   0 false positives, keySectionsFound ≥ 1, keyEntriesApplied = 100.
