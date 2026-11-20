import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/data/sample_bank.dart';
import 'package:officerpath_ai/models/exam.dart';
import 'package:officerpath_ai/models/question.dart';
import 'package:officerpath_ai/services/test_generator.dart';

Question _mk(String text, Subject s, String src, int correct) => Question(
  text: text,
  options: ['A', 'B', 'C', 'D'],
  correctIndex: correct,
  subject: s,
  sourceId: src,
  sourceLabel: src,
);

void main() {
  test('sample bank has at least 80 MCQs across 7 subjects', () {
    final bank = SampleBank.questions;
    expect(bank.length, 84);
    final subjects = bank.map((q) => q.subject).toSet();
    expect(subjects.length, 7);
    // HARD RULE: EVERY MCQ has EXACTLY 4 options — count violations.
    final badOptionCounts = bank.where((q) => q.options.length != 4).length;
    expect(badOptionCounts, 0);
    for (final q in bank) {
      expect(q.options.length, 4);
      expect(q.correctIndex, inInclusiveRange(0, 3));
      expect(q.explanation, isNotEmpty);
    }
    // Every built-in source holds questions (prepared-paper filter works).
    for (final src in SampleBank.sources) {
      expect(
        bank.where((q) => q.sourceId == src.id).length,
        greaterThan(0),
      );
    }
  });

  test('generateTest uses ONLY the ticked sources', () {
    final bank = [
      _mk('Q1', Subject.gk, 'paper-a', 0),
      _mk('Q2', Subject.gk, 'paper-a', 1),
      _mk('Q3', Subject.gk, 'paper-b', 2),
      _mk('Q4', Subject.gk, 'paper-b', 3),
    ];
    final test = generateTest(
      bank: bank,
      sourceIds: {'paper-a'},
      count: 10,
      seed: 42,
    );
    expect(test.length, 2);
    expect(test.every((q) => q.sourceId == 'paper-a'), isTrue);
  });

  test('option shuffle keeps the same correct answer text', () {
    final bank = [_mk('Q1', Subject.gk, 'paper-a', 2)];
    final test = generateTest(
      bank: bank,
      sourceIds: {'paper-a'},
      count: 1,
      seed: 7,
    );
    expect(test.first.options[test.first.correctIndex], 'C');
  });

  test('scoring applies -0.25 negative marking and 40% pass rule', () {
    final ppsc = ExamPattern.byId('ppsc');
    final questions = List.generate(
      10,
      (i) => _mk('Q$i', Subject.gk, 'paper-a', 0),
    );
    // 7 correct, 2 wrong, 1 skipped.
    final answers = <int, int?>{
      for (var i = 0; i < 7; i++) i: 0,
      7: 1,
      8: 2,
    };
    final result = scoreAttempt(
      questions: questions,
      answers: answers,
      markedForReview: {},
      exam: ppsc,
      durationSeconds: 600,
    );
    expect(result.correct, 7);
    expect(result.wrong, 2);
    expect(result.skipped, 1);
    // Full breakdown shown on the Result screen:
    // raw = 7 x +1, deduction = 2 x -0.25, final = 7 - 0.50 = 6.50.
    expect(result.rawScore, 7.0);
    expect(result.negativeDeduction(0.25), 0.5);
    expect(result.score, 6.5); // 7 - 2 x 0.25
    expect(result.percent, 65.0);
    expect(result.passed, isTrue);
    expect(result.secondsPerQuestion, 60.0);
  });

  test('negative marking can fail an attempt (raw vs final)', () {
    final ppsc = ExamPattern.byId('ppsc');
    final questions = List.generate(
      10,
      (i) => _mk('Q$i', Subject.gk, 'paper-a', 0),
    );
    // 4 correct, 6 wrong: raw 4.0, deduction 1.50, final 2.50 = 25% FAIL.
    final answers = <int, int?>{
      for (var i = 0; i < 4; i++) i: 0,
      for (var i = 4; i < 10; i++) i: 1,
    };
    final result = scoreAttempt(
      questions: questions,
      answers: answers,
      markedForReview: {},
      exam: ppsc,
      durationSeconds: 600,
    );
    expect(result.rawScore, 4.0);
    expect(result.negativeDeduction(0.25), 1.5);
    expect(result.score, 2.5);
    expect(result.percent, 25.0);
    expect(result.passed, isFalse);
  });

  test('exam minutes scale with question count (PPSC 100/90)', () {
    final ppsc = ExamPattern.byId('ppsc');
    expect(ppsc.minutesFor(100), 90);
    expect(ppsc.minutesFor(50), 45);
    expect(ppsc.minutesFor(25), 23); // 22.5 rounds up
    final css = ExamPattern.byId('css_mpt');
    expect(css.minutesFor(200), 200);
    expect(css.minutesFor(100), 100);
  });
}
