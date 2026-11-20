import 'gemini_config.dart';
import 'pdf_import_service.dart';

/// ONE centralized answer-status pipeline (MASTER BUG FIX DIRECTIVE,
/// 20 Nov 2026, §2–§3, §6).
///
/// Every module that talks about answers — OCR, extraction, key
/// matching, storage and the Save dialog — reads the SAME status from
/// the SAME [PdfImportResult]. Nothing infers "answers exist" on its
/// own: the dialog never says "no answers attached" when a key was
/// detected, and never calls an ML Kit result a Gemini result.
///
/// The seven statuses are the owner's directive, verbatim in meaning:
///   1. NO ANSWER KEY DETECTED — no key section and no key entries:
///      no key was detected at all. Inline answers (asterisk / bold /
///      table Ans column) do NOT count as a key: how many questions
///      carry one is in the counts line, and the green "no answers
///      attached" notice still shows for the pending ones (the
///      owner's 09:08 requirement, pinned by no_answers_test —
///      a mixed result with pending questions must still warn).
///   2. ANSWER KEY DETECTED — a key section was found, but no entries
///      could be read from it yet (nothing applied, nothing unmatched).
///   3. ANSWERS EXTRACTED BUT UNMATCHED — key entries were read, but
///      NONE matched a question (the phone's PPSC-66 case: 128
///      entries, 0 matched — usually because the questions
///      themselves did not parse, not because the key is wrong).
///   4. ANSWERS PARTIALLY MATCHED — some questions got answers, some
///      are still missing, or some key entries are unmatched.
///   5. ANSWERS FULLY VERIFIED — every parsed question has an answer
///      and no key entry is left unmatched.
///   6. CONFLICTING ANSWERS — the parser found two different answers
///      for the same question.
///   7. MANUAL REVIEW REQUIRED — the parse-validation report has
///      blocking errors (e.g. duplicated questions); the document
///      cannot be saved as-is, whatever the answer state is.
enum DocumentAnswerStatus {
  noAnswerKeyDetected,
  answerKeyDetected,
  answersExtractedUnmatched,
  answersPartiallyMatched,
  answersFullyVerified,
  conflictingAnswers,
  manualReviewRequired,
}

/// Whether any answer key was detected in this import — a key section
/// heading, an applied entry, or an unmatched entry. This is the one
/// check the Save dialog uses before it may say "no answers
/// attached": when this is true, that notice is forbidden.
bool keyDetected(PdfImportResult result) =>
    result.keySectionsFound > 0 ||
    result.keyEntriesApplied > 0 ||
    result.unmatchedKeyEntries.isNotEmpty;

/// Classifies one import into exactly one status. Pure function of
/// the result (+ whether the validation report blocks saving) — the
/// same input always gives the same status, in the dialog, in tests,
/// and in the report.
DocumentAnswerStatus classifyDocumentStatus(
  PdfImportResult result, {
  bool hasBlockingErrors = false,
}) {
  if (hasBlockingErrors) {
    return DocumentAnswerStatus.manualReviewRequired;
  }
  if (result.conflicts.isNotEmpty) {
    return DocumentAnswerStatus.conflictingAnswers;
  }
  final detected = keyDetected(result);
  // Total questions = answered questions + pending (answerless) ones.
  // In a real import the two lists are disjoint: the parser puts a
  // question in exactly one of them (mcq_parser.dart if/else) —
  // `questions` holds the answered ones, `answerPending` the ones
  // still waiting for an answer. (Synthetic tests sometimes also
  // put an unanswered Question in `questions`; count those too, so
  // the status never calls a half-answered import "fully verified".)
  final answered = result.questions.where((q) => q.hasAnswer).length;
  final missing =
      result.answerPending.length +
      (result.questions.length - answered);
  final total = result.questions.length + result.answerPending.length;
  if (detected) {
    if (result.keyEntriesApplied == 0 &&
        result.unmatchedKeyEntries.isNotEmpty) {
      return DocumentAnswerStatus.answersExtractedUnmatched;
    }
    if (result.keyEntriesApplied > 0 &&
        missing == 0 &&
        result.unmatchedKeyEntries.isEmpty) {
      return DocumentAnswerStatus.answersFullyVerified;
    }
    if (result.keyEntriesApplied > 0) {
      return DocumentAnswerStatus.answersPartiallyMatched;
    }
    // Key section found, but no entries read from it at all.
    return DocumentAnswerStatus.answerKeyDetected;
  }
  if (total > 0 && missing == 0) {
    return DocumentAnswerStatus.answersFullyVerified;
  }
  // No key was detected at all. The status is about the KEY, not
  // about inline answers: a mixed result (some asterisk/bold
  // answers, some pending) is still NO ANSWER KEY DETECTED — the
  // counts line reports how many answers exist, and the green
  // notice shows for the pending questions. (20 Nov 2026 fix:
  // classifying this as PARTIALLY MATCHED hid the notice and broke
  // the pre-existing no_answers_test expectation.)
  return DocumentAnswerStatus.noAnswerKeyDetected;
}

