import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/models/exam.dart';
import 'package:officerpath_ai/models/question.dart';
import 'package:officerpath_ai/services/document_status.dart';
import 'package:officerpath_ai/services/gemini_config.dart';
import 'package:officerpath_ai/services/pdf_import_service.dart';

/// The centralized answer-status pipeline (MASTER BUG FIX DIRECTIVE
/// §2–§3, 20 Nov 2026): one status per import, computed from the same
/// result every module reads. The phone's PPSC-66 case is the anchor:
/// 1 question parsed, a key detected with 128 entries, 0 matched —
/// the status must be ANSWERS EXTRACTED BUT UNMATCHED, never
/// "no answers attached".
void main() {
  Question answered(int n) => Question(
        text: 'Question $n?',
        options: const ['A', 'B', 'C', 'D'],
        correctIndex: 1,
        subject: Subject.gk,
        sourceId: 'status-test',
        sourceLabel: 'Status Test',
        answerSource: 'key',
      );

  Question unanswered(int n) => Question(
        text: 'Question $n?',
        options: const ['A', 'B', 'C', 'D'],
        correctIndex: -1,
        subject: Subject.gk,
        sourceId: 'status-test',
        sourceLabel: 'Status Test',
      );

  PdfImportResult resultWith({
    required List<Question> questions,
    int keySectionsFound = 0,
    int keyEntriesApplied = 0,
    List<String> unmatchedKeyEntries = const [],
    List<String> conflicts = const [],
    List<String> questionsMissingAnswers = const [],
    List<int> ocrPages = const [],
    bool geminiRequested = false,
    int geminiPages = 0,
    GeminiFailureKind? geminiFailure,
  }) {
    return PdfImportResult(
      text: '',
      pageCount: 1,
      textPages: 0,
      ocrPages: ocrPages,
      ocrCapped: false,
      questions: questions,
      parsed: questions.length,
      skipped: 0,
      errors: const [],
      formats: const {},
      generatedOptions: 0,
      excluded: const [],
      keySectionsFound: keySectionsFound,
      keyEntriesApplied: keyEntriesApplied,
      questionsMissingAnswers: questionsMissingAnswers,
      conflicts: conflicts,
      unmatchedKeyEntries: unmatchedKeyEntries,
      geminiRequested: geminiRequested,
      geminiPages: geminiPages,
      geminiFailure: geminiFailure,
    );
  }

  test('phone case: 1 parsed, 128 key entries, 0 matched', () {
    final unmatched = List.generate(
      128,
      (i) => 'Paper 66 key entry ${i + 1} — no matching question',
    );
    final result = resultWith(
      questions: [answered(1)],
      keySectionsFound: 1,
      keyEntriesApplied: 0,
      unmatchedKeyEntries: unmatched,
    );
    expect(keyDetected(result), isTrue);
    expect(
      classifyDocumentStatus(result),
      DocumentAnswerStatus.answersExtractedUnmatched,
    );
    final line = documentStatusLine(
      result,
      classifyDocumentStatus(result),
    );
    // Accurate counts, in the line the dialog shows.
    expect(line, contains('kul 1 sawal'));
    expect(line, contains('128 entries'));
    expect(line, contains('0 lagi, 128 be-jawab'));
    expect(line, contains('Key mili, jawab kisi sawal se nahi lage'));
  });

  test('no key, no answers → NO ANSWER KEY DETECTED', () {
    final result = resultWith(
      questions: [unanswered(1), unanswered(2)],
      questionsMissingAnswers: const ['Q1', 'Q2'],
    );
    expect(keyDetected(result), isFalse);
    expect(
      classifyDocumentStatus(result),
      DocumentAnswerStatus.noAnswerKeyDetected,
    );
    expect(
      documentStatusLine(result, classifyDocumentStatus(result)),
      contains('2 sawal baghair jawab'),
    );
  });

  test('no key, mixed inline answers → NO ANSWER KEY DETECTED', () {
    // 20 Nov 2026 fix: the status is about KEY detection. One
    // asterisked answer does not make a key exist — and the green
    // notice must still show for the pending question (the owner's
    // 09:08 requirement, pinned by no_answers_test). The counts
    // line still reports the one inline answer honestly.
    final result = resultWith(
      questions: [answered(1), unanswered(2)],
      questionsMissingAnswers: const ['Q2'],
    );
    expect(keyDetected(result), isFalse);
    expect(
      classifyDocumentStatus(result),
      DocumentAnswerStatus.noAnswerKeyDetected,
    );
    final line = documentStatusLine(
      result,
      classifyDocumentStatus(result),
    );
    expect(line, contains('kul 2 sawal, 1 ke jawab lage'));
    expect(line, contains('1 sawal baghair jawab'));
  });

  test('real import shape: pending lives in answerPending, not questions',
      () {
    // The shape a real import produces (mcq_parser.dart): answered
    // questions in `questions`, answerless ones ONLY in
    // `answerPending`. The classifier must count both lists, or a
    // half-answered import looks "fully verified" and the green
    // notice disappears (broke no_answers_test, 20 Nov 2026).
    final result = PdfImportResult(
      text: '',
      pageCount: 1,
      textPages: 0,
      ocrPages: const [1],
      ocrCapped: false,
      questions: [answered(1)],
      parsed: 1,
      skipped: 0,
      errors: const [],
      formats: const {'block': 1},
      generatedOptions: 0,
      excluded: const [],
      answerPending: [
        PendingQuestion(
          text: 'Question 2?',
          options: const ['A', 'B', 'C', 'D'],
          subject: Subject.gk,
        ),
      ],
      questionsMissingAnswers: const ['Q2'],
    );
    expect(keyDetected(result), isFalse);
    expect(
      classifyDocumentStatus(result),
      DocumentAnswerStatus.noAnswerKeyDetected,
    );
    final line = documentStatusLine(
      result,
      classifyDocumentStatus(result),
    );
    expect(line, contains('kul 2 sawal, 1 ke jawab lage'));
    expect(line, contains('1 sawal baghair jawab'));
  });

  test('key section found but no entries read → ANSWER KEY DETECTED', () {
    final result = resultWith(
      questions: [unanswered(1)],
      keySectionsFound: 1,
    );
    expect(
      classifyDocumentStatus(result),
      DocumentAnswerStatus.answerKeyDetected,
    );
  });

  test('all answered, nothing unmatched → FULLY VERIFIED', () {
    final result = resultWith(
      questions: [answered(1), answered(2)],
      keySectionsFound: 1,
      keyEntriesApplied: 2,
    );
    expect(
      classifyDocumentStatus(result),
      DocumentAnswerStatus.answersFullyVerified,
    );
  });

  test('some matched, some missing/unmatched → PARTIALLY MATCHED', () {
    final result = resultWith(
      questions: [answered(1), unanswered(2)],
      keySectionsFound: 1,
      keyEntriesApplied: 1,
      unmatchedKeyEntries: const [
        'Paper 66 key entry 99 — no matching question',
      ],
      questionsMissingAnswers: const ['Q2'],
    );
    expect(
      classifyDocumentStatus(result),
      DocumentAnswerStatus.answersPartiallyMatched,
    );
  });

  test('conflicts → CONFLICTING ANSWERS', () {
    final result = resultWith(
      questions: [answered(1)],
      conflicts: const ['Q1 has two answers'],
    );
    expect(
      classifyDocumentStatus(result),
      DocumentAnswerStatus.conflictingAnswers,
    );
  });

  test('blocking validation errors → MANUAL REVIEW REQUIRED', () {
    final result = resultWith(questions: [answered(1)]);
    expect(
      classifyDocumentStatus(result, hasBlockingErrors: true),
      DocumentAnswerStatus.manualReviewRequired,
    );
    // Without the blocking flag the same result is fully verified.
    expect(
      classifyDocumentStatus(result),
      DocumentAnswerStatus.answersFullyVerified,
    );
  });

  group('Gemini honesty line', () {
    test('no key → says Gemini did not run + what was actually used', () {
      final result = resultWith(
        questions: [unanswered(1)],
        ocrPages: const [1, 2, 3, 4, 5, 6, 7],
        geminiRequested: true,
        geminiPages: 0,
        geminiFailure: GeminiFailureKind.noKey,
      );
      final line = geminiFailureLine(result);
      expect(line, isNotNull);
      expect(line, contains('Behtar quality (Gemini) chali nahi'));
      expect(line, contains('Gemini key Settings mein nahi hai'));
      expect(line, contains('ML Kit'));
      expect(line, contains('Gemini se nahi'));
    });

    test('partial run → says how many pages Gemini read', () {
      final result = resultWith(
        questions: [unanswered(1)],
        ocrPages: const [1, 2, 3, 4, 5, 6, 7],
        geminiRequested: true,
        geminiPages: 3,
        geminiFailure: GeminiFailureKind.noInternet,
      );
      final line = geminiFailureLine(result);
      expect(line, contains('Gemini sirf 3/7 pages par chali'));
      expect(line, contains('Internet nahi mila'));
    });

    test('not requested → no line; success → no line', () {
      final notRequested = resultWith(questions: [unanswered(1)]);
      expect(geminiFailureLine(notRequested), isNull);
      final success = resultWith(
        questions: [answered(1)],
        ocrPages: const [1],
        geminiRequested: true,
        geminiPages: 1,
      );
      expect(geminiFailureLine(success), isNull);
    });
  });
}
