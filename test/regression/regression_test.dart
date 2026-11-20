import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';

/// Permanent regression library (Phase A, 19 Nov 2026).
///
/// Committed fixtures are SMALL EXCERPTS created by the worker from
/// legally accessible sources (see test/regression/README.md) —
// NEVER a whole copyrighted book. Full-sample PDFs (PakMCQs 500 GK,
/// PPSC Foodgrains 2013) live OUTSIDE the repo at
/// /tmp/phaseA_samples/ and are re-downloaded from their public URLs
/// (README lists them); those tests SKIP when the files are absent so
/// CI stays green without the samples.
void main() {
  group('committed excerpt fixtures', () {
    test('Skilling 500 GK excerpt: 20/20 via section-end answer key',
        () {
      final text = File(
        'test/regression/fixtures/skilling_gk_20.txt',
      ).readAsStringSync();
      final r = parseMcqs(
        text,
        sourceId: 'skilling-gk-20',
        sourceLabel: 'skilling-gk-20',
      );
      expect(r.parsed, 20, reason: 'skipped: ${r.skipped}');
      expect(r.skipped, 0);
      // Ground truth from the Skilling Foundation page's own
      // ANSWERS lists (1.C 2.D 3.D 4.C 5.A 6.B 7.A 8.A 9.B 10.B
      // 11.A 12.C 13.B 14.B 15.C 16.B 17.A 18.D 19.C 20.B).
      const expected = [
        2, 3, 3, 2, 0, 1, 0, 0, 1, 1,
        0, 2, 1, 1, 2, 1, 0, 3, 2, 1,
      ];
      expect(r.questions.length, 20);
      for (var i = 0; i < 20; i++) {
        expect(
          r.questions[i].correctIndex,
          expected[i],
          reason: 'Q${i + 1} wrong answer: '
              'got ${r.questions[i].correctIndex}, want ${expected[i]}',
        );
        expect(
          r.questions[i].answerSource,
          'key',
          reason: 'Q${i + 1} answer must come from the key section',
        );
      }
      expect(r.numberGaps, isEmpty);
    });
  });

  group('full-sample PDFs (skip when absent)', () {
    test('PPSC Foodgrains Inspector 2013: 79/80, Q59 honestly gapped',
        () {
      final file = File('/tmp/phaseA_samples/ppsc_foodgrains_2013.pdf');
      if (!file.existsSync()) {
        markTestSkipped(
          'sample PDF not present — download from the URL in '
          'test/regression/README.md',
        );
        return;
      }
      final maps = processPdfInBackground({
        'bytes': file.readAsBytesSync(),
        'sourceId': 'ppsc-foodgrains-2013',
        'sourceLabel': 'ppsc-foodgrains-2013',
      });
      expect(maps['parsed'], 79);
      expect(maps['skipped'], 0);
      expect(maps['errors'], isEmpty);
      // Q59's stem is absent from the PDF text layer itself (the
      // page break eats it); the ONLY gap reported must be Q59 —
      // Q52 is bare-numbered and parses (its false gap was fixed).
      expect(
        maps['numberGaps'],
        [
          'Q59 missing between Q58 (page 12) and Q60 (page 13) '
              '(1 question missing)',
        ],
      );
      // Spot-check: Q4 (National Anthem) must have all four
      // "Sec." options and answer B (80 Sec.) — the phantom-option
      // bug made C empty and the answer C.
      final qs = maps['questions'] as List;
      final q4 = (qs[3] as Map);
      expect(
        [q4['option_a'], q4['option_b'], q4['option_c'], q4['option_d']],
        ['60 Sec.', '80 Sec.', '100 Sec.', '120 Sec.'],
      );
      expect(q4['correct_index'], 1);
    });

    test('PakMCQs 500 GK: 373/500, zero polluted options', () {
      final file = File('/tmp/phaseA_samples/pakmcqs_500gk.pdf');
      if (!file.existsSync()) {
        markTestSkipped(
          'sample PDF not present — download from the URL in '
          'test/regression/README.md',
        );
        return;
      }
      final maps = processPdfInBackground({
        'bytes': file.readAsBytesSync(),
        'sourceId': 'pakmcqs-500gk',
        'sourceLabel': 'pakmcqs-500gk',
      });
      expect(maps['parsed'], 373);
      // 3 honestly skipped with reasons (not silently dropped): 2
      // whose only "answer" was footer debris ("- N of 62"), 1
      // whose answer was lost to the scrambled column order.
      expect(maps['skipped'], 3);
      // Zero polluted options: no '?' (merged next question), no
      // watermark URL, no bare-number fragment in any option.
      final qs = maps['questions'] as List;
      final bareRe = RegExp(r'\s\d{1,3}\s+[A-Z]');
      for (final q in qs) {
        final m = q as Map;
        final opts = [
          m['option_a'],
          m['option_b'],
          m['option_c'],
          m['option_d'],
        ].map((o) => o as String).toList();
        expect(opts.any((o) => o.contains('?')), isFalse);
        expect(opts.any((o) => o.contains('www.')), isFalse);
        expect(opts.any((o) => bareRe.hasMatch(o)), isFalse);
        expect(opts.any((o) => o.trim().isEmpty), isFalse);
      }
    });
  });
}
