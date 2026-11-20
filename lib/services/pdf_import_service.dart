import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:pdfx/pdfx.dart';

import '../models/question.dart';
import 'ai_generation.dart';
import 'book_structure.dart';
import 'docx_text_extractor.dart';
import 'image_preprocess.dart';
import 'mcq_parser.dart';
import 'pdf_text_extractor.dart';
import 'urdu_ocr.dart';

/// Progress of a PDF import, for the upload screen's progress card.
class PdfImportProgress {
  const PdfImportProgress({required this.stage, this.current = 0, this.total = 0});

  /// Human-readable stage, e.g. "Reading PDF…", "Scanning page 3 of 12…".
  final String stage;
  final int current;
  final int total;

  /// 0.0–1.0 while a counted step (OCR) runs; null for indeterminate work.
  double? get fraction => total > 0 ? current / total : null;
}

/// The result of importing one book / past paper.
class PdfImportResult {
  const PdfImportResult({
    required this.text,
    required this.pageCount,
    required this.textPages,
    required this.ocrPages,
    required this.ocrCapped,
    required this.questions,
    required this.parsed,
    required this.skipped,
    required this.errors,
    required this.formats,
    required this.generatedOptions,
    required this.excluded,
    this.parts = const [],
    this.keySectionsFound = 0,
    this.keyEntriesApplied = 0,
    this.questionsMissingAnswers = const [],
    this.answerSources = const {},
    this.conflicts = const [],
    this.unmatchedKeyEntries = const [],
    this.notes = const [],
    this.unmatchedNotes = const [],
    this.fiveOptionNormalised = 0,
    this.fiveOptionAnswerE = 0,
    this.numberGaps = const [],
    this.numberDuplicates = const [],
    this.noiseLinesFiltered = 0,
    this.facts = const [],
    this.answerPending = const [],
    this.ocrMethods = const {},
    this.poorOcrPages = const [],
  });

  /// All extracted text (text layer + OCR), in page order.
  final String text;

  /// Pages in the PDF (0 when the file could not be read at all).
  final int pageCount;

  /// Pages that had a readable text layer.
  final int textPages;

  /// 1-based page numbers that were read by OCR.
  final List<int> ocrPages;

  /// True when the book had more scanned pages than the per-import OCR
  /// cap — only the first [PdfImportService.maxOcrPagesPerImport] were
  /// scanned (the rest need a split book).
  final bool ocrCapped;

  final List<Question> questions;
  final int parsed;
  final int skipped;
  final List<String> errors;
  final Map<String, int> formats;
  final int generatedOptions;
  final List<String> excluded;

  /// Test-building parts with exact question counts (see
  /// [ParseResult.parts]); the selection screen offers these.
  final List<BookPart> parts;

  /// How many "Answer Key" sections were found.
  final int keySectionsFound;

  /// How many questions got their answer from the key.
  final int keyEntriesApplied;

  /// Answerless questions the key could not answer.
  final List<String> questionsMissingAnswers;

  /// Questions per answer signal source ('answer-line', 'key',
  /// 'tick', 'bold', 'flashcard', 'ai') — shown in the preview.
  final Map<String, int> answerSources;

  /// Signal conflicts (higher-precedence signal won; see
  /// [ParseResult.conflicts]).
  final List<String> conflicts;

  /// Answer-key entries matching no question in any segment.
  final List<String> unmatchedKeyEntries;

  /// Every "(Note: …)" evidence line found (see [ParseResult.notes]).
  final List<String> notes;

  /// Notes that could not be matched to a question's options, or had
  /// no preceding question (see [ParseResult.unmatchedNotes]).
  final List<String> unmatchedNotes;

  /// 5-option (A–E) questions normalised to exactly 4 (Examveda —
  /// see [ParseResult.fiveOptionNormalised]).
  final int fiveOptionNormalised;

  /// Of those, how many had E as the answer (E's text kept as the
  /// 4th option — see [ParseResult.fiveOptionAnswerE]).
  final int fiveOptionAnswerE;

  /// Number gaps in the book ("Q4–Q45 (42 questions missing)") —
  /// see [ParseResult.numberGaps].
  final List<String> numberGaps;

