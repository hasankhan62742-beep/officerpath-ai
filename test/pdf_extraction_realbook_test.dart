import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/screens/upload_screen.dart';
import 'package:officerpath_ai/services/pdf_import_service.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';

import 'pdf_test_helpers.dart';

/// Real-book hardening tests (v1.2): Form XObjects, object streams,
/// multi-stream /Contents, /Pages /Kids page order, Urdu hex + CMap
/// extraction, and mixed text/image import via the injected OCR seams.
///
/// Hand-crafted PDFs here are intentionally minimal: object headers,
/// dictionaries and streams, no xref table. They exercise the
/// OfficerPath extractor (which scans objects directly); they are NOT
/// guaranteed to open in a strict PDF viewer.

/// Concatenates raw object strings into a minimal PDF.
Uint8List _pdfFromObjects(List<String> objects) {
  final buf = BytesBuilder();
  buf.add(latin1.encode('%PDF-1.4\n'));
  for (final o in objects) {
    buf.add(latin1.encode(o));
  }
  buf.add(latin1.encode('%%EOF\n'));
  return buf.takeBytes();
}

/// One uncompressed stream object. [dict] is the dictionary content
/// before /Length, e.g. '/Type /XObject /Subtype /Form'.
String _streamObj(int num, String dict, String content) {
  final bytes = latin1.encode(content);
  return '$num 0 obj\n<< $dict /Length ${bytes.length} >>\nstream\n'
      '$content\nendstream\nendobj\n';
}

const _catalog = '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n';
const _font =
    '3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n';

String _pageObj(
  int num,
  String resources,
  String contents, {
  int parent = 2,
}) {
  return '$num 0 obj\n<< /Type /Page /Parent $parent 0 R '
      '/MediaBox [0 0 612 792] /Resources $resources '
      '/Contents $contents >>\nendobj\n';
}

const _q1Stream =
    'BT /F1 12 Tf 72 720 Td (Q1. What is the capital of Pakistan?) Tj '
    r'0 -20 Td (A\) Lahore) Tj 0 -20 Td (B\) Karachi) Tj '
    r'0 -20 Td (C\) Islamabad) Tj 0 -20 Td (D\) Quetta) Tj '
    '0 -20 Td (Answer: C) Tj ET';