/// Roman Urdu label for one status, for the dialog + the report.
String documentStatusLabel(DocumentAnswerStatus status) {
  switch (status) {
    case DocumentAnswerStatus.noAnswerKeyDetected:
      return 'Koi jawab key nahi mili';
    case DocumentAnswerStatus.answerKeyDetected:
      return 'Jawab key mili — entries parhi nahi ja sakein';
    case DocumentAnswerStatus.answersExtractedUnmatched:
      return 'Key mili, jawab kisi sawal se nahi lage';
    case DocumentAnswerStatus.answersPartiallyMatched:
      return 'Kuch jawab lage, kuch baaqi';
    case DocumentAnswerStatus.answersFullyVerified:
      return 'Tamam jawab verified';
    case DocumentAnswerStatus.conflictingAnswers:
      return 'Mutazad jawab mile';
    case DocumentAnswerStatus.manualReviewRequired:
      return 'Manual review zaroori hai';
  }
}

/// THE accurate-counts line (directive §6): total questions, detected
/// key entries, matched answers, unmatched entries, missing answers,
/// conflicting answers — one line, computed once, shown in the Save
/// dialog instead of the old contradictory pair (green "no answers"
/// notice + amber "128 unmatched" warnings).
String documentStatusLine(
  PdfImportResult result,
  DocumentAnswerStatus status,
) {
  // Total = answered questions + pending ones (see the classifier
  // above: the two lists are disjoint in a real import).
  final total = result.questions.length + result.answerPending.length;
  final matched = result.questions.where((q) => q.hasAnswer).length;
  final missing = total - matched;
  final keyEntries =
      result.keyEntriesApplied + result.unmatchedKeyEntries.length;
  final buf = StringBuffer()
    ..write('Jawab: ${documentStatusLabel(status)} — ')
    ..write('kul $total sawal, $matched ke jawab lage');
  if (keyDetected(result)) {
    buf.write(
      ', key ki $keyEntries entries mili '
      '(${result.keyEntriesApplied} lagi, '
      '${result.unmatchedKeyEntries.length} be-jawab)',
    );
  }
  if (missing > 0) buf.write(', $missing sawal baghair jawab');
  if (result.conflicts.isNotEmpty) {
    buf.write(', ${result.conflicts.length} mutazad jawab');
  }
  buf.write('.');
  return buf.toString();
}

/// The Gemini honesty line (20 Nov 2026): when best quality was
/// requested but Gemini did not run (or ran only partly), say so
/// plainly with the reason and the concrete next step — and name
/// what was actually used (ML Kit). Null when Gemini was not
/// requested, or ran without failing. Never present an ML Kit result
/// as a Gemini result.
String? geminiFailureLine(PdfImportResult result) {
  if (!result.geminiRequested || result.geminiFailure == null) {
    return null;
  }
  final reason = switch (result.geminiFailure!) {
    GeminiFailureKind.noKey =>
      'Gemini key Settings mein nahi hai — pehle apni free key '
          'daalein (Google AI Studio se free milti hai).',
    GeminiFailureKind.noInternet =>
      'Internet nahi mila ya request time out ho gayi — '
          'connection check karke dobara koshish karein.',
    GeminiFailureKind.quota =>
      'Gemini ki free limit khatam ho gayi — kal dobara koshish '
          'karein, ya paid key use karein.',
    GeminiFailureKind.badKeyOrModel =>
      'Gemini key ghalat ya band hai, ya model nahi mila — '
          'Settings mein key dobara daalein.',
    GeminiFailureKind.badResponse =>
      'Gemini ne khaali ya ghalat jawab diya — dobara koshish '
          'karein.',
    GeminiFailureKind.unknown =>
      'Gemini se achanak error aaya — thodi der baad dobara '
          'koshish karein.',
  };
  if (result.geminiPages == 0) {
    return 'Behtar quality (Gemini) chali nahi — $reason '
        'Ye result on-device OCR (ML Kit) se hai, Gemini se nahi.';
  }
  return 'Gemini sirf ${result.geminiPages}/${result.ocrPages.length} '
      'pages par chali — $reason '
      'Baaki pages ML Kit se parhe gaye.';
}