  /// Duplicated question numbers ("Q8 appears twice (p1, p2)") —
  /// see [ParseResult.numberDuplicates].
  final List<String> numberDuplicates;

  /// Watermark / promo / foreign-script noise lines filtered before
  /// parsing (see [ParseResult.noiseLinesFiltered]).
  final int noiseLinesFiltered;

  /// Label–value facts (organisation file — see [ParseResult.facts]).
  /// Kept as diagnostics; nothing is generated from them (AI
  /// generation is parked by the governing spec, 19 Nov 2026).
  final List<FactPair> facts;

  /// Questions with 4 options but no usable answer (see
  /// [ParseResult.answerPending]) — the user sets them by MANUAL
  /// CORRECTION on explicit choice. Never counted in [parsed],
  /// never guessed, never sent to AI.
  final List<PendingQuestion> answerPending;

  /// OCR method used per OCR'd page (1-based page → method label,
  /// e.g. "Urdu OCR: device (Tesseract)") — shown in the preview so
  /// the user knows how each scanned page was read.
  final Map<int, String> ocrMethods;

  /// OCR'd pages whose text reads poorly ([OcrQuality.poor] /
  /// unreadable) — the preview flags them honestly and offers
  /// re-scan / Gemini best-quality instead of storing garbage.
  final List<int> poorOcrPages;

  /// First ~600 characters of the extracted text, for the "no MCQs
  /// found" dialog so the user can see what was actually read.
  String get textPreview =>
      text.length > 600 ? '${text.substring(0, 600)}…' : text;
}

/// Thrown when the user taps Cancel during an import.
class PdfImportCancelled implements Exception {
  const PdfImportCancelled();
}

/// Renders one PDF page to a JPEG image (test seam: inject a fake).
typedef PageImageRenderer =
    Future<Uint8List?> Function(Uint8List pdfBytes, int pageNumber);

/// Runs OCR on one rendered page image (test seam: inject a fake).
typedef OcrRunner = Future<String> Function(Uint8List jpegBytes);

/// Imports a PDF: text extraction in a background isolate (never on the
/// UI thread — that is what caused the ANR), then on-device OCR for any
/// page with no text layer.
///
/// * Text-layer pages are extracted + parsed in one `compute()` call.
/// * Scanned/image pages are rendered with pdfx and read with
///   two-tier OCR (v1.2): ML Kit Latin for English pages; Tesseract
///   `eng+urd` (free, on-device) FIRST when a page contains Urdu
///   script or the user picked Urdu for the book; Gemini vision
///   ("best quality") only when the user picks it and a key is
///   configured. One page at a time, cancellable, with per-page
///   progress — so a big scanned book cannot freeze or OOM the phone.
/// * HONEST LIMIT: Tesseract on dense ~130 DPI Nastaliq scans is
///   partially readable, NOT reliable enough for clean Urdu MCQs —
///   Gemini vision is the quality path. A page that reads poorly is
///   flagged in the preview ([PdfImportResult.poorOcrPages]), never
///   silently stored as garbage.
class PdfImportService {
  /// Max scanned pages OCR'd per import — a 500-page scanned book would
  /// otherwise run for 10+ minutes. The user is told when the cap hits.
  static const int maxOcrPagesPerImport = 100;

  /// Render width for OCR pages: high enough to read small print,
  /// low enough to keep memory sane (~2 MP per page).
  static const double ocrRenderWidth = 1600;

