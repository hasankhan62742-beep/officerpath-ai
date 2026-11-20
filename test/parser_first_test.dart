import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/screens/upload_screen.dart';
import 'package:officerpath_ai/services/ai_usage_caps.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Worker 4 — extraction routing, governing spec 19 Nov 2026 (AI
/// generation PARKED — this supersedes the earlier "AI as a last
/// resort" rule):
/// * The local deterministic parser is the ONLY extraction path.
///   The uploaded PDF is the ONLY source of questions, options and
///   original answers. An answer is NEVER invented.
/// * If a document has no identifiable answer for a question, that
///   question is UNVERIFIED (answer-pending) and goes to MANUAL
///   CORRECTION by the user — never to AI.
/// * The "No MCQs found" dialog therefore offers manual correction
///   + diagnostics + the concrete next step — never AI generation.
/// * The AI service (lib/services/ai_generation.dart) STAYS in the
///   codebase, parked — but no extraction flow calls it.
void main() {
  group('extraction routing — the local parser is the only path', () {
    test('(a) parseable MCQs are extracted locally, no AI involved', () {
      const text = '''
Q1. What is the capital of Pakistan?
A) Lahore
B) Karachi
C) Islamabad
D) Quetta
Answer: C
''';
      final r = parseMcqs(
        text,
        sourceId: 'pf-a',
        sourceLabel: 'Parseable',
      );
      expect(r.parsed, 1);
      expect(r.questions.single.correctIndex, 2);
      expect(r.questions.single.answerSource, 'answer-line');
    });

    test('(b) 0 parseable MCQs → 0 parsed, nothing invented', () {
      const prose = '''
The Mughal Empire ruled India for centuries.
Its founder was Babur, who won the First Battle of Panipat.
The capital was Delhi for most of its history.
''';
      final r = parseMcqs(
        prose,
        sourceId: 'pf-b',
        sourceLabel: 'Prose',
      );
      expect(r.parsed, 0);
      expect(r.questions, isEmpty);
      // No question is fabricated to fill the gap.
      expect(r.answerPending, isEmpty);
    });

    test('(c) prose-only book: 0 MCQs, facts kept as diagnostics only',
        () {
      // Organisation file: 180 facts, 0 MCQs (see
      // universal_formats_test.dart) — under the old rule this was
      // the AI-generation case; under the parked-AI spec the facts
      // are diagnostics and NOTHING is generated from them.
      const text = '''
United Nations Organization: UNO
Headquarters of UNO: New York
Food and Agriculture Organization: FAO
''';
      final r = parseMcqs(
        text,
        sourceId: 'pf-c',
        sourceLabel: 'Fact cards',
      );
      expect(r.parsed, 0);
      expect(r.facts, isNotEmpty);
      expect(r.questions, isEmpty);
    });

    test('(d) a question without an answer stays UNVERIFIED, never '
        'guessed', () {
      const text = '''
1. Which is the largest planet?
(A) Mars
(B) Venus
(C) Jupiter
(D) Saturn
''';
      final r = parseMcqs(
        text,
        sourceId: 'pf-d',
        sourceLabel: 'No answer',
      );
      expect(r.parsed, 0);
      expect(r.questions, isEmpty);
      expect(r.answerPending.length, 1);
      expect(r.answerPending.single.reason, 'no-key-entry');
    });
  });

  group('daily caps — Free 2 / Premium 10 (AiUsageCaps, parked service)',
      () {
    // The AI service is parked, not deleted, and its caps are
    // retained with it. These unit tests prove the cap class itself
    // still behaves — no extraction flow consults it any more.
    test('Free: 2 runs allowed, 3rd blocked', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final caps = AiUsageCaps(prefs: prefs);
      expect(await caps.canRunAiBook(isPremium: false), isTrue);
      await caps.recordAiBookRun();
      expect(await caps.canRunAiBook(isPremium: false), isTrue);
      await caps.recordAiBookRun();
      expect(await caps.canRunAiBook(isPremium: false), isFalse);
      expect(await caps.booksRemainingToday(isPremium: false), 0);
    });

    test('Premium: 10 runs allowed, 11th blocked', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final caps = AiUsageCaps(prefs: prefs);
      for (var i = 0; i < 9; i++) {
        expect(await caps.canRunAiBook(isPremium: true), isTrue);
        await caps.recordAiBookRun();
      }
      expect(await caps.canRunAiBook(isPremium: true), isTrue);
      await caps.recordAiBookRun();
      expect(await caps.canRunAiBook(isPremium: true), isFalse);
      expect(await caps.booksRemainingToday(isPremium: true), 0);
    });

    test('cap is per-day: yesterday\'s runs never block today', () async {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final key =
          'ai_books_${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}';
      SharedPreferences.setMockInitialValues({key: 2});
      final prefs = await SharedPreferences.getInstance();
      final caps = AiUsageCaps(prefs: prefs);
      expect(await caps.canRunAiBook(isPremium: false), isTrue);
    });
  });

  group('flow wiring — source-level (same precedent as dead_end_ux_test)',
      () {
    test('upload flow has NO AI-generation call sites (AI parked)', () {
      final src =
          File('lib/screens/upload_screen.dart').readAsStringSync();
      expect(src.contains('generateFromText'), isFalse);
      expect(src.contains('inferAnswers'), isFalse);
      expect(src.contains('_runAiGeneration'), isFalse);
      expect(src.contains('_runAiInference'), isFalse);
      expect(src.contains('_aiFromPastedText'), isFalse);
      expect(src.contains('localParseSuffices'), isFalse);
      expect(src.contains('AI se MCQs banayein'), isFalse);
      expect(src.contains('AI se jawab nikaalein'), isFalse);
      expect(src.contains('AI se bhi banayein'), isFalse);
      expect(src.contains("import '../services/ai_generation.dart'"),
          isFalse);
      expect(src.contains("import '../services/ai_usage_caps.dart'"),
          isFalse);
      // …but it states the rule in words, so the user is never misled.
      expect(src, contains('AI se MCQs nahi banaye jate'));
    });

    test('manual correction is wired in place of AI', () {
      final src =
          File('lib/screens/upload_screen.dart').readAsStringSync();
      expect(src, contains('Jawab khud lagayein'));
      expect(src, contains('_runManualCorrection'));
      expect(src, contains('ManualCorrectionDialog'));
      expect(src, contains("Navigator.pop(context, 'manual')"));
      expect(src, contains("answerSource: 'manual'"));
      // The dialog offers manual correction only when there is
      // something to correct (pending questions exist).
      expect(
        src,
        contains(
          'if (!isLetter && result.answerPending.isNotEmpty)',
        ),
      );
    });

    test('file flow: parsed == 0 → no-MCQs dialog (diagnostics + ask)',
        () {
      final src =
          File('lib/screens/upload_screen.dart').readAsStringSync();
      expect(src, contains('if (result.parsed == 0)'));
      expect(src, contains('_showNoMcqsDialog(result, title, sourceId)'));
    });

    test('import service never calls AI generation', () {
      final src = File('lib/services/pdf_import_service.dart')
          .readAsStringSync();
      expect(src.contains('AiGenerationService'), isFalse);
      expect(src.contains('generateFromText'), isFalse);
      expect(src.contains('inferAnswers'), isFalse);
    });

    test('AI service is retained (parked, not deleted)', () {
      final service =
          File('lib/services/ai_generation.dart').readAsStringSync();
      expect(service, contains('class AiGenerationService'));
      expect(service, contains('generateFromText'));
      expect(service, contains('inferAnswers'));
    });
  });

  // Paste flow — end-to-end widget tests (parse-only now).
  //
  // SKIPPED in VM tests: UploadScreen loads its book list from
  // sqflite in initState, and sqflite has no VM implementation here
  // (same precedent as test/upgrade_payment_test.dart:16 — "Home /
  // My Books / ... need sqflite"). Pumping the screen hangs on the
  // loading spinner (pumpAndSettle timeout). Run these two on a real
  // phone (or with sqflite_common_ffi) — the bodies below are the
  // exact steps.
  group('paste flow — widget tests (parse-only, end-to-end)', () {
    Future<void> pumpUploadScreen(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        const MaterialApp(home: UploadScreen()),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      '(a) parseable pasted MCQs + Parse pasted text → save preview, '
      'no AI button',
      (tester) async {
        await pumpUploadScreen(tester);
        await tester.enterText(
          find.byWidgetPredicate(
            (w) =>
                w is TextField &&
                w.decoration?.labelText == 'Or paste MCQ text here',
          ),
          'Q1. What is the capital of Pakistan?\n'
          'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\nAnswer: C\n',
        );
        // There is no AI button any more (AI parked).
        expect(find.text('AI se MCQs banayein (pasted text)'), findsNothing);
        await tester.tap(find.text('Parse pasted text'));
        await tester.pumpAndSettle();
        // Local parse found it — the save preview opens.
        expect(find.text('Save these MCQs?'), findsOneWidget);
        expect(find.text('Gemini key chahiye'), findsNothing);
      },
      skip: true, // sqflite (phone only); see group comment
    );

    testWidgets('(b) 0 parseable MCQs + Parse pasted text → No MCQs '
        'dialog, no AI offer', (tester) async {
      await pumpUploadScreen(tester);
      await tester.enterText(
        find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              w.decoration?.labelText == 'Or paste MCQ text here',
        ),
        'The Mughal Empire ruled India for centuries.\n'
        'Its founder was Babur, who won the First Battle of Panipat.\n'
        'The capital was Delhi for most of its history.\n',
      );
      await tester.tap(find.text('Parse pasted text'));
      await tester.pumpAndSettle();
      // Nothing parsed locally → the no-MCQs dialog with diagnostics
      // and the next step — and no AI generation offer.
      expect(find.text('No MCQs found'), findsOneWidget);
      expect(find.text('AI se MCQs banayein'), findsNothing);
      expect(find.text('Jawab khud lagayein'), findsNothing);
    },
        skip: true); // sqflite (phone only); see group comment
  });
}
