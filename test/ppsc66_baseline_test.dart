// TEMPORARY baseline harness for PPSC-66 (delete after the run).
// Reads the 7 Gemini-OCR pages in test-fixtures/ppsc66/ and runs the
// real import entry point parseMcqsFromPages, printing the full result.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/book_structure.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/answer_key.dart';

void main() {
  test('ppsc66 baseline', () {
    final pages = <PageText>[];
    for (var p = 1; p <= 7; p++) {
      final text =
          File('test-fixtures/ppsc66/ocr-p$p.txt').readAsStringSync();
      pages.add(PageText(p, text));
    }
    final r = parseMcqsFromPages(
      pages,
      sourceId: 'ppsc66',
      sourceLabel: 'PPSC Paper 66',
      ocrPages: {1, 2, 3, 4, 5, 6, 7},
    );
    print('parsed=${r.parsed} skipped=${r.skipped}');
    print('formatCounts=${r.formatCounts}');
    print(
        'keySectionsFound=${r.keySectionsFound} keyEntriesApplied=${r.keyEntriesApplied}');
    print('answerSources=${r.answerSources}');
    print('questionsMissingAnswers=${r.questionsMissingAnswers}');
    print('unmatchedKeyEntries=${r.unmatchedKeyEntries}');
    print('numberGaps=${r.numberGaps}');
    print('numberDuplicates=${r.numberDuplicates}');
    print('conflicts=${r.conflicts}');
    print(
        'parts=${r.parts.map((e) => '${e.title}:${e.startPage}-${e.endPage}:${e.questionCount}').toList()}');
    print('errors=${r.errors}');
    print('--- ANSWER PENDING (${r.answerPending.length}) ---');
    for (final q in r.answerPending) {
      print(
          'PENDING page=${q.page} part=${q.part} reason=${q.reason} :: ${q.text}');
    }
    print('--- PARSED QUESTIONS (${r.questions.length}) ---');
    for (final q in r.questions) {
      final letter = q.correctIndex >= 0
          ? String.fromCharCode(65 + q.correctIndex)
          : '?';
      print(
          'Q page=${q.page} part=${q.part} src=${q.answerSource} ans=$letter verified=${q.answerVerified} :: ${q.text}');
    }
  });
test('verify key-heading hypothesis', () {
    print('HEADING "ANSWER KEY: Model Paper 66" -> ${isAnswerKeyHeading("ANSWER KEY: Model Paper 66")}');
    print('HEADING "ANSWER KEY" -> ${isAnswerKeyHeading("ANSWER KEY")}');
    print('HEADING "Answers - Paper 1" -> ${isAnswerKeyHeading("Answers - Paper 1")}');
    final p6blob = File('test-fixtures/ppsc66/ocr-p6.txt').readAsStringSync();
    final keyStart = p6blob.indexOf('1. (B) Broke out');
    final entries = parseKeyEntries(p6blob.substring(keyStart));
    print('P6 KEY ENTRIES parsed=${entries.length} keys=${entries.keys.toList()}');
    final p7 = File('test-fixtures/ppsc66/ocr-p7.txt').readAsStringSync();
    final e7 = parseKeyEntries(p7.substring(0, p7.indexOf('MODEL PAPER 67')));
    print('P7 KEY ENTRIES parsed=${e7.length} keys=${e7.keys.toList()}');
  });
}
