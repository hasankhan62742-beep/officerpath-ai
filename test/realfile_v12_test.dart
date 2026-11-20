import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/models/exam.dart';
import 'package:officerpath_ai/services/book_structure.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';

import 'test_helpers.dart';

/// v1.2 real-file regression (agent C): the same files agent A
/// verified, plus the new v1.2 behaviours (corrupt fail-fast,
/// answer-pending for inference, MPT pattern suggestion).
void main() {
  test('F1 PPSC 40 MCQs: 40/40 through the full isolate entry point',
      () async {
    final file = File(
      '/home/hatch/workspace/user/files/PPSC_Current_Affairs_40_MCQs.pdf',
    );
    if (skipIfFixtureMissing(file.path)) return;
    final bytes = await file.readAsBytes();
    expect(detectPdfCorruption(bytes), isNull);
    final maps = processPdfInBackground({
      'bytes': bytes,
      'sourceId': 'real-f1',
      'sourceLabel': 'PPSC 40',
    });
    // ignore: avoid_print
    print('F1 parsed=${maps['parsed']} skipped=${maps['skipped']} '
        'parts=${(maps['parts'] as List).length}');
    expect(maps['parsed'], 40);
    expect(maps['skipped'], 0);
  });

  test('F2 June 2025: 0 parsed, answer-pending questions exposed for AI',
      () async {
    final file = File(
      '/home/hatch/workspace/user/files/Current-Affairs-June-2025-in-PDF__1.pdf',
    );
    if (skipIfFixtureMissing(file.path)) return;
    final bytes = await file.readAsBytes();
    expect(detectPdfCorruption(bytes), isNull);
    final pages = extractPdfPages(bytes);
    final result = parseMcqsFromPages(
      [for (final p in pages) PageText(p.page, p.text)],
      sourceId: 'real-f2',
      sourceLabel: 'June 2025',
    );
    // ignore: avoid_print
    print('F2 pages=${pages.length} parsed=${result.parsed} '
        'pending=${result.answerPending.length}');
    expect(result.parsed, 0);
    expect(result.answerPending, isNotEmpty);
    // Every pending question has 4 options + evidence to infer from.
    for (final p in result.answerPending) {
      expect(p.options.length, 4);
    }
  });

  test('Pace 184pp: parses, corrupt gate passes', () async {
    final file = File(
      '/home/hatch/workspace/user/files/Current_Affairs_Jan-Nov_2026_by_Pace_GK_Academy.pdf',
    );
    if (skipIfFixtureMissing(file.path)) return;
    final bytes = await file.readAsBytes();
    expect(detectPdfCorruption(bytes), isNull);
    final maps = processPdfInBackground({
      'bytes': bytes,
      'sourceId': 'real-f6',
      'sourceLabel': 'Pace',
    });
    // ignore: avoid_print
    print('Pace parsed=${maps['parsed']} skipped=${maps['skipped']}');
    expect(maps['parsed'], greaterThan(1000));
  });

  test('Admission letter: 0 MCQs, no crash, corrupt gate passes',
      () async {
    final file = File(
      '/home/hatch/workspace/user/files/junior_clerk.pdf',
    );
    if (skipIfFixtureMissing(file.path)) return;
    final bytes = await file.readAsBytes();
    expect(detectPdfCorruption(bytes), isNull);
    final maps = processPdfInBackground({
      'bytes': bytes,
      'sourceId': 'real-letter',
      'sourceLabel': 'Admission letter',
    });
    expect(maps['parsed'], 0);
    // Known limit (honest): ONE numbered instruction paragraph +
    // its A–D penalties list looks like an MCQ to the parser, so it
    // lands in answerPending. It is never saved (parsed == 0 → the
    // no-MCQs dialog) and the dialog's admission-letter check
    // suppresses the AI buttons + text preview for it.
    expect((maps['answerPending'] as List).length, 1);
  });

  test('MPT file: title suggests the CSS MPT pattern, not PPSC',
      () async {
    expect(
      ExamPattern.suggestForTitle('MPT-CSS-2027-Solved')?.id,
      'css_mpt',
    );
    expect(
      ExamPattern.suggestForTitle('MPT-CSS-2027-Solved')
          ?.defaultQuestions,
      200,
    );
    expect(ExamPattern.suggestForTitle('PPSC Past Papers 2024'), isNull);
    expect(
      ExamPattern.suggestForTitle('CSS Preliminary Test 2027')?.id,
      'css_mpt',
    );
    final file = File(
      '/home/hatch/workspace/user/files/MPT-CSS-2027-Solved.pdf',
    );
    if (skipIfFixtureMissing(file.path)) return;
    final bytes = await file.readAsBytes();
    expect(detectPdfCorruption(bytes), isNull);
    final maps = processPdfInBackground({
      'bytes': bytes,
      'sourceId': 'real-mpt',
      'sourceLabel': 'MPT-CSS-2027-Solved',
    });
    // ignore: avoid_print
    print('MPT parsed=${maps['parsed']} skipped=${maps['skipped']} '
        'pending=${(maps['answerPending'] as List).length}');
    expect(maps['parsed'], greaterThan(0));
  });
}
