import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/models/exam.dart';
import 'package:officerpath_ai/models/question.dart';
import 'package:officerpath_ai/screens/about_screen.dart';
import 'package:officerpath_ai/screens/result_screen.dart';
import 'package:officerpath_ai/screens/review_screen.dart';
import 'package:officerpath_ai/screens/test_screen.dart';
import 'package:officerpath_ai/services/test_generator.dart';
import 'package:officerpath_ai/theme/app_theme.dart';
import 'package:officerpath_ai/widgets/developer_credit_footer.dart';

/// v1.2 UI polish — footer presence, small-phone overflow, icon assets.
///
/// Screens that need storage (Home / Upload / Setup / History /
/// Current Affairs / Upgrade) cannot be pumped in a unit test without
/// sqflite, so they are covered by a source check (the file contains
/// the shared footer widget) while the pumpable screens are rendered
/// for real at 360x640.

Question _q(int id) => Question(
  id: id,
  text: 'What is the capital of Pakistan?',
  options: const ['Lahore', 'Karachi', 'Islamabad', 'Quetta'],
  correctIndex: 2,
  subject: Subject.gk,
  sourceId: 's1',
  sourceLabel: 'Sample',
);

AttemptResult _result() => scoreAttempt(
  questions: [_q(1), _q(2)],
  answers: {0: 2, 1: 0},
  markedForReview: {},
  exam: ExamPattern.byId('ppsc'),
  durationSeconds: 600,
);

void _setSmallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

String _footerText(WidgetTester tester) {
  // The footer subtree has TWO RichTexts: the shield Icon renders
  // its glyph as text, plus the credit line itself. Pick the one
  // that carries the credit.
  final richTexts = tester.widgetList<RichText>(
    find.descendant(
      of: find.byType(DeveloperCreditFooter),
      matching: find.byType(RichText),
    ),
  );
  final rich = richTexts.firstWhere(
    (r) => r.text.toPlainText().contains('Developed by'),
  );
  return rich.text.toPlainText();
}

