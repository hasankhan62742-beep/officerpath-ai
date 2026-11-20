# Master Directive Wiring — 20 Nov 2026

The two remaining wave-2 wiring items from `MASTER_DIRECTIVE_AUDIT_2026-11-20.md`
(§9.3): `decideKeyMatch` into the parser's key join, and
`validateParseResult` into the upload preview. Working tree only — no
commits, pushes, releases, version bumps, or CI triggers (per task rules).

## 1. `decideKeyMatch` in the key join

**New function — `keyMatchDecisions` in `lib/services/answer_key.dart`**
(~line 1000). For every key-paper label in the segmented text it calls
`decideKeyMatch` with:

- Explicit key (its heading named a paper, e.g. `ANSWER KEY: Model Paper
  66`): the key carries that paper's number + title. Bare key (no
  heading): the key carries NO identity — its attribution to the
  preceding paper is position evidence only, never identity.
- Question paper identity from the paper label (`"Paper 66"` → number
  66 + title; `"January 2026"` → title only; default `"Paper 1"` →
  number 1).
- `paperCountInDocument` counts PAPER-kind labels only
  (Paper/Test/Set/Part/Section). Month labels are sections within one
  paper, not papers — a month-grouped book (Pace) is still one paper,
  so its per-month bare keys stay HIGH CONFIDENCE.
- Coverage: ≥1 key entry number appears among that paper's
  question-line numbers (corroboration, never proof).
- Exclusive coverage (new, see §3): no key entry number appears in
  any other segment's question numbers.

**Gate — `_parseImpl` in `lib/services/mcq_parser.dart`** (~line 2088).
Decisions are computed before the block loop. VERIFIED and HIGH
CONFIDENCE apply. NEEDS REVIEW / UNVERIFIED / MISMATCH entries are
**withheld upfront** — removed from `segmented.keyEntries`, so the joins
see no token, the defect-branch removals are no-ops, and the entries are
never reported as "unmatched". The decision reason is reported in
`keyPaperReport` instead: `"Key '<label>' nahi lagayi — <reason>"`.

**HIGH CONFIDENCE flag** (`mcq_parser.dart` ~line 3642). Applied keys
with a HIGH decision get an extra `keyPaperReport` line:
`"Key '<label>' HIGH CONFIDENCE se lagi — <reason> Save karne se pehle
tasdeeq karein."` — only when the key actually applied.

**Design decision (documented in code): the preview + Save IS the
existing user confirmation path for HIGH.** The parser runs BEFORE the
preview, so there is no per-key confirm dialog to wait on; withholding
HIGH would break the normal case (a bare key at the end of a
single-paper book, and the Pace book's per-month bare keys — both pinned
by existing tests). This reconciles "only VERIFIED auto-assigns" with
"HIGH needs the existing user confirmation path" and the
no-re-baselining rule.

**Deliberately NOT gated:** `applyAttachedKey` — the user's explicit
attach IS the confirmation path. The table pass does NOT consult the
book key (answers come from the per-row Ans column) — unaffected.
Explicit keys are always VERIFIED under the per-label construction (the
segmenter already scopes by label, so the join can never cross-apply an
explicit key); MISMATCH is unreachable in the in-book join (only
reachable via direct `decideKeyMatch` calls, already tested in
`paper_identity_test.dart`).

## 2. `validateParseResult` in the upload preview

**Call site — `_importResult` in `lib/screens/upload_screen.dart`.**
After the selection step, a minimal `ParseResult` is built from the
working (post-selection) result (questions, parsed, skipped,
answerPending, questionsMissingAnswers, numberDuplicates, conflicts,
unmatchedKeyEntries, keyPaperReport) and `validateParseResult` runs on
it. The `ValidationReport` is passed to `ExtractionPreviewDialog` as a
new optional nullable `validation` param (existing direct constructions
in tests still compile; null = no box).

**New widget — `ValidationReportBox`** (same file, public for tests):

- Errors → red card: "Is import mein masla hai — save nahi ho sakta."
  + up to 3 error details + "Duplicate sawal test ko kharab karte
  hain — file theek karke dobara import karein."
- Warnings/infos → amber card: "Check karne wali baatein:", warnings
  first then infos, capped at 5 + "…aur N aur." line.
- Shown in the dialog before the summary lines.

**Errors block saving:** Save (FilledButton) and save-answerless
(OutlinedButton) get `onPressed: null` when
`validation?.hasErrors == true`. Manual correction, key attach, MPT and
Cancel stay enabled (they don't save directly; they loop back to the
preview) — the user is never stuck without an exit.

**NoMcqsDialog (parsed == 0) was NOT changed:** validation errors
(duplicates) require ≥2 parsed questions, so they cannot occur there;
missing-answer infos are already covered by the no-answers notice.

The 10 baseline fabrications are flagged by `validateParseResult` as
warnings (already covered by `parse_validation_test.dart` — not
weakened); the preview surfacing is the new part.

## 3. Defect found during verification — and fixed

The first post-wiring full-suite run came back **835 passed, 5 skipped,
1 failed**. The failure was pre-existing, not one of the new tests:

