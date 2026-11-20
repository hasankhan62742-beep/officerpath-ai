import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/book_structure.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';

import 'test_helpers.dart';

/// Per-file parsed counts for the two prose/flashcard books that
/// realfile_v12_test.dart does not count exactly. Converted from
/// tmp_verify_all_test.dart (deleted). F3 numbers are the v1.3
/// measured values (parser md5 0edc9e9b…, 19 Nov 2026): the v1.2
/// audit counted 162 q-only; v1.3 adds 19 bold-resolved table rows.
/// 20 Nov 2026: 181 → 186 (159 q-only + 27 table) — table fixes
/// recover 8 more real rows; see universal_formats_test.dart.
void main() {
  test('F3 Pak Affairs prose: 186 MCQs (159 flashcard + 27 table)',
      () async {
    final file = File(
      '/home/hatch/workspace/user/files/Pak_Affairs_by_CSPs.pdf',
    );
    if (skipIfFixtureMissing(file.path)) return;
    final bytes = await file.readAsBytes();
    final pages = extractPdfPages(bytes);
    final r = parseMcqsFromPages(
      [for (final p in pages) PageText(p.page, p.text)],
      sourceId: 'counts-f3',
      sourceLabel: 'Pak Affairs',
    );
    expect(pages.length, 125);
    // 20 Nov 2026 (was 181 = 162 + 19): table fixes recover 8 more
    // real table rows (27) and 3 q-only items move to the table pass.
    expect(r.parsed, 186);
    expect(r.formatCounts['q-only'], 159);
    expect(r.formatCounts['table'], 27);
    expect(r.parts, isNotEmpty);
  });

  test('F8 Sir Tauqeer flashcard book: 284 MCQs, 9 month parts', () async {
    final file = File(
      '/home/hatch/workspace/user/files/Current_Affairs_Year_2026_Complete__October-January__Sir_Tauqeer_0_sw7h.pdf',
    );
    if (skipIfFixtureMissing(file.path)) return;
    final bytes = await file.readAsBytes();
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
