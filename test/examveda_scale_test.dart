import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/book_structure.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';

/// Examveda scale test (real file, v1.2): 546 pages / 1.03M chars.
/// Converted from tmp_probe_exam_test.dart (deleted). The numbers
/// below are the v1.3 run's measured values (parser md5 0edc9e9b…,
/// 19 Nov 2026); the 30 s bound is the no-ANR bar, not the measured
/// time (measured: ~6.7 s total).
void main() {
  test('Examveda 546pp: 3202 parsed, 1689 skipped, under 30 s', () async {
    final file = File(
      '/home/hatch/workspace/user/files/Examveda_GK_Comp_Eng_Sir_Waleed_0300_1111938.pdf',
    );
    final bytes = await file.readAsBytes();
    final t0 = DateTime.now();
    final pages = extractPdfPages(bytes);
    final text = pages.map((p) => p.text).join('\n');
    final parsed = parseMcqsFromPages(
      [for (final p in pages) PageText(p.page, p.text)],
      sourceId: 'examveda-scale',
      sourceLabel: 'examveda',
    );
    final totalMs = DateTime.now().difference(t0).inMilliseconds;
    expect(pages.length, 546);
    expect(text.length, greaterThan(1000000));
    // Phase A (19 Nov 2026): 3183/1710 → 3202/1689 — the
    // _splitOptionLine word-boundary fix + G7 2-row table recovered
    // 19 previously-skipped real questions (block 3160→3177,
    // answer-line 3162→3179; q-only 7→8, table 16→17). Two verified
    // book-correct: "The Mistral is" → D, "20th August is
    // celebrated as" → B (Sadbhavana Divas).
    expect(parsed.parsed, 3202);
    expect(parsed.skipped, 1689);
    expect(parsed.formatCounts['block'], 3177);
    expect(parsed.answerSources['answer-line'], 3179);
    expect(totalMs, lessThan(30000));
    // Spot-check: parsed questions are well-formed.
    expect(parsed.questions.first.options.length, 4);
    expect(
      parsed.questions.every((q) => q.correctIndex >= 0 && q.correctIndex < 4),
      isTrue,
    );
  });
}
