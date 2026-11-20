# ML Kit Parse Robustness — OfficerPath AI (20 Nov 2026)

**Task:** make the parser survive noisy on-device ML Kit OCR text (upload path
first; the bundled book bank is deferred by the user). Working tree only —
no commits, pushes, or releases. Parent handles v2.0.4 after its own
verification.

**Final verification (own runs, 20 Nov 2026):**
- Full suite: **882 passed, 5 skipped, 0 failed** (`flutter test`,
  log `/tmp/officerpath_v204_final_test.log`, TEST_EXIT=0).
  Baseline at v2.0.3 was 867/5/0 — the +15 is exactly the 15 new
  category-separation tests in `test/ocr_category_recovery_test.dart`.
- `flutter analyze`: **0 issues** (log
  `/tmp/officerpath_v204_final_analyze.log`, ANALYZE_EXIT=0).
- Gate tests green: paper_66_67 7/7, table_title_pending 4/4,
  parse_validation 6/6, paper_identity 12/12.
- Real-file counts all at baseline: F3 186 (159 q-only + 27 table),
  F8 284, MPT 143 parsed / 3 skipped, Examveda 3212 parsed / 1688 skipped,
  US History + GSA counts restored. Table photos: interjection 30,
  computer 15 (`test/pdf_ocr_routing_test.dart` 5/5).

## 1. What was reproduced first (the probe)

A temporary probe (`test/mlkit_robustness_probe_test.dart`, **deleted after
recording**) ran the real `importPdf` path with stubbed OCR text built from
the real Gemini OCR fixtures (`test-fixtures/ppsc66/ocr-p1.txt`…`ocr-p7.txt`)
under documented noise models. Format below is
`parsed / keyApplied / unmatched / missing / skipped / pending`.

| Model | Before | After |
|---|---|---|
| F clean (Gemini text) | 100 / 100 / 0 / 10 / 10 / 10 | 100 / 100 / 0 / 10 / 10 / 10 |
| A column interleave | 55 / 51 / 49 / 11 / 48 / 11 | 55 / 51 / 49 / 11 / 48 / 11 |
| B digit misreads (25%) | 85 / 85 / 1 / 23 / 23 / 23 | **98 / 98 / 0 / 11 / 11 / 11** |
| B2 option-marker misreads | 23 / 23 / 76 / 4 / 85 / 4 | **100 / 100 / 0 / 10 / 10 / 10** |
| B50 digit misreads (50%) | — (added this session) | **92 / 92 / 0 / 17 / 17 / 17** |
| Brun run Q41–50 destroyed | — (added this session) | **100 / 100 / 0 / 10 / 10 / 10** |
| C combined (A+B) | 44 / 41 / 45 / 20 / 54 / 20 | **52 / 48 / 50 / 10 / 50 / 10** |
| C2 full-phone-like (A+B+B2) | 32 / 29 / 52 / 18 / 64 / 18 | **52 / 48 / 50 / 10 / 50 / 10** |
| G real Tesseract 5.3.4 text | 16 / 10 / 75 / 5 / 25 / 5 | **20 / 14 / 71 / 5 / 22 / 5** |

Noise models (probe definitions): A interleaves p1–5 left/right line halves;
B corrupts every 4th line-start number and every 4th key-entry number
(first digit 1→I / 0→O / 5→S / 8→B); B2 corrupts every 4th option marker
`(B)`→`(8)` / `(D)`→`(0)`; B50 corrupts every 2nd number; Brun destroys
Q41–50 numbers entirely; C = A+B; C2 = A+B+B2; G = real Tesseract 5.3.4
text (psm 6, eng, regenerated 20 Nov, `/tmp/tess66/`).

**Correctness** (matched questions' answers vs the clean control, keyed by
normalised stem + SORTED options → correct option text; F control has 100
unique identities, 0 dups): B 98/98 right, 0 wrong; B2 100/100 right,
0 wrong; B50 92/92 right, 0 wrong; Brun 100/100 right, 0 wrong; C/C2
4/52 matched, 4 right, 0 wrong (interleave garbles stem text itself, so
few match — see §5); G 0/20 matched (vacuous — Tesseract stems too garbled
to match; the check is weak for G, reported honestly).

