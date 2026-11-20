// PERMANENT regression test for the Paper 66/67 gate (MASTER DIRECTIVE
// Part 17 critical regression; PPSC66_BASELINE_2026-11-20.md §8).
//
// The owner's strict training target: ppsc_paper_66.pdf — 7-page
// CamScanner scan, MODEL PAPER 66 (Tehsildar BS-16 2021, English
// Morning, 100 MCQs, answers ONLY in a trailing key) + MODEL PAPER 67
// (General Knowledge Evening, Q1–Q10) starting mid-page-7, with NO key
// of its own in this PDF.
//
// Acceptance target (§8 of the baseline report):
//   * 100/100 Paper 66 questions parsed with key answers
//   * Paper 67's 10 pending, never fabricated
//   * 0 false positives
//   * keyEntriesApplied == 100
//   * reprocessing creates no duplicates
//
// STATUS: this test FAILS on the parser as measured in the baseline
// (0/110 with an answer, 10 fabrications, keySectionsFound=0). It
// turns green only when the baseline root causes are fixed:
//   (1) key heading "ANSWER KEY: Model Paper 66" not recognised — the
//       word "Model" breaks the trailing-paper-ref strip;
//   (2) paper headings "MODEL PAPER 66/67" not recognised — same
//       "Model" qualifier problem, so both papers read as "Paper 1";
//   (3) Paper 66 Q1, Q3–Q9 vanish (numbers clipped at the left page
//       edge — stems and options ARE in the OCR);
//   (4) q-only fabrication from key fragments + Explanation /
//       Associated-Information bullets, all marked verified=true.
// Do NOT weaken these assertions to make the suite green — fix the
// parser. The input is the real Gemini OCR text of the real PDF
// (test-fixtures/ppsc66/ocr-pN.txt), NOT the on-device ML Kit path:
// do not quote these numbers as the phone result (baseline §6).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/models/question.dart';
import 'package:officerpath_ai/services/answer_key.dart';
import 'package:officerpath_ai/services/book_structure.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';

ParseResult _runPaper66() {
  final pages = <PageText>[];
  for (var p = 1; p <= 7; p++) {
    final text =
        File('test-fixtures/ppsc66/ocr-p$p.txt').readAsStringSync();
    pages.add(PageText(p, text));
  }
  return parseMcqsFromPages(
    pages,
    sourceId: 'ppsc66',
    sourceLabel: 'PPSC Paper 66',
    ocrPages: {1, 2, 3, 4, 5, 6, 7},
  );
}

