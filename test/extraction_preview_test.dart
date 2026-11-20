import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/models/exam.dart';
import 'package:officerpath_ai/models/question.dart';
import 'package:officerpath_ai/screens/upload_screen.dart';
import 'package:officerpath_ai/services/pdf_import_service.dart';

/// Phase A verification UI (item 4 + G8 + G-M3 + G-C6): the extraction
/// preview shows, per question, the question, options A–D, the
/// detected correct answer, the source page, the confidence score and
/// the verification status — and lets the user correct an
/// already-answered question, keeping the original answer separate.
void main() {
  Question q({
    required String text,
    required int correct,
    required String source,
    int page = 0,
    bool verified = true,
    double? confidence,
    String provenance = 'printed',
  }) {
    return Question(
      text: text,
      options: const ['Lahore', 'Karachi', 'Islamabad', 'Quetta'],
      correctIndex: correct,
      subject: Subject.gk,
      sourceId: 'preview-test',
      sourceLabel: 'Preview Test',
      page: page,
      answerSource: source,
      answerVerified: verified,
      confidence: confidence,
      markProvenance: provenance,
    );
  }

  PdfImportResult resultWith(List<Question> questions) {
    return PdfImportResult(
      text: '',
      pageCount: 3,
      textPages: 3,
      ocrPages: const [1],
      ocrCapped: false,
      questions: questions,
      parsed: questions.length,
      skipped: 0,
      errors: const [],
      formats: const {'block': 1, 'table': 1, 'q-only': 1},
      generatedOptions: 0,
      excluded: const [],
    );
  }

  /// Pumps a host page with a button that opens the preview dialog
  /// and records the popped decision, so tests can assert both the
  /// rendered rows AND what Save returns.
  Future<void> pumpPreview(
    WidgetTester tester,
    PdfImportResult result, {
    List<String> summary = const ['Parsed 3 MCQs from "Preview Test".'],
    bool showManual = false,
    bool showMpt = false,
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
                      summaryLines: summary,
                      showManual: showManual,
                      showMpt: showMpt,
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
    await tester.pumpAndSettle();
  }

  group('per-question preview rows', () {
    testWidgets('question, options, answer, page, confidence, status',
        (tester) async {
      PreviewDecision? decision;
      await pumpPreview(
        tester,
        resultWith([
          q(
            text: 'What is the capital of Pakistan?',
            correct: 2,
            source: 'key',
            page: 3,
          ),
        ]),
        onDecision: (d) => decision = d,
      );
      expect(find.text('Save these MCQs?'), findsOneWidget);
      expect(
        find.text('1. What is the capital of Pakistan?'),
        findsOneWidget,
      );
      // Options A–D; the detected answer is marked ✓ + bold + source.
      expect(find.text('✓ C. Islamabad (key se)'), findsOneWidget);
      expect(find.text('A. Lahore'), findsOneWidget);
      expect(find.text('B. Karachi'), findsOneWidget);
      expect(find.text('D. Quetta'), findsOneWidget);
      // Source page, confidence (key = 1.0) and verification status.
      expect(find.text('Page 3 • Confidence 100% • verified'), findsOneWidget);
      // Save returns the (uncorrected) questions.
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(decision, isNotNull);
      expect(decision!.action, 'save');
      expect(decision!.questions.single.correctIndex, 2);
      expect(decision!.questions.single.originalCorrectIndex, isNull);
    });

    testWidgets('G-C6: OCR-unverified answer shows its warning + 54%',
        (tester) async {
      await pumpPreview(
        tester,
        resultWith([
          q(
            text: 'Which is the largest planet?',
            correct: 1,
            source: 'tick',
            page: 1,
            verified: false,
            confidence: 0.54,
            provenance: 'ocr',
          ),
        ]),
        onDecision: (_) {},
      );
      expect(find.text('Page 1 • Confidence 54% • unverified'), findsOneWidget);
      // The warning is VISIBLE in the row, not just in the model.
      expect(
        find.textContaining('OCR se parha gaya'),
        findsOneWidget,
      );
      expect(find.textContaining('UNVERIFIED hai'), findsOneWidget);
    });

    testWidgets('G-C6: OCR-verified answer still warns about cut-off',
        (tester) async {
      // Paper 60 Q11 shape: asterisk answer via OCR — verified, but
      // the options may have been hallucinated past the page edge.
      await pumpPreview(
        tester,
        resultWith([
          q(
            text: 'Which function returns the sum?',
            correct: 3,
            source: 'asterisk',
            page: 1,
            provenance: 'ocr',
          ),
        ]),
        onDecision: (_) {},
      );
      expect(find.text('Page 1 • Confidence 90% • verified'), findsOneWidget);
      expect(find.textContaining('kata hua tha'), findsOneWidget);
    });

    testWidgets('G8: summary lines render table + flashcard counts',
        (tester) async {
      await pumpPreview(
        tester,
        resultWith([
          q(text: 'Table row question?', correct: 0, source: 'key', page: 2),
        ]),
        summary: const [
          'Parsed 3 MCQs from "Preview Test".',
          '• Table rows: 1',
          '• Flashcards: 1',
        ],
        onDecision: (_) {},
      );
      expect(find.textContaining('Table rows: 1'), findsOneWidget);
      expect(find.textContaining('Flashcards: 1'), findsOneWidget);
    });
  });

  group('G-M3 correct an already-answered question', () {
    testWidgets('CorrectAnswerDialog: Save disabled until a different '
        'option is picked', (tester) async {
      int? returned;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: TextButton(
                  onPressed: () async {
                    returned = await showDialog<int>(
                      context: context,
                      builder: (_) => CorrectAnswerDialog(
                        question: q(
                          text: 'What is the capital of Pakistan?',
                          correct: 2,
                          source: 'key',
                          page: 3,
                        ),
                      ),
                    );
                  },
                  child: const Text('Open correction'),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Open correction'));
      await tester.pumpAndSettle();
      expect(find.text('Jawab theek karein'), findsOneWidget);
      expect(find.textContaining('Book ka jawab: C (key se)'), findsOneWidget);
      // Save starts disabled (nothing changed yet).
      final saveButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save correction'),
      );
      expect(saveButton.onPressed, isNull);
      // Picking the CURRENT option keeps it disabled; picking A enables it.
      await tester.tap(find.text('Karachi'));
      await tester.pump();
      expect(
        tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Save correction'),
        ).onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Save correction'));
      await tester.pumpAndSettle();
      expect(returned, 1);
    });

    test('Question.withCorrection keeps the original separate', () {
      final original = q(
        text: 'What is the capital of Pakistan?',
        correct: 2,
        source: 'key',
        page: 3,
      );
      final corrected = original.withCorrection(1);
      expect(corrected.correctIndex, 1);
      expect(corrected.originalCorrectIndex, 2);
      expect(corrected.answerSource, 'manual');
      expect(corrected.verificationStatus, 'manually-corrected');
      expect(corrected.answerVerified, isTrue);
      expect(corrected.confidence, 1.0);
    });

    testWidgets('preview: correct in place, original shown, Save keeps it',
        (tester) async {
      PreviewDecision? decision;
      await pumpPreview(
        tester,
        resultWith([
          q(
            text: 'What is the capital of Pakistan?',
            correct: 2,
            source: 'key',
            page: 3,
          ),
        ]),
        onDecision: (d) => decision = d,
      );
      await tester.tap(
        find.widgetWithText(TextButton, 'Jawab theek karein'),
      );
      await tester.pumpAndSettle();
      // The correction dialog opened (its title collides with the row
      // button's label, so assert on its body text instead).
      expect(find.textContaining('Book ka jawab:'), findsOneWidget);
      await tester.tap(find.text('Karachi'));
      await tester.pump();
      await tester.tap(find.text('Save correction'));
      await tester.pumpAndSettle();
      // Back in the preview: the corrected answer + the original.
      expect(find.text('✓ B. Karachi (manual se)'), findsOneWidget);
      expect(find.text('Pehla jawab: C (aap ne theek kiya)'), findsOneWidget);
      expect(
        find.text('Page 3 • Confidence 100% • manually-corrected'),
        findsOneWidget,
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(decision, isNotNull);
      expect(decision!.action, 'save');
      expect(decision!.questions.single.correctIndex, 1);
      expect(decision!.questions.single.originalCorrectIndex, 2);
    });
  });

  group('G8 source check', () {
    test('_importResult builds table/flashcard counts from the parse',
        () {
      final src = File('lib/screens/upload_screen.dart').readAsStringSync();
      expect(src, contains("formats['table']"));
      expect(src, contains("answerSource == 'flashcard'"));
      expect(src, contains('Table rows:'));
      expect(src, contains('Flashcards:'));
    });
  });

  group('centralized answer status in the preview (20 Nov 2026)', () {
    PdfImportResult phoneCase() {
      // The owner's PPSC-66 phone case, reduced: 1 answered + 1
      // pending question, a key detected with 5 unmatched entries,
      // 0 applied. The old dialog showed the green "no answers
      // attached" notice AND the amber unmatched-key warnings at
      // the same time — a contradiction. The status is
      // ANSWERS EXTRACTED BUT UNMATCHED.
      return PdfImportResult(
        text: '',
        pageCount: 7,
        textPages: 0,
        ocrPages: const [1, 2, 3, 4, 5, 6, 7],
        ocrCapped: false,
        questions: [
          q(
            text: 'The transition period of Brexit ended on:',
            correct: 1,
            source: 'key',
            page: 7,
          ),
        ],
        parsed: 1,
        skipped: 0,
        errors: const [],
        formats: const {'block': 1},
        generatedOptions: 0,
        excluded: const [],
        keySectionsFound: 1,
        keyEntriesApplied: 0,
        questionsMissingAnswers: const ['Paper 67 Q2'],
        unmatchedKeyEntries: const [
          'Paper 66 key entry 1 — no matching question',
          'Paper 66 key entry 2 — no matching question',
          'Paper 66 key entry 21 — no matching question',
          'Paper 66 key entry 22 — no matching question',
          'Paper 66 key entry 3 — no matching question',
        ],
        answerPending: [
          PendingQuestion(
            text: 'Shin Bet is security intelligence agency of:',
            options: ['Israel', 'Russia', 'Japan', 'None of these'],
            subject: Subject.gk,
            page: 7,
          ),
        ],
      );
    }

    testWidgets(
        'key detected but unmatched: amber status box, NO green notice',
        (tester) async {
      PreviewDecision? decision;
      await pumpPreview(
        tester,
        phoneCase(),
        showManual: true,
        onDecision: (d) => decision = d,
      );
      expect(find.text('Save these MCQs?'), findsOneWidget);
      // The accurate-counts status box is shown…
      expect(find.byType(AnswerStatusBox), findsOneWidget);
      expect(
        find.textContaining('Key mili, jawab kisi sawal se nahi lage'),
        findsOneWidget,
      );
      expect(find.textContaining('5 entries'), findsOneWidget);
      // …and the green "no answers attached" notice is forbidden.
      expect(find.byType(NoAnswersNoticeBox), findsNothing);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(decision, isNotNull);
    });

    testWidgets('genuinely no key: green notice, no status box',
        (tester) async {
      PreviewDecision? decision;
      final noKey = PdfImportResult(
        text: '',
        pageCount: 1,
        textPages: 0,
        ocrPages: const [1],
        ocrCapped: false,
        questions: [
          q(
            text: 'Shin Bet is security intelligence agency of:',
            correct: -1,
            source: '',
            page: 7,
          ),
        ],
        parsed: 1,
        skipped: 0,
        errors: const [],
        formats: const {'block': 1},
        generatedOptions: 0,
        excluded: const [],
        questionsMissingAnswers: const ['Q1'],
        answerPending: [
          PendingQuestion(
            text: 'Shin Bet is security intelligence agency of:',
            options: ['Israel', 'Russia', 'Japan', 'None of these'],
            subject: Subject.gk,
            page: 7,
          ),
        ],
      );
      // Same as pumpPreview, but WITHOUT pumpAndSettle: the green
      // notice card pulses forever, so settle never returns. A
      // single pump renders the dialog fine.
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
                        result: noKey,
                        summaryLines: const [
                          'Parsed 1 MCQs from "No Key Test".',
                        ],
                        showManual: true,
                        showMpt: false,
                      ),
                    );
                    decision = d;
                  },
                  child: const Text('Open preview'),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Open preview'));
      await tester.pump();
      expect(find.byType(NoAnswersNoticeBox), findsOneWidget);
      expect(find.byType(AnswerStatusBox), findsNothing);
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(decision, isNotNull);
    });
  });
}
