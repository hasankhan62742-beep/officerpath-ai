import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/ai_generation.dart';
import 'package:officerpath_ai/services/urdu_ocr.dart';

/// v1.2 two-tier Urdu OCR routing (pure decisions — no device, no
/// key, no network). The live quality claim is NOT made here: the
/// VM test (19 Nov) showed Tesseract on dense ~130 DPI Nastaliq is
/// only partially readable, so Tier 2 (Gemini vision) is the quality
/// path — see the routing labels + AUDIT_REPORT.md.
void main() {
  group('chooseOcrMethod', () {
    test('Latin page → ML Kit', () {
      expect(
        chooseOcrMethod(
          pageHasUrdu: false,
          userPickedUrdu: false,
          userPickedBestQuality: false,
          hasGeminiKey: false,
        ),
        OcrMethod.mlKit,
      );
    });

    test('Urdu on the page → Tesseract first (free + offline)', () {
      expect(
        chooseOcrMethod(
          pageHasUrdu: true,
          userPickedUrdu: false,
          userPickedBestQuality: false,
          hasGeminiKey: true,
        ),
        OcrMethod.tesseract,
      );
    });

    test('user picked Urdu for the book → Tesseract even before a read',
        () {
      expect(
        chooseOcrMethod(
          pageHasUrdu: false,
          userPickedUrdu: true,
          userPickedBestQuality: false,
          hasGeminiKey: false,
        ),
        OcrMethod.tesseract,
      );
    });

    test('best quality + key → Gemini vision', () {
      expect(
        chooseOcrMethod(
          pageHasUrdu: true,
          userPickedUrdu: true,
          userPickedBestQuality: true,
          hasGeminiKey: true,
        ),
        OcrMethod.gemini,
      );
    });

    test('best quality WITHOUT a key → falls back to Tesseract, never crashes',
        () {
      expect(
        chooseOcrMethod(
          pageHasUrdu: true,
          userPickedUrdu: false,
          userPickedBestQuality: true,
          hasGeminiKey: false,
        ),
        OcrMethod.tesseract,
      );
    });
  });

  group('Method labels (shown in the preview)', () {
    test('labels name the engine honestly', () {
      expect(OcrMethod.mlKit.label, contains('ML Kit'));
      expect(OcrMethod.tesseract.label, contains('Tesseract'));
      expect(OcrMethod.gemini.label, contains('Gemini'));
    });
  });

  group('assessOcrQuality', () {
    test('plenty of words → good; few → poor; almost none → unreadable',
        () {
      expect(
        assessOcrQuality(
          List.generate(25, (i) => 'word$i').join(' '),
        ),
        OcrQuality.good,
      );
      expect(assessOcrQuality('hello world foo bar baz'), OcrQuality.poor);
      expect(assessOcrQuality('a b'), OcrQuality.unreadable);
      expect(assessOcrQuality(''), OcrQuality.unreadable);
    });
  });

  group('splitColumnsForOcr', () {
    test('two-column lines come back left column first', () {
      final lines = [
        (text: 'Q.1 left question', x: 10.0, width: 200.0),
        (text: 'Q.2 right question', x: 320.0, width: 200.0),
        (text: 'A. left option', x: 10.0, width: 100.0),
        (text: 'A. right option', x: 320.0, width: 100.0),
        (text: 'B. left option', x: 10.0, width: 100.0),
        (text: 'B. right option', x: 320.0, width: 100.0),
      ];
      final split = splitColumnsForOcr(lines);
      final leftIdx = split.indexOf('Q.1 left');
      final rightIdx = split.indexOf('Q.2 right');
      expect(leftIdx, greaterThanOrEqualTo(0));
      expect(rightIdx, greaterThan(leftIdx));
      expect(split.indexOf('B. left'), lessThan(split.indexOf('A. right')));
    });

    test('single column is unchanged', () {
      final lines = [
        (text: 'Line one', x: 10.0, width: 200.0),
        (text: 'Line two', x: 10.0, width: 200.0),
        (text: 'Line three', x: 10.0, width: 200.0),
        (text: 'Line four', x: 10.0, width: 200.0),
      ];
      expect(
        splitColumnsForOcr(lines),
        'Line one\nLine two\nLine three\nLine four',
      );
    });
  });

  group('Urdu detection', () {
    test('ocrTextHasUrdu spots Arabic-script in OCR text', () {
      expect(ocrTextHasUrdu('Q92 فعل معروف'), isTrue);
      expect(ocrTextHasUrdu('Q92 past tense'), isFalse);
      expect(containsUrduScript('کرنٹ افیئ جون'), isTrue);
    });
  });
}