void main() {
  group('Paper 66/67 gate (PPSC66_BASELINE_2026-11-20 §8)', () {
    test('Paper 66 key is found and all 100 entries are applied', () {
      final r = _runPaper66();
      expect(r.keySectionsFound, greaterThanOrEqualTo(1),
          reason: 'key heading "ANSWER KEY: Model Paper 66" not recognised');
      expect(r.keyEntriesApplied, 100,
          reason: 'expected all 100 key entries (1–78 on p6, 79–100 on p7)');
    });

    test('Paper 66: 100 questions parsed, all with key answers', () {
      final r = _runPaper66();
      final p66 = r.questions.where((q) => q.page >= 1 && q.page <= 6).toList();
      expect(p66.length, 100,
          reason: '92 pending + 8 clipped-number questions (Q1, Q3–Q9)');
      expect(
        p66
            .where((q) => q.answerSource == 'key' && q.correctIndex >= 0)
            .length,
        100,
      );
    });

    test('Paper 66 spot-checks: key letters match the book', () {
      final r = _runPaper66();
      Question? byText(String needle) {
        for (final q in r.questions) {
          if (q.text.contains(needle)) return q;
        }
        return null;
      }
      // Key 1 → (B) "Broke out"; key 2 → (A) "Are we being blamed".
      // Text-based (not number-based) so a numbering shift cannot
      // mask a wrong key application. A null here means the question
      // vanished (clipped number, root cause 3) or sits pending
      // unmatched — either way the gate is not met.
      final plague = byText('The Plague');
      expect(plague, isNotNull,
          reason: 'Q1 (The Plague) vanished — clipped number not recovered');
      expect(plague!.correctIndex, 1);
      final blame = byText('Are they blaming us');
      expect(blame, isNotNull,
          reason: 'Q2 sits pending unmatched — key entry 2 not applied');
      expect(blame!.correctIndex, 0);
    });

    test('Urdu key entries Q83–84 resolve with the script preserved', () {
      final r = _runPaper66();
      // Entry level (already true on the baseline: parseKeyEntries on
      // the page-7 blob returns 83 → "(B) تسلیم کرنا", 84 → "(A) بغل
      // میں چھری منہ میں رام رام" — letter intact even where the value
      // text is garbled mid-line). parseKeyEntries returns
      // Map<int, String>: number → "(letter) text".
      final p7 = File('test-fixtures/ppsc66/ocr-p7.txt').readAsStringSync();
      final entries = parseKeyEntries(
        p7.substring(0, p7.indexOf('MODEL PAPER 67')),
      );
      expect(entries[83], startsWith('(B)'));
      expect(entries[83], contains('تسلیم'));
      expect(entries[84], startsWith('(A)'));
      expect(entries[84], contains('بغل'));
      // Application level: the 100 applied entries include 83/84.
      expect(r.keyEntriesApplied, 100);
      // Mixed-script stems survive (Q78: Urdu in the stem).
      expect(
        r.questions.any(
          (q) => RegExp(r'[\u0600-\u06FF]').hasMatch(q.text),
        ),
        isTrue,
      );
    });

    test('Paper 67: its 10 questions are pending, never fabricated', () {
      final r = _runPaper66();
      // Paper 67 has no key in this PDF — its 10 must be pending.
      final p67pending = r.answerPending.where((q) => q.page == 7).toList();
      expect(p67pending.length, 10);
      // No parsed question may come from page 7 at all.
      expect(r.questions.where((q) => q.page == 7).length, 0);
      // None of Paper 66's key may leak onto Paper 67.
      expect(
        r.questions.where(
          (q) => q.page == 7 && q.answerSource == 'key',
        ),
        isEmpty,
      );
    });

    test('0 false positives: no question from key or explanation text',
        () {
      final r = _runPaper66();
      // The 10 baseline fabrications (3 key fragments + 7 Paper 67
      // Explanation / Associated-Information bullets), all marked
      // verified=true on the baseline parser.
      const forbidden = [
        'Halaku',
        'Ilkhanate',
        'Conquests',
        'Fall of Baghdad',
        'Oldest University',
        'Aftermath',
        'Mongol Emperor',
        'The Siege',
        '(A) Speak:',
        '(B) Muzzle:',
        '(C) [?',
      ];
      for (final q in r.questions) {
        for (final f in forbidden) {
          expect(q.text.contains(f), isFalse,
              reason: 'fabricated question kept: ${q.text}');
        }
      }
      // Total parsed == exactly the 100 real Paper 66 questions.
      expect(r.questions.length, 100);
    });

    test('reprocessing creates no duplicates', () {
      final first = _runPaper66();
      final second = _runPaper66();
      expect(second.questions.length, first.questions.length);
      // Identity is text + options, not text alone: the book itself
      // repeats two instruction stems with different options (Q24 and
      // Q89 are both "Choose the correct sentence:"; Q49 and Q50 are
      // both "Select the sentence with correct use of capital
      // letters."). Those are two real questions each, not duplicates
      // — the distinguishing content lives in the options.
      final ids = [
        for (final q in first.questions) '${q.text}|${q.options.join('|')}',
      ];
      expect(ids.toSet().length, ids.length,
          reason: 'same question parsed twice in one run');
      final paired = [
        for (var i = 0; i < first.questions.length; i++)
          '${first.questions[i].text}|${first.questions[i].correctIndex}',
      ];
      final pairedAgain = [
        for (var i = 0; i < second.questions.length; i++)
          '${second.questions[i].text}|${second.questions[i].correctIndex}',
      ];
      expect(pairedAgain, paired,
          reason: 'reprocessing must be deterministic');
    });
  });
}
