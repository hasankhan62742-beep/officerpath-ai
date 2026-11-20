import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/answer_key.dart';
import 'package:officerpath_ai/services/book_structure.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/pdf_import_service.dart';

import 'pdf_test_helpers.dart';

// Category separation (owner's principle, 20 Nov 2026): numbers,
// English letters, and Urdu are SEPARATE categories. Digits only in
// number slots (a Latin letter there is a misread digit, mapped with
// neighbour/sequence validation); letters only in option markers
// (never a digit); Urdu script preserved exactly, never normalised
// as Latin or digits. These tests pin the separation — including the
// negative cases (a garbled number that cannot be pinned stays
// pending; a "(4)" marker is never decoded to an option letter).
void main() {
  group('decodeOcrNumber: digits only in number slots', () {
    test('misread letters map to their digits', () {
      expect(decodeOcrNumber('S1'), 51);
      expect(decodeOcrNumber('I2'), 12);
      expect(decodeOcrNumber('B8'), 88);
      expect(decodeOcrNumber('O5'), 5);
      expect(decodeOcrNumber('5I'), 51);
      // Two letters, no real digit: NOT a number. A bare "SI" could
      // be a misread "51", but with no digit in the token it is
      // indistinguishable from a two-letter word — the decode
      // requires at least one real digit, so this stays null.
      expect(decodeOcrNumber('SI'), isNull);
      expect(decodeOcrNumber('\$1'), 51);
      expect(decodeOcrNumber('§1'), 51);
      expect(decodeOcrNumber('Z2'), 22);
      expect(decodeOcrNumber('1'), 1);
      expect(decodeOcrNumber('100'), 100);
    });

    test('a bare letter is never a number', () {
      expect(decodeOcrNumber('B'), isNull);
      expect(decodeOcrNumber('S'), isNull);
      expect(decodeOcrNumber('I'), isNull);
      expect(decodeOcrNumber('O'), isNull);
      expect(decodeOcrNumber('A'), isNull);
      expect(decodeOcrNumber(''), isNull);
      // Pure digits are exempt from the length cap: big books
      // number past 999 (Examveda runs to 3212), so "1234" is a
      // real number, never a word fragment.
      expect(decodeOcrNumber('1234'), 1234);
      expect(decodeOcrNumber('3212'), 3212);
      // A 4-char token CARRYING a letter is still capped: "S100"
      // could be a word fragment, never a pinned number.
      expect(decodeOcrNumber('S100'), isNull);
      expect(decodeOcrNumber('12A'), isNull);
    });

    test('Urdu script is never decoded as digits', () {
      // Urdu-Indic digits and Arabic-script letters are their own
      // category — never mapped to Latin digits.
      expect(decodeOcrNumber('۱۲۳'), isNull);
      expect(decodeOcrNumber('تسلیم'), isNull);
      expect(decodeOcrNumber('ا'), isNull);
    });
  });

  group('importPdf through the real path (stubbed OCR)', () {
    Future<PdfImportResult> runTextImport(String ocrText) async {
      var lastRendered = 0;
      return PdfImportService.importPdf(
        buildHandcraftedPdf([
          'BT /F1 12 Tf 72 720 Td (CamScanner) Tj ET',
        ]),
        sourceId: 'category-test',
        sourceLabel: 'Category Test',
        onProgress: (_) {},
        isCancelled: () => false,
        renderPage: (bytes, pageNumber) async {
          lastRendered = pageNumber;
          return Uint8List.fromList([0xFF, 0xD8, 0xFF]);
        },
        runOcr: (jpegBytes) async => lastRendered == 1 ? ocrText : '',
      );
    }

    test('misread question and key numbers recover with right answers',
        () async {
      const text =
          'S0. What is the capital of France?\n'
          '(A) London\n'
          '(B) Paris\n'
          '(C) Rome\n'
          '(D) Madrid\n'
          '51. What is 2 + 2?\n'
          '(A) 3\n'
          '(B) 4\n'
          '(C) 5\n'
          '(D) 6\n'
          'S2. What is the capital of Japan?\n'
          '(A) Seoul\n'
          '(B) Tokyo\n'
          '(C) Beijing\n'
          '(D) Bangkok\n'
          'ANSWER KEY\n'
          '50. (B) Paris\n'
          'S1. (B) 4\n'
          '52. (B) Tokyo\n';
      final r = await runTextImport(text);
      expect(r.parsed, 3);
      expect(r.keyEntriesApplied, 3);
      expect(r.unmatchedKeyEntries, isEmpty);
      final byStem = {
        for (final q in r.questions) q.text: q.options[q.correctIndex],
      };
      expect(byStem['What is the capital of France?'], 'Paris');
      expect(byStem['What is 2 + 2?'], '4');
      expect(byStem['What is the capital of Japan?'], 'Tokyo');
    });

    test('decoded label between clean neighbours is demoted, '
        'never joins a wrong key', () async {
      // "B1." decodes to 81, but it sits between clean Q51 and Q52:
      // 81 is not strictly before the next trusted number (52), so
      // the sequence validation demotes it. The block stays pending
      // and key entry 81 is reported unmatched — never attached to
      // a question that is not Q81.
      const text =
          '50. What is the capital of France?\n'
          '(A) London\n'
          '(B) Paris\n'
          '(C) Rome\n'
          '(D) Madrid\n'
          '51. What is 2 + 2?\n'
          '(A) 3\n'
          '(B) 4\n'
          '(C) 5\n'
          '(D) 6\n'
          'B1. Which colour is the sky?\n'
          '(A) Red\n'
          '(B) Blue\n'
          '(C) Green\n'
          '(D) Yellow\n'
          '52. What is the capital of Japan?\n'
          '(A) Seoul\n'
          '(B) Tokyo\n'
          '(C) Beijing\n'
          '(D) Bangkok\n'
          'ANSWER KEY\n'
          '50. (B) Paris\n'
          '51. (B) 4\n'
          '52. (B) Tokyo\n'
          '81. (B) Blue\n';
      final r = await runTextImport(text);
      expect(r.parsed, 3);
      expect(
        r.questions.any((q) => q.text.contains('sky')),
        isFalse,
        reason: 'the "B1." block must not parse as Q81',
      );
      expect(
        r.answerPending.any((p) => p.text.contains('sky')),
        isTrue,
        reason: 'the demoted block stays pending, never fabricated',
      );
      expect(
        r.unmatchedKeyEntries.any((e) => e.contains('81')),
        isTrue,
        reason: 'key entry 81 is reported unmatched, not silently used',
      );
    });

    test('decoded number duplicating a clean number loses', () async {
      // "S1." decodes to 51, but clean Q51 already holds that
      // number — the decoded block is demoted and stays pending,
      // while the real Q51 keeps its key answer.
      const text =
          '50. What is the capital of France?\n'
          '(A) London\n'
          '(B) Paris\n'
          '(C) Rome\n'
          '(D) Madrid\n'
          '51. What is 2 + 2?\n'
          '(A) 3\n'
          '(B) 4\n'
          '(C) 5\n'
          '(D) 6\n'
          'S1. Which colour is the sky?\n'
          '(A) Red\n'
          '(B) Blue\n'
          '(C) Green\n'
          '(D) Yellow\n'
          '52. What is the capital of Japan?\n'
          '(A) Seoul\n'
          '(B) Tokyo\n'
          '(C) Beijing\n'
          '(D) Bangkok\n'
          'ANSWER KEY\n'
          '50. (B) Paris\n'
          '51. (B) 4\n'
          '52. (B) Tokyo\n';
      final r = await runTextImport(text);
      expect(r.parsed, 3);
      final q51 = r.questions.firstWhere(
        (q) => q.text.contains('2 + 2'),
      );
      expect(q51.options[q51.correctIndex], '4');
      expect(
        r.answerPending.any((p) => p.text.contains('sky')),
        isTrue,
      );
    });

    test('Urdu key answers survive noisy numbers byte-identical',
        () async {
      const text =
          'B3. Give the Urdu meaning of "to admit"?\n'
          '(A) انکار کرنا\n'
          '(B) تسلیم کرنا\n'
          '(C) بھول جانا\n'
          '(D) چھپانا\n'
          '84. Translate the idiom "a wolf in sheep\'s clothing"?\n'
          '(A) بھیڑ کی کھال میں بھیڑیا\n'
          '(B) بغل میں چھری منہ میں رام رام\n'
          '(C) سانپ کی کھال میں سانپ\n'
          '(D) شیر کی کھال میں گیدڑ\n'
          'ANSWER KEY\n'
          '83. (B) تسلیم کرنا\n'
          'B4. (B) بغل میں چھری منہ میں رام رام\n';
      final r = await runTextImport(text);
      expect(r.parsed, 2);
      expect(r.keyEntriesApplied, 2);
      expect(r.unmatchedKeyEntries, isEmpty);
      final byStem = {
        for (final q in r.questions) q.text: q.options[q.correctIndex],
      };
      expect(
        byStem['Give the Urdu meaning of "to admit"?'],
        'تسلیم کرنا',
      );
      expect(
        byStem['Translate the idiom "a wolf in sheep\'s clothing"?'],
        'بغل میں چھری منہ میں رام رام',
      );
    });

    test('Final Answer value in Urdu is cross-checked, not stripped',
        () async {
      // The old ASCII-only trailing trim stripped a Urdu value to
      // "" and the cross-check silently skipped it. Now the value
      // survives, so a value matching a DIFFERENT option is
      // reported as a conflict (the letter still wins).
      const text =
          '1. Give the Urdu meaning of "to admit"?\n'
          '(A) انکار کرنا\n'
          '(B) تسلیم کرنا\n'
          '(C) بھول جانا\n'
          '(D) چھپانا\n'
          'Solution:\n'
          'To admit means to accept as true.\n'
          'Final Answer: (B) انکار کرنا\n'
          'ANSWER KEY\n'
          '1. (B) تسلیم کرنا\n';
      final r = await runTextImport(text);
      expect(r.parsed, 1);
      final q = r.questions.single;
      expect(q.options[q.correctIndex], 'تسلیم کرنا');
      expect(
        r.conflicts.any(
          (c) => c.contains('Final Answer') && c.contains('option A'),
        ),
        isTrue,
        reason: 'conflicts: ${r.conflicts}',
      );
    });

    test('option markers: (8)/(0) decode, (4) never does', () async {
      const text =
          '1. What is 2 + 2?\n'
          '(A) 3\n'
          '(8) 4\n'
          '(C) 5\n'
          '(D) 6\n'
          '2. What is 3 + 3?\n'
          '(A) 5\n'
          '(4) 6\n'
          '(C) 7\n'
          '(D) 8\n'
          '3. What is 4 + 4?\n'
          '(A) 6\n'
          '(B) 7\n'
          '(C) 9\n'
          '(D) 8\n'
          'ANSWER KEY\n'
          '1. (B) 4\n'
          '2. (B) 6\n'
          '3. 4\n';
      final r = await runTextImport(text);
      // Q1 parses with (8) as its B marker; Q3 parses with the
      // numeric answer token "4" (= 4th option, D). Q2 has only 3
      // recognised options — "(4)" is not a marker — so it is
      // skipped with a reason and its key entry is reported
      // unmatched. Nothing is silently dropped, nothing is guessed.
      expect(r.parsed, 2);
      final q1 = r.questions.firstWhere(
        (q) => q.text.contains('2 + 2'),
      );
      expect(q1.correctIndex, 1);
      expect(q1.options[q1.correctIndex], '4');
      final q3 = r.questions.firstWhere(
        (q) => q.text.contains('4 + 4'),
      );
      expect(q3.correctIndex, 3);
      expect(q3.options[q3.correctIndex], '8');
      expect(
        r.questions.any((q) => q.text.contains('3 + 3')),
        isFalse,
        reason: '"(4)" must not invent a B option',
      );
      // A 3-option block never becomes a candidate, so it is
      // SKIPPED (reported with a reason), not pending — and its key
      // entry had no candidate to join, so it is reported unmatched.
      // Nothing is silently dropped and nothing is guessed.
      expect(r.skipped, 1);
      expect(
        r.answerPending.any((p) => p.text.contains('3 + 3')),
        isFalse,
      );
      expect(
        r.unmatchedKeyEntries.any((e) => e.contains('2')),
        isTrue,
        reason: 'key entry 2 had no question to join: '
            '${r.unmatchedKeyEntries}',
      );
    });
  });

  group('key-only fallback: number slots are digits only', () {
    test('misread numbers count, bare letters do not', () {
      final seg = segmentLines([
        SegmentedLine('1. What is 2 + 2?', 'Paper 1', 0, 0),
        SegmentedLine('(A) 3', 'Paper 1', 0, 1),
        SegmentedLine('(B) 4', 'Paper 1', 0, 2),
        SegmentedLine('(C) 5', 'Paper 1', 0, 3),
        SegmentedLine('(D) 6', 'Paper 1', 0, 4),
        // Heading-less key table (no key heading at all): the
        // fallback must capture the misread entries and ignore the
        // bare-letter line.
        SegmentedLine('S1. B', 'Paper 1', 0, 5),
        SegmentedLine('S2. C', 'Paper 1', 0, 6),
        SegmentedLine('B. C', 'Paper 1', 0, 7),
      ]);
      final entries = seg.keyEntries['Paper 1'] ?? {};
      expect(entries[51], 'B');
      expect(entries[52], 'C');
      expect(entries.length, 2);
    });

    test('four-digit key numbers count (big books run past 999)',
        () {
      // Examveda numbers to 3212: a key-only line "1001. A 1002. B"
      // must be recognised as key entries, not skipped as content
      // (the 3-char token cap used to drop them, 20 Nov 2026).
      final seg = segmentLines([
        SegmentedLine('1001. A 1002. B 1003. C', 'Paper 1', 0, 0),
        SegmentedLine('3212. D', 'Paper 1', 0, 1),
      ]);
      final entries = seg.keyEntries['Paper 1'] ?? {};
      expect(entries[1001], 'A');
      expect(entries[1002], 'B');
      expect(entries[1003], 'C');
      expect(entries[3212], 'D');
      expect(entries.length, 4);
    });
  });

  group('misread numbers never take ":" as a separator', () {
    test('proper-sequence labels S1:/S6: are not question starts',
        () {
      // Examveda's "proper sequence" items label their sentences
      // S1:, P:, Q:, R:, S:, S6: — all with colons. "S1" decodes
      // to 51, so a colon after a misread token is a LABEL, never
      // a question number: splitting there cut every item apart
      // (45 gained / 44 lost stems, 20 Nov 2026). The dot form
      // still splits — "S1." is a misread "51.".
      expect(isMisreadNumberStart('S1: A man of that character'), isFalse);
      expect(isMisreadNumberStart('S6: She was touched.'), isFalse);
      expect(isMisreadNumberStart('S1. Choose the correct synonym'),
          isTrue);
      expect(isMisreadNumberStart('S6. The Proper sequence should be:'),
          isTrue);
    });

    test('a decimal is not a misread question number', () {
      // The separator must not be followed by a digit — the same
      // (?!\d) guard as the clean number regex. "6.2x20 = 124."
      // is an equation, not question 6 (MPT Block 88); "92.97 m"
      // is a measurement, not question 92. Without the guard these
      // lines passed the question-start guard and were counted as
      // skipped blocks (MPT 3→4, Examveda 1688→1715, 20 Nov 2026).
      expect(isMisreadNumberStart('6.2x20 = 124.'), isFalse);
      expect(isMisreadNumberStart('92.97 m of rope'), isFalse);
      expect(isMisreadNumberStart('3.14 is pi.'), isFalse);
      expect(isMisreadNumberStart('6. What is 2 + 2?'), isTrue);
      expect(isMisreadNumberStart('S1. Choose the best answer'), isTrue);
    });
  });

  group('book structure: leading slot is Q or a misread digit', () {
    test('arbitrary letter + digits does not swallow a heading',
        () async {
      // "A12." is not a misread number (A is not a digit
      // confusion), so it must not mark a question span: the real
      // heading after it survives as a part title.
      final structure = detectBookStructure([
        const PageText(
          1,
          'A12. Advanced Topics\n'
          'English Grammar\n'
          '1. The Plague ______ in London that summer.\n'
          '(A) Broke out\n(B) Broke up\n(C) Broke down\n(D) None of these\n',
        ),
      ]);
      final titles = structure.parts.map((p) => p.title).toList();
      expect(
        titles.any((t) => t.contains('English Grammar')),
        isTrue,
        reason: 'titles: $titles',
      );
    });

    test('Q-prefixed number still behaves as a question start', () {
      final structure = detectBookStructure([
        const PageText(
          1,
          'English Grammar\n'
          'Q12. Choose the correct synonym Wheedle:\n'
          '(A) Flatter\n(B) Coax\n(C) Deceive\n(D) Praise\n',
        ),
      ]);
      final titles = structure.parts.map((p) => p.title).toList();
      expect(
        titles.any((t) => t.contains('Wheedle')),
        isFalse,
        reason: 'Q12. stem must not become a title: $titles',
      );
      expect(
        titles.any((t) => t.contains('English Grammar')),
        isTrue,
      );
    });
  });
}
