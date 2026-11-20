import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/answer_key.dart';
import 'package:officerpath_ai/services/book_structure.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';

/// MPT answer-key table: multi-column "N. L" layout + "?" for unknown
/// answers. Converted from tmp_key_probe_test.dart + the MPT spot
/// checks in tmp_probe_new_test.dart (both deleted).
void main() {
  test('parseKeyEntries reads the multi-column key table, "?" kept', () {
    const blob =
        '1. D 58. B 73. A 88. B 2. D 59. C 74. C 89. D '
        '3. ? 60. B 75. B 90. A 46. B 61. B 76. A 91. D '
        '106. ? 127. A 148. C 184. B';
    final entries = parseKeyEntries(blob);
    expect(entries.length, 20);
    expect(entries[1], 'D');
    expect(entries[2], 'D');
    expect(entries[46], 'B');
    expect(entries[58], 'B');
    expect(entries[127], 'A');
    // Unknown answers stay "?" in the table — never guessed.
    expect(entries[3], '?');
    expect(entries[106], '?');
  });

  test('isUnknownKeyToken: "?", "??", "unknown" — nothing else', () {
    expect(isUnknownKeyToken('?'), isTrue);
    expect(isUnknownKeyToken('??'), isTrue);
    expect(isUnknownKeyToken('unknown'), isTrue);
    expect(isUnknownKeyToken('Unknown'), isTrue);
    expect(isUnknownKeyToken('D'), isFalse);
    expect(isUnknownKeyToken(''), isFalse);
  });

  test('MPT real file: 142 parsed, "?" questions excluded, Q1 keyed', () async {
    final bytes = await File(
      '/home/hatch/workspace/user/files/MPT-CSS-2027-Solved.pdf',
    ).readAsBytes();
    final maps = processPdfInBackground({
      'bytes': bytes,
      'sourceId': 'mpt-key',
      'sourceLabel': 'MPT-CSS-2027-Solved',
    });
    expect(maps['parsed'], 142);
    expect(maps['skipped'], 3);

    final pages = extractPdfPages(bytes);
    final result = parseMcqsFromPages(
      [for (final p in pages) PageText(p.page, p.text)],
      sourceId: 'mpt-key',
      sourceLabel: 'MPT-CSS-2027-Solved',
    );
    // Q3 is defective in the book ("[cut off]" options) and Q106's
    // key entry is "?" — both are EXCLUDED, never guessed.
    expect(
      result.questions.any((q) => q.text.contains('humanitarian')),
      isFalse,
      reason: 'MPT Q3 (defective) must be excluded',
    );
    expect(
      result.questions.any((q) => q.text.contains('positive multiples')),
      isFalse,
      reason: 'MPT Q106 (key "?") must be excluded',
    );
    // Q1 is bilingual (English + Urdu) and keyed: answer D (index 3).
    final q1 = result.questions.where(
      (q) => q.text.contains('Deen'),
    );
    expect(q1, isNotEmpty);
    expect(q1.first.correctIndex, 3);
    expect(q1.first.answerSource, 'key');
  });
}
