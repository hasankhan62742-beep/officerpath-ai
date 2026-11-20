// PPSC-66 parts carry pending counts (PPSC-66 §5.5, 20 Nov 2026): a
// part with only answer-pending questions (Paper 67's General
// Knowledge — 10 pending, 0 parsed) must still appear in the parts
// list, with its pending count, so the owner can see those questions
// exist instead of the part vanishing.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/book_structure.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';

void main() {
  test('parts include pending-only parts with their pending count', () {
    final pages = <PageText>[];
    for (var p = 1; p <= 7; p++) {
      pages.add(PageText(
          p, File('test-fixtures/ppsc66/ocr-p$p.txt').readAsStringSync()));
    }
    final r = parseMcqsFromPages(
      pages,
      sourceId: 'ppsc66',
      sourceLabel: 'PPSC Paper 66',
      ocrPages: {1, 2, 3, 4, 5, 6, 7},
    );
    expect(r.questions.length, 100);
    expect(r.answerPending.length, 10);
    final english =
        r.parts.firstWhere((p) => p.title == 'English Grammar');
    expect(english.questionCount, 100);
    expect(english.pendingCount, 0);
    final gk = r.parts.firstWhere((p) => p.title == 'General Knowledge');
    expect(gk.questionCount, 0);
    expect(gk.pendingCount, 10);
    expect(gk.startPage, 7);
    expect(gk.endPage, 7);
    // Round-trip through toMap/fromMap keeps the pending count.
    final back = BookPart.fromMap(gk.toMap());
    expect(back.pendingCount, 10);
    expect(back.questionCount, 0);
  });
}
