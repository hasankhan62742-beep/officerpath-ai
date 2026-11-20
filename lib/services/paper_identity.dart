// Paper identity + zero-cross-matching key decisions (MASTER DIRECTIVE
// Parts 7–8).
//
// A paper is identified by the full chain BOOK → EXAM → YEAR →
// DEPT/POST → PAPER → QUESTIONS → KEY. A key is NEVER matched by
// question numbers alone, NEVER matched to the nearest paper, and a
// bare key is NEVER assumed to belong to the immediately preceding
// section. Every match carries a confidence level, and only VERIFIED
// — or HIGH CONFIDENCE with an explicit, recorded owner approval —
// may be auto-assigned; everything else stays unassigned and flagged
// for review.
//
// Pure module: no file I/O, no parser imports, so it is testable in
// isolation. The parser supplies the facts (paper numbers, titles,
// position/coverage evidence); this module only decides.
//
// PAPER 66/67 EXAMPLE (the owner's strict target): the key headed
// "ANSWER KEY: Model Paper 66" carries paperNumber 66 + paperTitle
// "Model Paper 66" in the same source document as the Paper 66
// questions → VERIFIED. The same key against Paper 67's questions
// (paperNumber 67) → MISMATCH, and the key is never applied there.
// The page-7 key continuation (entries 79–100, no heading of its
// own) inherits its identity from the key section it continues —
// that inheritance is the segmenter's job; this module rates a bare
// continuation as HIGH CONFIDENCE only with position + coverage
// evidence, and it is auto-assigned only with explicit approval
// (the Paper 66/67 regression test is that approval artifact).
library;

enum KeyMatchConfidence {
  /// Source document + paper number + paper title all agree.
  verified,

  /// Strong evidence but one identifier is missing (e.g. a bare key
  /// continuation with position + full number coverage). Auto-assign
  /// ONLY with an explicit, recorded approval.
  highConfidence,

  /// Ambiguous — e.g. a bare key in a document holding several
  /// papers. Never auto-assigned; the user (or a later, better
  /// identification) decides.
  needsReview,

  /// The key carries no usable identity and no corroborating
  /// evidence. Never assigned.
  unverified,

  /// The key and the questions provably belong to different papers
  /// (different book, different number, different title). Never
  /// assigned; the mismatch is reported.
  mismatch,
}

/// The identity of one paper (or of one key section), per Part 7.
/// Every field except [sourceDocumentId] is nullable: OCR and books
/// omit fields all the time, and a missing field is "unknown", never
/// "matches anything".
class PaperIdentity {
  const PaperIdentity({
    required this.sourceDocumentId,
    this.exam,
    this.year,
    this.departmentOrPost,
    this.paperNumber,
    this.paperTitle,
    this.shiftOrSubject,
  });

  /// The file/book the paper came from (sourceId in the app, e.g.
  /// 'ppsc66'). Two papers from different documents are never the
  /// same paper, even when their numbers match — two different books
  /// can both print a "Model Paper 66".
  final String sourceDocumentId;

  /// Exam body, e.g. 'PPSC'.
  final String? exam;

  /// Exam year, e.g. 2021.
  final int? year;

  /// Post/department, e.g. 'Tehsildar BS-16'.
  final String? departmentOrPost;

  /// Paper number as printed, e.g. '66'. Compared as a string so
  /// '66' and '66' agree and '66' and '67' do not; a letter paper
  /// ('A') works the same way.
  final String? paperNumber;

  /// Paper title as printed, e.g. 'Model Paper 66' or 'English
  /// Morning'. Compared after normalisation (case, whitespace and a
  /// leading qualifier such as "Model"/"Mock"/"Sample" are ignored),
  /// so 'Model Paper 66' and 'Paper 66' are the same title.
  final String? paperTitle;

  /// Shift or subject, e.g. 'English Morning' / 'General Knowledge'.
  final String? shiftOrSubject;

