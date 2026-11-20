import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';

// Worker 4 — governing spec 19 Nov 2026, items 3–4.
//
// (3) OFFICIAL vs STUDENT marks: a student's own handwritten
// tick/circle is NOT the answer key. When the parser cannot tell a
// printed/official mark from a student's handwritten one, the
// question is UNVERIFIED, never guessed.
// (4) CONFIDENCE + VERIFICATION STATUS: the extraction preview must
// show, per question: question, options A–D, detected correct
// answer, source page, CONFIDENCE SCORE, verification status — and
// manual correction must keep the ORIGINAL extracted answer separate
// from the manually corrected answer.
//
// What the tests below prove:
// * A ✓ in TEXT-LAYER text is trusted (a text PDF's ✓ is printed
//   by definition — it came from the book's own typesetting).
// * Pen-stroke artefacts OCR commonly produces ('/', circled
//   letters) are NOT trusted as answer signals — the question goes
//   pending instead of being guessed.
// * The provenance distinction for OCR-sourced ticks, and the
//   confidence / verification-status / original-vs-corrected model,
//   are MISSING — documented as GAP tests (source-level) so the
//   integration phase can implement them. The parser takes raw text
//   and has no channel that says "this ✓ came from a camera photo,
//   provenance unknown".
void main() {
  ParseResult parseText(String text) => parseMcqs(
        text,
        sourceId: 'unverified-marks-test',
        sourceLabel: 'marks test',
      );

  group('printed tick — trusted when the source is the text layer', () {
    test('a ✓ on one option is the answer (answerSource tick)', () {
      const text = '''
1. Which is the largest planet?
(A) Mars
(B) Venus
(C) Jupiter ✓
(D) Saturn
''';
      final r = parseText(text);
      expect(r.parsed, 1);
      expect(r.questions.single.correctIndex, 2);
      expect(r.questions.single.answerSource, 'tick');
    });

    test('a ✔ on one option is the answer too', () {
      const text = '''
1. Which is the largest planet?
(A) Mars
(B) Venus ✔
(C) Jupiter
(D) Saturn
''';
      final r = parseText(text);
      expect(r.parsed, 1);
      expect(r.questions.single.correctIndex, 1);
      expect(r.questions.single.answerSource, 'tick');
    });
  });

  group('handwritten-style artefacts — never trusted as answers', () {
    test('a pen stroke "/" after an option is NOT an answer signal',
        () {
      // A hand-drawn tick often OCRs as '/' (or is dropped). The
      // parser must not read a '/' as a ✓ — the question goes
      // pending for manual correction instead of being guessed.
      const text = '''
1. Which is the largest planet?
(A) Mars /
(B) Venus
(C) Jupiter
(D) Saturn
''';
      final r = parseText(text);
      expect(r.parsed, 0);
      expect(r.questions, isEmpty);
      expect(r.answerPending.length, 1);
    });

    test('a circled option letter is NOT an answer signal', () {
      // A student circling (B) often OCRs as 'Ⓑ' or '(B)' debris.
      // A circle is a student marking until proven otherwise — the
      // question must never be guessed from it. Today the circled
      // line is not even recognised as an option, so the block has
      // only 3 options and the question is SKIPPED (not pending) —
      // still never guessed, but it cannot reach manual correction
      // either. Sub-gap: the option detector should recognise a
      // circled-letter line as an option (without trusting the
      // circle as an answer), so the question lands in UNVERIFIED
      // instead of disappearing.
      const text = '''
1. Which is the largest planet?
(A) Mars
Ⓑ Venus
(C) Jupiter
(D) Saturn
''';
      final r = parseText(text);
      expect(r.parsed, 0);
      expect(r.questions, isEmpty);
      expect(r.answerPending, isEmpty);
      expect(r.skipped, 1);
    });
  });

  group('GAP: mark provenance — the parser cannot tell printed from '
      'handwritten', () {
    test('a provenance channel exists for tick/bold marks', () {
      // Desired: the import/parse path carries, per option, whether
      // its mark came from the PRINTED book (text layer / printed
      // tick) or from an OCR read of a photo (provenance unknown —
      // could be the student's pen). An OCR-sourced tick must land
      // the question in UNVERIFIED until the user confirms it in
      // manual correction.
      // Gap: lib/services/mcq_parser.dart — _parseStandardBlock
      // (~line 3698) trusts every ✓/✔ via _extractOption (~line
      // 2688) with no provenance parameter; parseMcqs /
      // parseMcqsFromPages take no provenance input; and
      // lib/services/pdf_import_service.dart records no per-option
      // provenance either. The Question model has no field for it.
      final parser =
          File('lib/services/mcq_parser.dart').readAsStringSync();
      final importer = File('lib/services/pdf_import_service.dart')
          .readAsStringSync();
      final model =
          File('lib/models/question.dart').readAsStringSync();
      final hasProvenanceChannel =
          parser.contains('provenance') ||
              importer.contains('provenance') ||
              model.contains('provenance');
      expect(hasProvenanceChannel, isTrue);
    });

    test('an OCR-sourced tick lands the question UNVERIFIED', () {
      // Desired end state (needs the provenance channel above):
      // the same ✓ text, flagged as OCR-sourced with unknown
      // provenance, must NOT resolve to an answer — the question
      // stays pending for manual correction.
      // Today the parser resolves it as 'tick' (see the first group)
      // because it cannot tell the two apart.
      // This test is written against the behaviour the spec
      // requires; it fails until the provenance channel exists.
      // NOTE: there is currently no API to flag a parse as
      // OCR-sourced, so this test documents the requirement through
      // the model gap below rather than calling a missing API.
      final model =
          File('lib/models/question.dart').readAsStringSync();
      expect(model.contains('markProvenance'), isTrue);
    });
  });

  group('GAP: confidence + verification status + original vs corrected',
      () {
    test('Question carries a confidence score', () {
      // Spec: the extraction preview shows a CONFIDENCE SCORE per
      // question (how sure the engine is about the detected answer).
      // Gap: lib/models/question.dart — class Question has no
      // `confidence` field (no double 0–1), no `toMap`/`fromMap`
      // column for it, and ParseResult carries no per-question
      // confidence either.
      final model =
          File('lib/models/question.dart').readAsStringSync();
      expect(model.contains('confidence'), isTrue);
    });

    test('Question + PendingQuestion carry a verification status', () {
      // Spec: per-question verification status (verified /
      // unverified / manually-corrected), shown in the preview.
      // Gap: lib/models/question.dart — neither Question nor
      // PendingQuestion has a `verificationStatus` field; the only
      // status-like data today is `answerSource` (a string) and
      // PendingQuestion.reason ('no-key-entry' / 'unknown-key').
      final model =
          File('lib/models/question.dart').readAsStringSync();
      expect(model.contains('verificationStatus'), isTrue);
    });

    test('manual correction keeps original and corrected answers '
        'separate', () {
      // Spec: manual correction must keep the ORIGINAL extracted
      // answer separate from the manually corrected answer.
      // Gap: lib/models/question.dart — class Question has no
      // `originalCorrectIndex` / `correctedCorrectIndex` (or
      // `originalAnswer` / `correctedAnswer`) fields. Today a
      // manually set answer overwrites the answer with
      // answerSource 'manual' and the original is lost.
      // (For answer-pending questions there IS no original answer,
      // so nothing is lost there — this gap is about correcting an
      // already-answered question, for which no UI exists either.)
      final model =
          File('lib/models/question.dart').readAsStringSync();
      final hasSeparation =
          model.contains('originalCorrectIndex') ||
              model.contains('correctedCorrectIndex') ||
              model.contains('originalAnswer');
      expect(hasSeparation, isTrue);
    });

    test('the extraction preview shows per-question confidence + '
        'status', () {
      // Spec: the preview shows, PER QUESTION: question, options
      // A–D, detected correct answer, source page, confidence
      // score, verification status.
      // Gap: lib/screens/upload_screen.dart — _importResult shows
      // aggregate lines only (counts + format breakdown + answer
      // sources); there is no per-question row and no confidence /
      // status display anywhere in the preview.
      final src =
          File('lib/screens/upload_screen.dart').readAsStringSync();
      expect(src.contains('confidence'), isTrue);
    });
  });
}
