import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';

import 'test_helpers.dart';

/// v1.2 corrupt-file fail-fast (File 4, Ayesha Jalal — 4.5 MB).
/// The file's xref stream fails to decompress, which is exactly what
/// `pdftotext` reports ("Couldn't find trailer dictionary /
/// Couldn't read xref table"). The app must fail FAST with a clear
/// message — never ANR, never import garbage from it.
void main() {
  const ayesha =
      '/home/hatch/workspace/user/files/Ayesha_Jalal_-_The_Struggle_for_Pakistan__A_Muslim_Homeland_and_Global_Politics__2014__Belknap_Press.pdf';

  test('detectPdfCorruption flags the corrupt file', () async {
    if (skipIfFixtureMissing(ayesha)) return;
    final bytes = await File(ayesha).readAsBytes();
    final reason = detectPdfCorruption(bytes);
    // ignore: avoid_print
    print('Ayesha corruption reason: $reason');
    expect(reason, isNotNull);
    expect(reason, contains('Dobara download'));
  });

  test('processPdfInBackground fails fast with a timeout', () async {
    if (skipIfFixtureMissing(ayesha)) return;
    final bytes = await File(ayesha).readAsBytes();
    final stopwatch = Stopwatch()..start();
    Object? caught;
    try {
      await Future(
        () => processPdfInBackground({
          'bytes': bytes,
          'sourceId': 'corrupt',
          'sourceLabel': 'Ayesha Jalal',
        }),
      ).timeout(const Duration(seconds: 30));
    } catch (e) {
      caught = e;
    }
    stopwatch.stop();
    // ignore: avoid_print
    print('Ayesha fail-fast: ${stopwatch.elapsedMilliseconds}ms, '
        'caught=${caught.runtimeType}');
    expect(caught, isA<CorruptPdfException>());
    // Fail-fast means seconds, not the minutes a full garbage
    // extraction + parse used to take.
    expect(stopwatch.elapsedMilliseconds, lessThan(30000));
  });

  test('detectPdfCorruption passes every valid real file', () async {
    const valid = [
      'PPSC_Current_Affairs_40_MCQs.pdf',
      'Current-Affairs-June-2025-in-PDF__1.pdf',
      'Current_Affairs_Jan-Nov_2026_by_Pace_GK_Academy.pdf',
      'junior_clerk.pdf',
      'MPT-CSS-2027-Solved.pdf',
      'Pak_Affairs_by_CSPs.pdf',
    ];
    for (final name in valid) {
      final file = File(
        '/home/hatch/workspace/user/files/$name',
      );
      if (skipIfFixtureMissing(file.path)) return;
      final bytes = await file.readAsBytes();
      expect(
        detectPdfCorruption(bytes),
        isNull,
        reason: '$name must not be flagged corrupt',
      );
    }
  });

  test('a non-PDF file is flagged, not parsed', () {
    expect(detectPdfCorruption(_fakeBytes('hello, not a pdf')), isNotNull);
    expect(detectPdfCorruption(_fakeBytes('')), isNotNull);
  });

  test('a minimal well-formed PDF passes the gate', () {
    // Header + classic xref table + trailer. The startxref offset is
    // computed from the real position of 'xref' (a wrong offset is
    // itself corruption — the gate must catch it, not the fixture).
    final body =
        '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n'
        '2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n';
    final xrefAt = '%PDF-1.4\n'.length + body.length;
    final bytes = _fakeBytes(
      '%PDF-1.4\n$body'
      'xref\n0 3\n0000000000 65535 f \n0000000009 00000 n \n'
      '0000000058 00000 n \n'
      'trailer\n<< /Size 3 /Root 1 0 R >>\n'
      'startxref\n$xrefAt\n%%EOF\n',
    );
    expect(detectPdfCorruption(bytes), isNull);
  });
}

Uint8List _fakeBytes(String s) => Uint8List.fromList(s.codeUnits);