  /// Canonical identity string for logging and dedup keys.
  String get canonicalKey {
    final parts = <String>[
      sourceDocumentId,
      if (exam != null) 'exam:$exam',
      if (year != null) 'year:$year',
      if (departmentOrPost != null) 'post:$departmentOrPost',
      if (paperNumber != null) 'paper:$paperNumber',
      if (paperTitle != null) 'title:${normalisePaperTitle(paperTitle!)}',
      if (shiftOrSubject != null) 'subject:$shiftOrSubject',
    ];
    return parts.join(' | ');
  }

  @override
  String toString() => canonicalKey;
}

/// Normalises a paper title for comparison: lowercase, collapsed
/// whitespace, a leading qualifier word ("model", "mock", "sample",
/// "past") removed, trailing punctuation removed. 'Model Paper 66'
/// and 'PAPER 66' normalise to the same string; 'Model Paper 66'
/// and 'Model Paper 67' do not.
String normalisePaperTitle(String title) {
  var t = title.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  t = t.replaceFirst(
    RegExp(r'^(model|mock|sample|past)\s+'),
    '',
  );
  t = t.replaceAll(RegExp(r'[.,:;\-–—\s]+$'), '');
  return t;
}

/// The decision for one key → questions match.
class KeyMatchDecision {
  const KeyMatchDecision({
    required this.confidence,
    required this.reason,
    this.evidence = const [],
  });

  final KeyMatchConfidence confidence;

  /// Plain-language reason, for the preview / review UI.
  final String reason;

  /// The facts the decision rested on.
  final List<String> evidence;

  /// True only for VERIFIED. The caller auto-assigns only then —
  /// or for HIGH CONFIDENCE when [mayAutoAssignIfApproved] is true.
  bool get mayAutoAssign => confidence == KeyMatchConfidence.verified;

  /// True for VERIFIED, and for HIGH CONFIDENCE when the caller
  /// passes an explicit approval (the owner approved this exact
  /// match, e.g. the Paper 66/67 regression test). Never true for
  /// NEEDS REVIEW / UNVERIFIED / MISMATCH.
  bool mayAutoAssignIfApproved(bool approved) =>
      confidence == KeyMatchConfidence.verified ||
      (approved && confidence == KeyMatchConfidence.highConfidence);
}

