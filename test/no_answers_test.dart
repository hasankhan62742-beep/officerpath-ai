import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/models/exam.dart';
import 'package:officerpath_ai/models/question.dart';
import 'package:officerpath_ai/screens/result_screen.dart';
import 'package:officerpath_ai/screens/upload_screen.dart';
import 'package:officerpath_ai/services/pdf_import_service.dart';
import 'package:officerpath_ai/services/test_generator.dart';

/// "No-answers" notice + test-without-answers mode (20 Nov 2026,
/// owner's words): when a book/photo is parsed and the answers are
/// NOT attached, the app must say so plainly (no bold, no stars, no
/// ABCD key, no tick) — and a test without answers must never show a
/// score, pass/fail, or right/wrong breakdown. Nothing is ever
/// invented or guessed.
void main() {
  final ppsc = ExamPattern.byId('ppsc');

  Question answered({
    required String text,
    required int correct,
    int page = 0,
  }) {
    return Question(
      text: text,
      options: const ['Lahore', 'Karachi', 'Islamabad', 'Quetta'],
      correctIndex: correct,
      subject: Subject.gk,
      sourceId: 'no-answers-test',
      sourceLabel: 'No Answers Test',
      page: page,
      answerSource: 'asterisk',
      answerVerified: true,
    );
  }

  Question answerless({required String text}) {
    return Question(
      text: text,
      options: const ['Lahore', 'Karachi', 'Islamabad', 'Quetta'],
      correctIndex: -1,
      subject: Subject.gk,
      sourceId: 'no-answers-test',
      sourceLabel: 'No Answers Test',
      answerSource: '',
    );
  }

  PendingQuestion pending({required String text}) {
    return PendingQuestion(
      text: text,
      options: const ['Lahore', 'Karachi', 'Islamabad', 'Quetta'],
      subject: Subject.gk,
    );
  }

  PdfImportResult resultWith({
    required List<Question> questions,
    List<PendingQuestion> pendingList = const [],
  }) {
    return PdfImportResult(
      text: 'Some book text',
      pageCount: 3,
      textPages: 3,
      ocrPages: const [],
      ocrCapped: false,
      questions: questions,
      parsed: questions.length,
      skipped: 0,
      errors: const [],
      formats: const {'block': 1},
      generatedOptions: 0,
      excluded: const [],
      answerPending: pendingList,
    );
  }

  /// Pumps a host page with a button that opens the preview dialog
  /// and records the popped decision (same pattern as
  /// extraction_preview_test.dart).
  /// Pumps a few frames instead of pumpAndSettle: the no-answers
  /// notice card pulses forever by design (a repeating
  /// AnimationController), so pumpAndSettle would never settle. Five
  /// 100 ms frames are enough for a dialog to open / close.
  Future<void> pumpFrames(WidgetTester tester, [int frames = 5]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpPreview(
    WidgetTester tester,
    PdfImportResult result, {
    required void Function(PreviewDecision?) onDecision,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () async {
                  final d = await showDialog<PreviewDecision>(
                    context: context,
                    builder: (_) => ExtractionPreviewDialog(
                      result: result,
                      summaryLines: const ['Parsed 1 MCQs.'],
                      showManual: result.answerPending.isNotEmpty,
                      showMpt: false,
                    ),
                  );
                  onDecision(d);
                },
                child: const Text('Open preview'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('Open preview'));
    await pumpFrames(tester);
  }

  group('no-answers notice', () {
    testWidgets('shows when pending questions exist', (tester) async {
      PreviewDecision? decision;
      await pumpPreview(
        tester,
        resultWith(
          questions: [answered(text: 'Q1?', correct: 2)],
          pendingList: [pending(text: 'Q2?')],
        ),
        onDecision: (d) => decision = d,
      );
      expect(find.text(noAnswersNotice), findsOneWidget);
      expect(find.text('Jawab ke baghair save karein'), findsOneWidget);
      expect(find.text('Jawab khud lagayein'), findsOneWidget);
      expect(decision, isNull);
    });

    testWidgets('does NOT show when every question is answered',
        (tester) async {
      PreviewDecision? decision;
      await pumpPreview(
        tester,
        resultWith(
          questions: [answered(text: 'Q1?', correct: 2)],
        ),
        onDecision: (d) => decision = d,
      );
      expect(find.text(noAnswersNotice), findsNothing);
      expect(find.text('Jawab ke baghair save karein'), findsNothing);
      expect(find.text('Jawab khud lagayein'), findsNothing);
      expect(decision, isNull);
    });

    testWidgets(
        '"Jawab ke baghair save karein" pops save-answerless',
        (tester) async {
      PreviewDecision? decision;
      await pumpPreview(
        tester,
        resultWith(
          questions: [answered(text: 'Q1?', correct: 2)],
          pendingList: [pending(text: 'Q2?')],
        ),
        onDecision: (d) => decision = d,
      );
      await tester.tap(find.text('Jawab ke baghair save karein'));
      await pumpFrames(tester);
      expect(decision, isNotNull);
      expect(decision!.action, 'save-answerless');
      expect(decision!.questions.length, 1);
    });

    testWidgets(
        'all-pending case: NoMcqsDialog shows the notice + save action',
        (tester) async {
      String? action;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: TextButton(
                  onPressed: () async {
                    final a = await showDialog<String>(
                      context: context,
                      builder: (_) => NoMcqsDialog(
                        result: resultWith(
                          questions: [],
                          pendingList: [
                            pending(text: 'Q1?'),
                            pending(text: 'Q2?'),
                          ],
                        ),
                      ),
                    );
                    action = a;
                  },
                  child: const Text('Open dialog'),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Open dialog'));
      await pumpFrames(tester);
      expect(find.text(noAnswersNotice), findsOneWidget);
      expect(find.text('Jawab ke baghair save karein'), findsOneWidget);
      expect(find.text('Jawab khud lagayein'), findsOneWidget);
      await tester.tap(find.text('Jawab ke baghair save karein'));
      await pumpFrames(tester);
      expect(action, 'save-answerless');
    });
  });

  group('answerless Question model', () {
    test('correctIndex -1 round-trips through toMap/fromMap', () {
      final q = answerless(text: 'Q?');
      expect(q.hasAnswer, isFalse);
      expect(q.correctLetter, '');
      expect(q.verificationStatus, 'no-answer');
      final back = Question.fromMap(q.toMap());
      expect(back.correctIndex, -1);
      expect(back.hasAnswer, isFalse);
      expect(back.verificationStatus, 'no-answer');
    });

    test('copyWithShuffledOptions keeps an answerless question answerless',
        () {
      final q = answerless(text: 'Q?');
      final shuffled = q.copyWithShuffledOptions([2, 0, 3, 1]);
      expect(shuffled.correctIndex, -1);
      expect(shuffled.hasAnswer, isFalse);
    });

    test('withCorrection on an answerless question keeps no original',
        () {
      final q = answerless(text: 'Q?');
      final corrected = q.withCorrection(2);
      expect(corrected.correctIndex, 2);
      expect(corrected.hasAnswer, isTrue);
      expect(corrected.originalCorrectIndex, isNull);
    });
  });

  group('scoreAttempt with answerless questions', () {
    test('all-answerless test: nothing scored, no result', () {
      final questions = [
        answerless(text: 'Q1?'),
        answerless(text: 'Q2?'),
        answerless(text: 'Q3?'),
      ];
      final result = scoreAttempt(
        questions: questions,
        answers: {0: 1, 1: 2, 2: 0},
        markedForReview: {},
        exam: ppsc,
        durationSeconds: 300,
      );
      expect(result.correct, 0);
      expect(result.wrong, 0);
      expect(result.skipped, 0);
      expect(result.unscored, 3);
      expect(result.allUnscored, isTrue);
      expect(result.percent, 0.0);
      expect(result.wrongQuestions, isEmpty);
    });

    test('mixed test: only answered questions are scored', () {
      final questions = [
        answered(text: 'Q1?', correct: 0),
        answered(text: 'Q2?', correct: 1),
        answerless(text: 'Q3?'),
      ];
      final result = scoreAttempt(
        questions: questions,
        answers: {0: 0, 1: 3, 2: 2},
        markedForReview: {},
        exam: ppsc,
        durationSeconds: 300,
      );
      expect(result.correct, 1);
      expect(result.wrong, 1);
      expect(result.skipped, 0);
      expect(result.unscored, 1);
      expect(result.hasUnscored, isTrue);
      expect(result.allUnscored, isFalse);
      expect(result.scoredTotal, 2);
      // Scored only: 1 correct, 1 wrong at -0.25 -> 0.75 / 2 = 37.5%.
      expect(result.score, 0.75);
      expect(result.percent, 37.5);
    });
  });

  group('ResultScreen without answers', () {
    testWidgets('all-answerless test shows no score or result',
        (tester) async {
      final result = scoreAttempt(
        questions: [answerless(text: 'Q1?'), answerless(text: 'Q2?')],
        answers: {0: 1, 1: 0},
        markedForReview: {},
        exam: ppsc,
        durationSeconds: 120,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ResultScreen(result: result, exam: ppsc),
        ),
      );
      await pumpFrames(tester);
      expect(find.text('Is test ka result nahi hai'), findsOneWidget);
      expect(find.textContaining('Score:'), findsNothing);
      expect(find.text('PASS'), findsNothing);
      expect(find.text('FAIL'), findsNothing);
      expect(find.text('Review Answers — Har sawal dekhein'), findsNothing);
      expect(find.text('Download PDF'), findsNothing);
    });

    testWidgets('mixed test shows the unscored banner + scored total',
        (tester) async {
      final result = scoreAttempt(
        questions: [
          answered(text: 'Q1?', correct: 0),
          answered(text: 'Q2?', correct: 1),
          answerless(text: 'Q3?'),
        ],
        answers: {0: 0, 1: 3, 2: 2},
        markedForReview: {},
        exam: ppsc,
        durationSeconds: 300,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ResultScreen(result: result, exam: ppsc),
        ),
      );
      await pumpFrames(tester);
      expect(find.textContaining('ke jawab nahi the'), findsWidgets);
      expect(find.text('Score: 0.75 / 2'), findsOneWidget);
      expect(find.text('Unscored 1'), findsOneWidget);
    });
  });
}