/// Scrolls a lazily-built ListView until the footer is built.
Future<void> _revealFooter(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byType(DeveloperCreditFooter),
    500,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('footer renders the exact credit text, light mode',
      (tester) async {
    _setSmallPhone(tester);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: DeveloperCreditFooter()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DeveloperCreditFooter), findsOneWidget);
    expect(_footerText(tester), 'Developed by Muhammad Abdul Qadeer');
    expect(tester.takeException(), isNull);
  });

  testWidgets('footer renders in dark mode without overflow',
      (tester) async {
    _setSmallPhone(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const Scaffold(body: DeveloperCreditFooter()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DeveloperCreditFooter), findsOneWidget);
    expect(_footerText(tester), 'Developed by Muhammad Abdul Qadeer');
    expect(tester.takeException(), isNull);
  });

  testWidgets('About screen shows the footer at 360x640', (tester) async {
    _setSmallPhone(tester);
    await tester.pumpWidget(
      const MaterialApp(home: AboutScreen()),
    );
    await tester.pumpAndSettle();
    // The footer is the last ListView item — scroll it into view
    // (ListViews build lazily, so it is not in the tree yet).
    await _revealFooter(tester);
    expect(find.byType(DeveloperCreditFooter), findsOneWidget);
    expect(_footerText(tester), 'Developed by Muhammad Abdul Qadeer');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Result screen shows footer + download buttons at 360x640',
      (tester) async {
    _setSmallPhone(tester);
    await tester.pumpWidget(
      MaterialApp(home: ResultScreen(result: _result(), exam: ExamPattern.byId('ppsc'))),
    );
    await tester.pumpAndSettle();
    // Score card is at the top and visible on first paint.
    expect(find.text('Score: 0.75 / 2'), findsOneWidget);
    // Download buttons sit mid-list — scroll them into view.
    await tester.scrollUntilVisible(find.text('Download PDF'), 500);
    await tester.pumpAndSettle();
    expect(find.text('Download PDF'), findsOneWidget);
    expect(find.text('Share as image'), findsOneWidget);
    // Footer is the last item — scroll it into view (the top card
    // leaves the tree when scrolled away, so the score is checked
    // before scrolling, above).
    await _revealFooter(tester);
    expect(find.byType(DeveloperCreditFooter), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Review screen shows the footer at 360x640', (tester) async {
    _setSmallPhone(tester);
    await tester.pumpWidget(
      MaterialApp(home: ReviewScreen(result: _result())),
    );
    await tester.pumpAndSettle();
    await _revealFooter(tester);
    expect(find.byType(DeveloperCreditFooter), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Test screen at 360x640: no overflow, footer below buttons',
      (tester) async {
    _setSmallPhone(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: TestScreen(
          questions: [_q(1)],
          exam: ExamPattern.byId('ppsc'),
          durationMinutes: 10,
          isRetry: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('What is the capital of Pakistan?'), findsOneWidget);
    // One question only, so the last-question button says Submit.
    expect(find.text('Submit'), findsOneWidget);
    expect(find.byType(DeveloperCreditFooter), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Test screen at 360x640 in dark mode: no overflow',
      (tester) async {
    _setSmallPhone(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: TestScreen(
          questions: [_q(1)],
          exam: ExamPattern.byId('ppsc'),
          durationMinutes: 10,
          isRetry: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(DeveloperCreditFooter), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('every screen file includes the shared footer widget', () {
    // Home / Upload / Setup / History / Current Affairs / Upgrade
    // need sqflite + network, so they cannot be pumped here — but the
    // footer must still be wired in. This fails loudly if a screen
    // is added without it.
    const screens = [
      'home_screen',
      'upload_screen',
      'setup_screen',
      'test_screen',
      'result_screen',
      'review_screen',
      'history_screen',
      'current_affairs_screen',
      'upgrade_screen',
      'about_screen',
    ];
    for (final name in screens) {
      final source = File(
        'lib/screens/$name.dart',
      ).readAsStringSync();
      expect(
        source,
        contains('DeveloperCreditFooter'),
        reason: '$name.dart must include the shared footer',
      );
      expect(
        source,
        contains('developer_credit_footer.dart'),
        reason: '$name.dart must import the shared footer',
      );
    }
  });

  test('launcher icon files exist at every density (v1.2 candidate)', () {
    const densities = ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi'];
    for (final d in densities) {
      final legacy = File(
        'android/app/src/main/res/mipmap-$d/ic_launcher.png',
      );
      final round = File(
        'android/app/src/main/res/mipmap-$d/ic_launcher_round.png',
      );
      final fg = File(
        'android/app/src/main/res/drawable-$d/ic_launcher_foreground.png',
      );
      expect(legacy.existsSync(), isTrue, reason: 'mipmap-$d legacy icon');
      expect(legacy.lengthSync(), greaterThan(500));
      expect(round.existsSync(), isTrue, reason: 'mipmap-$d round icon');
      expect(round.lengthSync(), greaterThan(500));
      expect(fg.existsSync(), isTrue, reason: 'drawable-$d foreground');
      expect(fg.lengthSync(), greaterThan(500));
    }
    // No placeholder green icon left anywhere.
    expect(
      File(
        'android/app/src/main/res/drawable/ic_launcher_foreground.xml',
      ).existsSync(),
      isFalse,
      reason: 'old green vector foreground must be gone',
    );
    expect(
      File(
        'android/app/src/main/res/values/ic_launcher_background.xml',
      ).readAsStringSync(),
      contains('#0B1F3A'),
    );
    expect(
      File(
        'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml',
      ).readAsStringSync(),
      contains('@drawable/ic_launcher_foreground'),
    );
    // Source artwork kept as the master in assets.
    expect(
      File(
        'assets/media-generation-officerpath-icon-0-93fa5164-7fc7-4da5-95c7-30068c4a45d4.webp',
      ).existsSync(),
      isTrue,
    );
  });
}