void main() {
  test('questions drawn inside a Form XObject are extracted', () {
    // Fm2 holds the question; Fm1 draws Fm2 (nested form); the page
    // draws Fm1. Fm2's font comes from the PAGE resources, not its own
    // — the form must inherit the enclosing resources for that name.
    final pdf = _pdfFromObjects([
      _catalog,
      '2 0 obj\n<< /Type /Pages /Kids [4 0 R] /Count 1 >>\nendobj\n',
      _font,
      _pageObj(
        4,
        '<< /Font << /F1 3 0 R >> /XObject << /Fm1 6 0 R >> >>',
        '5 0 R',
      ),
      _streamObj(5, '', 'q /Fm1 Do Q'),
      _streamObj(
        6,
        '/Type /XObject /Subtype /Form /BBox [0 0 612 792] '
            '/Resources << /XObject << /Fm2 7 0 R >> >>',
        'q /Fm2 Do Q',
      ),
      _streamObj(
        7,
        '/Type /XObject /Subtype /Form /BBox [0 0 612 792]',
        _q1Stream,
      ),
    ]);
    final pages = extractPdfPages(pdf);
    expect(pages.length, 1);
    expect(pages.first.text, contains('What is the capital of Pakistan?'));
    expect(pages.first.text, contains('Islamabad'));

    // End to end: the form-drawn MCQ parses.
    final result = processPdfInBackground({
      'bytes': pdf,
      'sourceId': 'test-src',
      'sourceLabel': 'Form Book',
    });
    expect(result['parsed'], 1);
  });

  test('a self-referencing Form XObject does not hang', () {
    final pdf = _pdfFromObjects([
      _catalog,
      '2 0 obj\n<< /Type /Pages /Kids [4 0 R] /Count 1 >>\nendobj\n',
      _font,
      _pageObj(
        4,
        '<< /Font << /F1 3 0 R >> /XObject << /Fm1 6 0 R >> >>',
        '5 0 R',
      ),
      _streamObj(5, '', 'q /Fm1 Do Q'),
      _streamObj(
        6,
        '/Type /XObject /Subtype /Form /BBox [0 0 612 792]',
        'q /Fm1 Do Q',
      ),
    ]);
    final stopwatch = Stopwatch()..start();
    final pages = extractPdfPages(pdf);
    stopwatch.stop();
    expect(pages.length, 1);
    expect(pages.first.hasText, isFalse);
    expect(stopwatch.elapsedMilliseconds, lessThan(5000));
  });

  test('a /Contents array of several streams extracts in order', () {
    final pdf = _pdfFromObjects([
      _catalog,
      '2 0 obj\n<< /Type /Pages /Kids [4 0 R] /Count 1 >>\nendobj\n',
      _font,
      _pageObj(4, '<< /Font << /F1 3 0 R >> >>', '[6 0 R 7 0 R]'),
      _streamObj(
        6,
        '',
        'BT /F1 12 Tf 72 720 Td (First stream line) Tj ET',
      ),
      _streamObj(
        7,
        '',
        'BT /F1 12 Tf 72 720 Td (Second stream line) Tj ET',
      ),
    ]);
    final pages = extractPdfPages(pdf);
    expect(pages.length, 1);
    expect(pages.first.text, 'First stream line\nSecond stream line');
  });

  test('pages come back in /Pages /Kids order, not file order', () {
    // File order: page B (obj 4), then page A (obj 5). The page tree
    // (via a nested /Pages node) says A comes first.
    final pdf = _pdfFromObjects([
      _catalog,
      '2 0 obj\n<< /Type /Pages /Kids [8 0 R] /Count 2 >>\nendobj\n',
      _font,
      _pageObj(
        4,
        '<< /Font << /F1 3 0 R >> >>',
        '6 0 R',
        parent: 8,
      ),
      _pageObj(
        5,
        '<< /Font << /F1 3 0 R >> >>',
        '7 0 R',
        parent: 8,
      ),
      _streamObj(6, '', 'BT /F1 12 Tf 72 720 Td (PAGE-B) Tj ET'),
      _streamObj(7, '', 'BT /F1 12 Tf 72 720 Td (PAGE-A) Tj ET'),
      '8 0 obj\n<< /Type /Pages /Parent 2 0 R /Kids [5 0 R 4 0 R] '
          '/Count 2 >>\nendobj\n',
    ]);
    final pages = extractPdfPages(pdf);
    expect(pages.length, 2);
    expect(pages[0].page, 1);
    expect(pages[0].text, contains('PAGE-A'));
    expect(pages[1].text, contains('PAGE-B'));
  });

  test('Urdu hex strings + ToUnicode CMap extract in logical order', () {
    // "پاکستان کا دارالحکومت کون سا ہے؟" as 2-byte codes 0001..0010.
    // The codes start at 1, so the CMap code length MUST come from the
    // codespacerange — inferring it from the largest key would decode
    // these as 1-byte codes (NUL-separated garbage).
    const cmap = '4 0 obj\n'
        '<< /Length 600 >>\nstream\n'
        '/CIDInit /ProcSet findresource begin\n'
        '12 dict begin\n'
        'begincmap\n'
        '1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n'
        '16 beginbfchar\n'
        '<0001> <067E>\n<0002> <0627>\n<0003> <06A9>\n<0004> <0633>\n'
        '<0005> <062A>\n<0006> <0646>\n<0007> <0020>\n<0008> <062F>\n'
        '<0009> <0631>\n<000A> <0644>\n<000B> <062D>\n<000C> <0648>\n'
        '<000D> <0645>\n<000E> <06C1>\n<000F> <06D2>\n<0010> <061F>\n'
        'endbfchar\n'
        'endcmap\n'
        'CMapName currentdict /CMap defineresource pop\nend\nend\n'
        'endstream\nendobj\n';
    const hexLine =
        '000100020003000400050002000600070003000200070008000200090002000A'
        '000B0003000C000D000500070003000C00060007000400020007000E000F0010';
    final pdf = buildHandcraftedPdf(
      ['BT /F1 12 Tf 72 720 Td <$hexLine> Tj ET'],
      fontDict:
          '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
          '/ToUnicode 4 0 R >>',
      extraObjects: [cmap],
    );
    final pages = extractPdfPages(pdf);
    expect(pages.length, 1);
    // Logical order — the exact sentence, not reversed, no NULs.
    expect(pages.first.text, 'پاکستان کا دارالحکومت کون سا ہے؟');
    expect(pages.first.text.codeUnits.contains(0), isFalse);
  });

  test('page objects inside a compressed object stream are found', () {
    final pageDict =
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
        '/Resources << /Font << /F1 3 0 R >> >> /Contents 5 0 R >>';
    // ObjStm payload: header "4 0 " then the page dict at offset 4.
    final payload = latin1.encode('4 0 $pageDict');
    final compressed = zlib.encode(payload);
    final buf = BytesBuilder();
    void add(String s) => buf.add(latin1.encode(s));
    add('%PDF-1.4\n');
    add(_catalog);
    add('2 0 obj\n<< /Type /Pages /Kids [4 0 R] /Count 1 >>\nendobj\n');
    add(_font);
    add(
      _streamObj(
        5,
        '',
        'BT /F1 12 Tf 72 720 Td (ObjStm page question) Tj ET',
      ),
    );
    add(
      '6 0 obj\n<< /Type /ObjStm /N 1 /First 4 /Filter /FlateDecode '
      '/Length ${compressed.length} >>\nstream\n',
    );
    buf.add(compressed);
    add('\nendstream\nendobj\n');
    add('%%EOF\n');

    final pages = extractPdfPages(buf.takeBytes());
    expect(pages.length, 1);
    expect(pages.first.text, contains('ObjStm page question'));
  });

  test(
    'ObjStm book imports end to end; only the scanned page is OCR-d',
    () async {
      // Page 1: text layer (Q1). Page 2: image-only (empty content).
      // Both page dicts live in one object stream.
      final body4 =
          '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
          '/Resources << /Font << /F1 3 0 R >> >> /Contents 6 0 R >>';
      final body5 =
          '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
          '/Resources << /Font << /F1 3 0 R >> >> /Contents 7 0 R >>';
      final header = '4 0 5 ${body4.length} ';
      final payload = latin1.encode(header + body4 + body5);
      final compressed = zlib.encode(payload);
      final buf = BytesBuilder();
      void add(String s) => buf.add(latin1.encode(s));
      add('%PDF-1.4\n');
      add(_catalog);
      add(
        '2 0 obj\n<< /Type /Pages /Kids [4 0 R 5 0 R] /Count 2 >>\nendobj\n',
      );
      add(_font);
      add(_streamObj(6, '', _q1Stream));
      add(_streamObj(7, '', ''));
      add(
        '8 0 obj\n<< /Type /ObjStm /N 2 /First ${header.length} '
        '/Filter /FlateDecode /Length ${compressed.length} >>\nstream\n',
      );
      buf.add(compressed);
      add('\nendstream\nendobj\n');
      add('%%EOF\n');
      final pdf = buf.takeBytes();

      final rendered = <int>[];
      final result = await PdfImportService.importPdf(
        pdf,
        sourceId: 'test-src',
        sourceLabel: 'ObjStm Book',
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
      expect(result.questions[0].text, contains('capital of Pakistan'));
      expect(result.questions[1].text, contains('capital of France'));
    },
  );

  test('mixed text/image import: OCR runs only for the empty page',
      () async {
    final pdf = buildHandcraftedPdf([
      _q1Stream,
      '',
      'BT /F1 12 Tf 72 720 Td (Q3. What is the capital of Italy?) Tj '
          r'0 -20 Td (A\) London) Tj 0 -20 Td (B\) Paris) Tj '
          r'0 -20 Td (C\) Rome) Tj 0 -20 Td (D\) Berlin) Tj '
          '0 -20 Td (Answer: C) Tj ET',
    ]);
    final rendered = <int>[];
    final result = await PdfImportService.importPdf(
      pdf,
      sourceId: 'test-src',
      sourceLabel: 'Mixed Book',
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
    expect(result.pageCount, 3);
    expect(result.textPages, 2);
    expect(result.ocrPages, [2]);
    expect(rendered, [2]); // text pages are never rendered/OCR'd
    expect(result.parsed, 3);
    expect(result.text, contains('capital of Pakistan'));
    expect(result.text, contains('capital of France'));
    expect(result.text, contains('capital of Italy'));
  });

  testWidgets('Urdu preview renders right-to-left', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ExtractedTextPreview(
            text: 'پاکستان کا دارالحکومت کون سا ہے؟',
          ),
        ),
      ),
    );
    final selectable =
        tester.widget<SelectableText>(find.byType(SelectableText));
    expect(selectable.textDirection, TextDirection.rtl);
    expect(selectable.data, contains('پاکستان'));
  });

  testWidgets('Latin preview keeps the ambient direction', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ExtractedTextPreview(
            text: 'Q1. What is the capital of Pakistan?',
          ),
        ),
      ),
    );
    final selectable =
        tester.widget<SelectableText>(find.byType(SelectableText));
    expect(selectable.textDirection, isNull);
  });
}