  static Future<PdfImportResult> importPdf(
    Uint8List bytes, {
    required String sourceId,
    required String sourceLabel,
    required void Function(PdfImportProgress) onProgress,
    required bool Function() isCancelled,
    PageImageRenderer? renderPage,
    OcrRunner? runOcr,
    // v1.2 two-tier Urdu OCR: the user picked "Urdu" for this book
    // (Tesseract eng+urd runs first on every scanned page), and/or
    // "best quality" (Gemini vision, needs a configured key).
    bool urduBook = false,
    bool bestQualityOcr = false,
    OcrRunner? runTesseract,
    GeminiVisionOcr? visionOcr,
  }) async {
    onProgress(const PdfImportProgress(stage: 'Reading PDF…'));
    final bg = await compute(processPdfInBackground, {
      'bytes': bytes,
      'sourceId': sourceId,
      'sourceLabel': sourceLabel,
    });

    final pageTexts = <int, String>{};
    for (final p in (bg['pages'] as List).cast<Map<String, dynamic>>()) {
      pageTexts[p['page'] as int] = p['text'] as String;
    }
    var pageCount = pageTexts.length;
    // Pages that had a readable text layer — counted BEFORE OCR runs,
    // so the number means what it says even after OCR fills the gaps.
    final textPages = pageTexts.values
        .where((t) => t.trim().isNotEmpty)
        .length;
    var ocrTargets = pageTexts.entries
        .where((e) => e.value.trim().isEmpty)
        .map((e) => e.key)
        .toList();

    final ocrPages = <int>[];
    final ocrMethods = <int, String>{};
    final poorOcrPages = <int>[];
    var ocrCapped = false;

    // Two-tier OCR for one rendered page (see urdu_ocr.dart):
    // ML Kit first (Latin); Tesseract eng+urd when the page has Urdu
    // or the user picked Urdu for the book; Gemini vision when the
    // user picked best quality and a vision runner is available. A
    // tier that throws never kills the page — the best text so far
    // is kept. Returns (text, method-label).
    Future<(String, String)> ocrPage(Uint8List jpeg) async {
      final mlKit = runOcr ?? _runOcrWithMlKit;
      var text = await mlKit(jpeg);
      var method = OcrMethod.mlKit;
      final needsUrdu = urduBook || containsUrduScript(text);
      if (needsUrdu) {
        try {
          final tess = runTesseract ?? runTesseractOnBytes;
          // Camera photos / scans: enhance for Tesseract only (the
          // weakest tier). ML Kit and Gemini get the raw bytes — they
          // do their own preprocessing. The word-count comparison
          // below keeps a worse Tesseract read from replacing ML Kit.
          final tessText = await tess(preprocessForOcr(jpeg));
          // Keep whichever read more words (Tesseract on a Latin
          // page can be worse than ML Kit — never blindly prefer it).
          if (_wordCount(tessText) > _wordCount(text)) {
            text = tessText;
            method = OcrMethod.tesseract;
          } else if (containsUrduScript(tessText) &&
              !containsUrduScript(text)) {
            text = tessText;
            method = OcrMethod.tesseract;
          }
        } catch (_) {
          // Tesseract unavailable (no traineddata on device) — the
          // ML Kit text stands, labelled honestly as ML Kit.
        }
      }
      if (bestQualityOcr && visionOcr != null) {
        try {
          final vision = await visionOcr.run(jpeg);
          if (vision.text.trim().isNotEmpty) {
            text = vision.text;
            method = OcrMethod.gemini;
          }
        } catch (_) {
          // No key / no internet — keep the on-device text.
        }
      }
      return (text, method.label);
    }

    void recordOcrPage(int pageNum, String text, String methodLabel) {
      ocrPages.add(pageNum);
      ocrMethods[pageNum] = methodLabel;
      if (assessOcrQuality(text) != OcrQuality.good) {
        poorOcrPages.add(pageNum);
      }
    }

    if (pageCount == 0 || ocrTargets.isNotEmpty) {
      // Pages with no text layer (or no pages found at all, e.g. an
      // object-stream PDF) go through OCR, one page at a time.
      if (ocrTargets.length > maxOcrPagesPerImport) {
        ocrTargets = ocrTargets.sublist(0, maxOcrPagesPerImport);
        ocrCapped = true;
      }
      if (renderPage != null) {
        // Injected renderer (tests).
        for (var i = 0; i < ocrTargets.length; i++) {
          if (isCancelled()) throw const PdfImportCancelled();
          final pageNum = ocrTargets[i];
          onProgress(
            PdfImportProgress(
              stage: 'Scanning page $pageNum of $pageCount…',
              current: i,
              total: ocrTargets.length,
            ),
          );
          try {
            final img = await renderPage(bytes, pageNum);
            if (img == null) continue;
            final (text, methodLabel) = await ocrPage(img);
            if (text.trim().isNotEmpty) {
              pageTexts[pageNum] = text;
              recordOcrPage(pageNum, text, methodLabel);
            }
          } catch (_) {
            // One bad page must not kill the whole import.
            continue;
          }
        }
      } else {
        // Real renderer (pdfx, Android PdfRenderer).
        final doc = await PdfDocument.openData(bytes);
        try {
          if (pageCount == 0) {
            pageCount = doc.pagesCount;
            ocrTargets = List.generate(pageCount, (i) => i + 1);
            if (ocrTargets.length > maxOcrPagesPerImport) {
              ocrTargets = ocrTargets.sublist(0, maxOcrPagesPerImport);
              ocrCapped = true;
            }
            for (var p = 1; p <= pageCount; p++) {
              pageTexts.putIfAbsent(p, () => '');
            }
          }
          for (var i = 0; i < ocrTargets.length; i++) {
            if (isCancelled()) throw const PdfImportCancelled();
            final pageNum = ocrTargets[i];
            onProgress(
              PdfImportProgress(
                stage: 'Scanning page $pageNum of $pageCount…',
                current: i,
                total: ocrTargets.length,
              ),
            );
            try {
              final page = await doc.getPage(pageNum);
              try {
                final height =
                    ocrRenderWidth * page.height / page.width;
                final img = await page.render(
                  width: ocrRenderWidth,
                  height: height,
                  format: PdfPageImageFormat.jpeg,
                  quality: 85,
                  backgroundColor: '#FFFFFF',
                );
                if (img == null) continue;
                final (text, methodLabel) = await ocrPage(img.bytes);
                if (text.trim().isNotEmpty) {
                  pageTexts[pageNum] = text;
                  recordOcrPage(pageNum, text, methodLabel);
                }
              } finally {
                await page.close();
              }
            } catch (_) {
              // One bad page must not kill the whole import.
              continue;
            }
          }
        } finally {
          await doc.close();
        }
      }
    }

    // Re-parse if OCR added any text (or if the text layer was empty).
    // The re-parse gets the pages (not just the joined text) so page
    // numbers and parts survive — the combined text is still computed
    // for PdfImportResult.text.
    if (ocrPages.isNotEmpty || pageCount == 0) {
      onProgress(const PdfImportProgress(stage: 'Parsing MCQs…'));
      final combined = [
        for (var p = 1; p <= pageCount; p++) pageTexts[p] ?? '',
      ].join('\n\n');
      final reparsed = await compute(parseTextInBackground, {
        'pages': [
          for (var p = 1; p <= pageCount; p++)
            {'page': p, 'text': pageTexts[p] ?? ''},
        ],
        'text': combined,
        'sourceId': sourceId,
        'sourceLabel': sourceLabel,
        // Provenance: these pages were OCR'd (scan / camera photo),
        // so a tick/bold mark on them is UNVERIFIED until the user
        // confirms it — see mcq_parser.dart.
        'ocrPages': ocrPages,
      });
      return _resultFromMaps(
        text: combined,
        pageCount: pageCount,
        textPages: textPages,
        ocrPages: ocrPages,
        ocrCapped: ocrCapped,
        maps: reparsed,
        ocrMethods: ocrMethods,
        poorOcrPages: poorOcrPages,
      );
    }

    return _resultFromMaps(
      text: bg['text'] as String,
      pageCount: pageCount,
      textPages: textPages,
      ocrPages: ocrPages,
      ocrCapped: ocrCapped,
      maps: bg,
      ocrMethods: ocrMethods,
      poorOcrPages: poorOcrPages,
    );
  }

