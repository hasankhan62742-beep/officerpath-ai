import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';

import 'test_helpers.dart';

/// TEMPORARY diagnosis on the Pace GK Academy book (two-column layout).
/// To be converted into permanent tests by the v1.2 agents.
void main() {
  test('REAL FILE 6: Pace Jan-Nov 2026 — two-column + keys', () async {
    final file = File(
      '/home/hatch/workspace/user/files/Current_Affairs_Jan-Nov_2026_by_Pace_GK_Academy.pdf',
    );
    if (skipIfFixtureMissing(file.path)) return;
    final bytes = await file.readAsBytes();
    final sw = Stopwatch()..start();
    final pages = extractPdfPages(bytes);
    final extractMs = sw.elapsedMilliseconds;
    final text = pages.map((p) => p.text).join('\n\n');
    final result = parseMcqs(
      text,
      sourceId: 'real-f6',
      sourceLabel: 'Pace Jan-Nov 2026',
    );
    sw.stop();
    // ignore: avoid_print
    print('F6 pages=${pages.length} chars=${text.length} '
        'extractMs=$extractMs totalMs=${sw.elapsedMilliseconds} '
        'parsed=${result.parsed} skipped=${result.skipped}');
    // Ligatures present in extracted text?
    final ligCount = 'ﬃﬄﬅﬆ'.split('').fold<int>(
          0,
          (n, c) => n + c.allMatches(text).length,
        );
    final fbCount = text.runes.where((r) => r >= 0xFB00 && r <= 0xFB06).length;
    // ignore: avoid_print
    print('F6 ligature codepoints U+FB00-FB06: $fbCount (sample count: $ligCount)');
    // ignore: avoid_print
    print('F6 "(Answer Key)" occurrences: ${'Answer Key'.allMatches(text).length}');
    // ignore: avoid_print
    print('F6 "January 2026" occurrences: ${'January 2026'.allMatches(text).length}');
    // Q.1 / Q.2 check: find parsed questions mentioning Japan/Australia.
    final q1 = result.questions.where((q) => q.options.contains('Japan'));
    // ignore: avoid_print
    print('F6 parsed questions with option Japan: ${q1.length}');
    for (final q in result.questions.take(3)) {
      // ignore: avoid_print
      print('  Q: ${q.text} | opts: ${q.options} | correct: ${q.correctIndex}');
    }
    // ignore: avoid_print
    print('F6 first errors: ${result.errors.take(3).toList()}');
  });
}