`test/parser_signals_test.dart` — "mid-page key belongs to the previous
paper, never the next": Paper 1 Q61, bare key `61. (C) 3`, then Paper 2
Q1. Expected: the key answers Paper 1 Q61, Paper 2 Q1 stays pending.

**Root cause:** `decideKeyMatch`'s bare-key HIGH branch required
`paperCountInDocument == 1`, so ANY bare key in a 2-paper document was
NEEDS REVIEW and withheld — even when position and coverage agree on one
paper. My own multi-paper wiring test (bare key, entries {1, 2}, Paper 1
Q1–Q2 + Paper 2 Q1) was correctly NEEDS REVIEW, because entry 1 matches
BOTH papers — ambiguous. The failing test's entry 61 matches ONLY
Paper 1 — the two cases differ in exactly one fact: whether the
coverage is **exclusive**.

**Fix — exclusive coverage evidence:**

- `lib/services/paper_identity.dart`: new optional param
  `hasExclusiveCoverageEvidence` (default `false`, backward
  compatible). The bare-key HIGH branch is now
  `position && coverage && (paperCount == 1 || exclusiveCoverage)`,
  with a distinct reason for the multi-paper case: "Bare key follows
  this paper and its numbers match only this paper — no other paper in
  the document shares them." Non-exclusive coverage in a multi-paper
  document still falls through to NEEDS REVIEW. The existing direct
  test "bare key in a multi-paper document is NEEDS REVIEW" is
  untouched and still passes (it does not pass the new flag).
- `lib/services/answer_key.dart`: `keyMatchDecisions` now computes
  exclusivity — every key entry number must be absent from every other
  segment's question numbers (an entry matching nothing at all, e.g.
  from a clipped number, does not break exclusivity; it is reported as
  unmatched by the join). All other segments count, not just
  paper-kind labels — deliberately conservative: a wrong HIGH costs a
  mis-answered paper, a NEEDS REVIEW costs one explicit key-attach tap.
  A month-grouped book is unaffected (one paper → the single-paper
  branch applies before exclusivity is consulted).

**New pinning tests (2):**

- `test/paper_identity_test.dart`: "bare key, multi-paper, EXCLUSIVE
  coverage is HIGH CONFIDENCE" (direct `decideKeyMatch`).
- `test/key_match_wiring_test.dart`: "mid-page bare key applies when
  its numbers match only the preceding paper" (the exact
  parser_signals shape at parser level, including the HIGH flag line).

## 4. Files changed

| File | Change |
|---|---|
| `lib/services/answer_key.dart` | `keyMatchDecisions` (new) + exclusive-coverage computation |
| `lib/services/paper_identity.dart` | `hasExclusiveCoverageEvidence` param + HIGH branch + doc comments |
| `lib/services/mcq_parser.dart` | Gate in `_parseImpl` (~2088); HIGH flag + withheld reasons in `keyPaperReport` (~3642) |
| `lib/screens/upload_screen.dart` | `validateParseResult` in `_importResult`; `ValidationReportBox`; Save blocked on errors |
| `test/key_match_wiring_test.dart` | 6 tests (5 original + 1 mid-page pin) |
| `test/preview_validation_test.dart` | 5 tests (new) |
| `test/paper_identity_test.dart` | +1 test (exclusive coverage HIGH) |

NOT touched (per task rules): `storage_service.dart`, payment/admin
files, OCR column work, keystore/workflow files, `pubspec.yaml`. No
test counts were re-baselined: no existing expectation was changed; the
one existing test that failed was fixed by a real rule change
(exclusive coverage), pinned by 2 new tests.

## 5. Test results

- Targeted run (9 files: parser_signals, key_match_wiring,
  paper_identity, paper_66_67 regression, answer_key, key_attach,
  table_title_pending, parse_validation, preview_validation):
  **130/130 passed** (after the §3 fix).
- **Full suite (final): 838 passed, 5 skipped, 0 failed**
  (`flutter test`, exit 0, "All tests passed!"). Baseline before this
  work: 826 passed, 5 skipped, 0 failed. The +12 is exactly the 12 new
  tests (5 key-match wiring + 5 preview validation + 1 exclusive
  coverage unit test + 1 mid-page parser pin). No other count moved.
- **Analyze: 0 issues** (`flutter analyze`, "No issues found!").
- Gate tests still green in the final run: Paper 66/67 regression 7/7
  (100/100 Paper 66 keyed, 0 false positives, Paper 67's 10 pending),
  table_title_pending 4/4, parse_validation 6/6 (incl. the 10 baseline
  fabrications flagged), paper_identity 12/12.

## 6. NOT verified

- **Phone test is out of scope** (per task): no on-device run of the
  upload preview, the ValidationReportBox, the HIGH flag line, or the
  mid-page-key behaviour on a real phone. The owner's phone re-test
  (same Paper 60 photo, same 4 table photos, same PPSC-66 PDF) is still
  the proof for the parser work as a whole.
- No commit/push/release/CI run was done — the first signed v2.0.1 CI
  build is still the end-to-end proof for the workflow side.
- Live Supabase behaviour (admin-panel grant, redeem smoke test,
  payment-alert email, Realtime beep) is unchanged by this work and
  still awaits a real payment flow; none of it was touched here.