  /// Imports a single image (JPG/PNG photo of a book page): the image
  /// goes through the SAME OCR pipeline as a scanned PDF page (ML Kit
  /// → Tesseract eng+urd when Urdu → Gemini vision when best quality
  /// is picked), and the OCR text is parsed with the same page-aware
  /// parser (page 1). The image itself is never stored — only the
  /// parsed MCQs are saved, like a PDF.
  static Future<PdfImportResult> importImage(
    Uint8List bytes, {
    required String sourceId,
    required String sourceLabel,
    required void Function(PdfImportProgress) onProgress,
    required bool Function() isCancelled,
    OcrRunner? runOcr,
    bool urduBook = false,
    bool bestQualityOcr = false,
    OcrRunner? runTesseract,
    GeminiVisionOcr? visionOcr,
  }) async {
    onProgress(const PdfImportProgress(stage: 'Reading image…'));
    if (isCancelled()) throw const PdfImportCancelled();
    // Reuse the PDF OCR tiers by OCR'ing the image bytes directly.
    final mlKit = runOcr ?? _runOcrWithMlKit;
    var text = await mlKit(bytes);
    var method = OcrMethod.mlKit;
    if (urduBook || containsUrduScript(text)) {
      try {
        final tess = runTesseract ?? runTesseractOnBytes;
        // Camera photo: enhance for Tesseract only (see
        // [preprocessForOcr]). ML Kit and Gemini get the raw bytes.
        final tessText = await tess(preprocessForOcr(bytes));
        if (_wordCount(tessText) > _wordCount(text) ||
            (containsUrduScript(tessText) && !containsUrduScript(text))) {
          text = tessText;
          method = OcrMethod.tesseract;
        }
      } catch (_) {
        // Keep the ML Kit text.
      }
    }
    if (bestQualityOcr && visionOcr != null) {
      try {
        final vision = await visionOcr.run(bytes);
        if (vision.text.trim().isNotEmpty) {
          text = vision.text;
          method = OcrMethod.gemini;
        }
      } catch (_) {
        // Keep the on-device text.
      }
    }
    if (isCancelled()) throw const PdfImportCancelled();
    onProgress(const PdfImportProgress(stage: 'Parsing MCQs…'));
    final parsed = await compute(parseTextInBackground, {
      'pages': [
        {'page': 1, 'text': text},
      ],
      'text': text,
      'sourceId': sourceId,
      'sourceLabel': sourceLabel,
      // A single camera photo is ALL OCR — a tick/bold mark on it
      // could be the student's pen, so those questions are
      // UNVERIFIED until the user confirms them.
      'ocrPages': const [1],
    });
    return _resultFromMaps(
      text: text,
      pageCount: 1,
      textPages: 0,
      ocrPages: text.trim().isEmpty ? const [] : const [1],
      ocrCapped: false,
      maps: parsed,
      ocrMethods: text.trim().isEmpty ? const {} : {1: method.label},
      poorOcrPages: assessOcrQuality(text) == OcrQuality.good
          ? const []
          : const [1],
    );
  }

