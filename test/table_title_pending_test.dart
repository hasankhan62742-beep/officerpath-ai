// Regression tests for the two parser-side items from the OCR
// two-column/table report (OCR_TWO_COLUMN_FIX_2026-11-20.md, Sr.#
// probe verdict).
//
// (1) Sr.# tables yield 1 spurious PENDING question — the title line
// ("Computer Most Important Questions") paired with the header row's
// A–D as options. A title/header row must never become a pending
// question.
// (2) Subject mapping: Sr.# / computer / interjection rows come out
// Subject.gk (default); only the adjective table maps to
// Subject.english. Map by the paper's subject where it can be
// detected (title / section-heading keywords), never by guessing:
// 'computer' → Subject.mathsComputer; English-grammar terms
// (interjection, gerund, participle, ...) → Subject.english.
// No signal → keep the gk default.
//
// The table pass already strips "A." markers itself (OCR probe:
// Sr.# p1 3/3, computer p5 3/3, interjection 9/9, adjective 6/6,
// all correctIndex correct, answerSource='key') — these tests pin
// that behaviour too, so a fix for (1)/(2) must not break it.
//
// Input shape: the reconstructed '|' lines the camera path emits
// (one SegmentedLine per visual row), fed to parseTableFormat
// exactly as the OCR probe did.
import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/models/exam.dart';
import 'package:officerpath_ai/services/answer_key.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';

List<SegmentedLine> _lines(List<String> texts) {
  return [
    for (var i = 0; i < texts.length; i++)
      SegmentedLine(texts[i], 'Paper 1', 1, i),
  ];
}

/// Sr.# p1 ("Computer Most Important Questions"): the OCR probe's
/// 3/3 case — correctIndex 0/2/1, options stripped of "A." markers,
/// answerSource='key' — plus the 1 spurious pending.
const _srTable = [
  'Computer Most Important Questions',
  'Sr.# | Question | A | B | C | D | Ans',
  "1 | The word 'computer' comes from which language? | A. Latin | B. German | C. French | D. Spanish | A",
  '2 | Which is the first calculating device? | A. Abacus | B. Calculator | C. Difference Engine | D. ENIAC | C',
  '3 | Who is known as the father of computers? | A. Bill Gates | B. Charles Babbage | C. Alan Turing | D. John von Neumann | B',
];

void main() {
  group('Sr.# table title + subject (OCR probe verdict)', () {
    test('title never becomes a pending question', () {
      final r = parseTableFormat(
        _lines(_srTable),
        sourceId: 'sr-test',
        sourceLabel: 'Sr.# table',
      );
      // The 3 real rows, answers from the Ans column.
      expect(r.questions.length, 3);
      expect(
        [for (final q in r.questions) q.correctIndex],
        [0, 2, 1],
      );
      expect(
        r.questions.every((q) => q.answerSource == 'key'),
        isTrue,
      );
      // "A." markers are stripped by the table pass itself.
      expect(
        r.questions[0].options,
        ['Latin', 'German', 'French', 'Spanish'],
      );
      // The title + header A–D must not become a 4th (pending)
      // question.
      expect(r.pending, isEmpty);
      expect(
        [
          ...r.questions.map((q) => q.text),
          ...r.pending.map((q) => q.text),
        ].any((t) => t.contains('Computer Most Important')),
        isFalse,
      );
    });

    test('computer rows map to Subject.mathsComputer', () {
      final r = parseTableFormat(
        _lines(_srTable),
        sourceId: 'sr-test',
        sourceLabel: 'Sr.# table',
      );
      expect(r.questions.length, 3);
      expect(
        r.questions.every((q) => q.subject == Subject.mathsComputer),
        isTrue,
      );
    });

    test('interjection rows map to Subject.english via the heading', () {
      final r = parseTableFormat(
        _lines([
          'Interjection',
          '230 | ___! What a beautiful scene. | Hurrah | Alas | Bravo | Oh | A',
          '231 | ___! He has died. | Hurrah | Alas | Bravo | Oh | B',
        ]),
        sourceId: 'interjection-test',
        sourceLabel: 'Interjection table',
      );
      expect(r.questions.length, 2);
      expect(
        [for (final q in r.questions) q.correctIndex],
        [0, 1],
      );
      expect(
        r.questions.every((q) => q.subject == Subject.english),
        isTrue,
      );
      expect(r.pending, isEmpty);
    });

    test('no subject signal keeps the gk default (never guessed)', () {
      final r = parseTableFormat(
        _lines([
          'General Questions',
          'Sr.# | Question | A | B | C | D | Ans',
          '1 | Which is the largest planet? | A. Mars | B. Jupiter | C. Venus | D. Saturn | B',
          '2 | Which is the smallest planet? | A. Mercury | B. Mars | C. Venus | D. Earth | A',
        ]),
        sourceId: 'general-test',
        sourceLabel: 'General table',
      );
      expect(r.questions.length, 2);
      expect(
        r.questions.every((q) => q.subject == Subject.gk),
        isTrue,
      );
      expect(r.pending, isEmpty);
    });
  });
}