/// Decides whether [keyPaper] (the identity a key section carries)
/// may be applied to [questionPaper] (the identity of the questions
/// it would answer), per Part 8's levels.
///
/// Evidence the caller supplies (facts, not guesses):
/// * [paperCountInDocument] — how many papers the source document
///   holds. A bare key in a multi-paper document is ambiguous by
///   construction UNLESS its numbers match only one paper (see
///   [hasExclusiveCoverageEvidence]): the preceding paper is a hint,
///   never proof, on its own.
/// * [hasPositionEvidence] — the key immediately follows this
///   paper's questions (or continues a key section of this paper).
/// * [hasCoverageEvidence] — the key's numbers cover this paper's
///   question numbers (1–100 for a 100-question paper).
/// * [hasExclusiveCoverageEvidence] — the key's numbers match this
///   paper AND no other paper's questions in the document. This is
///   what separates a mid-page bare key that belongs to the
///   preceding paper (entry 61, existing only in Paper 1, before
///   Paper 2's heading) from an ambiguous bare key (entry 1,
///   existing in both papers). Position + coverage agree only when
///   coverage is exclusive; without it, a multi-paper bare key
///   stays NEEDS REVIEW.
/// * [highConfidenceApproved] — the owner explicitly approved
///   auto-assigning HIGH CONFIDENCE matches for this import. The
///   decision itself does not change; only the caller's gate does
///   (see [KeyMatchDecision.mayAutoAssignIfApproved]).
///
/// Coverage alone is NEVER sufficient for VERIFIED — it is
/// corroboration, not identity. Numbers alone are never sufficient
/// either: two books can both number a paper 66.
KeyMatchDecision decideKeyMatch({
  required PaperIdentity keyPaper,
  required PaperIdentity questionPaper,
  required int paperCountInDocument,
  bool hasPositionEvidence = false,
  bool hasCoverageEvidence = false,
  bool hasExclusiveCoverageEvidence = false,
}) {
  final evidence = <String>[];

  // Level 1 — source document. Different books never share a key.
  if (keyPaper.sourceDocumentId != questionPaper.sourceDocumentId) {
    return const KeyMatchDecision(
      confidence: KeyMatchConfidence.mismatch,
      reason: 'Key and questions come from different documents.',
      evidence: ['different sourceDocumentId'],
    );
  }
  evidence.add('same source document');

  // Level 2 — paper number. Both present and different = mismatch.
  final keyNumber = keyPaper.paperNumber?.trim();
  final qNumber = questionPaper.paperNumber?.trim();
  if (keyNumber != null &&
      keyNumber.isNotEmpty &&
      qNumber != null &&
      qNumber.isNotEmpty) {
    if (keyNumber != qNumber) {
      return KeyMatchDecision(
        confidence: KeyMatchConfidence.mismatch,
        reason:
            'Key is for paper $keyNumber but the questions are paper $qNumber.',
        evidence: ['paper number differs: $keyNumber vs $qNumber'],
      );
    }
    evidence.add('paper number agrees: $keyNumber');
  }

  // Level 3 — paper title. Both present and different = mismatch.
  final keyTitle = keyPaper.paperTitle?.trim();
  final qTitle = questionPaper.paperTitle?.trim();
  if (keyTitle != null &&
      keyTitle.isNotEmpty &&
      qTitle != null &&
      qTitle.isNotEmpty) {
    if (normalisePaperTitle(keyTitle) != normalisePaperTitle(qTitle)) {
      return KeyMatchDecision(
        confidence: KeyMatchConfidence.mismatch,
        reason: 'Key title "$keyTitle" does not match paper title "$qTitle".',
        evidence: ['paper title differs after normalisation'],
      );
    }
    evidence.add('paper title agrees: $keyTitle');
  }

  // Level 4 — metadata (exam/year). Present on both and different =
  // mismatch; agreement is corroboration, never identity by itself.
  if (keyPaper.year != null &&
      questionPaper.year != null &&
      keyPaper.year != questionPaper.year) {
    return KeyMatchDecision(
      confidence: KeyMatchConfidence.mismatch,
      reason:
          'Key year ${keyPaper.year} does not match paper year ${questionPaper.year}.',
      evidence: ['year differs'],
    );
  }
  if (keyPaper.year != null &&
      keyPaper.year == questionPaper.year) {
    evidence.add('year agrees: ${keyPaper.year}');
  }
  if (keyPaper.exam != null &&
      questionPaper.exam != null &&
      keyPaper.exam!.toLowerCase() != questionPaper.exam!.toLowerCase()) {
    return KeyMatchDecision(
      confidence: KeyMatchConfidence.mismatch,
      reason:
          'Key exam "${keyPaper.exam}" does not match paper exam "${questionPaper.exam}".',
      evidence: ['exam differs'],
    );
  }
  if (keyPaper.exam != null &&
      keyPaper.exam!.toLowerCase() ==
          questionPaper.exam?.toLowerCase()) {
    evidence.add('exam agrees: ${keyPaper.exam}');
  }

  final numberAgrees = keyNumber != null &&
      keyNumber.isNotEmpty &&
      keyNumber == qNumber;
  final titleAgrees = keyTitle != null &&
      keyTitle.isNotEmpty &&
      qTitle != null &&
      qTitle.isNotEmpty &&
      normalisePaperTitle(keyTitle) == normalisePaperTitle(qTitle);
  final keyHasIdentity = numberAgrees ||
      titleAgrees ||
      keyPaper.year != null ||
      keyPaper.exam != null;

  // VERIFIED: number + title agree, or number agrees with a second
  // corroborating field (title, year or exam) when the title is
  // missing on one side.
  if (numberAgrees && titleAgrees) {
    return KeyMatchDecision(
      confidence: KeyMatchConfidence.verified,
      reason: 'Paper number and title both match.',
      evidence: evidence,
    );
  }
  if (numberAgrees &&
      (keyPaper.year != null || keyPaper.exam != null) &&
      (keyPaper.year == questionPaper.year ||
          keyPaper.exam?.toLowerCase() ==
              questionPaper.exam?.toLowerCase())) {
    return KeyMatchDecision(
      confidence: KeyMatchConfidence.verified,
      reason: 'Paper number matches and metadata (year/exam) agrees.',
      evidence: evidence,
    );
  }

  // HIGH CONFIDENCE: an identifier agrees and position + coverage
  // corroborate it — e.g. a bare key continuation (no heading) that
  // immediately follows this paper's questions and covers its
  // numbers. Auto-assign only with explicit approval.
  if ((numberAgrees || titleAgrees) &&
      hasPositionEvidence &&
      hasCoverageEvidence) {
    return KeyMatchDecision(
      confidence: KeyMatchConfidence.highConfidence,
      reason:
          'Paper identifier agrees and the key follows this paper with full number coverage.',
      evidence: [
        ...evidence,
        'key immediately follows this paper',
        'key numbers cover this paper',
      ],
    );
  }
  if (!keyHasIdentity &&
      hasPositionEvidence &&
      hasCoverageEvidence &&
      (paperCountInDocument == 1 || hasExclusiveCoverageEvidence)) {
    // Multi-paper + exclusive coverage: the key's numbers match
    // ONLY this paper, so position and coverage agree on one paper
    // — a mid-page bare key between Paper 1's questions and Paper
    // 2's heading, whose entry 61 exists only in Paper 1, is
    // exactly this case. Non-exclusive coverage in a multi-paper
    // document stays NEEDS REVIEW below (the preceding paper is a
    // hint, never proof, when the numbers fit more than one paper).
    return KeyMatchDecision(
      confidence: KeyMatchConfidence.highConfidence,
      reason: paperCountInDocument == 1
          ? 'Bare key in a single-paper document, positioned after its questions with full coverage.'
          : 'Bare key follows this paper and its numbers match only this paper — no other paper in the document shares them.',
      evidence: [
        ...evidence,
        if (paperCountInDocument == 1) 'single paper in document',
        if (paperCountInDocument > 1)
          'key numbers match only this paper',
        'key immediately follows this paper',
        'key numbers cover this paper',
      ],
    );
  }

  // NEEDS REVIEW: something agrees but not enough, or a bare key in
  // a multi-paper document with non-exclusive coverage (the
  // preceding paper is a hint, not proof — Paper 66 vs Paper 67 in
  // one PDF is exactly this case when the numbers fit both).
  if (!keyHasIdentity && paperCountInDocument > 1) {
    return KeyMatchDecision(
      confidence: KeyMatchConfidence.needsReview,
      reason:
          'Key carries no paper identity and the document holds $paperCountInDocument papers — which paper it belongs to cannot be proven.',
      evidence: [
        ...evidence,
        '$paperCountInDocument papers in document',
      ],
    );
  }
  if (numberAgrees || titleAgrees) {
    return KeyMatchDecision(
      confidence: KeyMatchConfidence.needsReview,
      reason:
          'Paper identifier agrees but position/coverage evidence is missing — confirm before assigning.',
      evidence: evidence,
    );
  }

  // UNVERIFIED: no identity at all and no evidence.
  return KeyMatchDecision(
    confidence: KeyMatchConfidence.unverified,
    reason: 'Key carries no paper identity and no corroborating evidence.',
    evidence: evidence,
  );
}