  /// Builds a [PdfImportResult] from a plain-text parse (TXT file or
  /// pasted text) — same result type the PDF path returns, so the upload
  /// screen shows one identical preview for every source.
  static PdfImportResult resultFromTextParse({
    required String text,
    required String sourceId,
    required String sourceLabel,
    required Map<String, dynamic> maps,
  }) {
    return _resultFromMaps(
      text: text,
      pageCount: 0,
      textPages: 0,
      ocrPages: const [],
      ocrCapped: false,
      maps: maps,
    );
  }

  static PdfImportResult _resultFromMaps({
    required String text,
    required int pageCount,
    required int textPages,
    required List<int> ocrPages,
    required bool ocrCapped,
    required Map<String, dynamic> maps,
    Map<int, String> ocrMethods = const {},
    List<int> poorOcrPages = const [],
  }) {
    final questions = (maps['questions'] as List)
        .cast<Map<String, dynamic>>()
        .map(Question.fromMap)
        .toList();
    // Tolerant reads: maps produced before v1.2 (or by the plain-text
    // path) have no 'parts' / key / signal keys.
    final partsRaw = maps['parts'] as List?;
    return PdfImportResult(
      text: text,
      pageCount: pageCount,
      textPages: textPages,
      ocrPages: ocrPages,
      ocrCapped: ocrCapped,
      questions: questions,
      parsed: maps['parsed'] as int,
      skipped: maps['skipped'] as int,
      errors: (maps['errors'] as List).cast<String>(),
      formats: (maps['formats'] as Map).cast<String, int>(),
      generatedOptions: maps['generatedOptions'] as int,
      excluded: (maps['excluded'] as List).cast<String>(),
      parts:
          partsRaw
              ?.cast<Map<String, dynamic>>()
              .map(BookPart.fromMap)
              .toList() ??
          const [],
      keySectionsFound: maps['keySectionsFound'] as int? ?? 0,
      keyEntriesApplied: maps['keyEntriesApplied'] as int? ?? 0,
      questionsMissingAnswers:
          (maps['questionsMissingAnswers'] as List?)?.cast<String>() ??
          const [],
      answerSources:
          (maps['answerSources'] as Map?)?.cast<String, int>() ?? const {},
      conflicts: (maps['conflicts'] as List?)?.cast<String>() ?? const [],
      unmatchedKeyEntries:
          (maps['unmatchedKeyEntries'] as List?)?.cast<String>() ??
          const [],
      notes: (maps['notes'] as List?)?.cast<String>() ?? const [],
      unmatchedNotes:
          (maps['unmatchedNotes'] as List?)?.cast<String>() ?? const [],
      fiveOptionNormalised: maps['fiveOptionNormalised'] as int? ?? 0,
      fiveOptionAnswerE: maps['fiveOptionAnswerE'] as int? ?? 0,
      numberGaps: (maps['numberGaps'] as List?)?.cast<String>() ?? const [],
      numberDuplicates:
          (maps['numberDuplicates'] as List?)?.cast<String>() ?? const [],
      noiseLinesFiltered: maps['noiseLinesFiltered'] as int? ?? 0,
      facts:
          (maps['facts'] as List?)
              ?.cast<Map<String, dynamic>>()
              .map(FactPair.fromMap)
              .toList() ??
          const [],
      answerPending:
          (maps['answerPending'] as List?)
              ?.cast<Map<String, dynamic>>()
              .map(PendingQuestion.fromMap)
              .toList() ??
          const [],
      ocrMethods: ocrMethods,
      poorOcrPages: poorOcrPages,
    );
  }

