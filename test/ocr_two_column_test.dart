import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/urdu_ocr.dart';

/// Two-column camera-photo OCR (20 Nov 2026): the owner photographed
/// a two-column book page (Paper 60, Data Entry Operator, Q1–Q21,
/// answers marked with *) and the app parsed only 3 MCQs — ML Kit's
/// raw text interleaves the columns, so stems got separated from
/// their options and asterisk answers got detached. These tests
/// prove the wiring in [columnSplitOcrText]: synthetic ML Kit-style
/// line boxes in, left column first then right out. Coordinates
/// mimic the photo (page ~1000 px wide, left column x≈40–300,
/// right column x≈560–820). No device needed — the helper is pure.
void main() {
  group('columnSplitOcrText — two-column photo', () {
    test('interleaved left/right lines come back left column first',
        () {
      final lines = [
        (text: '12. When an Excel workbook is linked', x: 560.0, y: 120.0, width: 380.0),
        (text: '6. Which menu provides you options', x: 40.0, y: 100.0, width: 400.0),
        (text: '(A) The Word document contains a copy', x: 580.0, y: 160.0, width: 360.0),
        (text: '(A) Insert Menu', x: 60.0, y: 140.0, width: 150.0),
        (text: '(B) Format Menu', x: 300.0, y: 140.0, width: 150.0),
        (text: '(B) The word document cannot be edited', x: 820.0, y: 160.0, width: 120.0),
        (text: '(C) Tools Menu', x: 60.0, y: 170.0, width: 150.0),
        (text: '(D) Slide Show Menu*', x: 300.0, y: 170.0, width: 180.0),
      ];
      expect(
        columnSplitOcrText('RAW — should be replaced', lines),
        '6. Which menu provides you options\n'
        '(A) Insert Menu\n'
        '(B) Format Menu\n'
        '(C) Tools Menu\n'
        '(D) Slide Show Menu*\n'
        '12. When an Excel workbook is linked\n'
        '(A) The Word document contains a copy\n'
        '(B) The word document cannot be edited',
      );
    });

    test('Q11-style: stem in left column, options in right column — '
        'stem comes BEFORE its options', () {
      // The real photo: Q11's stem sits at the bottom of the left
      // column while its options (A) SUM (B) MAX (C) MIN (D) AVG*
      // sit at the TOP of the right column — raw ML Kit order puts
      // the options first, so the question can never parse.
      final lines = [
        (text: '(A) SUM', x: 580.0, y: 100.0, width: 80.0),
        (text: '(B) MAX', x: 820.0, y: 100.0, width: 80.0),
        (text: '(C) MIN', x: 580.0, y: 130.0, width: 80.0),
        (text: '(D) AVG*', x: 820.0, y: 130.0, width: 90.0),
        (text: '11. Which of the following is not a function in', x: 40.0, y: 1800.0, width: 400.0),
        (text: 'Microsoft Excel?', x: 40.0, y: 1830.0, width: 200.0),
        (text: '10. What lets you create new presentation', x: 40.0, y: 1700.0, width: 400.0),
        (text: '(A) Presentation Template', x: 60.0, y: 1740.0, width: 260.0),
      ];
      final split = columnSplitOcrText('RAW — should be replaced', lines);
      expect(
        split,
        '10. What lets you create new presentation\n'
        '(A) Presentation Template\n'
        '11. Which of the following is not a function in\n'
        'Microsoft Excel?\n'
        '(A) SUM\n'
        '(B) MAX\n'
        '(C) MIN\n'
        '(D) AVG*',
      );
      expect(split.indexOf('11. Which'), lessThan(split.indexOf('(A) SUM')));
      expect(
        split.indexOf('Microsoft Excel?'),
        lessThan(split.indexOf('(A) SUM')),
      );
      // The asterisk answer stays attached to its option.
      expect(split, contains('(D) AVG*'));
    });

    test('same-row lines keep ML Kit order (stable y-sort)', () {
      final lines = [
        (text: 'right second', x: 580.0, y: 100.0, width: 100.0),
        (text: 'left second', x: 40.0, y: 100.0, width: 100.0),
        (text: 'right first', x: 580.0, y: 100.0, width: 100.0),
        (text: 'left first', x: 40.0, y: 100.0, width: 100.0),
      ];
      expect(
        columnSplitOcrText('RAW', lines),
        'left second\nleft first\nright second\nright first',
      );
    });

    test('answer marks (* and ✓) survive the split on the right options',
        () {
      // The book marks answers with *, a pencil tick/circle, bold
      // print, or an answer in front of the question. The split
      // only reorders lines — a mark that ML Kit read must still
      // be attached to its own option afterwards, in the right
      // column and after its stem.
      final lines = [
        (text: '(D) AVG*', x: 820.0, y: 130.0, width: 90.0),
        (text: '11. Which of the following is not a function in', x: 40.0, y: 1800.0, width: 400.0),
        (text: '(A) SUM', x: 580.0, y: 100.0, width: 80.0),
        (text: '(B) MAX', x: 820.0, y: 100.0, width: 80.0),
        (text: 'Microsoft Excel?', x: 40.0, y: 1830.0, width: 200.0),
        (text: '(C) MIN', x: 580.0, y: 130.0, width: 80.0),
        (text: '6. Which menu provides you options', x: 40.0, y: 100.0, width: 400.0),
        (text: '(D) Slide Show Menu*', x: 300.0, y: 170.0, width: 180.0),
        (text: '(C) Tools Menu ✓', x: 60.0, y: 170.0, width: 150.0),
        (text: '12. When an Excel workbook is linked', x: 560.0, y: 120.0, width: 380.0),
      ];
      final split = columnSplitOcrText('RAW', lines);
      expect(
        split,
        '6. Which menu provides you options\n'
        '(D) Slide Show Menu*\n'
        '(C) Tools Menu ✓\n'
        '11. Which of the following is not a function in\n'
        'Microsoft Excel?\n'
        '(A) SUM\n'
        '(B) MAX\n'
        '12. When an Excel workbook is linked\n'
        '(D) AVG*\n'
        '(C) MIN',
      );
      // Marks stay on their own options, after their stems.
      expect(split.indexOf('11. Which'), lessThan(split.indexOf('(D) AVG*')));
      expect(
        split.indexOf('6. Which menu'),
        lessThan(split.indexOf('(D) Slide Show Menu*')),
      );
      expect(
        split.indexOf('6. Which menu'),
        lessThan(split.indexOf('(C) Tools Menu ✓')),
      );
    });
  });

  group('columnSplitOcrText — single column', () {
    test('single column in reading order is unchanged', () {
      final lines = [
        (text: 'Line one', x: 40.0, y: 100.0, width: 200.0),
        (text: 'Line two', x: 40.0, y: 130.0, width: 200.0),
        (text: 'Line three', x: 40.0, y: 160.0, width: 200.0),
        (text: 'Line four', x: 40.0, y: 190.0, width: 200.0),
      ];
      expect(
        columnSplitOcrText('RAW', lines),
        'Line one\nLine two\nLine three\nLine four',
      );
    });

    test('out-of-order single-column lines are reordered top-to-bottom',
        () {
      final lines = [
        (text: 'Line three', x: 40.0, y: 160.0, width: 200.0),
        (text: 'Line one', x: 40.0, y: 100.0, width: 200.0),
        (text: 'Line four', x: 40.0, y: 190.0, width: 200.0),
        (text: 'Line two', x: 40.0, y: 130.0, width: 200.0),
      ];
      expect(
        columnSplitOcrText('RAW', lines),
        'Line one\nLine two\nLine three\nLine four',
      );
    });
  });

  group('columnSplitOcrText — fallback', () {
    test('fewer than 4 lines returns the raw text unchanged', () {
      const raw = 'raw ML Kit text — only read of the page';
      expect(columnSplitOcrText(raw, []), raw);
      expect(
        columnSplitOcrText(raw, [
          (text: 'one', x: 40.0, y: 100.0, width: 100.0),
        ]),
        raw,
      );
      // Even a two-column-looking trio falls back — a sparse line
      // list must never lose the only read of the page.
      expect(
        columnSplitOcrText(raw, [
          (text: 'left line', x: 40.0, y: 100.0, width: 100.0),
          (text: 'right line', x: 580.0, y: 100.0, width: 100.0),
          (text: 'left line two', x: 40.0, y: 130.0, width: 100.0),
        ]),
        raw,
      );
    });
  });
}