**Discrepancy, recorded honestly:** the prior probe (PHONE_MLKIT_PARSE
§2) measured digit-noise alone at 9 parsed; this probe's B-before is 85.
Unexplained in the record (the prior probe file was deleted; its exact
model is only summarised). Working hypothesis: the current tree's
numberless-stem split + exact-gap sequence interpolation already recover
isolated single corrupted numbers, so 25%-rate corruption mostly recovers;
the phone likely has LONG RUNS of destroyed numbers and destroyed option
markers, not isolated corruptions. The probe's B2 (option markers 100→23)
is the worst single model — option-marker recovery is the biggest lever,
then interleave, then numbers.

## 2. What each fix does

All production changes are in `lib/services/mcq_parser.dart`,
`lib/services/answer_key.dart`, `lib/services/book_structure.dart`.

### 2.1 Category separation (owner's principle, 20 Nov 17:25 PKT)

"Numbers or English letters or urdu ko alag samjhega tb system sahi hoga."
Applied as three rules, pinned by `test/ocr_category_recovery_test.dart`
(15 tests, all green):

1. **DIGITS ONLY in number slots.** `decodeOcrNumber` (answer_key.dart)
   maps a Latin letter where a digit belongs — S→5, I/i/l/L→1, O→0,
   B→8, Z→2 (also `$`/`§`→5) — but only in a 1–3-char token that
   contains **≥1 real digit**. A token with no real digit ("SI", "B")
   decodes to null, never guessed. Pure-digit tokens are exempt from the
   length cap (see §3.4). Only letters map to digits — a digit never
   maps to another digit — so a decoded number is determined by position.
2. **LETTERS ONLY in option markers.** `(A)–(D)` are English letters.
   OCR reads `(B)` as `(8)` and `(D)` as `(0)` (Tesseract on PPSC-66:
   `(0)` 26×, `(8)` 15×) — `decodeOcrOptionLetter` maps 8→B, 0→D only.
   `(4)` is NEVER decoded (it is both a valid option number and a
   misread of A). Digit-recovery never touches a marker letter.
3. **URDU is its own category.** Arabic-script tokens are never
   normalised or misread as Latin letters or digits; the script is
   preserved exactly. Q83–84 Urdu key answers resolve with script
   preserved, and a pinning test asserts Urdu answer text survives the
   recovery pass byte-identical, including a Final Answer value in Urdu
   (the old trailing-trim regex `[^A-Za-z0-9]+$` stripped a Urdu value
   to an EMPTY string — fixed to `[^\p{L}0-9]+$` with `unicode: true`,
   proven by standalone Dart script).

### 2.2 Number recovery (the biggest lever)

- `decodeOcrNumber` + `ocrNumberTokenPattern` (answer_key.dart): the
  token pattern is an alternation expressing "≥1 real digit" in 1–3
  chars (plus pure digits of any length, §3.4).
- `questionPrefixRe` uses the token pattern; `_keyEntryStartRe` captures
  misread key numbers; `parseKeyEntries` decodes via `decodeOcrNumber`
  (null → skipped).
- `_questionNumber` gained a misread-token fallback (clean regex first,
  then token pattern + decode), refactored this session into
  `_questionNumberDetailed` returning `({number, decoded})`.
- `_bareNumberAtStart` / `_bareNumberAtStartDetailed`: pure-digit tokens
  of ANY length first (preserves the old inline `^\d+` behaviour for
  4-digit bare years like "1947"), then misread tokens of 1–3 chars.
- `isMisreadNumberStart` (top-level): token + separator + stem text +
  decode check. `isQStart` (local in `_parseImpl`) =
  `questionStart` (clean) OR `isMisreadNumberStart`.
- **Sequence validation pass** (after the recovery pass): pre-computes
  `blockNumbers` / `blockNumbersDecoded` for all blocks, then per paper
  over option-bearing blocks, a decoded number is demoted to null if
  (a) it duplicates any trusted (clean or interpolated) number in the
  paper, (b) it is not strictly after the previous accepted number, or
  (c) it is not strictly before the next trusted number. Clean numbers
  are never demoted. A demoted block stays pending — it can never join
  a wrong key entry.
