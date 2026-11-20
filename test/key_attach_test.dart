// Attach-answer-key flow (20 Nov 2026, "Jawab wali key attach
// karein"): after an import where questions lack answers, the user
// attaches the answer key separately (typed/pasted text, or a key
// photo/PDF read through the import's own OCR/text path). The app
// reads it and fills answers by NUMBERING, reusing the parser's own
// key-entry machinery ([parseKeyEntries] / [applyAttachedKey]) — no
// second key parser. A key that names a paper applies only to that
// paper (strict paper rule); a bare key applies to all pending by
// number. Nothing is ever guessed: an unparseable key reports
// [KeyAttachResult.parseFailed] and fills nothing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/models/exam.dart';
import 'package:officerpath_ai/models/question.dart';
import 'package:officerpath_ai/screens/upload_screen.dart';
import 'package:officerpath_ai/services/answer_key.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/pdf_import_service.dart';

const _options4 = ['Lahore', 'Karachi', 'Islamabad', 'Quetta'];

void main() {
  final options4 = _options4;

  PendingQuestion pendingQ({
    required int? number,
    String paper = '',
    String text = 'Capital of Pakistan?',
    List<String> options = _options4,
  }) {
    return PendingQuestion(
      text: text,
      options: options,
      subject: Subject.gk,
      number: number,
      paper: paper,
    );
  }

  Question answeredQ({required String text, required int correct}) {
    return Question(
      text: text,
      options: options4,
      correctIndex: correct,
      subject: Subject.gk,
      sourceId: 'key-attach-test',
      sourceLabel: 'Key Attach Test',
      answerSource: 'asterisk',
      answerVerified: true,
    );
  }

  PdfImportResult resultWith({
    required List<Question> questions,
    List<PendingQuestion> pendingList = const [],
    List<String> keyPaperReport = const [],
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
      keyPaperReport: keyPaperReport,
    );
  }

  /// Bounded pumps (see no_answers_test.dart): the no-answers notice
  /// and the key-attach result card pulse forever by design, so
  /// pumpAndSettle would never settle.
  Future<void> pumpFrames(WidgetTester tester, [int frames = 5]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  group('applyAttachedKey — unit', () {
    test('fills answers by number (typed forms)', () {
      final pending = [pendingQ(number: 1), pendingQ(number: 2),
        pendingQ(number: 3)];
      final r = applyAttachedKey(keyText: '1-C 2-B 3-D', pending: pending);
      expect(r.parseFailed, isFalse);
      expect(r.filled, {0: 2, 1: 1, 2: 3});
      expect(r.stillMissingNumbers, isEmpty);
      expect(r.unnumberedStillMissing, 0);
    });

    test('fills a 100-question key list', () {
      final pending = [
        for (var n = 1; n <= 100; n++)
          pendingQ(
            number: n,
            options: const ['Alpha', 'Beta', 'Gamma', 'Delta'],
          ),
      ];
      final key = List.generate(
        100,
        (i) => '${i + 1}-${'ABCD'[i % 4]}',
      ).join(' ');
      final r = applyAttachedKey(keyText: key, pending: pending);
      expect(r.parseFailed, isFalse);
      expect(r.filled.length, 100);
      expect(r.stillMissingNumbers, isEmpty);
      // Spot-check the cycle: Q1→A(0), Q2→B(1), Q3→C(2), Q4→D(3).
      expect(r.filled[0], 0);
      expect(r.filled[1], 1);
      expect(r.filled[2], 2);
      expect(r.filled[3], 3);
    });

    test('partial key leaves the rest pending', () {
      final pending = [
        for (var n = 1; n <= 5; n++) pendingQ(number: n),
      ];
      final r = applyAttachedKey(keyText: '1-C 3-A', pending: pending);
      expect(r.filled, {0: 2, 2: 0});
      expect(r.stillMissingNumbers, [2, 4, 5]);
    });

    test('unparseable key is reported, nothing is guessed', () {
      final pending = [pendingQ(number: 1), pendingQ(number: 2)];
      final r = applyAttachedKey(
        keyText: 'hello world no numbers here',
        pending: pending,
      );
      expect(r.parseFailed, isTrue);
      expect(r.filled, isEmpty);
      expect(r.stillMissingNumbers, [1, 2]);
    });

    test('"?" token stays pending, never guessed', () {
      final pending = [pendingQ(number: 1), pendingQ(number: 2)];
      final r = applyAttachedKey(keyText: '1-? 2-B', pending: pending);
      expect(r.parseFailed, isFalse);
      expect(r.filled, {1: 1});
      expect(r.stillMissingNumbers, [1]);
    });

    test('text token resolves against the options', () {
      final pending = [pendingQ(number: 1)];
      final r = applyAttachedKey(
        keyText: '1. Islamabad',
        pending: pending,
      );
      expect(r.filled, {0: 2});
    });

    test('unresolvable token (E for 4 options) is reported', () {
      final pending = [pendingQ(number: 1)];
      final r = applyAttachedKey(keyText: '1-E', pending: pending);
      expect(r.filled, isEmpty);
      expect(r.unresolvedNumbers, [1]);
      expect(r.stillMissingNumbers, [1]);
    });

    test('named paper fills only that paper', () {
      final pending = [
        pendingQ(number: 1, paper: 'Paper 60'),
        pendingQ(number: 2, paper: 'Paper 60'),
        pendingQ(number: 1, paper: 'Paper 61'),
        pendingQ(number: 2, paper: 'Paper 61'),
      ];
      final r = applyAttachedKey(
        keyText: 'Answers – Paper 60\n1-C 2-B',
        pending: pending,
      );
      expect(r.filled, {0: 2, 1: 1});
      expect(r.stillMissingNumbers, [1, 2]);
      expect(r.orphanKeyPapers, isEmpty);
    });

    test('key naming a paper not in the import applies to nothing', () {
      final pending = [
        pendingQ(number: 1, paper: 'Paper 60'),
        pendingQ(number: 2, paper: 'Paper 60'),
      ];
      final r = applyAttachedKey(
        keyText: 'Answers – Paper 62\n1-C 2-B',
        pending: pending,
      );
      expect(r.filled, isEmpty);
      expect(r.stillMissingNumbers, [1, 2]);
      expect(r.orphanKeyPapers, ['Paper 62']);
    });

    test('bare key applies to every pending paper by number', () {
      final pending = [
        pendingQ(number: 1, paper: 'Paper 60'),
        pendingQ(number: 2, paper: 'Paper 60'),
        pendingQ(number: 1, paper: 'Paper 61'),
        pendingQ(number: 2, paper: 'Paper 61'),
      ];
      final r = applyAttachedKey(keyText: '1-C 2-B', pending: pending);
      expect(r.filled, {0: 2, 1: 1, 2: 2, 3: 1});
      expect(r.stillMissingNumbers, isEmpty);
    });

    test('unnumbered pending can never be filled by a key', () {
      final pending = [pendingQ(number: null), pendingQ(number: 1)];
      final r = applyAttachedKey(keyText: '1-C', pending: pending);
      expect(r.filled, {1: 2});
      expect(r.unnumberedStillMissing, 1);
    });
  });

  group('PendingQuestion number/paper round-trip', () {
    test('toMap/fromMap keeps number and paper', () {
      final p = pendingQ(number: 5, paper: 'Paper 60');
      final back = PendingQuestion.fromMap(p.toMap());
      expect(back.number, 5);
      expect(back.paper, 'Paper 60');
      expect(back.text, p.text);
      expect(back.options, p.options);
    });
  });

  group('keyAttachResultMessage wording', () {
    test('filled count + still-missing numbers', () {
      const r = KeyAttachResult(
        filled: {0: 2, 1: 1},
        stillMissingNumbers: [4, 7],
        unnumberedStillMissing: 0,
        unresolvedNumbers: [],
        orphanKeyPapers: [],
      );
      final m = keyAttachResultMessage(r);
      expect(m, contains('2 jawab key se lag gaye'));
      expect(m, contains('Q4, Q7'));
    });

    test('zero filled says plainly that nothing matched', () {
      const r = KeyAttachResult(
        filled: {},
        stillMissingNumbers: [1, 2],
        unnumberedStillMissing: 0,
        unresolvedNumbers: [],
        orphanKeyPapers: [],
      );
      expect(
        keyAttachResultMessage(r),
        contains('koi jawab nahi laga'),
      );
    });

    test('orphan paper is reported', () {
      const r = KeyAttachResult(
        filled: {},
        stillMissingNumbers: [],
        unnumberedStillMissing: 0,
        unresolvedNumbers: [],
        orphanKeyPapers: ['Paper 62'],
      );
      final m = keyAttachResultMessage(r);
      expect(m, contains("Key 'Paper 62' mili"));
      expect(m, contains('key nahi lagayi'));
    });
  });

  group('AttachAnswerKeyDialog — widget', () {
    Future<KeyAttachResult?> pumpKeyDialog(
      WidgetTester tester,
      List<PendingQuestion> pending, {
      required Future<String?> Function() readKeyFile,
      required void Function(KeyAttachResult?) onResult,
    }) async {
      KeyAttachResult? popped;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: TextButton(
                  onPressed: () async {
                    popped = await showDialog<KeyAttachResult>(
                      context: context,
                      builder: (_) => AttachAnswerKeyDialog(
                        pending: pending,
                        readKeyFile: readKeyFile,
                      ),
                    );
                    onResult(popped);
                  },
                  child: const Text('Open key dialog'),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Open key dialog'));
      await pumpFrames(tester);
      return popped;
    }

    testWidgets('typed key fills by number and pops the result',
        (tester) async {
      KeyAttachResult? result;
      await pumpKeyDialog(
        tester,
        [pendingQ(number: 1), pendingQ(number: 2), pendingQ(number: 3)],
        readKeyFile: () async => null,
        onResult: (r) => result = r,
      );
      await tester.enterText(find.byType(TextField), '1-C 2-B');
      await tester.tap(find.text('Key lagayein'));
      await pumpFrames(tester);
      expect(result, isNotNull);
      expect(result!.filled, {0: 2, 1: 1});
      expect(result!.stillMissingNumbers, [3]);
    });

    testWidgets('unparseable key shows the error and stays open',
        (tester) async {
      KeyAttachResult? result;
      await pumpKeyDialog(
        tester,
        [pendingQ(number: 1)],
        readKeyFile: () async => null,
        onResult: (r) => result = r,
      );
      await tester.enterText(find.byType(TextField), 'hello world');
      await tester.tap(find.text('Key lagayein'));
      await pumpFrames(tester);
      expect(result, isNull);
      expect(find.text('Key lagayein'), findsOneWidget);
      expect(find.textContaining('Key samajh nahi aayi'), findsOneWidget);
    });

    testWidgets('file button reads the key text and applies it',
        (tester) async {
      KeyAttachResult? result;
      await pumpKeyDialog(
        tester,
        [pendingQ(number: 1), pendingQ(number: 2), pendingQ(number: 3)],
        readKeyFile: () async => '1-C 2-B 3-D',
        onResult: (r) => result = r,
      );
      expect(find.text('Key ki photo / PDF attach karein'), findsOneWidget);
      await tester.tap(find.text('Key ki photo / PDF attach karein'));
      await pumpFrames(tester, 8);
      // The read text lands in the field.
      expect(find.text('1-C 2-B 3-D'), findsOneWidget);
      await tester.tap(find.text('Key lagayein'));
      await pumpFrames(tester);
      expect(result, isNotNull);
      expect(result!.filled, {0: 2, 1: 1, 2: 3});
    });
  });

  group('ExtractionPreviewDialog — key action', () {
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

    testWidgets('key button shows when pending exist, pops key',
        (tester) async {
      PreviewDecision? decision;
      await pumpPreview(
        tester,
        resultWith(
          questions: [answeredQ(text: 'Q1?', correct: 2)],
          pendingList: [pendingQ(number: 1), pendingQ(number: 2)],
        ),
        onDecision: (d) => decision = d,
      );
      expect(find.text('Jawab wali key attach karein'), findsOneWidget);
      await tester.tap(find.text('Jawab wali key attach karein'));
      await pumpFrames(tester);
      expect(decision, isNotNull);
      expect(decision!.action, 'key');
    });

    testWidgets('key button hidden when everything is answered',
        (tester) async {
      await pumpPreview(
        tester,
        resultWith(questions: [answeredQ(text: 'Q1?', correct: 2)]),
        onDecision: (_) {},
      );
      expect(find.text('Jawab wali key attach karein'), findsNothing);
      expect(
        find.textContaining('Aap ne sirf questions bheje hain'),
        findsNothing,
      );
    });

    testWidgets('key-attach result message shows green + pulsing',
        (tester) async {
      await pumpPreview(
        tester,
        resultWith(
          questions: [answeredQ(text: 'Q1?', correct: 2)],
          pendingList: [pendingQ(number: 3)],
          keyPaperReport: const [],
        ),
        onDecision: (_) {},
      );
      // The preview takes an explicit keyAttachMessage param; pump it
      // through a fresh dialog to check the box renders.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KeyAttachResultBox(
              message: keyAttachResultMessage(
                const KeyAttachResult(
                  filled: {0: 2},
                  stillMissingNumbers: [3],
                  unnumberedStillMissing: 0,
                  unresolvedNumbers: [],
                  orphanKeyPapers: [],
                ),
              ),
            ),
          ),
        ),
      );
      await pumpFrames(tester);
      expect(find.textContaining('1 jawab key se lag gaye'), findsOneWidget);
      expect(find.textContaining('Q3'), findsOneWidget);
    });
  });

  group('NoMcqsDialog — key action + key paper report', () {
    testWidgets('key button pops key and the report lines show',
        (tester) async {
      String? action;
      final result = resultWith(
        questions: const [],
        pendingList: [pendingQ(number: 1), pendingQ(number: 2)],
        keyPaperReport: const ["Key 'Paper 60' se 2 jawab lage."],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: TextButton(
                  onPressed: () async {
                    action = await showDialog<String>(
                      context: context,
                      builder: (_) => NoMcqsDialog(result: result),
                    );
                  },
                  child: const Text('Open no-mcqs'),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Open no-mcqs'));
      await pumpFrames(tester);
      expect(find.textContaining("Key 'Paper 60' se 2 jawab lage."),
          findsOneWidget);
      expect(find.text('Jawab wali key attach karein'), findsOneWidget);
      await tester.tap(find.text('Jawab wali key attach karein'));
      await pumpFrames(tester);
      expect(action, 'key');
    });
  });

  group('regression — already-answered PDF is unchanged', () {
    test('asterisk answers parse with no pending', () {
      final r = parseMcqs(
        'Q1. Which key refreshes a slide show?\n'
        '(A) F1\n(B) F2\n(C) F5 *\n(D) F7\n'
        'Q2. What is the capital of Pakistan?\n'
        '(A) Lahore\n(B) Karachi\n(C) Islamabad *\n(D) Quetta\n',
        sourceId: 't',
        sourceLabel: 't',
      );
      expect(r.questions.length, 2);
      expect(r.answerPending, isEmpty);
      expect(r.questions.every((q) => q.answerSource == 'asterisk'),
          isTrue);
    });

    test('key answers parse with no pending', () {
      final r = parseMcqs(
        'Q1. What is the capital of Pakistan?\n'
        '(A) Lahore\n(B) Karachi\n(C) Islamabad\n(D) Quetta\n\n'
        'Answer Key\n1. C\n',
        sourceId: 't',
        sourceLabel: 't',
      );
      expect(r.questions.length, 1);
      expect(r.answerPending, isEmpty);
      expect(r.questions.first.answerSource, 'key');
    });
  });
}
