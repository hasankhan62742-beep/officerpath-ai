// Tests for lib/services/paper_identity.dart (MASTER DIRECTIVE
// Parts 7–8: paper identity + zero-cross-matching).
import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/paper_identity.dart';

void main() {
  group('decideKeyMatch', () {
    test('Paper 66 key on Paper 66 questions is VERIFIED', () {
      final d = decideKeyMatch(
        keyPaper: const PaperIdentity(
          sourceDocumentId: 'ppsc66',
          exam: 'PPSC',
          year: 2021,
          paperNumber: '66',
          paperTitle: 'Model Paper 66',
        ),
        questionPaper: const PaperIdentity(
          sourceDocumentId: 'ppsc66',
          exam: 'PPSC',
          year: 2021,
          paperNumber: '66',
          paperTitle: 'Model Paper 66',
        ),
        paperCountInDocument: 2,
      );
      expect(d.confidence, KeyMatchConfidence.verified);
      expect(d.mayAutoAssign, isTrue);
    });

    test('qualifier-insensitive title: "Model Paper 66" == "Paper 66"', () {
      expect(normalisePaperTitle('Model Paper 66'), 'paper 66');
      expect(normalisePaperTitle('PAPER 66'), 'paper 66');
      final d = decideKeyMatch(
        keyPaper: const PaperIdentity(
          sourceDocumentId: 'ppsc66',
          paperNumber: '66',
          paperTitle: 'Model Paper 66',
        ),
        questionPaper: const PaperIdentity(
          sourceDocumentId: 'ppsc66',
          paperNumber: '66',
          paperTitle: 'Paper 66',
        ),
        paperCountInDocument: 2,
      );
      expect(d.confidence, KeyMatchConfidence.verified);
    });

    test('Paper 66 key on Paper 67 questions is MISMATCH', () {
      final d = decideKeyMatch(
        keyPaper: const PaperIdentity(
          sourceDocumentId: 'ppsc66',
          paperNumber: '66',
          paperTitle: 'Model Paper 66',
        ),
        questionPaper: const PaperIdentity(
          sourceDocumentId: 'ppsc66',
          paperNumber: '67',
          paperTitle: 'Model Paper 67',
        ),
        paperCountInDocument: 2,
      );
      expect(d.confidence, KeyMatchConfidence.mismatch);
      expect(d.mayAutoAssign, isFalse);
      expect(d.mayAutoAssignIfApproved(true), isFalse);
    });

    test('same paper number in a different book is MISMATCH', () {
      final d = decideKeyMatch(
        keyPaper: const PaperIdentity(
          sourceDocumentId: 'book-a',
          paperNumber: '66',
          paperTitle: 'Model Paper 66',
        ),
        questionPaper: const PaperIdentity(
          sourceDocumentId: 'book-b',
          paperNumber: '66',
          paperTitle: 'Model Paper 66',
        ),
        paperCountInDocument: 1,
      );
      expect(d.confidence, KeyMatchConfidence.mismatch);
    });

    test('bare key in a multi-paper document is NEEDS REVIEW', () {
      // The preceding paper is a hint, never proof — Paper 66 vs
      // Paper 67 in one PDF is exactly this case.
      final d = decideKeyMatch(
        keyPaper: const PaperIdentity(sourceDocumentId: 'ppsc66'),
        questionPaper: const PaperIdentity(
          sourceDocumentId: 'ppsc66',
          paperNumber: '66',
        ),
        paperCountInDocument: 2,
        hasPositionEvidence: true,
        hasCoverageEvidence: true,
      );
      expect(d.confidence, KeyMatchConfidence.needsReview);
      expect(d.mayAutoAssign, isFalse);
      expect(d.mayAutoAssignIfApproved(true), isFalse);
    });

    test('bare key, multi-paper, EXCLUSIVE coverage is HIGH CONFIDENCE',
        () {
      // Same shape as the NEEDS REVIEW test above, except the key's
      // numbers match ONLY this paper (no other paper shares them):
      // position and coverage then agree on one paper. A mid-page
      // bare key between Paper 1's questions and Paper 2's heading,
      // entry 61 existing only in Paper 1, is exactly this case
      // (parser_signals_test: 'mid-page key belongs to the previous
      // paper, never the next').
      final d = decideKeyMatch(
        keyPaper: const PaperIdentity(sourceDocumentId: 'ppsc66'),
        questionPaper: const PaperIdentity(
          sourceDocumentId: 'ppsc66',
          paperNumber: '66',
        ),
        paperCountInDocument: 2,
        hasPositionEvidence: true,
        hasCoverageEvidence: true,
        hasExclusiveCoverageEvidence: true,
      );
      expect(d.confidence, KeyMatchConfidence.highConfidence);
      expect(d.mayAutoAssign, isFalse);
      expect(d.mayAutoAssignIfApproved(false), isFalse);
      expect(d.mayAutoAssignIfApproved(true), isTrue);
    });

    test('bare key, single paper, position + coverage is HIGH CONFIDENCE',
        () {
      final d = decideKeyMatch(
        keyPaper: const PaperIdentity(sourceDocumentId: 'pace-book'),
        questionPaper: const PaperIdentity(
          sourceDocumentId: 'pace-book',
          paperNumber: '1',
        ),
        paperCountInDocument: 1,
        hasPositionEvidence: true,
        hasCoverageEvidence: true,
      );
      expect(d.confidence, KeyMatchConfidence.highConfidence);
      expect(d.mayAutoAssign, isFalse);
      expect(d.mayAutoAssignIfApproved(false), isFalse);
      expect(d.mayAutoAssignIfApproved(true), isTrue);
    });

    test('number agrees + position + coverage, title missing one side',
        () {
      final d = decideKeyMatch(
        keyPaper: const PaperIdentity(
          sourceDocumentId: 'ppsc66',
          paperNumber: '66',
        ),
        questionPaper: const PaperIdentity(
          sourceDocumentId: 'ppsc66',
          paperNumber: '66',
          paperTitle: 'Model Paper 66',
        ),
        paperCountInDocument: 2,
        hasPositionEvidence: true,
        hasCoverageEvidence: true,
      );
      expect(d.confidence, KeyMatchConfidence.highConfidence);
    });

    test('number agrees but no position/coverage evidence is NEEDS REVIEW',
        () {
      final d = decideKeyMatch(
        keyPaper: const PaperIdentity(
          sourceDocumentId: 'ppsc66',
          paperNumber: '66',
        ),
        questionPaper: const PaperIdentity(
          sourceDocumentId: 'ppsc66',
          paperNumber: '66',
          paperTitle: 'Model Paper 66',
        ),
        paperCountInDocument: 2,
      );
      expect(d.confidence, KeyMatchConfidence.needsReview);
    });

    test('key with no identity and no evidence is UNVERIFIED', () {
      final d = decideKeyMatch(
        keyPaper: const PaperIdentity(sourceDocumentId: 'ppsc66'),
        questionPaper: const PaperIdentity(
          sourceDocumentId: 'ppsc66',
          paperNumber: '66',
        ),
        paperCountInDocument: 1,
      );
      expect(d.confidence, KeyMatchConfidence.unverified);
      expect(d.mayAutoAssignIfApproved(true), isFalse);
    });

    test('coverage alone never verifies (numbers alone never verify)', () {
      // A key whose numbers merely cover the questions, with no
      // paper number or title on the key side, is at best HIGH
      // CONFIDENCE with position evidence — never VERIFIED.
      final d = decideKeyMatch(
        keyPaper: const PaperIdentity(sourceDocumentId: 'ppsc66'),
        questionPaper: const PaperIdentity(
          sourceDocumentId: 'ppsc66',
          paperNumber: '66',
        ),
        paperCountInDocument: 1,
        hasPositionEvidence: true,
        hasCoverageEvidence: true,
      );
      expect(d.confidence, isNot(KeyMatchConfidence.verified));
    });
  });

  group('normalisePaperTitle', () {
    test('strips qualifier, case and trailing punctuation', () {
      expect(normalisePaperTitle('Model Paper 66'), 'paper 66');
      expect(normalisePaperTitle('Mock  Test  2:'), 'test 2');
      expect(normalisePaperTitle('PAST PAPER 1.'), 'paper 1');
      expect(normalisePaperTitle('Model Paper 66'),
          isNot(normalisePaperTitle('Model Paper 67')));
    });
  });
}
