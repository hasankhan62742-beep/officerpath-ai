import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/gemini_config.dart';
import 'package:officerpath_ai/services/pdf_import_service.dart';
import 'package:officerpath_ai/services/urdu_ocr.dart';

import 'pdf_test_helpers.dart';

/// The silent Gemini fallback (20 Nov 2026): when the user ticked
/// "Behtar quality (Gemini)" but Gemini never ran — no key on the
/// phone (wiped by the v2.0.1 uninstall/reinstall) or no internet —
/// the import swallowed the failure and presented the ML Kit result
/// as if that were the outcome. The owner retried with Gemini ticked
/// and got the identical 1-MCQ result. The result must now record
/// whether Gemini was requested, how many pages it read, and why it
/// failed — so the preview can say so plainly.
class _ThrowingVision extends GeminiVisionOcr {
  _ThrowingVision(this.kind);

  final GeminiFailureKind kind;

  @override
  Future<OcrPageResult> run(List<int> jpegBytes) async {
    throw GeminiException(kind, 'fake Gemini failure');
  }
}

class _WorkingVision extends GeminiVisionOcr {
  _WorkingVision(this.text);

  final String text;

  @override
  Future<OcrPageResult> run(List<int> jpegBytes) async {
    return OcrPageResult(
      text: text,
      method: OcrMethod.gemini,
      quality: OcrQuality.good,
    );
  }
}

void main() {
  /// The real PPSC-66 text layer: one word per page, 7 pages.
  Uint8List watermarkOnlyPdf() => buildHandcraftedPdf(
        List.filled(
          7,
          'BT /F1 12 Tf 72 720 Td (CamScanner) Tj ET',
        ),
      );

  const mlKitQuestion =
      'What is the capital of Pakistan?\n'
      'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\nAnswer: C\n';

  Future<PdfImportResult> runImport({
    required bool bestQualityOcr,
    GeminiVisionOcr? visionOcr,
  }) async {
    var lastRendered = 0;
    return PdfImportService.importPdf(
      watermarkOnlyPdf(),
      sourceId: 'ppsc66-gemini',
      sourceLabel: 'PPSC Paper 66 Gemini',
      onProgress: (_) {},
      isCancelled: () => false,
      renderPage: (bytes, pageNumber) async {
        lastRendered = pageNumber;
        return Uint8List.fromList([0xFF, 0xD8, 0xFF]);
      },
      // One distinct ML Kit question per page, so the parse count
      // proves the on-device text survived the Gemini failure.
      runOcr: (jpegBytes) async => '$lastRendered. $mlKitQuestion',
      bestQualityOcr: bestQualityOcr,
      visionOcr: visionOcr,
    );
  }

  test('no key: Gemini requested, ran on 0 pages, reason recorded', () async {
    final result = await runImport(
      bestQualityOcr: true,
      visionOcr: _ThrowingVision(GeminiFailureKind.noKey),
    );
    expect(result.geminiRequested, isTrue);
    expect(result.geminiPages, 0);
    expect(result.geminiFailure, GeminiFailureKind.noKey);
    // The ML Kit text still stands — but labelled honestly as ML Kit.
    expect(result.ocrPages, [1, 2, 3, 4, 5, 6, 7]);
    expect(
      result.ocrMethods.values.toSet(),
      {'English OCR: device (ML Kit)'},
    );
    expect(result.parsed, 7, reason: 'one ML Kit question per page');
  });

  test('no internet: same honest recording, different reason', () async {
    final result = await runImport(
      bestQualityOcr: true,
      visionOcr: _ThrowingVision(GeminiFailureKind.noInternet),
    );
    expect(result.geminiRequested, isTrue);
    expect(result.geminiPages, 0);
    expect(result.geminiFailure, GeminiFailureKind.noInternet);
  });

  test('Gemini works: pages counted, no failure recorded', () async {
    final fixture =
        File('test-fixtures/ppsc66/ocr-p1.txt').readAsStringSync();
    final result = await runImport(
      bestQualityOcr: true,
      visionOcr: _WorkingVision(fixture),
    );
    expect(result.geminiRequested, isTrue);
    expect(result.geminiPages, 7);
    expect(result.geminiFailure, isNull);
    expect(
      result.ocrMethods.values.toSet(),
      {'Urdu OCR: best quality (Gemini)'},
    );
  });

  test('best quality not ticked: Gemini never attempted', () async {
    final result = await runImport(bestQualityOcr: false);
    expect(result.geminiRequested, isFalse);
    expect(result.geminiPages, 0);
    expect(result.geminiFailure, isNull);
  });
}
