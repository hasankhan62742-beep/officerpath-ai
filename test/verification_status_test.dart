// Verification status (governing spec 19 Nov 2026): every parsed
// question carries `answerVerified` — true when the answer comes
// from the book's own printed/official signal (answer-line, key,
// tick, bold, asterisk), false when it was inferred by
// AI, the signals conflicted, or the question is a flashcard
// reconstruction (options generated, never printed). The v2 preview
// / manual-correction
// UI reads this flag; an unverified answer must never be presented
// as correct without review.
import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/models/exam.dart';
import 'package:officerpath_ai/models/question.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';

void main() {
  group('answerVerified — printed signals are verified', () {
    test('key answer is verified', () {
      final r = parseMcqs(
        'Q1. What is the capital of Pakistan?\n'
        '(A) Lahore\n(B) Karachi\n(C) Islamabad\n(D) Quetta\n\n'
        'Answer Key\n1. C\n',
        sourceId: 't',
        sourceLabel: 't',
      );
      expect(r.questions, hasLength(1));
      final q = r.questions.first;
      expect(q.correctIndex, 2);
      expect(q.answerSource, 'key');
      expect(q.answerVerified, isTrue);
      expect(q.page, 0); // string path has no page tracking
    });

    test('asterisk answer is verified', () {
      final r = parseMcqs(
        'Q1. Which key refreshes a slide show?\n'
        '(A) F1\n(B) F2\n(C) F5 *\n(D) F7\n',
        sourceId: 't',
        sourceLabel: 't',
      );
      expect(r.questions, hasLength(1));
      expect(r.questions.first.correctIndex, 2);
      expect(r.questions.first.answerSource, 'asterisk');
      expect(r.questions.first.answerVerified, isTrue);
    });

    test('answer-line answer is verified', () {
      final r = parseMcqs(
        'Q1. What is 2 + 2?\n'
        '(A) 3\n(B) 4\n(C) 5\n(D) 6\n'
        'Answer: B\n',
        sourceId: 't',
        sourceLabel: 't',
      );
      expect(r.questions, hasLength(1));
      expect(r.questions.first.correctIndex, 1);
      expect(r.questions.first.answerSource, 'answer-line');
      expect(r.questions.first.answerVerified, isTrue);
    });
  });

  group('answerVerified — conflicts are unverified', () {
    test('answer line vs asterisk conflict → unverified, line wins', () {
      final r = parseMcqs(
        'Q1. Which key refreshes a slide show?\n'
        '(A) F1 *\n(B) F2\n(C) F5\n(D) F7\n'
        'Answer: C\n',
        sourceId: 't',
        sourceLabel: 't',
      );
      expect(r.questions, hasLength(1));
      final q = r.questions.first;
      // Precedence: the answer line wins over the asterisk.
      expect(q.correctIndex, 2);
      expect(q.answerSource, 'answer-line');
      // But the disagreement means the answer is NOT certain.
      expect(q.answerVerified, isFalse);
      expect(r.conflicts, isNotEmpty);
    });

    test('key vs tick conflict → unverified, key wins', () {
      final r = parseMcqs(
        'Q1. What is the capital of Pakistan?\n'
        '(A) Lahore ✓\n(B) Karachi\n(C) Islamabad\n(D) Quetta\n\n'
        'Answer Key\n1. C\n',
        sourceId: 't',
        sourceLabel: 't',
      );
      expect(r.questions, hasLength(1));
      final q = r.questions.first;
      expect(q.correctIndex, 2);
      expect(q.answerSource, 'key');
      expect(q.answerVerified, isFalse);
      expect(r.conflicts, isNotEmpty);
    });
  });

  group('answerVerified — model defaults', () {
    test('AI source defaults to unverified', () {
      final q = Question(
        text: 'Q',
        options: const ['a', 'b', 'c', 'd'],
        correctIndex: 0,
        subject: Subject.gk,
        sourceId: 't',
        sourceLabel: 't',
        answerSource: 'ai',
      );
      expect(q.answerVerified, isFalse);
    });

    test('key source defaults to verified', () {
      final q = Question(
        text: 'Q',
        options: const ['a', 'b', 'c', 'd'],
        correctIndex: 0,
        subject: Subject.gk,
        sourceId: 't',
        sourceLabel: 't',
        answerSource: 'key',
      );
      expect(q.answerVerified, isTrue);
    });

    test('explicit override wins over the source default', () {
      final q = Question(
        text: 'Q',
        options: const ['a', 'b', 'c', 'd'],
        correctIndex: 0,
        subject: Subject.gk,
        sourceId: 't',
        sourceLabel: 't',
        answerSource: 'key',
        answerVerified: false,
      );
      expect(q.answerVerified, isFalse);
    });

    test('round-trips through toMap/fromMap, old rows derive it', () {
      final q = Question(
        text: 'Q',
        options: const ['a', 'b', 'c', 'd'],
        correctIndex: 1,
        subject: Subject.gk,
        sourceId: 't',
        sourceLabel: 't',
        answerSource: 'asterisk',
      );
      final back = Question.fromMap(q.toMap());
      expect(back.answerVerified, isTrue);
      expect(back.answerSource, 'asterisk');
      // A row written before verification tracking has no flag.
      final old = Map<String, Object?>.from(q.toMap())
        ..remove('answer_verified');
      expect(Question.fromMap(old).answerVerified, isTrue);
      final oldAi = Map<String, Object?>.from(q.toMap())
        ..remove('answer_verified')
        ..['answer_source'] = 'ai';
      expect(Question.fromMap(oldAi).answerVerified, isFalse);
    });

    test('copyWith preserves the flag; shuffle keeps it', () {
      final q = Question(
        text: 'Q',
        options: const ['a', 'b', 'c', 'd'],
        correctIndex: 0,
        subject: Subject.gk,
        sourceId: 't',
        sourceLabel: 't',
        answerSource: 'key',
        answerVerified: false,
      );
      expect(q.copyWith(text: 'Q2').answerVerified, isFalse);
      expect(q.copyWithShuffledOptions([3, 2, 1, 0]).answerVerified,
          isFalse);
    });
  });
}
