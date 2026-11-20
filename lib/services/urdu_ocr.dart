import 'dart:io';

import 'package:tesseract_ocr/ocr_engine_config.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart';

import 'ai_generation.dart' show containsUrduScript;
import 'gemini_client.dart';
import 'gemini_config.dart';

/// Two-tier OCR routing (v1.2).
///
/// Tier 1 — FREE + OFFLINE (primary): Tesseract `eng+urd`
/// (`tessdata_best` urd + `tessdata_fast` eng, bundled as assets in
/// `assets/tessdata/`), one pass for mixed English+Urdu pages.
/// Tier 2 — HIGH ACCURACY: Gemini vision with the user's own key
/// ("Behtar quality (Gemini)"), only when a key is configured.
///
/// Routing per scanned page:
/// * Latin-only page → ML Kit (the existing v1.1 path, fastest).
/// * Page contains Urdu script (Arabic-script Unicode in any OCR
///   result, or the user picked "Urdu" for the book) → Tesseract
///   `eng+urd` FIRST, labelled "Urdu OCR: device (Tesseract)".
/// * The user can then pick Tier 2 for a page/book when a key exists.
///
/// HONEST LIMIT (VM test 19 Nov 2026): Tesseract on dense ~130 DPI
/// Nastaliq scans yields partially readable Urdu (keywords/names
/// often recognisable) but NOT reliable enough to parse clean Urdu
/// MCQs — do not claim otherwise; Tier 2 is the quality path.
/// Column-split happens BEFORE OCR (both languages suffer without
/// it) — see [splitColumnsForOcr].
///
/// A page that reads poorly is flagged honestly ([OcrPageResult.
/// quality]) and the preview offers re-scan / Gemini best-quality —
/// garbage is never silently stored.
enum OcrMethod {
  /// On-device Latin OCR (ML Kit) — English pages.
  mlKit,

  /// On-device Tesseract eng+urd — Urdu / mixed pages, free+offline.
  tesseract,

  /// Gemini vision — best quality, needs key + internet.
  gemini,
}

extension OcrMethodLabel on OcrMethod {
  String get label {
    switch (this) {
      case OcrMethod.mlKit:
        return 'English OCR: device (ML Kit)';
      case OcrMethod.tesseract:
        return 'Urdu OCR: device (Tesseract)';
      case OcrMethod.gemini:
        return 'Urdu OCR: best quality (Gemini)';
    }
  }
}

/// How good one page's OCR text looks, so the preview can flag a
/// poor read honestly instead of storing garbage silently.
enum OcrQuality {
  /// Plenty of readable words — safe to parse.
  good,

  /// Some words, but short / fragmented — parse, but flag it.
  poor,

  /// Almost nothing readable — do not parse; offer re-scan/Gemini.
  unreadable,
}

class OcrPageResult {
  const OcrPageResult({
    required this.text,
    required this.method,
    required this.quality,
  });

  final String text;
  final OcrMethod method;
  final OcrQuality quality;
}

/// Pure routing decision, so tests can prove it without a device.
OcrMethod chooseOcrMethod({
  required bool pageHasUrdu,
  required bool userPickedUrdu,
  required bool userPickedBestQuality,
  required bool hasGeminiKey,
}) {
  if (userPickedBestQuality && hasGeminiKey) return OcrMethod.gemini;
  if (pageHasUrdu || userPickedUrdu) return OcrMethod.tesseract;
  return OcrMethod.mlKit;
}

/// Quality heuristic for one page's OCR text: a page is `good` when
/// it has at least 20 words of ≥ 3 letters; `poor` when it has some
/// words but few; `unreadable` when it has almost nothing. Word
/// counts, not confidence scores — ML Kit / Tesseract give no
/// per-page confidence the app can trust, so the app says so.
OcrQuality assessOcrQuality(String text) {
  final words = text
      .split(RegExp(r'\s+'))
      .where((w) => w.trim().length >= 3)
      .length;
  if (words >= 20) return OcrQuality.good;
  if (words >= 5) return OcrQuality.poor;
  return OcrQuality.unreadable;
}

