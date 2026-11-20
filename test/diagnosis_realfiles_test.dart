import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';

import 'test_helpers.dart';

/// TEMPORARY diagnosis test on the user's FOUR REAL files.
/// To be deleted once the v1.2 fixes land (real-file tests replace it).
void main() {
  test('REAL FILE 1: PPSC 40 MCQs — current pipeline', () async {
    final file = File(
      '/home/hatch/workspace/user/files/PPSC_Current_Affairs_40_MCQs.pdf',
    );
    if (skipIfFixtureMissing(file.path)) return;
    final bytes = await file.readAsBytes();
    final pages = extractPdfPages(bytes);
    final text = pages.map((p) => p.text).join('\n\n');
    final result = parseMcqs(
      text,
      sourceId: 'real-f1',
      sourceLabel: 'PPSC 40',
    );
    // ignore: avoid_print
    print('F1 pages=${pages.length} chars=${text.length} '
        'parsed=${result.parsed} skipped=${result.skipped}');
    // ignore: avoid_print
    print('F1 first errors: ${result.errors.take(2).toList()}');
    expect(result.parsed, 40,
        reason:
            'v1.2: the "Correct Answer:" fix parses all 40 (was 0 before '
            'the fix — the stale expectation is now the permanent 40/40 '
            'assertion)');
  });

  test('REAL FILE 2: mcqsplanet June 2025 — coverage + Urdu', () async {
    final file = File(
      '/home/hatch/workspace/user/files/Current-Affairs-June-2025-in-PDF__1.pdf',
    );
    if (skipIfFixtureMissing(file.path)) return;
    final bytes = await file.readAsBytes();
    final pages = extractPdfPages(bytes);
    final textPages = pages.where((p) => p.hasText).length;
    final emptyPages = pages.where((p) => !p.hasText).length;
    final text = pages.map((p) => p.text).join('\n\n');
    final result = parseMcqs(
      text,
      sourceId: 'real-f2',
      sourceLabel: 'June 2025',
    );
    // ignore: avoid_print
    print('F2 pages=${pages.length} textPages=$textPages '
        'emptyPages=$emptyPages chars=${text.length} '
        'parsed=${result.parsed} skipped=${result.skipped}');
    // ignore: avoid_print
    print('F2 has Urdu title line: ${text.contains('کرنٹ افیئ جون')}');
    // ignore: avoid_print
    print('F2 has "Answer Key": ${text.toLowerCase().contains('answer key')}');
  });

  test('REAL FILE 3: Pak Affairs notes — what extracts', () async {
    final file = File(
      '/home/hatch/workspace/user/files/Pak_Affairs_by_CSPs.pdf',
    );
    if (skipIfFixtureMissing(file.path)) return;
    final bytes = await file.readAsBytes();
    final pages = extractPdfPages(bytes);
    final text = pages.map((p) => p.text).join('\n\n');
    // ignore: avoid_print
    print('F3 pages=${pages.length} chars=${text.length}');
    // ignore: avoid_print
    print('F3 head: ${text.substring(0, text.length > 300 ? 300 : text.length)}');
  });

  test('REAL FILE 4: corrupt Ayesha Jalal — must fail fast, not hang',
      () async {
    final file = File(
      '/home/hatch/workspace/user/files/Ayesha_Jalal_-_The_Struggle_for_Pakistan__A_Muslim_Homeland_and_Global_Politics__2014__Belknap_Press.pdf',
    );
    if (skipIfFixtureMissing(file.path)) return;
    final bytes = await file.readAsBytes();
    final sw = Stopwatch()..start();
    final pages = extractPdfPages(bytes);
    sw.stop();
    // ignore: avoid_print
    print('F4 pages=${pages.length} tookMs=${sw.elapsedMilliseconds}');
    // HANG GUARD, not a performance benchmark: the point is the
    // corrupt 448-page file completes instead of hanging. The bound
    // is wall-clock on a shared VM, so it must have headroom — it was
    // 5000 ms and failed at 5486 ms in isolation / 7214 ms under a
    // full-suite run (19 Nov 2026, 1.5 shared CPUs), with the file
    // still completing normally both times. 15000 ms still catches a
    // real hang (minutes / test timeout) without flaking on load.
    expect(sw.elapsedMilliseconds, lessThan(15000),
        reason: 'corrupt file must fail fast');
  });
}
