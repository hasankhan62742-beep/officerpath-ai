import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'pdf_test_helpers.dart';

void main() {
  test('extracts a multi-page MCQ PDF made by the pdf package', () async {
    final doc = pw.Document();
    for (var p = 0; p < 3; p++) {
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          build: (ctx) {
            final lines = <pw.Widget>[];
            for (var q = 1; q <= 4; q++) {
              final n = p * 4 + q;
              lines.addAll([
                pw.Text('Q$n. What is the capital of Pakistan?'),
                pw.Text('A) Lahore'),
                pw.Text('B) Karachi'),
                pw.Text('C) Islamabad'),
                pw.Text('D) Quetta'),
                pw.Text('Answer: C'),
                pw.SizedBox(height: 10),
              ]);
            }
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: lines,
            );
          },
        ),
      );
    }
    final bytes = await doc.save();

    final pages = extractPdfPages(bytes);
    expect(pages.length, 3);
    for (final page in pages) {
      expect(page.text, contains('What is the capital of Pakistan?'));
      expect(page.text, contains('Islamabad'));
    }

    // End-to-end in the background entry point: text + parsed MCQs.
    final result = processPdfInBackground({
      'bytes': bytes,
      'sourceId': 'test-src',
      'sourceLabel': 'Test Book',
    });
    expect(result['parsed'], 12);
    expect((result['questions'] as List).length, 12);
    expect(result['formats']['block'], 12);
  });

  test('same extraction runs in an isolate via compute()', () async {
    final pdf = buildHandcraftedPdf([
      r'BT /F1 12 Tf 72 720 Td (Q1. What is 2+2?) Tj 0 -20 Td (A\) 3) Tj '
          r'0 -20 Td (B\) 4) Tj 0 -20 Td (C\) 5) Tj 0 -20 Td (D\) 6) Tj '
          '0 -20 Td (Answer: B) Tj ET',
    ]);
    final result = await compute(processPdfInBackground, {
      'bytes': pdf,
      'sourceId': 'test-src',
      'sourceLabel': 'Test',
    });
    expect(result['parsed'], 1);
    final q = (result['questions'] as List).first as Map<String, dynamic>;
    expect(q['text'], contains('2+2'));
    expect(q['correct_index'], 1);
  });

  test('hex strings + ToUnicode CMap decode custom fonts', () {
    const cmap = '4 0 obj\n'
        '<< /Length 200 >>\nstream\n'
        '/CIDInit /ProcSet findresource begin\n'
        '12 dict begin\n'
        'begincmap\n'
        '1 begincodespacerange\n<00> <FF>\nendcodespacerange\n'
        '3 beginbfchar\n<01> <0041>\n<02> <0042>\n<03> <0043>\nendbfchar\n'
        'endcmap\n'
        'CMapName currentdict /CMap defineresource pop\nend\nend\n'
        'endstream\nendobj\n';
    final pdf = buildHandcraftedPdf(
      ['BT /F1 12 Tf 72 720 Td <010203> Tj ET'],
      fontDict:
          '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
          '/ToUnicode 4 0 R >>',
      extraObjects: [cmap],
    );
    final pages = extractPdfPages(pdf);
    expect(pages.length, 1);
    expect(pages.first.text, contains('ABC'));
  });

  test('TJ arrays and Td line breaks keep one line per line', () {
    final pdf = buildHandcraftedPdf([
      'BT /F1 12 Tf 72 720 Td [(Hello) -120 (World)] TJ 0 -20 Td '
          '(Second line) Tj ET',
    ]);
    final pages = extractPdfPages(pdf);
    expect(pages.length, 1);
    expect(pages.first.text, 'Hello World\nSecond line');
  });

  test('image streams are never inflated; image-only page is empty', () {
    final pdf = buildScannedStylePdf(
      'BT /F1 12 Tf 72 720 Td (Q1. Sample question?) Tj ET',
    );
    // Sanity: the file really does carry a big image stream.
    expect(pdf.lengthInBytes, greaterThan(100000));
    final stopwatch = Stopwatch()..start();
    final pages = extractPdfPages(pdf);
    stopwatch.stop();
    expect(pages.length, 2);
    expect(pages[0].text, contains('Sample question'));
    expect(pages[1].hasText, isFalse);
    // The 8 MB Flate image stream must not be inflated or scanned.
    // HANG/SLOWNESS GUARD, not a benchmark: the bound is wall-clock
    // on a shared VM, so it needs headroom — it was 1000 ms and
    // failed at 1378 ms under a full-suite run (19 Nov 2026, 1.5
    // shared CPUs; passes in isolation), while the real assertions
    // above (2 pages, image-only page empty) all held. 5000 ms still
    // catches a real regression (inflating + scanning the stream).
    expect(stopwatch.elapsedMilliseconds, lessThan(5000));
  });

  test('returns no pages for a PDF with no page objects', () {
    final pdf = Uint8List.fromList(
      '%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF'.codeUnits,
    );
    expect(extractPdfPages(pdf), isEmpty);
    expect(extractTextFromPdfBytes(pdf).trim(), isEmpty);
  });
}
