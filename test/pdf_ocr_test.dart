import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/pdf_import_service.dart';

import 'pdf_test_helpers.dart';

/// OCR-path test with STUBS — the real ML Kit plugin cannot run in VM
/// tests (it needs a phone + the on-device model). This test proves the
/// import pipeline: a page with no text layer is detected, rendered,
/// OCR'd (stub), and the OCR text flows into the same parser as
/// text-layer pages. The real ML Kit path must still be verified on a
/// real phone (see AUDIT_REPORT.md).

void main() {
  test('scanned page is OCR-d (stub) and its MCQs are parsed', () async {
    // Page 1: real text layer with 1 MCQ. Page 2: image-only, no text.
    final pdf = buildScannedStylePdf(
      'BT /F1 12 Tf 72 720 Td (Q1. What is the capital of Pakistan?) Tj '
      r'0 -20 Td (A\) Lahore) Tj 0 -20 Td (B\) Karachi) Tj '
      r'0 -20 Td (C\) Islamabad) Tj 0 -20 Td (D\) Quetta) Tj '
      '0 -20 Td (Answer: C) Tj ET',
    );

    var renderedPages = <int>[];
    final result = await PdfImportService.importPdf(
      pdf,
      sourceId: 'test-src',
      sourceLabel: 'Scanned Book',
      onProgress: (_) {},
      isCancelled: () => false,
      renderPage: (bytes, pageNumber) async {
        renderedPages.add(pageNumber);
        return Uint8List.fromList([0xFF, 0xD8, 0xFF]); // fake JPEG bytes
      },
      runOcr: (jpegBytes) async {
        // The stub pretends ML Kit read this MCQ off the scanned page.
        return 'Q2. What is the capital of France?\n'
            'A) London\nB) Paris\nC) Rome\nD) Berlin\nAnswer: B\n';
      },
    );

    expect(result.pageCount, 2);
    expect(result.textPages, 1);
    expect(result.ocrPages, [2]);
    expect(renderedPages, [2]);
    expect(result.parsed, 2);
    expect(result.questions[1].text, contains('capital of France'));
    expect(result.questions[1].correctIndex, 1);
  });

  test('OCR text that parses to 0 MCQs is reported, not hidden', () async {
    final pdf = buildScannedStylePdf(
      'BT /F1 12 Tf 72 720 Td (Q1. What is the capital of Pakistan?) Tj '
      r'0 -20 Td (A\) Lahore) Tj 0 -20 Td (B\) Karachi) Tj '
      r'0 -20 Td (C\) Islamabad) Tj 0 -20 Td (D\) Quetta) Tj '
      '0 -20 Td (Answer: C) Tj ET',
    );
    final result = await PdfImportService.importPdf(
      pdf,
      sourceId: 'test-src',
      sourceLabel: 'Scanned Book',
      onProgress: (_) {},
      isCancelled: () => false,
      renderPage: (bytes, pageNumber) async =>
          Uint8List.fromList([0xFF, 0xD8, 0xFF]),
      // The stub "reads" prose with no MCQs in it.
      runOcr: (jpegBytes) async =>
          'This page is just a foreword about the book and its author.',
    );
    expect(result.parsed, 1); // only the text-layer question
    expect(result.ocrPages, [2],
        reason: 'OCR did read text on page 2 — it just had no MCQs');
    expect(result.text, contains('foreword'));
  });

  test('import is cancellable between OCR pages', () async {
    // Two image-only pages, so cancellation can hit between them.
    final pdf = buildHandcraftedPdf(['', '']);
    var calls = 0;
    await expectLater(
      PdfImportService.importPdf(
        pdf,
        sourceId: 'test-src',
        sourceLabel: 'Scanned Book',
        onProgress: (_) {},
        isCancelled: () => calls >= 1,
        renderPage: (bytes, pageNumber) async {
          calls++;
          return Uint8List.fromList([0xFF, 0xD8, 0xFF]);
        },
        runOcr: (jpegBytes) async => '',
      ),
      throwsA(isA<PdfImportCancelled>()),
    );
    expect(calls, 1);
  });
}
