import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';

/// MASTER DIRECTIVE Part 8 wiring (20 Nov 2026): the parser's key
/// join goes through decideKeyMatch. Only VERIFIED auto-assigns
/// silently; HIGH CONFIDENCE is applied but flagged in
/// keyPaperReport (the upload preview + Save is the confirmation);
/// NEEDS REVIEW / UNVERIFIED are never applied and their reason is
/// reported. Never matched by numbers alone.
void main() {
  const src = 'wiring-test';
  const label = 'Wiring Test';

  group('decideKeyMatch gate in the key join', () {
    test('explicit key naming its paper is VERIFIED and applies', () {
      const text = 'Paper 66\n'
          'Q1. Capital of Pakistan?\n'
          'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n'
          'Q2. Capital of France?\n'
          'A) London\nB) Paris\nC) Rome\nD) Berlin\n'
          'ANSWER KEY: Paper 66\n'
          '1. C\n'
          '2. B\n';
      final r = parseMcqs(text, sourceId: src, sourceLabel: label);
      expect(r.parsed, 2);
      expect(r.keyEntriesApplied, 2);
      expect(
        r.questions.map((q) => q.correctIndex).toList(),
        [2, 1],
      );
      expect(
        r.keyPaperReport.any(
          (l) => l.contains("Key 'Paper 66' se 2 jawab lage."),
        ),
        isTrue,
      );
      // VERIFIED needs no flag.
      expect(
        r.keyPaperReport.any((l) => l.contains('HIGH CONFIDENCE')),
        isFalse,
      );
    });

    test('bare key in a single-paper doc applies but is flagged HIGH',
        () {
      const text = 'Paper 60\n'
          'Q1. Capital of Pakistan?\n'
          'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n'
          'Q2. Capital of France?\n'
          'A) London\nB) Paris\nC) Rome\nD) Berlin\n'
          'ANSWER KEY\n'
          '1. C\n'
          '2. B\n';
      final r = parseMcqs(text, sourceId: src, sourceLabel: label);
      expect(r.parsed, 2);
      expect(r.keyEntriesApplied, 2);
      expect(
        r.questions.map((q) => q.correctIndex).toList(),
        [2, 1],
      );
      expect(
        r.keyPaperReport.any(
          (l) => l.contains("Key 'Paper 60' se 2 jawab lage."),
        ),
        isTrue,
      );
      // HIGH CONFIDENCE is applied, but the preview must show the
      // flag so the user confirms it before saving.
      expect(
        r.keyPaperReport.any(
          (l) =>
              l.contains('Paper 60') &&
              l.contains('HIGH CONFIDENCE') &&
              l.contains('tasdeeq karein'),
        ),
        isTrue,
      );
    });

    test('bare key in a multi-paper doc is NEEDS REVIEW and applies '
        'to nothing', () {
      const text = 'Paper 1\n'
          'Q1. Capital of Pakistan?\n'
          'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n'
          'Q2. Capital of France?\n'
          'A) London\nB) Paris\nC) Rome\nD) Berlin\n'
          'Paper 2\n'
          'Q1. Capital of Spain?\n'
          'A) Madrid\nB) Barcelona\nC) Seville\nD) Valencia\n'
          'ANSWER KEY\n'
          '1. C\n'
          '2. B\n';
      final r = parseMcqs(text, sourceId: src, sourceLabel: label);
      // The bare key follows Paper 2's questions, but the document
      // holds two papers — the preceding paper is a hint, never
      // proof. Nothing is applied, whatever the numbers say.
      expect(r.keyEntriesApplied, 0);
      expect(r.parsed, 0);
      expect(r.answerPending.length, 3);
      expect(
        r.keyPaperReport.any(
          (l) =>
              l.contains('Paper 2') &&
              l.contains('nahi lagayi') &&
              l.contains('cannot be proven'),
        ),
        isTrue,
      );
      // Withheld, not "unmatched": the entries had matching
      // questions — they were refused by the decision, not lost.
      expect(r.unmatchedKeyEntries, isEmpty);
    });

    test('mid-page bare key applies when its numbers match only the '
        'preceding paper', () {
      // The parser_signals_test case ('mid-page key belongs to the
      // previous paper, never the next'): the bare key sits between
      // Paper 1's questions and Paper 2's heading, and entry 61
      // exists only in Paper 1 — position and coverage agree, so
      // this is HIGH CONFIDENCE (applied, flagged), not NEEDS
      // REVIEW. Contrast with the ambiguous multi-paper test above,
      // where entry 1 matches both papers.
      const text = 'Paper 1\n'
          '61. What is 2 + 1?\n'
          'A) 1\nB) 2\nC) 3\nD) 4\n'
          'Answer Key\n'
          '61. (C) 3\n'
          'Paper 2\n'
          '1. What is the capital of Pakistan?\n'
          'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n';
      final r = parseMcqs(text, sourceId: src, sourceLabel: label);
      expect(r.parsed, 1);
      expect(r.questions.first.correctIndex, 2);
      expect(r.keyEntriesApplied, 1);
      // Paper 2's Q1 has no key entry — it is missing, not answered
      // by Paper 1's key.
      expect(r.questionsMissingAnswers.length, 1);
      expect(r.questionsMissingAnswers.first, contains('Paper 2 Q1'));
      expect(
        r.keyPaperReport.any(
          (l) =>
              l.contains('Paper 1') &&
              l.contains('HIGH CONFIDENCE') &&
              l.contains('tasdeeq karein'),
        ),
        isTrue,
      );
    });

    test('bare key whose numbers match nothing is UNVERIFIED and '
        'applies to nothing', () {
      const text = 'Paper 60\n'
          'Q1. Capital of Pakistan?\n'
          'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n'
          'Q2. Capital of France?\n'
          'A) London\nB) Paris\nC) Rome\nD) Berlin\n'
          'ANSWER KEY\n'
          '9. C\n'
          '10. B\n';
      final r = parseMcqs(text, sourceId: src, sourceLabel: label);
      expect(r.keyEntriesApplied, 0);
      expect(r.parsed, 0);
      expect(r.answerPending.length, 2);
      expect(
        r.keyPaperReport.any(
          (l) =>
              l.contains('Paper 60') &&
              l.contains('nahi lagayi') &&
              l.contains('no paper identity'),
        ),
        isTrue,
      );
      expect(r.unmatchedKeyEntries, isEmpty);
    });

    test('bare key per month stays HIGH in a month-grouped book', () {
      const text = 'January 2026\n'
          'Q1. Capital of Pakistan?\n'
          'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n'
          'Q2. Capital of France?\n'
          'A) London\nB) Paris\nC) Rome\nD) Berlin\n'
          'ANSWER KEY\n'
          '1. C\n'
          '2. B\n'
          'February 2026\n'
          'Q1. Capital of Spain?\n'
          'A) Madrid\nB) Barcelona\nC) Seville\nD) Valencia\n'
          'ANSWER KEY\n'
          '1. A\n';
      final r = parseMcqs(text, sourceId: src, sourceLabel: label);
      // Month labels are sections within ONE paper, not papers — so
      // the per-month bare keys are HIGH CONFIDENCE, not NEEDS
      // REVIEW, and they apply to their own month only.
      expect(r.keyEntriesApplied, 3);
      expect(r.parsed, 3);
      expect(
        r.questions.map((q) => q.correctIndex).toList(),
        [2, 1, 0],
      );
    });
  });
}
