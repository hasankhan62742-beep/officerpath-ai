import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/pdf_import_service.dart';

import 'pdf_test_helpers.dart';

/// Regression tests for the scanned-PDF OCR routing bug (20 Nov 2026):
/// a page counted as a "text page" whenever its extracted text was
/// merely non-empty, so a CamScanner scan whose text layer holds only
/// the "CamScanner" watermark on every page was never sent to OCR —
/// the import parsed 82 chars of watermark and reported
/// "No MCQs found" (owner's phone, v2.0.1, PPSC Paper 66).
///
/// The rule under test is generic — no watermark word is hardcoded:
/// a page is a text page only when its text layer carries enough
/// words to be real content, and a short text repeated on most pages
/// is a stamp/header, not content. Both conditions send the page to
/// OCR. The real ML Kit plugin cannot run in VM tests, so OCR is
/// stubbed (renderPage/runOcr seams) with the real Gemini OCR
/// fixture text for Paper 66 and the two table photos.
void main() {
  /// The real PPSC-66 text layer: one word per page, 7 pages.
  Uint8List watermarkOnlyPdf() => buildHandcraftedPdf(
        List.filled(
          7,
          'BT /F1 12 Tf 72 720 Td (CamScanner) Tj ET',
        ),
      );

  /// Gemini OCR fixture text per Paper 66 page (the OCR output the
  /// phone's ML Kit tier is expected to approximate).
  String ocrFixture(int page) =>
      File('test-fixtures/ppsc66/ocr-p$page.txt').readAsStringSync();

  test('watermark-only scan: every page goes to OCR and MCQs parse',
      () async {
    var rendered = <int>[];
    var lastRendered = 0;
    final result = await PdfImportService.importPdf(
      watermarkOnlyPdf(),
      sourceId: 'ppsc66',
      sourceLabel: 'PPSC Paper 66',
      onProgress: (_) {},
      isCancelled: () => false,
      renderPage: (bytes, pageNumber) async {
        rendered.add(pageNumber);
        lastRendered = pageNumber;
        return Uint8List.fromList([0xFF, 0xD8, 0xFF]);
      },
      runOcr: (jpegBytes) async => ocrFixture(lastRendered),
    );

    // The bug: textPages was 7 and ocrPages was [] — the watermark
    // counted as a text layer, so no page was ever scanned.
    expect(result.pageCount, 7);
    expect(result.textPages, 0,
        reason: 'a watermark-only page is not a text page');
    expect(result.ocrPages, [1, 2, 3, 4, 5, 6, 7]);
    expect(rendered, [1, 2, 3, 4, 5, 6, 7]);
    // Paper 66: 100 questions with key answers (see
    // PPSC66_BASELINE_2026-11-20.md §8 + the no-answers agent's
    // verified 100/100); Paper 67's 10 stay pending, never fabricated.
    expect(result.parsed, 100);
    expect(result.keyEntriesApplied, 100);
    expect(result.keySectionsFound, 1);
    expect(result.questionsMissingAnswers.length, 10);
    expect(
      result.questionsMissingAnswers.first,
      startsWith('Paper 67 Q1'),
    );
  });

  test('genuine short text page is NOT sent to OCR unnecessarily',
      () async {
    // Page 1: one complete MCQ as a real text layer (~17 words).
    // Page 2: image-only (no text) — the only OCR target.
    final pdf = buildHandcraftedPdf([
      'BT /F1 12 Tf 72 720 Td (Q1. What is the capital of Pakistan?) Tj '
          r'0 -20 Td (A\) Lahore) Tj 0 -20 Td (B\) Karachi) Tj '
          r'0 -20 Td (C\) Islamabad) Tj 0 -20 Td (D\) Quetta) Tj '
          '0 -20 Td (Answer: C) Tj ET',
      '',
    ]);
    var rendered = <int>[];
    final result = await PdfImportService.importPdf(
      pdf,
      sourceId: 'test-src',
      sourceLabel: 'Short Text Book',
      onProgress: (_) {},
      isCancelled: () => false,
      renderPage: (bytes, pageNumber) async {
        rendered.add(pageNumber);
        return Uint8List.fromList([0xFF, 0xD8, 0xFF]);
      },
      runOcr: (jpegBytes) async =>
          'Q2. What is the capital of France?\n'
          'A) London\nB) Paris\nC) Rome\nD) Berlin\nAnswer: B\n',
    );

    expect(result.pageCount, 2);
    expect(result.textPages, 1);
    expect(result.ocrPages, [2]);
    expect(rendered, [2]);
    expect(result.parsed, 2);
  });

  test('same short header on every page is a stamp, not content',
      () async {
    // A running header repeated verbatim on every page of a scan
    // (10 words — at the word-count bar, so only the repetition
    // rule can catch it). No watermark word is named anywhere.
    const header =
        'Advanced FPJC MCQs Model Papers Volume 2 Papers of 2021';
    final pdf = buildHandcraftedPdf(
      List.filled(
        3,
        'BT /F1 12 Tf 72 720 Td ($header) Tj ET',
      ),
    );
    var rendered = <int>[];
    final result = await PdfImportService.importPdf(
      pdf,
      sourceId: 'test-src',
      sourceLabel: 'Stamped Scan',
      onProgress: (_) {},
      isCancelled: () => false,
      renderPage: (bytes, pageNumber) async {
        rendered.add(pageNumber);
        return Uint8List.fromList([0xFF, 0xD8, 0xFF]);
      },
      runOcr: (jpegBytes) async =>
          'Q1. What is 2 + 2?\nA) 3\nB) 4\nC) 5\nD) 6\nAnswer: B\n',
    );

    expect(result.textPages, 0);
    expect(result.ocrPages, [1, 2, 3]);
    expect(rendered, [1, 2, 3]);
    expect(result.parsed, 3);
  });

  test('interjection table photo parses through the image path',
      () async {
    final bytes = File(
      'test-fixtures/ppsc66/table-interjection-q230-257.jpg',
    ).readAsBytesSync();
    final ocrText = File(
      'test-fixtures/ppsc66/ocr-table-interjection-gemini.txt',
    ).readAsStringSync();
    final result = await PdfImportService.importImage(
      bytes,
      sourceId: 'test-photo',
      sourceLabel: 'Interjection table Q230-257',
      onProgress: (_) {},
      isCancelled: () => false,
      runOcr: (_) async => ocrText,
    );

    expect(result.pageCount, 1);
    expect(result.ocrPages, [1]);
    // 30 physical rows: Q230–Q257 is 28 numbers, plus the book's own
    // misnumbered rows 162/164 inserted after 253 (see the error
    // note the parser emits about them).
    expect(result.parsed, 30);
    expect(result.questionsMissingAnswers, isEmpty);
  });

  test('computer table photo parses through the image path', () async {
    final bytes = File(
      'test-fixtures/ppsc66/table-computer-q67-81.jpg',
    ).readAsBytesSync();
    final ocrText = File(
      'test-fixtures/ppsc66/ocr-table-computer-gemini.txt',
    ).readAsStringSync();
    final result = await PdfImportService.importImage(
      bytes,
      sourceId: 'test-photo',
      sourceLabel: 'Computer table Q67-81',
      onProgress: (_) {},
      isCancelled: () => false,
      runOcr: (_) async => ocrText,
    );

    expect(result.pageCount, 1);
    expect(result.ocrPages, [1]);
    // Q67–Q81 = 15 rows.
    expect(result.parsed, 15);
    expect(result.questionsMissingAnswers, isEmpty);
  });
}