  /// Word count used to pick the better OCR read (ML Kit vs
  /// Tesseract) for a page — more words usually means more of the
  /// page was actually read.
  static int _wordCount(String text) =>
      text.split(RegExp(r'\s+')).where((w) => w.trim().isNotEmpty).length;

  /// Imports a .docx MCQ bank (v1.2, steer 18): the document is a ZIP
  /// of XML — `word/document.xml` is read in a background isolate
  /// (never on the UI thread), paragraphs become the line stream, and
  /// the result is the SAME [PdfImportResult] the PDF path returns, so
  /// the upload screen shows one identical preview for every source.
  /// A .docx is always text (no OCR): `ocrPages` is empty and
  /// `pageCount` is the number of approximated pages (50 paragraphs
  /// each — see [docxParagraphsPerPage]). Throws [DocxImportException]
  /// (a clear, user-facing message) on a corrupt / empty file.
  static Future<PdfImportResult> importDocx(
    Uint8List bytes, {
    required String sourceId,
    required String sourceLabel,
    required void Function(PdfImportProgress) onProgress,
    required bool Function() isCancelled,
  }) async {
    onProgress(const PdfImportProgress(stage: 'Reading Word document…'));
    final bg = await compute(processDocxInBackground, {'bytes': bytes});
    if (isCancelled()) throw const PdfImportCancelled();
    final pages = (bg['pages'] as List).cast<Map<String, dynamic>>();
    final text = bg['text'] as String;
    final pageCount = bg['pageCount'] as int;
    onProgress(const PdfImportProgress(stage: 'Parsing MCQs…'));
    final parsed = await compute(parseTextInBackground, {
      'pages': pages,
      'text': text,
      'sourceId': sourceId,
      'sourceLabel': sourceLabel,
    });
    return _resultFromMaps(
      text: text,
      pageCount: pageCount,
      textPages: pageCount,
      ocrPages: const [],
      ocrCapped: false,
      maps: parsed,
    );
  }

  /// ML Kit on-device Latin OCR for one JPEG page image.
  static Future<String> _runOcrWithMlKit(Uint8List jpegBytes) async {
    final tmp = File(
      '${Directory.systemTemp.path}/officerpath-ocr-'
      '${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    try {
      await tmp.writeAsBytes(jpegBytes, flush: true);
      final recognizer = TextRecognizer(
        script: TextRecognitionScript.latin,
      );
      try {
        final recognized = await recognizer.processImage(
          InputImage.fromFilePath(tmp.path),
        );
        return recognized.text;
      } finally {
        await recognizer.close();
      }
    } finally {
      try {
        await tmp.delete();
      } catch (_) {}
    }
  }
}
