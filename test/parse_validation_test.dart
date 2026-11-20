// Tests for lib/services/parse_validation.dart (MASTER DIRECTIVE
// Part 10: detect + flag, never silently repair).
import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/models/exam.dart';
import 'package:officerpath_ai/models/question.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/parse_validation.dart';

Question _q(
  String text, {
  String source = 'key',
  int correctIndex = 0,
  int page = 1,
}) {
  return Question(
    text: text,
    options: const ['A', 'B', 'C', 'D'],
    correctIndex: correctIndex,
    subject: Subject.gk,
    sourceId: 'test',
    sourceLabel: 'Test',
    answerSource: source,
    page: page,
  );
}

ParseResult _result({
  List<Question> questions = const [],
  List<PendingQuestion> pending = const [],
  List<String> missing = const [],
  List<String> duplicates = const [],
  List<String> conflicts = const [],
  List<String> unmatched = const [],
  List<String> keyPaperReport = const [],
}) {
  return ParseResult(
    questions: questions,
    parsed: questions.length,
    skipped: 0,
    questionsMissingAnswers: missing,
    numberDuplicates: duplicates,
    conflicts: conflicts,
    unmatchedKeyEntries: unmatched,
    answerPending: pending,
    keyPaperReport: keyPaperReport,
  );
}

void main() {
  group('validateParseResult', () {
    test('clean result has no issues', () {
      final r = validateParseResult(_result(
        questions: [_q('What is 2 + 2?')],
        keyPaperReport: const ["Key 'Paper 1' se 1 jawab lage."],
      ));
      expect(r.issues, isEmpty);
      expect(r.hasErrors, isFalse);
      expect(r.keyPaperNotes, ["Key 'Paper 1' se 1 jawab lage."]);
      expect(r.summary, 'No validation issues.');
    });

    test('missing answers are info, never errors', () {
      final r = validateParseResult(_result(
        pending: [
          PendingQuestion(
            text: 'Unanswered?',
            options: const ['A', 'B', 'C', 'D'],
            subject: Subject.gk,
            page: 7,
            reason: 'no-key-entry',
          ),
        ],
        missing: const ['Paper 1 Q4 — no key entry'],
      ));
      expect(r.countsByKind[ValidationKind.missingAnswer], 2);
      expect(r.hasErrors, isFalse);
      expect(
        r.issues
            .where((i) => i.kind == ValidationKind.missingAnswer)
            .every((i) => i.severity == ValidationSeverity.info),
        isTrue,
      );
    });

    test('duplicate question text is an error', () {
      final r = validateParseResult(_result(
        questions: [_q('Same question?'), _q('Same question?')],
      ));
      expect(r.countsByKind[ValidationKind.duplicateQuestion], 1);
      expect(r.hasErrors, isTrue);
    });

    test('duplicate numbers, conflicts and unmatched keys are flagged',
        () {
      final r = validateParseResult(_result(
        duplicates: const ['Q10 appears twice'],
        conflicts: const ['Q5: key says B, tick says C'],
        unmatched: const ['Key entry 101 has no question'],
      ));
      expect(r.countsByKind[ValidationKind.duplicateNumber], 1);
      expect(r.countsByKind[ValidationKind.conflictingAnswer], 1);
      expect(r.countsByKind[ValidationKind.unmatchedKeyEntry], 1);
      expect(r.hasErrors, isTrue); // duplicate number is an error
    });

    test('the 10 PPSC-66 baseline fabrications are all flagged', () {
      // Baseline §4: 3 key fragments + 7 Paper 67 Explanation /
      // Associated-Information bullets, all marked verified=true.
      const fabrications = [
        '(A) Speak:',
        '(B) Muzzle:',
        '(C) [?',
        'of the Islamic Golden Age and had significant repercussions for the region. Halaku Khan was - Mongol Emperor:',
        '- Conquests:',
        '- Founder of the Ilkhanate:',
        'lasted from 1256 to 1335. The Siege of Baghdad - The Siege:',
        '- The Fall of Baghdad:',
        "city's fortifications, leading to a massacre and the eventual surrender of the Caliph. - Aftermath:",
        'Oldest University in Europe:',
      ];
      final r = validateParseResult(_result(
        questions: [
          for (final f in fabrications)
            _q(f, source: 'flashcard', page: 7),
        ],
      ));
      expect(r.countsByKind[ValidationKind.fabricationSuspect], 10);
    });

    test('legitimate q-only / flashcard questions are NOT flagged', () {
      final r = validateParseResult(_result(
        questions: [
          _q('What is the capital of France?', source: 'flashcard'),
          _q('Choose the correct synonym Wheedle:', source: 'q-only'),
          _q('The capital of France is', source: 'q-only'),
          _q('Give the meaning of Idiom: Spick and Span',
              source: 'q-only'),
          // A key-sourced question is never a fabrication suspect,
          // whatever its text — the guard only applies to
          // flashcard/q-only answers built from the pool.
          _q('(A) Speak:', source: 'key'),
        ],
      ));
      expect(r.countsByKind[ValidationKind.fabricationSuspect], isNull);
    });
  });
}
