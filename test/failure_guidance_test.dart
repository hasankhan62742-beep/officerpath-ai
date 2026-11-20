import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/models/exam.dart';
import 'package:officerpath_ai/models/question.dart';
import 'package:officerpath_ai/screens/upload_screen.dart';
import 'package:officerpath_ai/services/pdf_import_service.dart';

/// Worker 4 — Requirement A (user guidance on screen), governing
/// spec 19 Nov 2026 (AI generation PARKED): every "No MCQs found" /
/// failure dialog must ALWAYS include ALL of:
/// (1) what went wrong in plain words, (2) the concrete next step —
/// which format to re-make the book in and how to upload it so it
/// works — plus what the app already tried, and (3) the MANUAL
/// CORRECTION option where it applies (questions found without
/// answers). AI generation is NEVER offered. No dead ends, no
/// silent failures.
void main() {
  PdfImportResult result({
    required String text,
    int pageCount = 5,
    int textPages = 5,
    List<int> ocrPages = const [],
    int keySectionsFound = 0,
    int keyEntriesApplied = 0,
    List<PendingQuestion> answerPending = const [],
  }) =>
      PdfImportResult(
        text: text,
        pageCount: pageCount,
        textPages: textPages,
        ocrPages: ocrPages,
        ocrCapped: false,
        questions: const [],
        parsed: 0,
        skipped: 0,
        errors: const [],
        formats: const {},
        generatedOptions: 0,
        excluded: const [],
        keySectionsFound: keySectionsFound,
        keyEntriesApplied: keyEntriesApplied,
        answerPending: answerPending,
      );

/// Bounded pumps instead of pumpAndSettle: the no-answers notice
  /// card pulses forever by design (a repeating AnimationController),
  /// so pumpAndSettle would never settle on any dialog that shows it
  /// (NoMcqsDialog with pending questions). Five 100 ms frames are
  /// enough for a dialog to open / close.
  Future<void> pumpFrames(WidgetTester tester, [int frames = 5]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Pumps [NoMcqsDialog] behind an "Open" button. The dialog's
  /// popped value is written into [popped] when a button is tapped.
  Future<void> pumpDialog(
    WidgetTester tester,
    PdfImportResult r,
    ValueNotifier<String?> popped,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              popped.value = await showDialog<String>(
                context: context,
                builder: (_) => NoMcqsDialog(result: r),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await pumpFrames(tester);
  }

  group('NoMcqsDialog — all three Req A elements', () {
    testWidgets('0 MCQs, text read: reason + next step, NEVER AI',
        (tester) async {
      final r = result(
        text: 'Some prose without any question in it. ' * 20,
      );
      final popped = ValueNotifier<String?>(null);
      await pumpDialog(tester, r, popped);
      // (1) Plain-language reason — no jargon.
      expect(find.textContaining('no question matched'), findsOneWidget);
      // (2) Concrete next step: which format + how to upload.
      expect(find.text('What to do next:'), findsOneWidget);
      expect(find.textContaining('Text PDF banayein'), findsOneWidget);
      expect(find.textContaining('Scanned book ho to saaf scan'),
          findsOneWidget);
      expect(find.textContaining('Try TXT / paste'), findsOneWidget);
      // Diagnostics = what the app already tried.
      expect(find.text('Diagnostics:'), findsOneWidget);
      expect(find.textContaining('Pages parhe gaye:'), findsOneWidget);
      expect(find.textContaining('Answer Key:'), findsOneWidget);
      // (3) NO AI option anywhere — the dialog says so in words.
      expect(find.text('AI se MCQs banayein'), findsNothing);
      expect(find.text('AI se jawab nikaalein'), findsNothing);
      expect(find.textContaining('AI se MCQs nahi banaye'), findsOneWidget);
      // Nothing to correct either (no pending questions).
      expect(find.text('Jawab khud lagayein'), findsNothing);
      await tester.tap(find.text('Close'));
      await pumpFrames(tester);
      expect(popped.value, 'close');
    });

    testWidgets('empty text: reason + next step, no AI, no correction',
        (tester) async {
      final r = result(text: '', pageCount: 0, textPages: 0);
      final popped = ValueNotifier<String?>(null);
      await pumpDialog(tester, r, popped);
      expect(find.textContaining('No text could be read'), findsOneWidget);
      expect(find.text('What to do next:'), findsOneWidget);
      expect(find.textContaining('Text PDF banayein'), findsOneWidget);
      // No text → nothing to generate from and nothing to correct.
      expect(find.text('AI se MCQs banayein'), findsNothing);
      expect(find.text('Jawab khud lagayein'), findsNothing);
      expect(find.text('Close'), findsOneWidget);
    });

    testWidgets('admission letter: own message, no AI, no preview',
        (tester) async {
      final r = result(
        text: 'PUNJAB PUBLIC SERVICE COMMISSION\n'
            'ADMISSION LETTER\n'
            'Roll No: 12345\n'
            'Candidate: Test Person\n'
            'Instructions: report at the test centre at 8:00 AM.\n'
            'Reporting time: 08:00.',
      );
      final popped = ValueNotifier<String?>(null);
      await pumpDialog(tester, r, popped);
      expect(find.textContaining('admission letter'), findsOneWidget);
      expect(find.textContaining('is se test nahi ban sakta'),
          findsOneWidget);
      expect(find.text('AI se MCQs banayein'), findsNothing);
      expect(find.text('Jawab khud lagayein'), findsNothing);
      // The letter's text is never previewed (privacy).
      expect(find.text('What was actually read:'), findsNothing);
      expect(find.text('What to do next:'), findsNothing);
    });

    testWidgets('answer-pending: MANUAL CORRECTION offered, never AI',
        (tester) async {
      final r = result(
        text: 'Q1. Something?\nA) One\nB) Two\nC) Three\nD) Four\n',
        answerPending: [
          PendingQuestion(
            text: 'Q1. Something?',
            options: ['One', 'Two', 'Three', 'Four'],
            subject: Subject.gk,
            reason: 'no-key-entry',
          ),
        ],
      );
      final popped = ValueNotifier<String?>(null);
      await pumpDialog(tester, r, popped);
      expect(find.text('AI se jawab nikaalein'), findsNothing);
      expect(find.text('AI se MCQs banayein'), findsNothing);
      expect(find.text('Jawab khud lagayein'), findsOneWidget);
      await tester.tap(find.text('Jawab khud lagayein'));
      await pumpFrames(tester);
      expect(popped.value, 'manual');
    });
  });

  group('ManualCorrectionDialog — user sets unverified answers', () {
    late List<PendingQuestion> pending;

    setUp(() {
      pending = [
        PendingQuestion(
          text: 'What is the capital of France?',
          options: ['London', 'Berlin', 'Paris', 'Rome'],
          subject: Subject.gk,
          reason: 'no-key-entry',
        ),
        PendingQuestion(
          text: 'Which colour is the sky?',
          options: ['Red', 'Green', 'Blue', 'Yellow'],
          subject: Subject.gk,
          reason: 'no-key-entry',
        ),
      ];
    });

    /// Pumps the dialog behind an "Open" button; popped map goes
    /// into [popped] when Save is tapped, null on Cancel.
    Future<void> pumpCorrection(
      WidgetTester tester,
      ValueNotifier<Map<int, int>?> popped,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                popped.value = await showDialog<Map<int, int>>(
                  context: context,
                  builder: (_) => ManualCorrectionDialog(pending: pending),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await pumpFrames(tester);
    }

    testWidgets('explains manual marking; Save disabled until a pick',
        (tester) async {
      final popped = ValueNotifier<Map<int, int>?>(null);
      await pumpCorrection(tester, popped);
      expect(find.text('Jawab khud lagayein'), findsOneWidget);
      expect(find.textContaining('"manual" mark hoga'), findsOneWidget);
      expect(
        find.textContaining('UNVERIFIED jawab kabhi AI se nahi'),
        findsOneWidget,
      );
      expect(find.textContaining('What is the capital of France?'),
          findsOneWidget);
      expect(
          find.textContaining('Which colour is the sky?'), findsOneWidget);
      // Nothing picked yet: Save (0) is disabled.
      final save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save (0)'),
      );
      expect(save.onPressed, isNull);
      expect(popped.value, isNull);
    });

    testWidgets('picking options then Save returns the choices',
        (tester) async {
      final popped = ValueNotifier<Map<int, int>?>(null);
      await pumpCorrection(tester, popped);
      // The dialog scrolls (2 questions x 4 options): bring each
      // option into view before tapping it.
      await tester.ensureVisible(find.text('Paris'));
      await tester.tap(find.text('Paris'));
      await pumpFrames(tester);
      expect(find.text('Save (1)'), findsOneWidget);
      await tester.ensureVisible(find.text('Blue'));
      await tester.tap(find.text('Blue'));
      await pumpFrames(tester);
      expect(find.text('Save (2)'), findsOneWidget);
      await tester.tap(find.text('Save (2)'));
      await pumpFrames(tester);
      expect(popped.value, {0: 2, 1: 2});
    });

    testWidgets('partial correction saves only the answered ones',
        (tester) async {
      final popped = ValueNotifier<Map<int, int>?>(null);
      await pumpCorrection(tester, popped);
      await tester.tap(find.text('Paris'));
      await pumpFrames(tester);
      await tester.tap(find.text('Save (1)'));
      await pumpFrames(tester);
      expect(popped.value, {0: 2});
    });

    testWidgets('Cancel returns null — nothing is guessed',
        (tester) async {
      final popped = ValueNotifier<Map<int, int>?>(null);
      await pumpCorrection(tester, popped);
      await tester.tap(find.text('Paris'));
      await pumpFrames(tester);
      await tester.tap(find.text('Cancel'));
      await pumpFrames(tester);
      expect(popped.value, isNull);
    });
  });

  group('file-failure dialog — corrupt / unreadable file', () {
    testWidgets('reason + next step, stays until read, no AI option',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showFileFailureDialog(
                context,
                'Is PDF ka index (xref table) nahi parha gaya — file '
                'kharab ya incomplete download lagti hai. Dobara '
                'download karein.',
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await pumpFrames(tester);
      expect(find.text('File nahi parhi ja saki'), findsOneWidget);
      expect(find.textContaining('Dobara download karein'), findsOneWidget);
      expect(find.text('What to do next:'), findsOneWidget);
      expect(find.textContaining('File dobara download karein'),
          findsOneWidget);
      expect(find.textContaining('text PDF banayein'), findsOneWidget);
      expect(find.text('AI se MCQs banayein'), findsNothing);
      await tester.tap(find.text('OK'));
      await pumpFrames(tester);
      expect(find.text('File nahi parhi ja saki'), findsNothing);
    });
  });

  group('failure paths route to dialogs — source-level', () {
    test('corrupt/docx/generic failures show the dialog, not a snackbar',
        () {
      final src =
          File('lib/screens/upload_screen.dart').readAsStringSync();
      expect(src, contains('showFileFailureDialog(context, e.message)'));
      expect(
        src,
        contains(
          'await showFileFailureDialog(\n          context,\n          '
          "'Could not read this file: \$e',",
        ),
      );
      // The corrupt-file catch shows the dialog, not a snackbar.
      final corruptAt = src.indexOf('on CorruptPdfException catch (e)');
      expect(corruptAt, isNot(-1));
      final block = src.substring(corruptAt, corruptAt + 400);
      expect(block, contains('showFileFailureDialog'));
      expect(block.contains('_showMessage(e.message)'), isFalse);
    });

    test('the upload flow has NO AI-generation call sites (AI parked)',
        () {
      final src =
          File('lib/screens/upload_screen.dart').readAsStringSync();
      // No generation, no inference, no AI entry-point methods.
      expect(src.contains('generateFromText'), isFalse);
      expect(src.contains('inferAnswers'), isFalse);
      expect(src.contains('_runAiGeneration'), isFalse);
      expect(src.contains('_runAiInference'), isFalse);
      expect(src.contains('_aiFromPastedText'), isFalse);
      expect(src.contains('AI se MCQs banayein'), isFalse);
      expect(src.contains('AI se jawab nikaalein'), isFalse);
      expect(src.contains('AI se bhi banayein'), isFalse);
      // The manual-correction path is wired instead.
      expect(src, contains("Navigator.pop(context, 'manual')"));
      expect(src, contains('_runManualCorrection'));
      expect(src, contains('ManualCorrectionDialog'));
      // The AI service itself is retained (parked, not deleted) —
      // but nothing in the upload flow imports it.
      expect(src.contains("import '../services/ai_generation.dart'"),
          isFalse);
      final service =
          File('lib/services/ai_generation.dart').readAsStringSync();
      expect(service, contains('class AiGenerationService'));
    });
  });
}
