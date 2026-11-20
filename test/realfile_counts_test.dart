import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/book_structure.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';

/// Per-file parsed counts for the two prose/flashcard books that
/// realfile_v12_test.dart does not count exactly. Converted from
/// tmp_verify_all_test.dart (deleted). F3 numbers are the v1.3
/// measured values (parser md5 0edc9e9b…, 19 Nov 2026): the v1.2
/// audit counted 162 q-only; v1.3 adds 19 bold-resolved table rows.
void main() {
  test('F3 Pak Affairs prose: 181 MCQs (162 flashcard + 19 table)',
      () async {
    final bytes = await File(
      '/home/hatch/workspace/user/files/Pak_Affairs_by_CSPs.pdf',
    ).readAsBytes();
    final pages = extractPdfPages(bytes);
    final r = parseMcqsFromPages(
      [for (final p in pages) PageText(p.page, p.text)],
      sourceId: 'counts-f3',
      sourceLabel: 'Pak Affairs',
    );
    expect(pages.length, 125);
    expect(r.parsed, 181);
    expect(r.formatCounts['q-only'], 162);
    expect(r.formatCounts['table'], 19);
    expect(r.parts, isNotEmpty);
  });

  test('F8 Sir Tauqeer flashcard book: 284 MCQs, 9 month parts', () async {
    final bytes = await File(
      '/home/hatch/workspace/user/files/Current_Affairs_Year_2026_Complete__October-January__Sir_Tauqeer_0_sw7h.pdf',
    ).readAsBytes();
    final pages = extractPdfPages(bytes);
    final r = parseMcqsFromPages(
      [for (final p in pages) PageText(p.page, p.text)],
      sourceId: 'counts-f8',
      sourceLabel: 'Sir Tauqeer',
    );
    expect(pages.length, 314);
    // 284, not 277: cross-page stitching (19 Nov 2026) finds
    // 7 more flashcards whose ANSWER is on the next page —
    // previously missed because walkForward stopped at the break.
    // Verified by disabling the crossing: count drops back to 277.
    expect(r.parsed, 284);
    expect(r.formatCounts['q-only'], 284);
    expect(r.parts.length, 9);
    expect(
      r.parts.any((p) => p.title.contains('October 2026')),
      isTrue,
    );
    expect(
      r.questions.every((q) => q.options.length == 4),
      isTrue,
    );
  });
}
