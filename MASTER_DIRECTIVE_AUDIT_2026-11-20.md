# MASTER DIRECTIVE — Audit, Design, Implementation (2026-11-20)

Coordinator report for the OfficerPath AI "ULTIMATE MASTER DEVELOPMENT
DIRECTIVE" (22 parts; verbatim at `MASTER_DIRECTIVE_2026-11-20.md`).
Owner's strict instruction: working, tested code — not proposals.
This report separates **implemented** from **planned / partial / blocked**
throughout. Nothing here was committed, pushed, released, or version-bumped.

## 0. Status at writing (10:21 PKT, 05:21 UTC)

- **Implemented + tested by this pass:** `paper_identity.dart` +
  tests (11/11), `parse_validation.dart` + tests (6/6),
  running-header fix in `book_structure.dart` + tests (2/2),
  permanent Paper 66/67 regression test (written; 0/7 passing — fails
  by design until the parser fixes land), table title/subject
  regression tests (written; 0/4 passing — reproduce the two
  OCR-probe items).
- **Sibling state:** TID agent DONE (report folded in, §6). Baseline
  agent DONE (report folded in, §5). OCR agent DONE (report folded in,
  §6). **No-answers agent STILL RUNNING** (72+ min, actively editing
  `mcq_parser.dart` / `answer_key.dart` / `question.dart` at 05:20 UTC)
  — its report has NOT landed. Its in-flight work already fixed the
  key heading (§5.2) and is mid-rewrite of the flashcard/q-only/
  pending paths, which is why parser counts move run to run.
- **Tree state:** the working tree does NOT always compile right now —
  the sibling left `answer_key.dart` syntax-broken at 05:13 UTC
  (half-written `_explanationHeadingRe`) and saved compiling versions
  since. Every number below is labelled with when it was measured.
- **Full-suite re-run after the siblings land is still pending** — it
  cannot be run meaningfully while the tree is mid-edit. The last
  full-suite numbers are the OCR agent's ~10:10 PKT run (§7).

## 1. PHASE 1 — AUDIT (per directive Part 2)

Read-only audit of `lib/` (plus migrations, Edge Functions, admin
panel, tests). What works, what fails, what is hardcoded.

### 1.1 Architecture (as found)

Flutter app, modular services. Parse pipeline:
`pdf_import_service.dart` (import orchestration, 3-tier OCR) →
`urdu_ocr.dart` (ML Kit / Tesseract `eng+urd` / Gemini vision;
column split; table reconstruction) → `pdf_text_extractor.dart`
(pure-Dart hardened extractor, bold markers, per-page text) →
`image_preprocess.dart` (Tesseract tier only: grayscale +
autocontrast + sharpen; measured 7→9/21 asterisks on the Paper 60
photo; Gemini reads 21/21) → `mcq_parser.dart` (~5,000 lines,
`_parseImpl`: block / one-liner / q-only / flashcard + table format)
→ `answer_key.dart` (segmentation, key parsing, key join) →
`book_structure.dart` (parts detection) → `storage_service.dart`
(SQLite v4, re-import replaces a source's questions in one
transaction — reprocessing creates no duplicate *stored* rows).
Format registry: `extraction/format_registry.dart` — only the table
format is extracted behind a handler; block/one-liner/q-only/
flashcard still live inside `_parseImpl` (documented honest scope).

### 1.2 What works (verified by tests / measurement)

- Key-entry machinery: `parseKeyEntries` on the Paper-66 page blobs
  returns 78 entries (1–78) + 22 entries (79–100) with correct
  values, including Urdu Q83–84 (`83 → "(B) تسلیم کرنا"`,
  `84 → "(A) بغل میں چھری منہ میں رام رام"` — letter intact even
  where the value text is garbled mid-line).
- Table format: 32/32 table tests (pre-existing); OCR probe
  (Sr.# p1 3/3, computer p5 3/3, interjection 9/9, adjective 6/6,
  all correctIndex correct, `answerSource='key'`); "A." markers are
  stripped by the table pass itself.
- Answer signals in priority answer-line > key > tick > bold >
  asterisk (doc, `mcq_parser.dart`); preview shows counts per source.
- Extraction-only spec is honoured in the block path (no invented
  answers; unverified → manual correction; AI generation parked).
- Storage: re-import replaces (no duplicate stored questions);
  schema v4 (crash fix) + parity tripwire test.
- OCR routing: 3 tiers with honest quality labels; Gemini is best
  (99/100 on the 112-edition key test, 19 Nov); Tesseract is the
  free/offline route; ML Kit is on-device camera OCR. EasyOCR is NOT
  viable (tested 19 Nov — poor accuracy, silent wrong answers);
  verdict stands, not re-tested.
- Security fix pass + C1 live verification, TID guard, PWA/alerts:
  see §6 (sibling reports).