- `resolveAnswerToken` extended: classes `[A-Ea-e1-5]` →
  `[A-Ea-e1-580]` in optionLetter/parenLetter/letterText, misread
  checked first via `_misreadAnswerLetterIndex`, plus a trailing
  bare-"8"/"0" fallback AFTER the text match (so a real numeric answer
  "8" still wins).

### 2.3 Option-marker recovery

- `_optionRe`, `_optionMarkerRe`, and the local marker regex in
  `_splitOptionLine` accept 8/0 **only parenthesised** ("(8)", "(0)")
  — see §3.1 for why the bare form was a bug. Letters match in any form
  ("(A)", "A.", "A)"). Callers decode the marker via
  `decodeOcrOptionLetter` before the consecutiveness check (inline
  splits) or the column-position check (table rows).
- The table marker site decodes the marker before comparing it with the
  column position; a mismatch makes the row's answer distrusted (pending,
  never guessed).

### 2.4 Splitter guards (misread numbers split only with proof)

- Main splitter branch: clean numbers split unconditionally
  (long-standing behaviour); a **misread** number splits only when its
  options follow within 8 lines (`optionsFollow`). A bare "B8." / "S1."
  line inside prose or a list is not a question, and splitting there
  cuts a real question in half.
- `isNumberlessStemStart`: a CLEAN number is a numbered start, never a
  numberless stem; a MISREAD number is still eligible as a numberless
  stem (the previous question being complete — all 4 options present —
  is the proof it is a new question).
- `book_structure.dart` `_misreadNumberStartRe` tightened: the leading
  slot accepts only "Q" or a misread digit — "A12." no longer counts
  as a misread number (A is not a digit confusion), so it cannot
  swallow a following real heading.

### 2.5 Regex audit (category separation)

Mixed classes found in the parse path and their verdicts:
- `mcq_parser.dart` `[^A-Za-z0-9]+$` (trailing trim) — **REAL FIX**
  (Urdu strip, §2.1.3).
- `answer_key.dart` `(^|[^A-Za-z0-9])Q\s*(\d+)…` — boundary use only,
  OK (Urdu chars correctly count as boundaries; number slot
  digits-only, letter slot letters-only).
- `book_structure.dart` `^[^A-Za-z0-9]?\d{1,4}\s+[A-Z]` — prefix
  allowance, OK.
- `book_structure.dart` `_misreadNumberStartRe` — **TIGHTENED** (§2.4).
- `mcq_parser.dart` T-word guards `(?![A-Za-z](?:hat|hich|…)\b)` —
  English question-word check, OK.
- `answer_key.dart` phone-line guard — OK (first regex requires
  digits/punct only; Urdu lines cannot match it).
- `book_structure.dart` `_alphaWordCount` / `_isTitleCase` /
  `_isAllCaps` — Latin-only word/letter counting for heading
  heuristics; documented limitation (Urdu headings are not positively
  detected by them, but they never normalise or drop Urdu —
  `isNoiseLine` has no Latin requirement, proven by Q83–84 resolving).
- `auth_service.dart` email cleaning — not parse path, out of scope.
- No `\w` uses in the parse path.

## 3. Regressions found by the full suite — and fixed (item-by-item)

The first full run after the recovery work was **876 passed, 5 skipped,
12 failed** (log `/tmp/officerpath_v204_test.log`). All 12 were real
regressions on CLEAN text, not re-baselined. Each was bisected to a
single cause and fixed; the final run is 882/5/0 with every documented
count at baseline.

### 3.1 Bare "8." faked an option marker (`_optionRe` / `_optionMarkerRe`)

- **Symptom:** 12 failures — parser_signals shape C (GSA trailing ":"
  answer 4→0), F3 186→176, F8 284→282, US History 515→488, GSA 467→463,
  Examveda skipped 1688→1862 (parsed 3212→~3038), MPT 3→5.
