import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';

void main() {
  test('extracts text from a simple uncompressed PDF stream', () {
    const pdf = '%PDF-1.4\n'
        '1 0 obj\n<< /Length 44 >>\nstream\n'
        'BT /F1 24 Tf 100 700 Td (Hello World) Tj ET\n'
        'endstream\nendobj\n%%EOF';
    final text = extractTextFromPdfBytes(
      Uint8List.fromList(latin1.encode(pdf)),
    );
    expect(text, contains('Hello World'));
  });

  test('extracts Flate-compressed stream text', () {
    final content = latin1.encode(
      'BT /F1 24 Tf 100 700 Td (Compressed Text) Tj ET',
    );
    final compressed = zlib.encode(content);
    final header = latin1.encode(
      '%PDF-1.4\n1 0 obj\n<< /Length ${compressed.length} '
      '/Filter /FlateDecode >>\nstream\n',
    );
    final footer = latin1.encode('\nendstream\nendobj\n%%EOF');
    final bytes = Uint8List.fromList([...header, ...compressed, ...footer]);
    final text = extractTextFromPdfBytes(bytes);
    expect(text, contains('Compressed Text'));
  });

  test('returns empty text for a PDF with no text stream', () {
    const pdf = '%PDF-1.4\n%%EOF';
    final text = extractTextFromPdfBytes(
      Uint8List.fromList(latin1.encode(pdf)),
    );
    expect(text.trim(), isEmpty);
  });
}