### 1.3 What fails (measured, not assumed)

Baseline on pushed HEAD 1ba64ed0 (Gemini OCR of the real PDF):
**0 of 110 real questions parsed with an answer**; 10 parsed, all
false positives (fabricated, `verified=true`); 203 blocks skipped;
`keySectionsFound=0`, `keyEntriesApplied=0`; 102 answer-pending;
8 vanished (Q1, Q3–Q9). Root causes (each verified — see §5):
(1) key heading "ANSWER KEY: Model Paper 66" not recognised — the
word "Model" breaks the trailing-paper-ref strip; (2) paper headings
"MODEL PAPER 66/67" not recognised — same "Model" problem, both
papers labelled "Paper 1"; (3) Q1, Q3–Q9 vanish (numbers clipped at
the left page edge; stems and options ARE in the OCR, blocks can't
start without a number); (4) q-only fabrication from key fragments +
Explanation/Associated-Information bullets, all `verified=true`;
(5, minor) running headers become part titles; p7 key continuation
(79–100) has no heading; Q48's options split across columns; Q78's
stem mixes Urdu script.

### 1.4 Hardcoded / fragile (directive Part 21 violations found)

- `_looksLikeHeaderLine` hardcoded the year **2026** ("papers of
  2026", "year 2026") — the 2021 book's "Papers of 2021 521" header
  passed through and became a part title. **Fixed this pass** (§3.4).
- `_paperKindRe` had no qualifier: "Model" broke both the paper
  heading and the key-heading strip. **Fixed by the no-answers
  sibling in the working tree** (`(?:model\s+)?` prefix, groups
  unchanged — observed in the tree, §5.2).
- `Question` carries **no structured paper identity** (no paper
  number/title/year — only `part` + `sourceId`). A key applied to
  the wrong paper cannot be detected from the result alone (Part 13
  gap). `ParseResult.keyPaperReport` is human-readable strings, not
  structured attribution. Noted as a follow-up (wire
  `paper_identity.dart` into the key join + store the decision).
- `segmentLines` bare-key fallback (`lastQuestionPaper` — a bare key
  belongs to the paper whose questions immediately precede it)
  contradicts the directive's strict rule ("never assume a key
  belongs to the immediately preceding section"). `paper_identity.dart`
  rates that case NEEDS REVIEW in multi-paper documents; the
  follow-up must reconcile it (recommendation §9.3).
- `isVerifiedSource` includes `'flashcard'` — a flashcard "answer"
  (text after a ":" in prose) is presented as VERIFIED with
  confidence 0.9. That is the fabrication vector (§5, root cause 4).
- `_footerRe` is only `page\s*\d+\s*$` — narrow; running headers
  ("Papers of 2021 521", "524 Advanced FPJC MCQs…") were not
  caught. **Fixed this pass** (§3.4).
- No paper-identity fields are persisted per question (SQLite or
  Supabase — Supabase holds profiles/codes/payments/test_results/
  waitlist, not parsed questions).

### 1.5 Urdu OCR (directive Part 4)

- Urdu is FIRST-CLASS in routing (`chooseOcrMethod`: Urdu script →
  Tesseract `eng+urd` first, Gemini best-quality tier) and the
  parser preserves Urdu script (never Romanizes): the Paper-66 key
  entries Q83–84 resolve with script intact (§5.3).
- Honest limit (VM test 19 Nov, still true): Tesseract on dense
  ~130 DPI Nastaliq scans yields partially readable Urdu (keywords
  often recognisable) but NOT reliable enough to parse clean Urdu
  MCQs — Tier 2 (Gemini) is the quality path.
- **PaddleOCR: NOT evaluated.** Not installed on this VM; install is
  a multi-hundred-MB binary + model download; the VM had ~2 GB free
  RAM with four agents running, so a heavy install risked
  destabilising in-flight work; and PaddleOCR's script model is
  Arabic, not Nastaliq Urdu, so its expected value for the owner's
  Urdu books is low versus the already-working Gemini route (which
  read the Urdu key entries correctly). What would be needed: a
  quiet VM window, `pip install paddleocr` + the Arabic-script
  recognition model, and a test on the Paper-66 p7 Urdu key entries
  + an Urdu question page. Do NOT re-run EasyOCR (verdict stands).

### 1.6 Multi-page / duplicates / waste

- Cross-page: key continuation across pages (p6→p7) has no heading —
  the segmenter must recognise a bare numbered `(letter) text` run
  continuing an open key (follow-up §9.2). Q48's cross-column
  options and Q78's mixed-script stem are OCR-input notes, not
  parser bugs.
- Duplicates: storage dedups by sourceId replace; parse-level
  determinism was probed (8 consecutive parses, same input):
  98/98 every time on the stable tree — but a mid-edit tree showed
  98 then 96 in one run, which traced to the sibling saving
  mid-run, not to parser state. The permanent regression test pins
  determinism (`test/paper_66_67_regression_test.dart`).
- Waste: none material found in the parse path; the full suite's
  slowest tests are the real-file count tests (Examveda 546 pp,
  ~30 s) — acceptable.

## 2. PHASE 2 — DESIGN

### 2.1 Modules (implemented this pass, new files)

- **`lib/services/paper_identity.dart`** — `PaperIdentity`
  (BOOK→EXAM→YEAR→DEPT/POST→PAPER→QUESTIONS→KEY, all fields
  nullable except `sourceDocumentId`), `KeyMatchConfidence`
  (VERIFIED / HIGH_CONFIDENCE / NEEDS_REVIEW / UNVERIFIED /
  MISMATCH), `KeyMatchDecision` (`mayAutoAssign` = VERIFIED only;
  `mayAutoAssignIfApproved` adds HIGH_CONFIDENCE with explicit
  approval), `decideKeyMatch()` — pure function over caller-supplied
  facts (paper count in document, position + coverage evidence).
  Rules: different book → MISMATCH; number differs → MISMATCH;
  title differs (after qualifier-insensitive normalisation) →
  MISMATCH; number+title agree → VERIFIED; number agrees + metadata
  agrees → VERIFIED; identifier agrees + position + coverage →
  HIGH_CONFIDENCE; bare key + multi-paper doc → NEEDS REVIEW
  (preceding paper is a hint, never proof); no identity + no
  evidence → UNVERIFIED. **Coverage alone never verifies; numbers
  alone never verify.**
- **`lib/services/parse_validation.dart`** — `validateParseResult()`
  over `ParseResult`: missing answers (info, never an error —
  answerless is legitimate), duplicate questions / numbers (error),
  conflicting signals (warning), unmatched key entries (warning),
  fabrication suspects (warning). Detection rule for fabrication:
  a flashcard/q-only question whose text is an option-marker
  fragment (`(A) Speak:`), a bullet label (`- Conquests:`), a
  dash-label tail (`… - Mongol Emperor:`), or a short bare label
  ending in `:` with no `?` and no instruction verb
  (`Oldest University in Europe:`) — all 10 baseline fabrications
  match; legitimate stems (`What is…?`, `Choose the correct
  synonym Wheedle:`) do not. Never repairs, never drops — only
  reports. Known limit: wrong-paper key application is undetectable
  from `ParseResult` alone (see §1.4).

### 2.2 Interaction (how the pieces fit — to be wired after the sibling lands)

OCR/layout → `parseMcqsFromPages` (parser + `segmentLines`) →
`paper_identity.decideKeyMatch` at the key join (segmenter supplies
key paper + question paper + position/coverage evidence; only
VERIFIED, or HIGH_CONFIDENCE with the regression test as the
recorded approval, auto-assigns) → `parse_validation.validateParseResult`
on the result (preview shows the report before anything is saved)
→ storage (sourceId replace = no duplicate stored rows).
Prohibitions honoured: no hardcoded paper numbers/pages/positions
(the "Model" fix is a qualifier rule, not a Paper-66 special case);
no nearest-key; no numbers-alone matching; no fabricated answers
(the validation rule flags them, and the parser fix must stop
marking pool-built answers `verified=true`).

## 3. PHASE 3 — IMPLEMENTATION (this pass)

### 3.1 New files (implemented + tested)

| File | What | Tests |
|---|---|---|
| `lib/services/paper_identity.dart` | Part 7 identity + Part 8 decisions (§2.1) | `test/paper_identity_test.dart` — **11/11 passed** (Paper 66 key→66 VERIFIED; 66 key→67 MISMATCH; same number different book MISMATCH; bare key multi-paper NEEDS REVIEW; bare key single-paper + position/coverage HIGH CONFIDENCE; coverage-alone never VERIFIED) |
| `lib/services/parse_validation.dart` | Part 10 validation (§2.1) | `test/parse_validation_test.dart` — **6/6 passed** (clean result; missing = info; duplicates = error; conflicts/unmatched flagged; all 10 baseline fabrications flagged; legitimate q-only/flashcard NOT flagged) |
| `test/paper_66_67_regression_test.dart` | Permanent Paper 66/67 gate (§5, acceptance target) | **0/7 passing — fails by design** until RC3 + RC4-remainder land (see §5.2) |
| `test/table_title_pending_test.dart` | Sr.# title + subject items (§3.5) | **0/4 passing — fails by design** (reproduces both items; fix spec §9.1) |
| `test/running_header_test.dart` | Running headers never become parts | **2/2 passed** |

### 3.2 Regression test — the Paper 66/67 gate (permanent)

`test/paper_66_67_regression_test.dart` runs the real parser on the
real Gemini OCR text (`test-fixtures/ppsc66/ocr-pN.txt`) and asserts
the §8 acceptance target: `keySectionsFound ≥ 1`,
`keyEntriesApplied == 100`, 100 Paper-66 questions parsed with key
answers, spot-checks (Q1 "The Plague" → B; Q2 "Are they blaming
us" → A), Urdu entries 83–84 resolve with script preserved,
Paper 67's 10 pending (0 parsed on p7, no key leakage), 0 false
positives (none of the 10 baseline fabrication texts), total parsed
== 100, reprocessing deterministic with no duplicates. **Do NOT
weaken these assertions to make the suite green — fix the parser.**

### 3.3 What the sibling already fixed (observed in the working tree)

The no-answers agent fixed the "Model" qualifier in
`answer_key.dart`: `_paperKindRe` is now
`(?:model\s+)?(paper|test|set|part|section)` (non-capturing prefix,
so kind/id group numbering is unchanged everywhere it is used —
paper headings, paper references, key-heading strips).
Measured effect (§5.2): `isAnswerKeyHeading("ANSWER KEY: Model
Paper 66")` → **true**; `keySectionsFound` 0 → 1;
`keyEntriesApplied` 0 → 91. It also fixed the broken import
(`answer_key.dart:59` now `import '../models/question.dart'`).
Its key-fragment guard works: the 3 key-fragment fabrications are
gone (10 → 7 fabrications). It is mid-rewrite of the
flashcard/q-only/pending paths (counts move run to run) and was
observed adding an `_explanationHeadingRe` guard (mid-edit at
05:13 UTC).

### 3.4 Running-header fix (implemented this pass — `book_structure.dart`)

Baseline §5.5: pending rows carried part labels from running
headers ("522", "524", "524 Advanced FPJC MCQs Model Papers
(Volume 2)"). Root cause: `_looksLikeHeaderLine` hardcoded the
year 2026, and `_isExcludedLine` had no rule for bare page numbers
or page-number-prefixed footers. Fix (in `book_structure.dart`,
unowned file, untouched by any sibling):
- `_looksLikeHeaderLine`: `year` / `papers of` now match ANY year
  `(19|20)\d\d`, not just 2026.
- `_isExcludedLine`: a running header/footer is never a part title —
  `Papers of YYYY N`, `Year YYYY`, a bare number (`^\d{1,4}$`),
  or a page-number-prefixed footer (`^(\d{1,4})\s+[A-Z]` where the
  number is NOT a year 1900–2099, so a real "2021 Current Affairs"
  heading survives; a question start `524. …` carries punctuation,
  not a space, so it is untouched).
Verified: `test/running_header_test.dart` 2/2, and the mid-flight
harness shows clean parts (`English Grammar:1-6:91`,
`General Knowledge:7-7:7`) with Q2's pending row correctly
part-labelled "English Grammar".

### 3.5 Table title + subject (OCR probe items — tests written, fix specified, NOT yet implemented)

Probe (verified this pass, `test/_probe_phantom_test.dart`, deleted
after running): Sr.# input → 3 questions correct + **1 spurious
pending: text="Computer Most Important Questions",
options=[A, B, C, D], reason=no-key-entry, subject=gk**. Mechanism
(traced in `_parseTableRowWise`): the title line buffers as a
question stem (it is not a section heading — no "and its types" —
and the heading-row skip needs the next cell to be a bare number,
but the next line is the header row); the header row's A–D cells are
collected as its 4-option run and anchored by the "Ans" cell as a
type label, with no key letter → pending. The same phantom appears
for ANY Sr.#-style table with a title (my "General Questions"
control also yields 1 spurious pending). The 3 real rows are
correct (correctIndex 0/2/1, "A." markers stripped,
`answerSource='key'`) — the fix must preserve that.
Subject: rows come out `Subject.gk`; the existing rule
(`_tableSubjectFor`) only maps English-grammar section headings
(adjective/article/noun/verb/adverb/pronoun/grammar/english) and
never sees the table title (not a section heading) or the
in-table heading rows ("Interjection" is not an "and its types"
heading).
**Fix spec — see §9.1 (exact code). Blocked on the no-answers
sibling: `mcq_parser.dart` is its in-flight file (saved 05:20 UTC,
still running). Tests are in place; the edit must wait for its
report to land.**

## 4. PHASE 4 — OCR EVALUATION (summary; detail in §1.5 + §5.3)

- Tesseract: kept, free/offline; partial Urdu on dense Nastaliq
  scans; cannot do column split (plain `String` API, no
  coordinates); plain-`String` API also means no bold/style.
- ML Kit: on-device camera OCR; column split + table
  reconstruction now wired in (OCR agent, 25/25 tests); no
  bold/style field (verified from `google_mlkit_text_recognition`
  0.16.0) — bold is undetectable from a camera photo.
- Gemini vision: best quality; reads the Paper-66 Urdu key
  entries correctly (Q83–84) and 21/21 asterisks on the Paper 60
  photo.
- PaddleOCR: unevaluated with reasons (§1.5). EasyOCR: not viable
  (19 Nov verdict stands, not re-tested).

## 5. PHASE 5–6 — TESTING + REAL VALIDATION: the Paper-66 baseline, re-run

### 5.1 Baseline (HEAD 1ba64ed0, Gemini OCR) — from PPSC66_BASELINE_2026-11-20.md

| Metric | Baseline |
|---|---|
| Questions parsed (with an answer) | 10 — all FALSE positives |
| True positives | 0 / 110 |
| Skipped blocks | 203 |
| Format counts | block 0, one-liner 0, q-only 10, table 0 |
| Answer sources | flashcard 10 |
| Key sections found / entries applied | 0 / 0 |
| Answer-pending | 102 (92 Paper 66 + 10 Paper 67) |
| Vanished (no parsed, no pending, no error) | 8 (Q1, Q3–Q9) |
| Parts | 2 garbage parts (key/explanation fragments) |

### 5.2 Mid-flight re-run (working tree, ~05:09 UTC / 10:09 PKT — NO-ANSWERS SIBLING STILL EDITING, not the post-sibling re-run)

The parent asked for a harness re-run after the siblings land.
They have not landed, so this is a labelled mid-flight snapshot,
measured with the baseline harness
(`test/ppsc66_baseline_test.dart`) + the new regression test on the
same OCR text:

| Metric | Baseline | Mid-flight |
|---|---|---|
| Questions parsed (with an answer) | 10 (all false) | **98** |
| Skipped blocks | 203 | **15** |
| Format counts | block 0, q-only 10 | block 91, q-only 7 |
| Answer sources | flashcard 10 | key 91, flashcard 7 |
| Key sections found / entries applied | 0 / 0 | **1 / 91** |
| `isAnswerKeyHeading("ANSWER KEY: Model Paper 66")` | false | **true** |
| Questions missing answers | 101 (mangled, Q10 twice, Q2 absent) | **10** (clean: Paper 67 Q1–Q10, "no key entry") |
| Unmatched key entries | [] | 9 (Paper 66 entries 1–9 — the clipped-number questions) |
| Number gaps / duplicates | [] / [] | [] / [] |
| Conflicts | [] | [] |
| Parts | 2 garbage | English Grammar:1-6:91, General Knowledge:7-7:7 |
| Answer-pending | 102 | 11 (Q2 p1 + 10 Paper 67) |
| Fabrications (verified=true) | 10 | 7 (key fragments gone; Paper-67 explanation bullets remain) |
| Vanished | 8 (Q1, Q3–Q9) | 8 (Q1, Q3–Q9 — Q2 now pending, unmatched) |

Reconciliation: 91 keyed + 7 fabricated + 11 pending + 8 vanished
= 117 = 110 real + 7 fabrications. **The gate is NOT met:**
100/100 Paper 66 with key answers needs RC3 (clipped numbers) +
the Q2 numbering fix; 0 false positives needs the
Explanation/Associated-Information guard (RC4 remainder).
**The final harness re-run must wait for the no-answers sibling's
report to land** — the tree did not compile at 05:13 UTC
(syntax-broken mid-edit) and counts move run to run while it edits.

### 5.3 Urdu test material (Paper-66 key Q83–84 + Q78 stem)

- Entry level: `parseKeyEntries` on the p7 blob returns
  `83 → "(B) تسلیم کرنا"`, `84 → "(A) بغل میں چھری منہ میں رام رام"`
  — letter intact, script preserved, never Romanized. Pinned by
  the regression test (passes at entry level today).
- Application level: entries 83/84 are among the 91 applied (the
  9 unmatched are entries 1–9, not 83/84); the regression test's
  application-level assertion (`keyEntriesApplied == 100`) fails
  until RC3 lands.
- Mixed-script stems survive: Q78's stem carries Urdu script
  (`78. بیگu حالت Translate into English.` — the `u` is a misread,
  reported as-is, not corrected).
- No Urdu accuracy claim is made from English-only material.

### 5.4 Five test photos (owner's formats) — validation status

- (1) Paper 60 two-column photo: OCR agent fixed the camera path
  (column split wired in; table detection first). Phone re-test
  with the same photo is the proof (Q11 + cross-column questions
  must parse with `*` answers) — NOT yet done (needs v2.0.1).
- (2) Adjective/Article table: OCR 25/25; parser 6/6, 0 pending.
- (3) Computer Sr.# table p1/71: OCR probe 3/3; parser 3/3 +
  1 spurious pending (this pass, §3.5).
- (4) Interjection table Q230–257: OCR probe 9/9; parser subject
  is gk, not english (this pass, §3.5).
- (5) Computer table Q67–81 p5/71: OCR probe 3/3; parser subject
  is gk (this pass, §3.5).
- Real-device ML Kit segmentation is unverified for all four table
  photos — the owner's phone re-test is the proof.

## 6. SIBLING REPORTS FOLDED IN

- **Baseline agent (DONE):** `PPSC66_BASELINE_2026-11-20.md` —
  the measurement in §5.1 + the §8 checklist this pass works from.
  Caveats carried forward: Gemini OCR ≠ on-device ML Kit OCR;
  p3 hand-stitched after Gemini recitation blocks; baseline measured
  on HEAD, not the working tree.
- **TID/payment agent (DONE):** `SECURITY_FIXES_2026-11-20.md`
  (TID section) — migration 012 (partial unique index, file only,
  NOT live); issue-code v2 ACTIVE (payment binding, server-side
  approval, plan from the payment row); payment-alert v1 ACTIVE
  (`verify_jwt=False`, secret-gated); receipt BOTH channels
  (in-app upload REQUIRED via migration 013 + private
  `payment-proofs` bucket, AND WhatsApp to 03427717288); PWA
  (manifest + icons + service worker, panel deployments
  `988d6a23` + `33631139`); Realtime new-payment alert (green
  pulsing banner + Web Audio beep, needs migration 014 live);
  payment-chain audit verdict: no bypass found, premium only via
  admin approval; residual risks stated plainly (admin manual check
  is the ONLY proof money arrived — no Easypaisa/JazzCash lookup
  API; duplicate guard stops the SAME TID twice, not a fresh one).
  Full suite in its pass: 762 passed, 5 skipped, 5 failed (all 5
  parser table/OCR in-flight tests). Parent actions outstanding:
  apply migrations 012–014 live; set `PAYMENT_ALERT_SECRET` in the
  dashboard + create the DB webhook (the value the agent generated
  was redacted by the parent before any commit — use a fresh strong
  random value, the SAME value in the secret AND the webhook
  header); live end-to-end proofs (receipt upload + signed URL,
  Realtime beep on a real payment, PWA install on his phone, alert
  email).
- **OCR agent (DONE):** `OCR_TWO_COLUMN_FIX_2026-11-20.md` —
  column split wired into `_runOcrWithMlKit` (7/7 tests);
  `reconstructTableText` (7/7 tests); standalone harness 59/59;
  OCR total 25/25; analyze clean on its files. Limits (verified):
  Tesseract returns plain `String` — no coordinates, so the column
  split cannot apply to the Tesseract path; ML Kit exposes no font/
  weight/style — bold cannot be detected from a camera photo.
  Parser-side items from its probe are this pass's §3.5.
- **No-answers agent (STILL RUNNING, report NOT landed):**
  no-answers notice (green + animated), key-attach flow,
  title-matched keys, test-without-answers mode. Observed in the
  tree: "Model" qualifier fix (§3.3), import fix, key-fragment
  guard, `_explanationHeadingRe` in progress. Its report
  (`PARSE_NO_ANSWER_NOTICE_2026-11-20.md`) does not exist yet.

## 7. FULL-SUITE STATE + THE SIX NON-REGRESSION FAILURES (verdict)

- 08:45 PKT: 723 passed, 5 skipped, **1 failed** (payment_proof —
  a mid-run edit artifact; standalone re-run 18/18).
- TID pass (~10:00): **762 passed, 5 skipped, 5 failed** — all 5
  parser table/OCR tests in the OCR agent's in-flight work.
- OCR pass (~10:10): **784 passed, 5 skipped, 13 failed** — 0 in
  any OCR file. The 13: 7 in `paper_66_67_regression_test` (fails
  by design until the parser fixes land) + 2
  `universal_formats_test`, 1 `realfile_counts_test`, 1
  `examveda_scale_test`, 1 `failure_guidance_test`, 1
  `phase_a_gaps_test`.
- My re-run of those 5 files (~10:15 UTC): 67 passed, **10 failed**
  in those files (the count moves as the sibling edits).

**Verdict on the 6 (now 10 in the latest run): NOT pre-existing.**
All six passed in the 08:45 full suite and in the TID pass. They
appeared between ~10:00 and 10:10, while the no-answers sibling
was rewriting the flashcard/q-only/key/pending paths. Failure
signature (measured 10:15): pure COUNT shifts in extraction paths
— F2 pending 25→7; F3 181→189; F6 Pace 1442→1376; MPT 142→128;
Examveda 3202→3293; junior_clerk pending 1→0; G2 (same F3 count).
**Not caused by this pass's `book_structure.dart` edit:** that
edit touches only part-title detection, and no failure mentions a
part title, subject, or header — every failure is a parsed/pending
count or an answer-source label in the sibling's paths. Some of
these documented counts may legitimately need re-baselining (the
sibling's answerless `-1` sentinel changes parsed-vs-pending
accounting by design) rather than "fixing" in code — that call
belongs to the sibling's report + the parent, after it lands.
**`flutter analyze`: 20–23 issues, all info-level `avoid_print`
in `test/ppsc66_baseline_test.dart` (the diagnostic harness's
prints); zero errors, zero warnings, zero issues in any file this
pass touched or created.**

## 8. REMAINING LIMITATIONS (honest)

- The Paper 66/67 gate is NOT met (91/100 keyed, 7 fabrications,
  8 vanished) — RC3 + RC4-remainder outstanding (§9).
- The table title/subject fixes are specified + tested, not
  implemented (blocked on the sibling).
- `paper_identity.dart` and `parse_validation.dart` are NOT yet
  wired into the key join / upload preview (their call sites are
  sibling-owned files).
- PaddleOCR unevaluated (§1.5). Tesseract Urdu is partial; Gemini
  is the quality route. Bold is undetectable from camera photos
  (ML Kit API limit, verified).
- On-device ML Kit behaviour (column split, table reconstruction,
  asterisk reading) is proven only by synthetic tests — the
  owner's phone re-test is the proof (v2.0.1).
- The full suite has not been re-run green on a settled tree; the
  last green full suite was 723/1 at 08:45 (before wave 2).

## 9. WHAT IS NOT DONE AND WHY — WITH EXACT FIX SPECS FOR THE FOLLOW-UP

### 9.1 Table title + subject (blocked on no-answers sibling; tests ready)

File: `lib/services/mcq_parser.dart`. Tests:
`test/table_title_pending_test.dart` (0/4 — fails by design).

**(a) Title skip in `_parseTableRowWise`** — right after the
existing in-table heading-row skip (the block that skips a lone
heading followed by a bare Sr.#). Add a parallel rule: when the
buffer is empty, the cell is alone on its line, and the NEXT line
is the column-header row, the line is a table TITLE — consume it
(`sink.consumed.add(cell.lineIndex)`) and skip it. Next-line-is-
header-row test: the next line has ≥3 cells and EVERY cell is a
column header (`_isTableColumnHeader`) or a bare single letter
A–D. Safety (from the code's own invariants): a real stem is never
alone on its line in a `'|'` table (its row shares the line), and a
real stem is never followed by a header row — so this can only
match a title. Helper: `_isTableTitleLine(cells, i)`.

**(b) Backstop in `_TableSink.addRow`** — at the resolved/pending
branch (after option-marker stripping): if the 4 options are
exactly the bare header labels `['A','B','C','D']` and the question
text contains no `?`, the row is header structure, not a question
— skip it (`skipped++`, add to neither questions nor pending).
A real row's options are never bare single letters.

**(c) Subject in `_tableSubjectFor`** — the heading scan currently
only accepts `_isTableSectionHeading` cells ("…and its types").
Extend it to also accept: (i) an in-table heading row
(`_isTableHeadingRow`, alone on its line — e.g. "Interjection");
(ii) a table title line (same `_isTableTitleLine` shape as (a) —
e.g. "Computer Most Important Questions"). Take the NEAREST such
heading/title before the question line. Keyword map (lexical,
same kind as the existing rule — detection, not guessing):
`computer` → `Subject.mathsComputer`; `english`, `grammar`,
`adjective`, `article`, `noun`, `verb`, `adverb`, `pronoun`,
`interjection`, `gerund`, `participle`, `infinitive`, `tense`,
`part of speech` / `parts of speech` → `Subject.english`. No
match → keep the `fallback` (`Subject.gk`). Deliberately minimal:
do not add other subjects without a real table that needs them.

### 9.2 Paper-66 root causes 3 + 4 (blocked on no-answers sibling)

**(RC3 — clipped numbers Q1, Q3–Q9 + Q2 misnumbering).** The
stems and options ARE in the OCR; blocks can't start without a
number, and the sequential numbering shifts so key entry 2 doesn't
match Q2 (entries 1–9 all unmatched). Fix direction (per baseline
§5.3 — "needs a block-level trace, not another guess"): instrument
the block formation, then recover numbers from sequence position
(a complete-looking block — stem + 4 options — with no number,
sitting between numbered neighbours, takes the next expected
number). Hard constraint: a recovered number must never shift key
matching — if the number can't be trusted, the question stays
pending for manual correction with its position recorded, never
silently dropped and never guessed. Acceptance: the regression
test's spot-checks (Q1 → B, Q2 → A) + `keyEntriesApplied == 100`.

**(RC4 remainder — Explanation/Associated-Information guard).**
The key-fragment half is fixed (key section now recognised, its
lines never reach the question parsers). Remaining: the 7 Paper-67
explanation bullets. The sibling was observed adding
`_explanationHeadingRe` (mid-edit 05:13 UTC). Requirement:
"Explanation:" / "Associated Information:" blocks and their bullet
lines must never reach `_scanFlashcards` / the q-only path; and a
q-only/flashcard question whose answer comes from the book's
answer pool must never be marked `verified=true`
(`isVerifiedSource` including `'flashcard'` is the vector).
`parse_validation.dart`'s `_looksFabricated` encodes the exact
detection rule — reuse it (or an equivalent) in the parser path
or as a post-parse filter that demotes such questions to pending.
Acceptance: regression test "0 false positives" + Paper-67 "10
pending, 0 parsed on p7".

**(Key continuation, minor.)** The p7 key continuation (79–100)
has no heading — the segmenter must recognise a bare numbered
`(letter) text` run continuing an open key from the previous page.
Covered by the regression test (`keyEntriesApplied == 100`).

### 9.3 Wiring + reconciliation (after the sibling lands)

- Wire `decideKeyMatch` into the key join (`segmentLines` /
  `flushKey` in `answer_key.dart`): the segmenter supplies key
  paper + question paper + paper count + position/coverage
  evidence; only VERIFIED (or HIGH_CONFIDENCE with the regression
  test as the recorded approval) auto-assigns; NEEDS_REVIEW /
  UNVERIFIED / MISMATCH stay unassigned and are reported in
  `keyPaperReport`. Reconcile the `lastQuestionPaper` bare-key
  fallback with the directive: keep it ONLY when the document
  holds exactly one paper (HIGH CONFIDENCE with position +
  coverage); in multi-paper documents a bare key stays unassigned
  pending review.
- Wire `validateParseResult` into the upload preview
  (`upload_screen.dart`): show the report before anything is saved.
- Re-run the harness + the regression test on the settled tree;
  re-baseline the six documented-count tests if the sibling's
  answerless accounting legitimately changed them (update
  `AUDIT_REPORT.md` counts with measured numbers, don't force the
  code back to stale counts).
- Then: full suite + analyze green, then the v2.0.1 push (see §10).

## 10. DEPLOYMENT REQUIREMENTS (for the parent — nothing done here)

- Do NOT commit/push/release from this pass. The tree is mid-edit
  by the no-answers sibling; nothing here is pushed.
- Parent live steps outstanding (from the TID pass): apply
  migrations 012, 013, 014 in the Supabase SQL editor (013's
  storage-policy SQL is unverified against the live project —
  verify before running); set `PAYMENT_ALERT_SECRET` (fresh strong
  random value) in Dashboard → Edge Functions → Secrets AND use
  the same value as the webhook header when creating the
  Database webhook (payments INSERT → payment-alert); live proofs:
  receipt upload + signed URL, Realtime beep on a real payment,
  PWA install on his phone, alert email end to end.
- v2.0.1 contents (when the parent confirms the signed rebuild):
  crash fix (storage v4), L6 deep-link fix, L7 secure storage, M3
  checksum, TID + receipt + PWA + alerts, no-answers notice +
  key-attach, OCR column split + table reconstruction, parser fixes
  from the PPSC-66 baseline (§9) + the table title/subject fixes
  (§9.1). H1 keystore decision still pending with the user (v2.0.0's
  ephemeral key is lost — one uninstall/reinstall for the ~62
  v1.2.0 users + his own v2.0.0 install).
- Phone re-test acceptance (owner's proof, after v2.0.1): same
  Paper 60 photo (Q11 + cross-column questions with `*` answers),
  same 4 table photos, same PPSC-66 PDF. Do not call the parser
  work complete until his phone test passes.

## 11. FILES INSPECTED / MODIFIED (this pass)

- **Inspected (read-only):** `lib/services/mcq_parser.dart`,
  `answer_key.dart`, `book_structure.dart`, `urdu_ocr.dart`,
  `pdf_import_service.dart`, `pdf_text_extractor.dart`,
  `image_preprocess.dart`, `storage_service.dart`,
  `extraction/format_registry.dart`, `extraction/layout_patterns.dart`,
  `lib/models/question.dart`, `test_generator.dart`,
  `supabase/migrations/001–014.sql`, `lib/services/payment_proof_service.dart`
  (via the TID report), `admin/` (via the TID report).
- **Created:** `lib/services/paper_identity.dart`,
  `lib/services/parse_validation.dart`,
  `test/paper_identity_test.dart`, `test/parse_validation_test.dart`,
  `test/paper_66_67_regression_test.dart`,
  `test/table_title_pending_test.dart`,
  `test/running_header_test.dart`,
  `MASTER_DIRECTIVE_AUDIT_2026-11-20.md` (this report).
- **Modified:** `lib/services/book_structure.dart` only (running-
  header fix, §3.4). No payment/admin/storage/OCR files touched.
  No DB changes. No commits, pushes, releases, or version bumps.