- **Root cause (proven by bisection + standalone Dart script):**
  `_optionRe` with letter class `[A-Da-d80]` matches a bare "8." at
  line start as an option marker — "8. Bodies which usually fall from
  the sky are called: Meteors" → marker=8, rest="Bodies…". That kills
  the flashcard scan (`_scanFlashcards` early-returns false when ANY
  block line matches `_optionRe`) and corrupts the flashcard-heavy
  books. Reverting `_optionRe` to `[A-Da-d]` alone made
  parser_signals_test pass 48/48 including shape C.
  (Why the earlier 867 run passed with `[80]` is unresolved — do not
  assume; the bisection result stands on its own.)
- **Fix:** `_optionRe`, `_optionMarkerRe`, and the `_splitOptionLine`
  local marker regex now use two branches — letters in any form,
  digits 8/0 **only parenthesised** ("(8)", "(0)"). A bare "8." is a
  question number (Q8), never an option; the digit form is only ever
  evidenced parenthesised in OCR text. All callers updated for the new
  group layout (1 = letter marker, 2 = letter rest, 3 = digit marker,
  4 = digit rest).
- **Follow-on (F3 table):** the same bare-"8." fault in
  `_optionMarkerRe` made one F3 table row's option cell ("8. …") decode
  to marker B, disagree with its column, and distrust the row's answer
  (table 27→26, pending "option markers disagree"). The paren-only fix
  restored F3 to 186 (q-only 159, table 27).

### 3.2 "S1:" / "S6:" are labels, not question numbers (Examveda)

- **Symptom:** after the marker fix, Examveda parsed 3214 (baseline
  3212) with 45 gained / 44 lost stems (normalised-stem diff between
  the current tree and a no-recovery bisect tree).
- **Root cause (proven item-by-item):** Examveda's "proper sequence"
  items label their sentences `S1:`, `P:`, `Q:`, `R:`, `S:`, `S6:` —
  all with COLONS (verified in the raw text: `S6: A man of that
  character is free from fear,`). "S1" decodes to 51, so the misread
  logic split every item at its S1/S6 lines: the gained stems were
  truncated ("…The Proper sequence should be:" with the jumbled
  sentences cut off — unanswerable), the lost stems were the more
  complete ones (containing R:/S: fragments).
- **Fix:** a misread number never takes ":" as its separator
  (`_questionNumberDetailed` misread branch and `isMisreadNumberStart`:
  `[\.\)]` only; clean digits keep ":"). Result: Examveda parsed
  back to exactly 3212, probe unchanged (B 98, B2 100, B50 92,
  Brun 100, C/C2 52).

### 3.3 A decimal is not a question number (MPT + Examveda)

- **Symptom:** MPT skipped 3→4; Examveda skipped 1688→1715.
- **Root cause (proven item-by-item):** MPT's 4th skipped block was
  "6.2x20 = 124." (Block 88, found via a temporary debug print at the
  fallthrough site). `isMisreadNumberStart` lacked the `(?!\d)` guard
  the clean number regex has, so "6." + "2x20" matched as question 6.
  The other MPT skipped blocks are Q3 + Q106 (book defects, excluded)
  and Q198 (column interleave — known defect, its key entry 198 stays
  unmatched).
- **Fix:** `(?!\d)` added after the separator in
  `isMisreadNumberStart` (same guard as the clean regex). MPT skipped
  4→3 (baseline). Examveda stayed 1715 — its +27 had a different
  cause (§3.5).

### 3.4 Four-digit numbers are real numbers (Examveda key lines)

- **Root cause (proven from code):** `decodeOcrNumber` capped ALL
  tokens at 3 chars, and `_isKeyOnlyLine`'s token class was
  `[0-9IiLlOoSsBbZz$§]{1,3}` — so a key-only line "1001. A 1002. B"
  was not recognised as a key line (Examveda numbers to 3212).
  `_keyEntryStartRe` had the same cap via `ocrNumberTokenPattern`.
- **Fix:** pure-digit tokens are exempt from the length cap
  (`decodeOcrNumber` fast path: all-digits → `int.tryParse`, any
  length); `ocrNumberTokenPattern` prepends `\d+`; `_isKeyOnlyLine`
  uses `(?:\d+|[0-9IiLlOoSsBbZz$§]{1,3})`. A 4-char LETTER-bearing
  token ("S100") is still capped — it could be a word fragment.
  Pinned by tests (`decodeOcrNumber('1234') == 1234`,
  `decodeOcrNumber('S100') == null`, "1001. A 1002. B 1003. C" +
  "3212. D" → 4 entries). Note: Examveda's text has no 4-digit
  key-only lines (its answers are inline "Answer: Option X" lines),
  so this fix did not move Examveda's counts — it fixes a real latent
  bug for books with big keys.