/// Splits one rendered page image's OCR text into left/right columns
/// — the contract the parser needs ("already-column-split OCR text,
/// left column first, then right"). This runs on the OCR *lines*,
/// not pixels: the caller passes the page's OCR lines with their
/// x-positions (from ML Kit / Tesseract blocks), and the split point
/// is the widest horizontal gap between line starts in the middle
/// third of the page. When no clear gap exists the text is returned
/// unchanged (single column).
///
/// In practice the import service renders the page, runs OCR, and
/// feeds the recognised lines here; the returned text is what the
/// parser sees. Kept line-based (not image-based) so it is testable
/// without a rendered page.
String splitColumnsForOcr(List<({String text, double x, double width})> lines) {
  if (lines.length < 4) return lines.map((l) => l.text).join('\n');
  // Candidate split: the median x of line starts, weighted to the
  // middle of the page. A two-column page has most line starts in
  // two clusters (left margin, mid-page margin); the gap between
  // the clusters is the split.
  final starts = lines.map((l) => l.x).toList()..sort();
  var bestGap = 0.0;
  var bestSplit = 0.0;
  for (var i = 1; i < starts.length; i++) {
    final gap = starts[i] - starts[i - 1];
    final mid = (starts[i] + starts[i - 1]) / 2;
    // The split must sit in the middle third of the page width.
    final pageWidth = lines
        .map((l) => l.x + l.width)
        .reduce((a, b) => a > b ? a : b);
    if (mid < pageWidth * 0.3 || mid > pageWidth * 0.7) continue;
    if (gap > bestGap) {
      bestGap = gap;
      bestSplit = mid;
    }
  }
  // No clear middle gap → single column, keep reading order.
  if (bestGap < 40) return lines.map((l) => l.text).join('\n');
  final left = <String>[];
  final right = <String>[];
  for (final l in lines) {
    if (l.x < bestSplit) {
      left.add(l.text);
    } else {
      right.add(l.text);
    }
  }
  return [...left, ...right].join('\n');
}

/// Runs Tesseract `eng+urd` on one JPEG file. The image file must
/// already exist on disk (the import service writes the rendered page
/// to a temp file first). Throws when the traineddata cannot load —
/// the caller falls back to ML Kit and labels the page honestly.
class TesseractUrduOcr {
  Future<String> run(String imagePath) async {
    return TesseractOcr.extractText(
      imagePath,
      config: const OCRConfig(
        language: 'eng+urd',
        engine: OCREngine.tesseract,
        options: {
          // PSM 3: fully automatic page segmentation (two-column
          // pages are split by [splitColumnsForOcr] after OCR, not
          // by forcing a single-column PSM here).
          'tessedit_pageseg_mode': '3',
        },
      ),
    );
  }
}

/// Runs Gemini vision OCR on one JPEG page (Tier 2). The image must
/// already be rendered at [GeminiConfig.visionImageWidth] wide.
class GeminiVisionOcr {
  GeminiVisionOcr({GeminiClient? client}) : _client = client ?? GeminiClient();

  final GeminiClient _client;

  Future<OcrPageResult> run(List<int> jpegBytes) async {
    final text = await _client.generateText(
      prompt:
          'Transcribe ALL text on this scanned book page EXACTLY as '
          'printed, line by line, in reading order (left column first, '
          'then right column). Keep Urdu script as Urdu script and '
          'English as English. Do not correct, translate, summarise or '
          'add anything. If a word is unreadable, write [?] for it.',
      maxOutputTokens: GeminiConfig.maxOutputTokensOcr,
      inlineImages: [geminiImagePart(jpegBytes)],
    );
    return OcrPageResult(
      text: text,
      method: OcrMethod.gemini,
      quality: assessOcrQuality(text),
    );
  }
}

/// Detects Urdu script in OCR text (for routing the NEXT page, or
/// for labelling a page that was OCR'd as Latin but contains Urdu).
bool ocrTextHasUrdu(String text) => containsUrduScript(text);

/// Writes JPEG bytes to a temp file for the Tesseract runner, runs
/// it, and deletes the temp file. Kept small: one page at a time.
Future<String> runTesseractOnBytes(List<int> jpegBytes) async {
  final tmp = File(
    '${Directory.systemTemp.path}/officerpath-tess-'
    '${DateTime.now().microsecondsSinceEpoch}.jpg',
  );
  try {
    await tmp.writeAsBytes(jpegBytes, flush: true);
    return await TesseractUrduOcr().run(tmp.path);
  } finally {
    try {
      await tmp.delete();
    } catch (_) {}
  }
}
