import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';

/// TEMPORARY negative test on the user's admission letter.
/// PRIVACY: this test prints ONLY counts and timings — NEVER the
/// extracted text (the file contains the user's CNIC/roll number).
/// Delete after the v1.2 negative-path work lands.
void main() {
  test('NEGATIVE: admission letter must yield 0 MCQs, fast, no crash',
      () async {
    final bytes = await File(
      '/home/hatch/workspace/user/files/junior_clerk.pdf',
    ).readAsBytes();
    final sw = Stopwatch()..start();
    final pages = extractPdfPages(bytes);
    final text = pages.map((p) => p.text).join('\n\n');
    final result = parseMcqs(
      text,
      sourceId: 'neg-letter',
      sourceLabel: 'Admission Letter',
    );
    sw.stop();
    // ignore: avoid_print
    print('LETTER pages=${pages.length} chars=${text.length} '
        'parsed=${result.parsed} skipped=${result.skipped} '
        'tookMs=${sw.elapsedMilliseconds}');
    expect(result.parsed, 0);
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });
}