### 3.5 Bold-marker prefix inflated the skipped count (Examveda +27)

- **Symptom:** Examveda skipped 1688→1715 (parsed correct at 3212)
  survived every single-change bisect (marker regexes, validation,
  numberless change, book_structure tightening, `resolveAnswerToken`,
  `isQStart` group revert, misread-recovery disable — all still 1715).
- **Root cause (proven by file-level bisect + single-variable test):**
  swapping in the v2.0.3 `mcq_parser.dart` alone (with current
  `answer_key.dart` / `book_structure.dart`) restored 3212/1688, so
  the cause was in `mcq_parser.dart`. Diffing the v2.0.3 file against
  the current file isolated the skipped-block guard (§3455): v2.0.3
  checks `questionStart.hasMatch(firstLine)` (RAW first line); the
  robustness work changed it to `isQStart(cleanFirst)` (CLEANED first
  line). `_cleanStored` strips the bold marker (U+E000), so a
  bold-marked number line ("12. …") matches on the cleaned form and
  is counted as skipped, while the raw form does not match and is
  silently continued. Changing only that one variable back to
  `firstLine` restored 3212/1688 exactly, with the probe unchanged.
- **Fix:** the guard now uses `isQStart(firstLine)` (raw) for the
  numbered check, keeping `isBareNumberQuestionStart(cleanFirst)` for
  the bare check (v2.0.3 structure). The 27 blocks fail to parse
  either way (their options are garbled — a pre-existing limitation,
  visible in the fallthrough dump: real questions with clean numbers
  whose inline options cannot be split); the fix keeps the diagnostic
  count at baseline instead of inflating it. Comment added at the
  guard explaining the raw-vs-cleaned choice.

## 4. Interleave decision (NOT implemented — documented)

NO parser-level stem/option rejoin was added. Reasons:
- The text probe cannot distinguish a safe rejoin from an unsafe one
  (no column geometry — the real signal is x-coordinates, which the
  text probe lacks).
- The column split (`splitColumnsForOcr`) IS the correct defence — it
  runs on ML Kit line boxes on the phone, reordering lines into column
  order BEFORE the parser sees them, and the probe's interleave model
  simulates the failure mode the split prevents, not the split itself.
- Any text-level rejoin risks merging two different questions (a
  fabrication risk under the extraction-only spec).
Model A stays 55; the remaining interleave loss is a phone-geometry
problem, not a text problem. The phone's column-split effectiveness on
real ML Kit boxes is unproven (needs the phone test).

## 5. Correctness-check method and its limits

- Questions are compared by normalised stem + SORTED options →
  correct option TEXT (not index), against the clean-text control
  (100 unique identities, 0 dups). The first version keyed by stem
  alone and flagged 1 "wrong" in A/C/C2 — proven a COMPARISON
  ARTEFACT (3 duplicate instruction stems in the control: "select the
  sentence with correct use of capital letters", "choose the correct
  sentence", "select the correct sentence" — same instruction,
  different option sets, different answers; the map kept the first).
  Fixed by keying on stem + sorted options → correct option text.
- Interleave correctness remains weak (only 4/55 matched — interleave
  garbles stem text itself, not just option order; sorted options did
  not raise the match rate). G correctness is vacuous (0/20 — stems
  too garbled to match). Both reported honestly; the count gains
  (B 98, B2 100, B50 92, Brun 100) are the verified signal, with 0
  wrong answers among matched questions in every model.
- The probe's Tesseract model (G) is harsher than ML Kit is likely to
  be; it is a lower bound, not the phone's actual text. Tesseract
  evidence: `(0)` 26×, `(8)` 15×, `(B)`→`(8)`, `(D)`→`(0)`; `(A)` 117
  and `(C)` 111 mostly survive; **no `(4)` seen** — (A)→(4) is NOT
  evidenced, so `(4)` is never decoded.
