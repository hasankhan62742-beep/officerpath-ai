import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/models/exam.dart';
import 'package:officerpath_ai/models/question.dart';
import 'package:officerpath_ai/screens/upload_screen.dart';
import 'package:officerpath_ai/services/parse_validation.dart';
import 'package:officerpath_ai/services/pdf_import_service.dart';

/// MASTER DIRECTIVE Part 10 wiring (20 Nov 2026): validateParseResult
/// runs before the preview shows. Errors block saving; warnings and
/// infos are shown as a note. The 10 baseline fabrications are
/// flagged by validateParseResult itself (parse_validation_test.dart)
/// — these tests pin the preview surfacing.
void main() {
  Question answered(String text) => Question(
    text: text,
    options: const ['Lahore', 'Karachi', 'Islamabad', 'Quetta'],
    correctIndex: 2,
    subject: Subject.gk,
    sourceId: 'preview-validation-test',
    sourceLabel: 'Preview Validation Test',
    answerSource: 'key',
  );

  PendingQuestion pending(String text) => PendingQuestion(
    text: text,
    options: const ['Lahore', 'Karachi', 'Islamabad', 'Quetta'],
    subject: Subject.gk,
    number: 1,
    paper: 'Paper 1',
  );

  PdfImportResult resultWith({
    required List<Question> questions,
    required List<PendingQuestion> answerPending,
  }) {
    return PdfImportResult(
      text: '',
      pageCount: 1,
      textPages: 1,
      ocrPages: const [],
      ocrCapped: false,
      questions: questions,
      parsed: questions.length,
      skipped: 0,
      errors: const [],
      formats: const {'block': 1},
      generatedOptions: 0,
      excluded: const [],
      answerPending: answerPending,
    );
  }

  /// Pumps a few frames instead of pumpAndSettle: the no-answers
  /// notice is a pulsing animation (a repeating AnimationController),
  /// so pumpAndSettle would never settle while the dialog is open.
  Future<void> pumpFrames(WidgetTester tester, [int frames = 5]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpPreview(
    WidgetTester tester,
    PdfImportResult result,
    ValidationReport? validation, {
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
                      validation: validation,
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

  group('validation in the upload preview', () {
    testWidgets('errors block Save and save-answerless, with a plain '
        'message', (tester) async {
      PreviewDecision? decision;
      final validation = ValidationReport(
        issues: const [
          ValidationIssue(
            kind: ValidationKind.duplicateQuestion,
            severity: ValidationSeverity.error,
            detail: 'Question text parsed 2 times.',
            questionRef: 'what is the capital of pakistan?',
          ),
        ],
        keyPaperNotes: const [],
      );
      await pumpPreview(
        tester,
        resultWith(
          questions: [answered('What is the capital of Pakistan?')],
          answerPending: [pending('Capital of France?')],
        ),
        validation,
        onDecision: (d) => decision = d,
      );
      expect(find.text('Save these MCQs?'), findsOneWidget);
      expect(
        find.text('Is import mein masla hai — save nahi ho sakta.'),
        findsOneWidget,
      );
      expect(find.textContaining('parsed 2 times'), findsOneWidget);
      // Both save paths are disabled; Cancel / manual / key stay open.
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(
                OutlinedButton,
                'Jawab ke baghair save karein',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Cancel'));
      await pumpFrames(tester);
      expect(decision, isNotNull);
      expect(decision!.action, 'cancel');
    });

    testWidgets('warnings show as a note and Save stays enabled',
        (tester) async {
      PreviewDecision? decision;
      final validation = ValidationReport(
        issues: const [
          ValidationIssue(
            kind: ValidationKind.fabricationSuspect,
            severity: ValidationSeverity.warning,
            detail:
                'Question looks like a key fragment or explanation bullet, not a real question — review before using.',
            questionRef: 'page 7 :: (A) Speak:',
          ),
          ValidationIssue(
            kind: ValidationKind.unmatchedKeyEntry,
            severity: ValidationSeverity.warning,
            detail: 'Paper 66 key entry 3 — no matching question',
          ),
        ],
        keyPaperNotes: const [],
      );
      await pumpPreview(
        tester,
        resultWith(
          questions: [answered('What is the capital of Pakistan?')],
          answerPending: const [],
        ),
        validation,
        onDecision: (d) => decision = d,
      );
      expect(find.text('Check karne wali baatein:'), findsOneWidget);
      expect(find.textContaining('key fragment'), findsOneWidget);
      expect(find.textContaining('no matching question'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Save'));
      await pumpFrames(tester);
      expect(decision, isNotNull);
      expect(decision!.action, 'save');
    });

    testWidgets('infos show as a note, capped with an "aur N aur" line',
        (tester) async {
      final issues = [
        for (var i = 1; i <= 7; i++)
          ValidationIssue(
            kind: ValidationKind.missingAnswer,
            severity: ValidationSeverity.info,
            detail: 'No answer in the book — kept answerless, never scored.',
            questionRef: 'page 1 :: Question $i?',
          ),
      ];
      final validation = ValidationReport(
        issues: issues,
        keyPaperNotes: const [],
      );
      await pumpPreview(
        tester,
        resultWith(
          questions: [answered('What is the capital of Pakistan?')],
          answerPending: const [],
        ),
        validation,
        onDecision: (_) {},
      );
      expect(find.text('Check karne wali baatein:'), findsOneWidget);
      // 5 shown + "…aur 2 aur." — a 100-pending book never floods
      // the dialog.
      expect(find.text('…aur 2 aur.'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save'),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('no validation means no report box (existing behaviour)',
        (tester) async {
      await pumpPreview(
        tester,
        resultWith(
          questions: [answered('What is the capital of Pakistan?')],
          answerPending: const [],
        ),
        null,
        onDecision: (_) {},
      );
      expect(find.byType(ValidationReportBox), findsNothing);
      expect(find.text('Save these MCQs?'), findsOneWidget);
    });
  });

  group('_importResult wiring', () {
    test('runs validateParseResult and passes it to the preview', () {
      final src = File(
        'lib/screens/upload_screen.dart',
      ).readAsStringSync();
      expect(src, contains('validateParseResult('));
      expect(src, contains('validation: validation,'));
      expect(src, contains('widget.validation?.hasErrors == true'));
    });
  });
}
