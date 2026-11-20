import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/models/exam.dart';
import 'package:officerpath_ai/models/question.dart';
import 'package:officerpath_ai/screens/test_screen.dart';
import 'package:officerpath_ai/services/rss_service.dart';
import 'package:officerpath_ai/services/subscription_service.dart';
import 'package:officerpath_ai/services/test_generator.dart';
import 'package:officerpath_ai/services/test_progress_service.dart';
import 'package:officerpath_ai/widgets/progress_chart.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression tests for the 18 Nov full-app audit (AUDIT_REPORT.md).
/// Each test names the finding it covers.

Question _q(int id) => Question(
  id: id,
  text: 'What is the capital of Pakistan?',
  options: const ['Lahore', 'Karachi', 'Islamabad', 'Quetta'],
  correctIndex: 2,
  subject: Subject.gk,
  sourceId: 's1',
  sourceLabel: 'Sample',
);

void main() {
  test('F18: percent floors at 0 when the raw score is negative', () {
    final exam = ExamPattern.byId('ppsc');
    final questions = [_q(1), _q(2)];
    // 0 correct, 2 wrong at -0.25 -> score -0.50.
    final result = scoreAttempt(
      questions: questions,
      answers: {0: 0, 1: 0},
      markedForReview: {},
      exam: exam,
      durationSeconds: 60,
    );
    expect(result.score, -0.5);
    expect(result.percent, 0.0);
    expect(result.passed, isFalse);
  });

  test('m1: perMonthLabel never divides by zero for a sub-30-day plan', () {
    const plan = PremiumPlan(
      id: 'test_7day',
      name: 'Test — 7 Days',
      pricePkr: 100,
      durationDays: 7,
      playStoreProductId: 'test_7day',
      tagline: 'test',
    );
    expect(plan.perMonthLabel, 'Rs 100 / month');
  });

  test('F12: RFC 822 GMT dates convert to the right instant, not local-naive',
      () {
    const xml = '''
<?xml version="1.0"?>
<rss version="2.0"><channel>
<item><title>BBC story</title><link>https://example.com/1</link>
<pubDate>Tue, 18 Nov 2026 06:40:10 GMT</pubDate></item>
<item><title>No date story</title><link>https://example.com/2</link></item>
<item><title>Offset story</title><link>https://example.com/3</link>
<pubDate>Tue, 18 Nov 2026 11:40:10 +0500</pubDate></item>
</channel></rss>
''';
    final items = RssService.parseFeedXml(
      xml,
      source: 'BBC',
      category: 'International',
    );
    expect(items.length, 3);
    final gmt = items.firstWhere((i) => i.title == 'BBC story');
    // 06:40:10 GMT is the same instant as 11:40:10 +0500.
    expect(gmt.publishedAt.toUtc(), DateTime.utc(2026, 11, 18, 6, 40, 10));
    final offset = items.firstWhere((i) => i.title == 'Offset story');
    expect(offset.publishedAt.toUtc(), DateTime.utc(2026, 11, 18, 6, 40, 10));
    // Undated items get the epoch sentinel — never "now".
    final undated = items.firstWhere((i) => i.title == 'No date story');
    expect(
      undated.publishedAt,
      DateTime.fromMillisecondsSinceEpoch(0),
    );
  });

  test('C3: test progress survives a save/load round-trip', () async {
    SharedPreferences.setMockInitialValues({});
    final progress = TestProgress(
      examId: 'ppsc',
      durationMinutes: 45,
      startedAtIso: DateTime.now().toIso8601String(),
      questionIds: [1, 2, 3],
      answers: {0: 2, 2: 1},
      marked: {1},
    );
    await TestProgressService.instance.save(progress);
    final loaded = await TestProgressService.instance.load();
    expect(loaded, isNotNull);
    expect(loaded!.examId, 'ppsc');
    expect(loaded.questionIds, [1, 2, 3]);
    expect(loaded.answers, {0: 2, 2: 1});
    expect(loaded.marked, {1});
    expect(loaded.remaining.inMinutes, greaterThanOrEqualTo(44));
    await TestProgressService.instance.clear();
    expect(await TestProgressService.instance.load(), isNull);
  });

  testWidgets('F17: TestScreen with no questions shows an error, not a crash',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TestScreen(
          questions: const [],
          exam: ExamPattern.byId('ppsc'),
          durationMinutes: 10,
        ),
      ),
    );
    expect(find.text('No questions in this test.'), findsOneWidget);
    expect(find.text('Go back'), findsOneWidget);
  });

  testWidgets('C4: a retry TestScreen builds and shows the question',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TestScreen(
          questions: [_q(1)],
          exam: ExamPattern.byId('ppsc'),
          durationMinutes: 10,
          isRetry: true,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('What is the capital of Pakistan?'), findsOneWidget);
    expect(find.text('EXAM MODE  •  Correct +1  •  Wrong −0.25  •  Skipped 0'),
        findsOneWidget);
  });

  testWidgets('F15: ProgressChart takes a per-exam pass percent',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ProgressChart(percents: [100, 50, 33], passPercent: 33),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(ProgressChart), findsOneWidget);
  });
}