- Table photos verified on the Gemini fixtures after the changes:
  interjection 30, computer 15 (`pdf_ocr_routing_test` 5/5). No
  plain-text table fallback was invented (probe I already proved
  plain-text tables cannot work — tables depend on ML Kit element
  boxes).

## 6. What remains unproven on the phone

- **Everything about real ML Kit OCR text.** All noisy numbers here
  are Tesseract/synthetic models. The phone's actual ML Kit read
  (its digit confusions, its column geometry, its element boxes for
  tables) is unproven until the owner's phone test on his three files
  (PPSC-66 PDF + Interjection photo + Computer photo) + the Paper 60
  camera test.
- **Column split on real ML Kit boxes.** The split is verified wired
  and running for rendered PDF pages; its effectiveness on the phone's
  real line boxes is unproven. Model A (55) is the residual risk.
- **Table photos on the phone.** They depend on phone ML Kit element
  boxes; the Gemini-fixture parse (30/15) does not prove the phone
  path.
- **The 128 key entries.** Now understood as a SYMPTOM of the
  question-parse collapse (digit misreads create phantom numbers,
  "(B)"→"1)" splits create phantom entries, page/year numbers leak
  in, Paper 67 Explanation items) — entries are not assumed invalid
  or discarded. Whether the phone still produces ~128 depends on its
  actual OCR noise.
- **No test was weakened.** `decideKeyMatch`, the extraction-only
  spec, and the gate tests are untouched. No count was re-baselined
  without an item-by-item proof (see §3 — every residual was traced
  to a single cause and fixed; the final counts equal the v2.0.3
  baselines exactly).
- **Deliberately not decoded:** `(4)`→A (ambiguous — both a valid
  option number and a misread of A); `_parseOneLiner` markerRe
  unchanged (a spurious "8)" inside "(18)" could fake a marker);
  `_tableKeyLetterRe` unchanged (table key column; "0" is ambiguous
  with a numeric option value).

## 7. Files changed (working tree only)

- `lib/services/mcq_parser.dart` — number recovery, option-marker
  recovery (paren-only digits), sequence validation, splitter guards,
  `(?!\d)` decimal guard, ":" exclusion for misread numbers,
  `\p{L}` Urdu trim, raw-first-line skipped-block guard.
- `lib/services/answer_key.dart` — `decodeOcrNumber`,
  `ocrNumberTokenPattern` (pure digits any length),
  `decodeOcrOptionLetter`, `questionPrefixRe`, `_keyEntryStartRe`,
  `_isKeyOnlyLine` (4-digit keys), `resolveAnswerToken`.
- `lib/services/book_structure.dart` — `_misreadNumberStartRe`
  tightened (leading slot Q or a misread digit only).
- `test/ocr_category_recovery_test.dart` — 15 tests (was 12; +3 this
  session: 4-digit key numbers, S1:/S6: labels, decimal guard).
- Probe file `test/mlkit_robustness_probe_test.dart` — created to be
  deleted; **deleted** after recording (its counts are in §1).
  Temporary debug tests (`f3_debug_temp_test`, `examveda_debug_temp_test`,
  `mpt_debug_temp_test`) — **deleted**. No BISECT-ONLY / TEMP-DEBUG
  markers remain in the tree (grep-verified, 0 hits). No "CamScanner"
  in production matching logic (2 remaining occurrences are pre-existing
  doc comments).

## 8. Handover notes for v2.0.4

- Parent's own verification run is still required before release
  (this report's numbers are the agent's own runs).
- `pubspec.yaml` version bump (2.0.3 → 2.0.4) is the parent's step;
  no version change was made here.
- The probe is deleted; to re-measure a new noise model, rebuild it
  from `test/pdf_ocr_routing_test.dart`'s harness (watermark-only PDF
  + stubbed renderPage/runOcr) and the Gemini fixtures in
  `test-fixtures/ppsc66/`.
- Known accepted edges (from the report §12 lineage, still true):
  multi-line table titles (only the line directly before the header
  is skipped); a numberless stem after an explanation is swallowed;
  trailing number runs left null — never guessed; 5-option unanswered
  candidates appear in `errors` but not in `questionsMissingAnswers`.
