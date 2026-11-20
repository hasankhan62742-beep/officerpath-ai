import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:pdfx/pdfx.dart';

import '../models/question.dart';
import 'ai_generation.dart';
import 'book_structure.dart';
import 'docx_text_extractor.dart';
import 'gemini_config.dart';
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
    this.keyPaperReport = const [],
    this.ocrMethods = const {},
    this.poorOcrPages = const [],
    this.geminiRequested = false,
    this.geminiPages = 0,
    this.geminiFailure,
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

  /// Plain-language key-paper report for the preview (see
  /// [ParseResult.keyPaperReport]): per-paper attribution plus any
  /// key whose named paper has no questions in the import.
  final List<String> keyPaperReport;

  /// OCR method used per OCR'd page (1-based page → method label,
  /// e.g. "Urdu OCR: device (Tesseract)") — shown in the preview so
  /// the user knows how each scanned page was read.
  final Map<int, String> ocrMethods;

  /// OCR'd pages whose text reads poorly ([OcrQuality.poor] /
  /// unreadable) — the preview flags them honestly and offers
  /// re-scan / Gemini best-quality instead of storing garbage.
  final List<int> poorOcrPages;

  /// Gemini "best quality" was requested for this import (the user
  /// ticked the checkbox). Recorded so the preview can say, honestly,
  /// whether Gemini actually ran — see [geminiPages] /
  /// [geminiFailure]. False when the user did not tick best quality
  /// (Gemini was never attempted) or the source has no OCR pages.
  final bool geminiRequested;

  /// OCR'd pages Gemini vision actually read (method "Gemini").
  /// When [geminiRequested] is true and this is 0, Gemini ran on
  /// NO page — the result is entirely on-device OCR and the preview
  /// must say so with the reason ([geminiFailure]), never present
  /// the ML Kit result as a Gemini result.
  final int geminiPages;

  /// Why Gemini did not run on some page (first failure across the
  /// import), when it was requested. Null when Gemini was not
  /// requested, or when it ran without failing. The kind carries the
  /// concrete next step (noKey → enter the key in Settings;
  /// noInternet → check the connection; quota → free limit
  /// reached). When [geminiPages] is 0 the failure is total; when
  /// it is between 1 and [ocrPages].length - 1 the run was partial.
  final GeminiFailureKind? geminiFailure;

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
    // A page counts as a text page ONLY when its text layer is real
    // content: enough words to be a question page, and not the same
    // short stamp repeated on most pages (a scanner watermark or a
    // running header). No watermark word is named — the rule is
    // word-count + repetition only, so it holds for any stamp text.
    // A watermark-only page (1–2 words) or a repeated stamp goes to
    // OCR exactly like an empty page: a watermark must never be the
    // reason OCR does not run. Pages are counted BEFORE OCR runs, so
    // the number means what it says even after OCR fills the gaps.
    final stamps = stampPages(pageTexts);
    bool isTextPage(MapEntry<int, String> e) =>
        pageTextIsContent(e.value) && !stamps.contains(e.key);
    final textPages = pageTexts.entries.where(isTextPage).length;
    var ocrTargets = pageTexts.entries
        .where((e) => !isTextPage(e))
        .map((e) => e.key)
        .toList();

    final ocrPages = <int>[];
    final ocrMethods = <int, String>{};
    final poorOcrPages = <int>[];
    var ocrCapped = false;
    // Gemini honesty (20 Nov 2026): a best-quality failure used to
    // be swallowed silently and the ML Kit text presented as the
    // result. Record the first failure + how many pages Gemini
    // actually read, so the preview can say so plainly.
    GeminiFailureKind? geminiFailureKind;
    var geminiPages = 0;

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
            geminiPages++;
          }
        } on GeminiException catch (e) {
          // No key / no internet / quota / bad key — keep the
          // on-device text, but RECORD the failure (first one wins)
          // so the preview can tell the user Gemini did not run and
          // why. Never silently present ML Kit text as Gemini's.
          geminiFailureKind ??= e.kind;
        } catch (_) {
          // Any other vision failure — same honest treatment, kind
          // unknown (the on-device text still stands).
          geminiFailureKind ??= GeminiFailureKind.unknown;
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
        geminiRequested: bestQualityOcr,
        geminiPages: geminiPages,
        geminiFailure: geminiFailureKind,
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
      geminiRequested: bestQualityOcr,
      geminiPages: geminiPages,
      geminiFailure: geminiFailureKind,
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
    // Gemini honesty (20 Nov 2026): same recording as the PDF path
    // — a silent best-quality failure must reach the preview.
    GeminiFailureKind? geminiFailureKind;
    var geminiPages = 0;
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
          geminiPages++;
        }
      } on GeminiException catch (e) {
        geminiFailureKind ??= e.kind;
      } catch (_) {
        geminiFailureKind ??= GeminiFailureKind.unknown;
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
      geminiRequested: bestQualityOcr,
      geminiPages: geminiPages,
      geminiFailure: geminiFailureKind,
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

  /// Reads the RAW TEXT of a separately attached answer-key file
  /// (20 Nov 2026, "Jawab wali key attach karein") — a key photo, a
  /// key PDF, a DOCX, or a TXT key. The file goes through the SAME
  /// import path the book import uses ([importPdf] / [importImage] /
  /// [importDocx] — same OCR tiers, same text extraction; no new OCR
  /// engine), and only the `.text` is kept: the caller parses key
  /// entries out of it with `parseKeyEntries` via `applyAttachedKey`
  /// (see `answer_key.dart`). The MCQ parse the import also runs is
  /// discarded — a key page is not a question bank. Throws the same
  /// exceptions the import throws (corrupt file, cancelled) so the
  /// caller can report them plainly.
  static Future<String> extractKeyText(
    Uint8List bytes, {
    required String extension,
    void Function(PdfImportProgress)? onProgress,
    bool Function()? isCancelled,
    bool urduBook = false,
    bool bestQualityOcr = false,
    GeminiVisionOcr? visionOcr,
  }) async {
    final progress = onProgress ?? (_) {};
    final cancelled = isCancelled ?? () => false;
    switch (extension) {
      case 'pdf':
        return (await importPdf(
          bytes,
          sourceId: 'key-attach',
          sourceLabel: 'Answer key',
          onProgress: progress,
          isCancelled: cancelled,
          urduBook: urduBook,
          bestQualityOcr: bestQualityOcr,
          visionOcr: visionOcr,
        )).text;
      case 'jpg':
      case 'jpeg':
      case 'png':
        return (await importImage(
          bytes,
          sourceId: 'key-attach',
          sourceLabel: 'Answer key',
          onProgress: progress,
          isCancelled: cancelled,
          urduBook: urduBook,
          bestQualityOcr: bestQualityOcr,
          visionOcr: visionOcr,
        )).text;
      case 'docx':
        return (await importDocx(
          bytes,
          sourceId: 'key-attach',
          sourceLabel: 'Answer key',
          onProgress: progress,
          isCancelled: cancelled,
        )).text;
      default:
        // TXT (and anything else the picker allowed): plain text.
        return utf8.decode(bytes, allowMalformed: true);
    }
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
    bool geminiRequested = false,
    int geminiPages = 0,
    GeminiFailureKind? geminiFailure,
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
      keyPaperReport:
          (maps['keyPaperReport'] as List?)?.cast<String>() ?? const [],
      ocrMethods: ocrMethods,
      poorOcrPages: poorOcrPages,
      geminiRequested: geminiRequested,
      geminiPages: geminiPages,
      geminiFailure: geminiFailure,
    );
  }

  /// Word count used to pick the better OCR read (ML Kit vs
  /// Tesseract) for a page — more words usually means more of the
  /// page was actually read.
  static int _wordCount(String text) =>
      text.split(RegExp(r'\s+')).where((w) => w.trim().isNotEmpty).length;

  /// Minimum words for a page's text layer to count as real content.
  /// A scanned page's text layer is typically a one-word stamp per
  /// page; a genuine question page carries a stem plus four options
  /// (~15+ words even for a single short MCQ), so 10 keeps every
  /// complete question page as text while watermark/header-only
  /// pages go to OCR. A page with only a short stem fragment
  /// (options on the next page) can fall below the bar — OCR then
  /// re-reads the same words off the rendered page, so the cost is
  /// one extra OCR pass, never a lost question.
  static const int minTextLayerWords = 10;

  /// Whether one page's extracted text looks like real content
  /// rather than a stamp: at least [minTextLayerWords] words.
  /// Generic — no watermark word is named anywhere.
  static bool pageTextIsContent(String text) =>
      _wordCount(text) >= minTextLayerWords;

  /// Pages whose whole text layer is the SAME short text on most
  /// pages of the document — a running header/footer or a scanner
  /// stamp repeated verbatim on every page. The rule is repetition
  /// + brevity only (same text on at least 3 pages and at least half
  /// the document, under 50 words); no stamp text is named, so it
  /// holds for any watermark. A genuine question page is never
  /// identical to most other pages, and a full page of questions is
  /// far longer than 50 words, so a real page cannot trip this.
  /// Returns the 1-based page numbers that are stamps.
  static Set<int> stampPages(Map<int, String> pageTexts) {
    if (pageTexts.length < 3) return {};
    final counts = <String, int>{};
    for (final t in pageTexts.values) {
      final key = t.trim().toLowerCase();
      if (key.isEmpty) continue;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    final stamped = <int>{};
    for (final e in pageTexts.entries) {
      final key = e.value.trim().toLowerCase();
      final n = counts[key] ?? 0;
      if (n >= 3 &&
          n * 2 >= pageTexts.length &&
          _wordCount(e.value) < 50) {
        stamped.add(e.key);
      }
    }
    return stamped;
  }

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
        // Two-column pages: ML Kit's raw text interleaves the
        // columns, so stems get separated from their options and
        // asterisk answers get detached. Order the lines
        // top-to-bottom and split the columns first — the parser's
        // contract. A table page spans the full width, so it is
        // detected FIRST: the column split would destroy its rows.
        // Any failure here falls back to the raw text, never to a
        // lost page.
        try {
          final lines =
              <({String text, double x, double y, double width})>[];
          final elements = <({
            String text,
            double x,
            double y,
            double width,
            double height
          })>[];
          for (final block in recognized.blocks) {
            for (final line in block.lines) {
              final text = line.text.trim();
              if (text.isEmpty) continue;
              final box = line.boundingBox;
              lines.add((
                text: text,
                x: box.left,
                y: box.top,
                width: box.right - box.left,
              ));
              for (final el in line.elements) {
                final elText = el.text.trim();
                if (elText.isEmpty) continue;
                final ebox = el.boundingBox;
                elements.add((
                  text: elText,
                  x: ebox.left,
                  y: ebox.top,
                  width: ebox.right - ebox.left,
                  height: ebox.bottom - ebox.top,
                ));
              }
            }
          }
          final table = reconstructTableText(elements);
          if (table != null) return table;
          return columnSplitOcrText(recognized.text, lines);
        } catch (_) {
          return recognized.text;
        }
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
