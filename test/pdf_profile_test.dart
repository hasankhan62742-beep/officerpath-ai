import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'pdf_test_helpers.dart';

/// Regression tests for the 18 Nov ANR: the user's failing PDF was only
/// ~2 MB, so the v1 extractor was pathologically slow, not the file too
/// big. Extraction of a realistic ~2 MB book must be fast — well under
/// 1 second on this VM — AND it must run in an isolate so the UI never
/// blocks regardless of file size.

Future<Uint8List> _buildRealisticBook() async {
  final doc = pw.Document();
  // 50 pages x 6 MCQ text (300 questions). Six per page at 12 pt fits
  // an A4 page; ten per page does NOT — the pdf package clips the
  // overflow itself, so a 10-per-page book genuinely holds ~7/page.
  for (var p = 0; p < 50; p++) {
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (ctx) {
          final lines = <pw.Widget>[];
          for (var q = 1; q <= 6; q++) {
            final n = p * 6 + q;
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
  // 2 scanned-style pages: big noisy images, no text layer.
  for (var i = 0; i < 2; i++) {
    final png = makeNoisyPng(900, 1200);
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (ctx) => pw.Image(pw.MemoryImage(png)),
      ),
    );
  }
  return doc.save();
}

void main() {
  test('realistic ~2 MB book extracts in well under 1 second', () async {
    final bytes = await _buildRealisticBook();
    // ignore: avoid_print
    print('profile PDF size: ${(bytes.lengthInBytes / 1024 / 1024).toStringAsFixed(2)} MB');
    expect(bytes.lengthInBytes, greaterThan(1500000),
        reason: 'the profile PDF must really be ~2 MB');

    final stopwatch = Stopwatch()..start();
    final pages = extractPdfPages(bytes);
    stopwatch.stop();
    // ignore: avoid_print
    print('extraction took ${stopwatch.elapsedMilliseconds} ms');
    expect(pages.length, 52);
    expect(pages.where((p) => p.hasText).length, 50);
    expect(pages.where((p) => !p.hasText).length, 2);

    // The MCQs must survive extraction (line breaks preserved).
    final result = processPdfInBackground({
      'bytes': bytes,
      'sourceId': 'test-src',
      'sourceLabel': 'Profile Book',
    });
    expect(result['parsed'], 300);

    // The actual performance bar: well under 1 second on the VM.
    expect(stopwatch.elapsedMilliseconds, lessThan(1000));
  });
}
