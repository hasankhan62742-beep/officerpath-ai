import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/exam.dart';
import '../models/question.dart';
import '../services/book_selection.dart';
import '../services/docx_text_extractor.dart';
import '../services/pdf_import_service.dart';
import '../services/pdf_text_extractor.dart';
import '../services/storage_service.dart';
import '../services/subscription_service.dart';
import '../services/urdu_ocr.dart';
import '../widgets/developer_credit_footer.dart';
import '../widgets/upgrade_button.dart';
import 'ai_settings_screen.dart';
import 'book_selection_screen.dart';
import 'upgrade_screen.dart';

/// My Books & Past Papers — upload a PDF/TXT, or paste MCQ text.
/// Parsed questions are previewed (count + format breakdown) BEFORE
/// saving.
///
/// STORAGE DESIGN (on-device-first):
/// * The original PDF is NEVER uploaded anywhere — it stays on the
///   student's own phone. Only the extracted MCQs (plain text) are stored
///   in the app database. 1,000 MCQs ≈ 200–300 KB.
/// * v1 limits: max 100 MB per file, PDF/TXT only, max 5 books on Free
///   (Premium: unlimited).
///
/// HOW A PDF IS READ (fixed 18 Nov — the ANR bug):
/// * Text extraction + parsing run in a background isolate via
///   [PdfImportService] — the UI thread is never blocked, so Android
///   can never show "isn't responding" for a PDF, whatever its size.
/// * Pages with no text layer (scanned / image PDFs) are rendered and
///   read with on-device OCR (ML Kit, Latin/English text only — a
///   scanned Urdu-script book still cannot be read; that is stated
///   honestly wherever it matters). OCR runs one page at a time with
///   per-page progress and a Cancel button.
/// * Books come in different shapes: standard blocks, one-line
///   questions, and Q&A without options (options are built from the
///   book's own answers). See `mcq_parser.dart`.
class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  List<BookSource> _sources = [];
  bool _loading = true;
  bool _isParsing = false;
  PdfImportProgress? _progress;
  bool _cancelRequested = false;
  String _kind = 'book';
  // v1.2 two-tier OCR choices (persist per session, not per book):
  // Urdu book → Tesseract eng+urd first; best quality → Gemini
  // vision (needs a key — the import falls back silently without one).
  bool _urduBook = false;
  bool _bestQualityOcr = false;
  final _titleController = TextEditingController();
  final _pasteController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _pasteController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final sources = await StorageService.instance.getSources();
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _loading = false;
    });
  }

  int get _customBookCount =>
      _sources.where((s) => !s.isBuiltIn).length;

  Future<bool> _checkBookQuota() async {
    final canAdd = await SubscriptionService.instance.canAddBook(
      _customBookCount,
    );
    if (canAdd) return true;
    if (!mounted) return false;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Book limit reached'),
        content: const Text(
          'Free plan allows up to ${SubscriptionService.freeBookLimit} books. '
          'Upgrade to Premium for unlimited books.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('See Premium'),
          ),
        ],
      ),
    );
    if (go == true && mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const UpgradeScreen()),
      );
    }
    return false;
  }

  void _setProgress(PdfImportProgress p) {
    if (mounted) setState(() => _progress = p);
  }

  Future<void> _pickFile() async {
    if (_isParsing) return;
    if (!await _checkBookQuota()) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      // v1.2 (agent A gap): 'docx' added; JPG/PNG photos of a book
      // page go through the same OCR pipeline as a scanned PDF.
      allowedExtensions: ['pdf', 'txt', 'docx', 'jpg', 'jpeg', 'png'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      _showMessage('Could not read this file. Try again.');
      return;
    }
    // v1 limit: max 100 MB per book file.
    if (file.size > SubscriptionService.maxBookFileBytes) {
      _showMessage(
        'This file is ${(file.size / (1024 * 1024)).toStringAsFixed(0)} MB — '
        'over the 100 MB limit. Split the book into smaller parts, or use a '
        'text file with just the MCQs.',
      );
      return;
    }
    final ext = (file.extension ?? '').toLowerCase();
    const supported = {'pdf', 'txt', 'docx', 'jpg', 'jpeg', 'png'};
    if (!supported.contains(ext)) {
      _showMessage('Only PDF, TXT, DOCX and JPG/PNG files are supported.');
      return;
    }
    final title = _titleController.text.trim().isEmpty
        ? file.name
        : _titleController.text.trim();
    // One id for the whole import — the questions and the book source
    // must carry the SAME id (v1 generated two different ones).
    final sourceId = 'user-${DateTime.now().millisecondsSinceEpoch}';
    setState(() {
      _isParsing = true;
      _cancelRequested = false;
      _progress = const PdfImportProgress(stage: 'Reading file…');
    });
    try {
      late final PdfImportResult imported;
      if (ext == 'pdf') {
        imported = await PdfImportService.importPdf(
          bytes,
          sourceId: sourceId,
          sourceLabel: title,
          onProgress: _setProgress,
          isCancelled: () => _cancelRequested,
          urduBook: _urduBook,
          bestQualityOcr: _bestQualityOcr,
          visionOcr: _bestQualityOcr ? GeminiVisionOcr() : null,
        );
      } else if (ext == 'docx') {
        imported = await PdfImportService.importDocx(
          bytes,
          sourceId: sourceId,
          sourceLabel: title,
          onProgress: _setProgress,
          isCancelled: () => _cancelRequested,
        );
      } else if (ext == 'jpg' || ext == 'jpeg' || ext == 'png') {
        imported = await PdfImportService.importImage(
          bytes,
          sourceId: sourceId,
          sourceLabel: title,
          onProgress: _setProgress,
          isCancelled: () => _cancelRequested,
          urduBook: _urduBook,
          bestQualityOcr: _bestQualityOcr,
          visionOcr: _bestQualityOcr ? GeminiVisionOcr() : null,
        );
      } else {
        _setProgress(
          const PdfImportProgress(stage: 'Parsing MCQs…'),
        );
        final text = utf8.decode(bytes, allowMalformed: true);
        final maps = await compute(parseTextInBackground, {
          'text': text,
          'sourceId': sourceId,
          'sourceLabel': title,
        });
        imported = PdfImportService.resultFromTextParse(
          text: text,
          sourceId: sourceId,
          sourceLabel: title,
          maps: maps,
        );
      }
      await _importResult(imported, title, sourceId);
    } on PdfImportCancelled {
      _showMessage('Import cancelled.');
    } on CorruptPdfException catch (e) {
      // v2 Req A: a corrupt file is a failure path, not a snackbar —
      // the user gets a dialog with the plain reason + the concrete
      // next step (re-download, or a text PDF / TXT / paste instead).
      // No AI option: there is no text to generate from.
      if (mounted) await showFileFailureDialog(context, e.message);
    } on DocxImportException catch (e) {
      if (mounted) await showFileFailureDialog(context, e.message);
    } catch (e) {
      if (mounted) {
        await showFileFailureDialog(
          context,
          'Could not read this file: $e',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isParsing = false;
          _progress = null;
        });
      }
    }
  }

  /// Shows the preview (count + format breakdown) and saves on confirm.
  /// When nothing parsed, shows the dead-end-free dialog instead.
  /// Before saving, the selection screen offers the detected parts +
  /// a page range (v1.2) — the saved bank is ONLY the selection.
  Future<void> _importResult(
    PdfImportResult result,
    String title,
    String sourceId,
  ) async {
    if (!mounted) return;
    if (result.parsed == 0) {
      await _showNoMcqsDialog(result, title, sourceId);
      return;
    }
    var working = result;
    // Selection step (only when there is something to select between).
    if (result.parts.length > 1 || result.pageCount > 1) {
      final selection = await Navigator.push<BookSelection>(
        context,
        MaterialPageRoute(
          builder: (_) => BookSelectionScreen(
            parts: result.parts,
            totalPages: result.pageCount,
            title: 'Kis hisse save karein?',
          ),
        ),
      );
      if (selection == null) return; // User cancelled — nothing saved.
      if (!mounted) return;
      if (!selection.isWholeBook) {
        final filtered = selection.apply(result.questions);
        if (filtered.isEmpty) {
          _showMessage(
            'Selection mein koi MCQ nahi — dobara chunein ya poori book lein.',
          );
          return;
        }
        working = _withQuestions(result, filtered);
      }
    }
    // MPT fit (v1.2): an MPT-titled book suggests the CSS MPT pattern
    // (200 Q / 200 min) instead of the PPSC default.
    final mptSuggestion = ExamPattern.suggestForTitle(title);
    final lines = <String>[
      'Parsed ${working.parsed} MCQs from "$title".',
      '',
      'Formats found:',
      '• Standard blocks: ${working.formats['block'] ?? 0}',
      '• One-line questions: ${working.formats['one-liner'] ?? 0}',
      '• Q&A without options: ${working.formats['q-only'] ?? 0}',
    ];
    // G8 (Phase A): the preview used to omit the table and flashcard
    // counts — a grammar-table book showed "0" everywhere. Table
    // rows come from formats['table']; flashcards are the q-only
    // questions whose answerSource is 'flashcard'.
    final tableCount = working.formats['table'] ?? 0;
    final flashcardCount = working.questions
        .where((q) => q.answerSource == 'flashcard')
        .length;
    if (tableCount > 0) lines.add('• Table rows: $tableCount');
    if (flashcardCount > 0) lines.add('• Flashcards: $flashcardCount');
    if (working.generatedOptions > 0) {
      lines.add(
        '• ${working.generatedOptions} question(s) got their options from '
        'other answers in this book.',
      );
    }
    if (working.answerSources.isNotEmpty) {
      lines.add(
        '• Answers: ${working.answerSources.entries.map((e) => '${e.value} ${e.key} se').join(', ')}.',
      );
    }
    // Verification + confidence (governing spec 19 Nov 2026): the
    // preview shows how many answers are verified (from the book's
    // own printed signal) and how many are unverified (AI-inferred,
    // conflicting signals, or an OCR-sourced tick/bold that could be
    // the student's pen) — unverified answers are never presented as
    // correct without review. The per-question confidence score
    // (0–1, from the answer source) and the full per-question
    // preview live in the v2 extraction preview.
    final verifiedCount =
        working.questions.where((q) => q.answerVerified).length;
    final unverifiedCount = working.parsed - verifiedCount;
    final avgConfidence = working.questions.isEmpty
        ? 0.0
        : working.questions.map((q) => q.confidence).reduce((a, b) => a + b) /
              working.questions.length;
    lines.add(
      '• Verification: $verifiedCount verified, $unverifiedCount '
      'unverified (avg confidence ${(avgConfidence * 100).round()}%).',
    );
    if (unverifiedCount > 0) {
      lines.add(
        '• Unverified jawab test mein "unverified" ke tor par dikhaye '
        'jate hain — "Jawab khud lagayein" se aap unhein theek kar '
        'sakte hain.',
      );
    }
    // G-C6 (Phase A): OCR-sourced answers must be VISIBLE as
    // low-confidence, not just stored in the model. The count is
    // here; each such question also carries its warning in the
    // per-question preview below (ExtractionPreviewDialog).
    final ocrUnverifiedCount = working.questions
        .where((q) => q.markProvenance == 'ocr' && !q.answerVerified)
        .length;
    if (ocrUnverifiedCount > 0) {
      lines.add(
        '• $ocrUnverifiedCount jawab OCR (scan / camera photo) se '
        'hain aur UNVERIFIED hain — neeche har question par unki '
        'warning dekhein, aur ghalat jawab ko "Jawab theek karein" '
        'se theek karein.',
      );
    }
    if (working.ocrPages.isNotEmpty) {
      lines.add(
        '• Scanned pages read with OCR: ${working.ocrPages.length} '
        '(${working.ocrMethods.values.toSet().join(', ')}).',
      );
    }
    if (working.poorOcrPages.isNotEmpty) {
      lines.add(
        '• ${working.poorOcrPages.length} page(s) theek se parhe nahi '
        'gaye (pages ${working.poorOcrPages.join(', ')}) — dobara scan '
        'karein ya "Behtar quality (Gemini)" try karein.',
      );
    }
    if (working.ocrCapped) {
      lines.add(
        '• Only the first ${PdfImportService.maxOcrPagesPerImport} '
        'scanned pages were read — split the book to read the rest.',
      );
    }
    if (working.answerPending.isNotEmpty) {
      lines.add(
        '• ${working.answerPending.length} question(s) ke jawab nahi '
        'mile (options hain, answer nahi) — "Jawab khud lagayein" se '
        'aap khud sahi option chun sakte hain. UNVERIFIED jawab kabhi '
        'AI se nahi nikale jate.',
      );
    }
    if (working.skipped > 0) {
      lines.add(
        'Skipped ${working.skipped} block(s) (missing options/answer).',
      );
    }
    // Numbering gaps + duplicates (19 Nov 2026 — MCQ numbering
    // rule): a question number missing between two parsed questions,
    // or a number parsed twice, is reported here WITH page numbers,
    // never silently skipped or merged. The strings come from the
    // parser (`numberGaps` / `numberDuplicates`).
    if (working.numberGaps.isNotEmpty) {
      lines.add('');
      lines.add('Numbering gaps (missing questions):');
      lines.addAll(working.numberGaps.take(5));
    }
    if (working.numberDuplicates.isNotEmpty) {
      lines.add('');
      lines.add('Duplicated question numbers (both copies kept):');
      lines.addAll(working.numberDuplicates.take(5));
    }
    if (working.excluded.isNotEmpty) {
      lines.add('');
      lines.add('Not imported:');
      lines.addAll(working.excluded.take(3));
    }
    if (working.errors.isNotEmpty) {
      lines.add('');
      lines.addAll(working.errors.take(3));
    }
    // Per-question preview (Phase A, v2): the dialog below shows
    // every question with its options, detected answer, source page,
    // confidence and verification status — and lets the user correct
    // an already-answered question in place (G-M3). The decision it
    // returns carries the (possibly corrected) question list, so a
    // correction is never lost on the way to Save.
    final decision = await showDialog<PreviewDecision>(
      context: context,
      builder: (ctx) => ExtractionPreviewDialog(
        result: working,
        summaryLines: lines,
        showManual: working.answerPending.isNotEmpty,
        showMpt: mptSuggestion != null,
      ),
    );
    if (decision == null || decision.action == 'cancel') return;
    final corrected = _withQuestions(working, decision.questions);
    if (decision.action == 'manual') {
      await _runManualCorrection(corrected, title, sourceId);
      return;
    }
    if (decision.action == 'mpt') {
      await StorageService.instance.setLastExamId('css_mpt');
      if (mounted) {
        _showMessage(
          'CSS MPT pattern set (200 MCQs • 200 min). Ab Save karein.',
        );
      }
      // Re-show the preview so the user still saves explicitly.
      await _importResult(corrected, title, sourceId);
      return;
    }
    if (decision.action != 'save') return;
    final source = BookSource(
      id: sourceId,
      title: title,
      kind: _kind,
      addedAtIso: DateTime.now().toIso8601String(),
    );
    await StorageService.instance.addSource(source, corrected.questions);
    _titleController.clear();
    _pasteController.clear();
    await _load();
    if (mounted) {
      _showMessage('Saved ${corrected.parsed} MCQs from "$title".');
    }
  }

  /// Returns a copy of [result] with [questions] replaced (used after
  /// selection filtering and manual correction). The diagnostics
  /// (parts, sources, pending) stay from the original parse, except
  /// `answerPending` which becomes [remainingPending] when given
  /// (the questions the user left unanswered stay pending).
  PdfImportResult _withQuestions(
    PdfImportResult result,
    List<Question> questions, {
    List<PendingQuestion>? remainingPending,
  }) {
    return PdfImportResult(
      text: result.text,
      pageCount: result.pageCount,
      textPages: result.textPages,
      ocrPages: result.ocrPages,
      ocrCapped: result.ocrCapped,
      questions: questions,
      parsed: questions.length,
      skipped: result.skipped,
      errors: result.errors,
      formats: result.formats,
      generatedOptions: result.generatedOptions,
      excluded: result.excluded,
      parts: result.parts,
      keySectionsFound: result.keySectionsFound,
      keyEntriesApplied: result.keyEntriesApplied,
      questionsMissingAnswers: result.questionsMissingAnswers,
      answerSources: result.answerSources,
      conflicts: result.conflicts,
      unmatchedKeyEntries: result.unmatchedKeyEntries,
      notes: result.notes,
      unmatchedNotes: result.unmatchedNotes,
      fiveOptionNormalised: result.fiveOptionNormalised,
      fiveOptionAnswerE: result.fiveOptionAnswerE,
      numberGaps: result.numberGaps,
      numberDuplicates: result.numberDuplicates,
      noiseLinesFiltered: result.noiseLinesFiltered,
      facts: result.facts,
      answerPending: remainingPending ?? result.answerPending,
      ocrMethods: result.ocrMethods,
      poorOcrPages: result.poorOcrPages,
    );
  }

  /// Manual correction for [PdfImportResult.answerPending] (governing
  /// spec 19 Nov 2026 — AI generation/inference is PARKED, never the
  /// extraction path): the user picks the correct option for each
  /// question whose answer the book did not give. Questions the user
  /// does not answer stay pending — never guessed, never sent to AI.
  /// Manually set answers are saved with answerSource 'manual' (the
  /// book gave NO original answer for these, so there is nothing to
  /// keep separate here; correcting an already-answered question is
  /// a separate gap — see docs/extraction-audit.md). Merged answers
  /// re-open the preview.
  Future<void> _runManualCorrection(
    PdfImportResult result,
    String title,
    String sourceId,
  ) async {
    if (result.answerPending.isEmpty) return;
    final chosen = await showDialog<Map<int, int>>(
      context: context,
      builder: (ctx) =>
          ManualCorrectionDialog(pending: result.answerPending),
    );
    if (chosen == null || chosen.isEmpty || !mounted) return;
    final manual = <Question>[];
    final still = <PendingQuestion>[];
    for (var i = 0; i < result.answerPending.length; i++) {
      final p = result.answerPending[i];
      final c = chosen[i];
      if (c == null) {
        still.add(p);
        continue;
      }
      manual.add(
        Question(
          text: p.text,
          options: p.options,
          correctIndex: c,
          subject: p.subject,
          sourceId: sourceId,
          sourceLabel: title,
          explanation: p.explanation,
          page: p.page,
          part: p.part,
          answerSource: 'manual',
        ),
      );
    }
    _showMessage(
      '${manual.length} jawab aap ne lagaye'
      '${still.isNotEmpty ? ', ${still.length} abhi bhi UNVERIFIED hain' : ''}.',
    );
    final next = _withQuestions(
      result,
      [...result.questions, ...manual],
      remainingPending: still,
    );
    await _importResult(next, title, sourceId);
  }

  /// The "No MCQs found" dialog is NEVER a dead end. It offers:
  /// (a) MANUAL CORRECTION ("Jawab khud lagayein") when the parse
  /// found questions without answers — the user picks the correct
  /// option; unverified answers are NEVER sent to AI (governing
  /// spec 19 Nov 2026: AI generation/inference is parked),
  /// (b) plain-language diagnostics (pages, text vs OCR, key
  /// found/not found, questions without answers, answer-source
  /// counts), (c) "Try TXT / paste" guidance. An admission letter
  /// gets its own honest message and its text is never previewed
  /// (privacy: it carries personal details) and never persisted.
  /// See [NoMcqsDialog] — the dialog itself is a public widget so
  /// widget tests can assert Req A (reason + next step + manual
  /// correction option).
  Future<void> _showNoMcqsDialog(
    PdfImportResult result,
    String title,
    String sourceId,
  ) async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => NoMcqsDialog(result: result),
    );
    if (action == 'manual') {
      await _runManualCorrection(result, title, sourceId);
    }
  }

  Future<void> _parsePastedText() async {
    if (_isParsing) return;
    final text = _pasteController.text;
    if (text.trim().isEmpty) {
      _showMessage('Paste your MCQ text first.');
      return;
    }
    if (!await _checkBookQuota()) return;
    final title = _titleController.text.trim().isEmpty
        ? 'Pasted MCQs'
        : _titleController.text.trim();
    final sourceId = 'user-${DateTime.now().millisecondsSinceEpoch}';
    setState(() {
      _isParsing = true;
      _cancelRequested = false;
      _progress = const PdfImportProgress(stage: 'Parsing MCQs…');
    });
    try {
      final maps = await compute(parseTextInBackground, {
        'text': text,
        'sourceId': sourceId,
        'sourceLabel': title,
      });
      final result = PdfImportService.resultFromTextParse(
        text: text,
        sourceId: sourceId,
        sourceLabel: title,
        maps: maps,
      );
      await _importResult(result, title, sourceId);
    } finally {
      if (mounted) {
        setState(() {
          _isParsing = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _deleteSource(BookSource source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${source.title}"?'),
        content: Text(
          'This removes ${source.questionCount} MCQs from your bank.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await StorageService.instance.deleteSource(source.id);
      await _load();
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Books & Past Papers'),
        // v1.2 (user): RED UPGRADE button, top corner.
        actions: const [UpgradeAppBarButton()],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_isParsing)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _progress?.stage ??
                                      'Parsing your book…',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: () {
                                  setState(
                                    () => _cancelRequested = true,
                                  );
                                },
                                child: const Text('Cancel'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: _progress?.fraction,
                          ),
                          if (_progress != null &&
                              _progress!.total > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '${_progress!.current} / ${_progress!.total}',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Add your book',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'MCQ book ho ya past papers — PDF, TXT ya DOCX '
                          'upload karein, book page ki photo (JPG/PNG) '
                          'lein, ya text paste karein. Max 100 MB per file. '
                          'Your PDF stays on your phone — only the extracted '
                          'MCQs are stored in the app (1,000 MCQs ≈ 200–300 KB). '
                          'Scanned pages on-device OCR se parhe jate hain '
                          '(English: ML Kit; Urdu: Tesseract, free + '
                          'offline) — dense Urdu scans ke liye "Behtar '
                          'quality (Gemini)" hai.',
                        ),
                        const SizedBox(height: 12),
                        // v1.2 two-tier OCR choices for scanned books.
                        CheckboxListTile(
                          value: _urduBook,
                          onChanged: (v) =>
                              setState(() => _urduBook = v ?? false),
                          title: const Text('Urdu book (scanned)'),
                          subtitle: const Text(
                            'Urdu OCR: device (Tesseract, free + offline). '
                            'Dense Nastaliq scans par behtar quality ke '
                            'liye Gemini chahiye.',
                          ),
                          controlAffinity: ListTileControlAffinity.leading,
                          contentPadding: EdgeInsets.zero,
                        ),
                        CheckboxListTile(
                          value: _bestQualityOcr,
                          onChanged: (v) => setState(
                            () => _bestQualityOcr = v ?? false,
                          ),
                          title: const Text(
                            'Behtar quality (Gemini)',
                          ),
                          subtitle: const Text(
                            'Scanned pages Gemini vision se parhein — '
                            'key + internet chahiye.',
                          ),
                          controlAffinity: ListTileControlAffinity.leading,
                          contentPadding: EdgeInsets.zero,
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const AiSettingsScreen(),
                                ),
                              );
                            },
                            icon: const Icon(Icons.smart_toy),
                            label: const Text(
                              'AI Settings — Gemini key',
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _titleController,
                          decoration: const InputDecoration(
                            labelText: 'Title — e.g. PPSC Past Papers 2024',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(
                              value: 'book',
                              label: Text('Book'),
                            ),
                            ButtonSegment(
                              value: 'past_paper',
                              label: Text('Past Paper'),
                            ),
                            ButtonSegment(
                              value: 'topic',
                              label: Text('Topic'),
                            ),
                          ],
                          selected: {_kind},
                          onSelectionChanged: (s) =>
                              setState(() => _kind = s.first),
                        ),
                        const SizedBox(height: 12),
                        // v1.2: the two buttons stack on narrow phones —
                        // side-by-side they clipped at 360px.
                        LayoutBuilder(
                          builder: (ctx, constraints) {
                            final narrow = constraints.maxWidth < 400;
                            final buttons = [
                              SizedBox(
                                width: narrow ? double.infinity : null,
                                child: FilledButton.icon(
                                  onPressed: _isParsing ? null : _pickFile,
                                  icon: const Icon(Icons.upload_file),
                                  label: const Text(
                                    'Pick PDF / TXT / DOCX / Image',
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: narrow ? double.infinity : null,
                                child: OutlinedButton.icon(
                                  onPressed: _isParsing
                                      ? null
                                      : _parsePastedText,
                                  icon: const Icon(Icons.paste),
                                  label: const Text('Parse pasted text'),
                                ),
                              ),
                            ];
                            if (narrow) {
                              return Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.stretch,
                                children: [
                                  buttons[0],
                                  const SizedBox(height: 8),
                                  buttons[1],
                                ],
                              );
                            }
                            return Row(
                              children: [
                                Expanded(child: buttons[0]),
                                const SizedBox(width: 8),
                                Expanded(child: buttons[1]),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _pasteController,
                          maxLines: 5,
                          decoration: const InputDecoration(
                            labelText: 'Or paste MCQ text here',
                            hintText:
                                'Q1. What is the capital of Pakistan?\nA) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\nAnswer: C\nExplanation: ...',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Formats accepted: standard blocks (Q + 4 options '
                          '+ "Answer: C"), one-line questions '
                          '"(a) Lahore (b) Karachi (c) Islamabad (d) Quetta" '
                          'with "Ans: (c)"), and Q&A without options '
                          '("Q … Ans: Islamabad" — options are built from '
                          'other answers in the same book). A sample file is '
                          'bundled in the app assets (assets/sample_books/). '
                          'AI se MCQs nahi banaye jate — sirf is text mein '
                          'maujood questions save hote hain.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Your sources (${_sources.length}) — '
                  'your books: $_customBookCount / ${SubscriptionService.freeBookLimit} on Free',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                ..._sources.map(
                  (s) => Card(
                    child: ListTile(
                      leading: Icon(
                        s.kind == 'past_paper'
                            ? Icons.description
                            : s.kind == 'sample'
                                ? Icons.school
                                : Icons.book,
                      ),
                      title: Text(s.title),
                      subtitle: Text(
                        '${s.kindLabel} • ${s.questionCount} MCQs'
                        '${s.isBuiltIn ? ' • Built-in sample' : ''}',
                      ),
                      trailing: s.isBuiltIn
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: 'Delete',
                              onPressed: () => _deleteSource(s),
                            ),
                    ),
                  ),
                ),
                // v1.2: developer credit — last item of the scroll view.
                const DeveloperCreditFooter(),
              ],
            ),
    );
  }
}

/// "No MCQs found" dialog (v2 Req A, governing spec 19 Nov 2026) —
/// NEVER a dead end. Every failure shows ALL THREE: (1) what went
/// wrong in plain words, (2) the concrete next step — which format
/// to re-make the book in and how to upload it so it works — plus
/// what the app already tried, and (3) the MANUAL CORRECTION option
/// where it applies (when the parse found questions without
/// answers). AI generation is PARKED — the dialog never offers it.
/// Pops 'manual' / 'close'. A public widget so widget tests can
/// assert its contents.
class NoMcqsDialog extends StatelessWidget {
  const NoMcqsDialog({super.key, required this.result});

  final PdfImportResult result;

  @override
  Widget build(BuildContext context) {
    final isLetter = isAdmissionLetterText(result.text);
    final diagnostics = <String>[
      'Pages parhe gaye: ${result.pageCount} '
      '(text pages: ${result.textPages}, OCR pages: ${result.ocrPages.length})',
      'Answer Key: ${result.keySectionsFound > 0 ? '${result.keySectionsFound} mili, ${result.keyEntriesApplied} jawab lage' : 'nahi mili'}',
      'Jawab ke baghair questions: ${result.answerPending.length}',
    ];
    if (result.answerSources.isNotEmpty) {
      diagnostics.add(
        'Answers: ${result.answerSources.entries.map((e) => '${e.value} ${e.key} se').join(', ')}',
      );
    }
    if (result.poorOcrPages.isNotEmpty) {
      diagnostics.add(
        'Kharab OCR pages: ${result.poorOcrPages.join(', ')} — dobara '
        'scan karein ya "Behtar quality (Gemini)" try karein.',
      );
    }
    final reason = isLetter
        ? 'Is PDF mein koi MCQ nahi mila — ye aik admission letter / '
              'instructions hai, is se test nahi ban sakta. Koi aur file '
              '(MCQ book ya past paper) chunein.'
        : result.text.trim().isEmpty
            ? 'No text could be read from this file at all. '
                  'If it is a scanned book in Urdu script, try the '
                  '"Urdu book" option (Tesseract OCR) or "Behtar quality '
                  '(Gemini)" — or use an English text PDF, a .txt file, '
                  'or paste the text instead.'
            : 'Read ${result.text.length} characters, but no question matched '
                  'the formats. Each question needs 4 options (A–D) and an '
                  'Answer line, a one-line "(a)–(d)" question, or a '
                  '"Q … Ans: …" line.'
                  '${result.errors.isNotEmpty ? '\n${result.errors.take(2).join('\n')}' : ''}'
                  '${result.excluded.isNotEmpty ? '\n${result.excluded.take(2).join('\n')}' : ''}';
    return AlertDialog(
      title: const Text('No MCQs found'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(reason),
            const SizedBox(height: 12),
            const Text(
              'Diagnostics:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            ...diagnostics.map((d) => Text('• $d')),
            if (result.text.trim().isNotEmpty && !isLetter) ...[
              const SizedBox(height: 12),
              const Text(
                'What was actually read:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              ExtractedTextPreview(text: result.textPreview),
            ],
            if (!isLetter) ...[
              const SizedBox(height: 12),
              const Text(
                'What to do next:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              const Text(
                '• Text PDF banayein: Word / Google Docs se "Save as PDF" '
                'karein (scanned image wali PDF nahi) — phir dobara '
                'upload karein.',
              ),
              const Text(
                '• Scanned book ho to saaf scan karein aur "Urdu book" ya '
                '"Behtar quality (Gemini)" tick karke dobara try karein.',
              ),
              const Text(
                '• Ya text file / paste use karein: har question ke 4 '
                'options (A–D) aur "Answer: C" line likhein.',
              ),
            ],
            const SizedBox(height: 12),
            const Text(
              'Try TXT / paste: text file ya pasted text se bhi MCQs '
              'ban sakte hain — neeche "Or paste MCQ text here" mein '
              'text paste karein aur "Parse pasted text" dabayein. '
              'Parser khud MCQs nikaal lega — AI se MCQs nahi banaye '
              'jate, sirf is text mein maujood questions save hote '
              'hain.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, 'close'),
          child: const Text('Close'),
        ),
        if (!isLetter && result.answerPending.isNotEmpty)
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, 'manual'),
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Jawab khud lagayein'),
          ),
      ],
    );
  }
}

/// Manual correction dialog (governing spec 19 Nov 2026): the user
/// picks the correct option for each question whose answer the book
/// did not give (UNVERIFIED — never guessed, never sent to AI).
/// Pops a map from pending index to option index for the questions
/// the user answered, or null on Cancel. A public widget so widget
/// tests can assert the correction flow.
class ManualCorrectionDialog extends StatefulWidget {
  const ManualCorrectionDialog({super.key, required this.pending});

  final List<PendingQuestion> pending;

  @override
  State<ManualCorrectionDialog> createState() =>
      _ManualCorrectionDialogState();
}

class _ManualCorrectionDialogState extends State<ManualCorrectionDialog> {
  final _chosen = <int, int>{};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Jawab khud lagayein'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'In questions ke jawab book mein nahi mile — aap khud '
                'sahi option chunein. Jo jawab aap lagayenge woh '
                '"manual" mark hoga (book ka original jawab nahi). '
                'UNVERIFIED jawab kabhi AI se nahi nikale jate.',
              ),
              const SizedBox(height: 12),
              ...widget.pending.asMap().entries.map((e) {
                final i = e.key;
                final p = e.value;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${i + 1}. ${p.text}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    RadioGroup<int>(
                      groupValue: _chosen[i],
                      onChanged: (v) {
                        if (v != null) {
                          setState(() => _chosen[i] = v);
                        }
                      },
                      child: Column(
                        children: [
                          ...p.options.asMap().entries.map((o) {
                            return RadioListTile<int>(
                              title: Text(o.value),
                              value: o.key,
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                            );
                          }),
                        ],
                      ),
                    ),
                  ],
                );
              }),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _chosen.isEmpty
              ? null
              : () => Navigator.pop(context, Map<int, int>.from(_chosen)),
          child: Text('Save (${_chosen.length})'),
        ),
      ],
    );
  }
}

/// What the extraction preview decided: which action the user took
/// ('save' / 'manual' / 'mpt' / 'cancel') and the question list as
/// it stands after any in-preview answer corrections (G-M3) — the
/// caller saves THIS list, never the pre-correction one.
class PreviewDecision {
  const PreviewDecision(this.action, this.questions);

  final String action;
  final List<Question> questions;
}

/// Extraction preview dialog (Phase A, v2.0.0 — governing spec:
/// the preview BEFORE a test is generated must show, per question:
/// the question, options A–D, the detected correct answer, the
/// source page, the CONFIDENCE SCORE and the verification status —
/// plus manual correction).
///
/// The summary lines (counts, format breakdown incl. table +
/// flashcard counts, verification + average confidence, numbering
/// gaps/duplicates) come from [_importResult]; the per-question list
/// below them shows every parsed question:
/// * options A–D, the detected answer marked ✓ and bold, with its
///   source ("key se" / "bold se" / …);
/// * "Page N • Confidence NN% • verified / unverified /
///   manually-corrected";
/// * an OCR warning on every question whose mark came from OCR
///   (G-C6): a tick/bold on a scan could be the student's pen, and
///   an asterisk/key/answer-line on a scan can still be cut off at
///   the page edge (Paper 60 Q11) — both say so in plain words,
///   with the exact confidence, instead of hiding it in the model;
/// * the ORIGINAL answer when the user already corrected this
///   question ("Pehla jawab: B");
/// * a "Jawab theek karein" button per question (G-M3) that opens
///   [CorrectAnswerDialog]; the correction keeps the original in
///   [Question.originalCorrectIndex] via [Question.withCorrection].
/// A public widget so widget tests can assert the per-question rows.
class ExtractionPreviewDialog extends StatefulWidget {
  const ExtractionPreviewDialog({
    super.key,
    required this.result,
    required this.summaryLines,
    required this.showManual,
    required this.showMpt,
  });

  final PdfImportResult result;
  final List<String> summaryLines;
  final bool showManual;
  final bool showMpt;

  @override
  State<ExtractionPreviewDialog> createState() =>
      _ExtractionPreviewDialogState();
}

class _ExtractionPreviewDialogState extends State<ExtractionPreviewDialog> {
  late List<Question> _questions;

  @override
  void initState() {
    super.initState();
    _questions = List<Question>.from(widget.result.questions);
  }

  Future<void> _correctAnswer(int index) async {
    final q = _questions[index];
    final chosen = await showDialog<int>(
      context: context,
      builder: (ctx) => CorrectAnswerDialog(question: q),
    );
    if (chosen == null || chosen == q.correctIndex) return;
    setState(() {
      _questions[index] = q.withCorrection(chosen);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Save these MCQs?'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.summaryLines.join('\n')),
              const SizedBox(height: 16),
              Text(
                'Questions (${_questions.length}):',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ..._questions.asMap().entries.map((e) {
                final i = e.key;
                final q = e.value;
                final confidencePct = (q.confidence * 100).round();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${i + 1}. ${q.text}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    ...q.options.asMap().entries.map((o) {
                      final isCorrect = o.key == q.correctIndex;
                      final letter =
                          String.fromCharCode(65 + o.key);
                      return Text(
                        isCorrect
                            ? '✓ $letter. ${o.value} (${q.answerSource} se)'
                            : '$letter. ${o.value}',
                        style: isCorrect
                            ? const TextStyle(fontWeight: FontWeight.bold)
                            : null,
                      );
                    }),
                    Text(
                      'Page ${q.page == 0 ? '?' : q.page} • '
                      'Confidence $confidencePct% • '
                      '${q.verificationStatus}',
                    ),
                    if (q.originalCorrectIndex != null)
                      Text(
                        'Pehla jawab: '
                        '${String.fromCharCode(65 + q.originalCorrectIndex!)} '
                        '(aap ne theek kiya)',
                      ),
                    if (q.markProvenance == 'ocr')
                      Text(
                        q.answerVerified
                            ? 'OCR se parha gaya (scan / photo) — agar '
                                'jawab page ke kinare par kata hua tha to '
                                'ghalat ho sakta hai; tasdeeq karein.'
                            : 'OCR se parha gaya (scan / photo) — ye tick '
                                '/ bold student ke pen ka ho sakta hai; '
                                'jawab UNVERIFIED hai, tasdeeq karein.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => _correctAnswer(i),
                        child: const Text('Jawab theek karein'),
                      ),
                    ),
                    const Divider(),
                  ],
                );
              }),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(context, PreviewDecision('cancel', _questions)),
          child: const Text('Cancel'),
        ),
        if (widget.showManual)
          TextButton(
            onPressed: () =>
                Navigator.pop(context, PreviewDecision('manual', _questions)),
            child: const Text('Jawab khud lagayein'),
          ),
        if (widget.showMpt)
          TextButton(
            onPressed: () =>
                Navigator.pop(context, PreviewDecision('mpt', _questions)),
            child: const Text('CSS MPT pattern use karein'),
          ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, PreviewDecision('save', _questions)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Correct-an-already-answered-question dialog (G-M3, Phase A).
/// Shows the book's extracted answer ("Book ka jawab: C") and lets
/// the user pick a different option. Pops the chosen option index,
/// or null on Cancel / no change. Save stays disabled until the user
/// picks an option DIFFERENT from the extracted one — tapping Save
/// with the same answer would mark a correct answer as
/// "manually-corrected" for no reason. A public widget so widget
/// tests can assert the correction flow (original kept separate).
class CorrectAnswerDialog extends StatefulWidget {
  const CorrectAnswerDialog({super.key, required this.question});

  final Question question;

  @override
  State<CorrectAnswerDialog> createState() => _CorrectAnswerDialogState();
}

class _CorrectAnswerDialogState extends State<CorrectAnswerDialog> {
  late int _chosen;

  @override
  void initState() {
    super.initState();
    _chosen = widget.question.correctIndex;
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.question;
    return AlertDialog(
      title: const Text('Jawab theek karein'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(q.text, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                'Book ka jawab: ${q.correctLetter} (${q.answerSource} se). '
                'Agar ye ghalat hai to sahi option chunein — pehla jawab '
                'mehfooz rahega (preview mein "Pehla jawab" dikhega).',
              ),
              const SizedBox(height: 12),
              RadioGroup<int>(
                groupValue: _chosen,
                onChanged: (v) {
                  if (v != null) setState(() => _chosen = v);
                },
                child: Column(
                  children: [
                    ...q.options.asMap().entries.map((o) {
                      return RadioListTile<int>(
                        title: Text(o.value),
                        value: o.key,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      );
                    }),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _chosen == q.correctIndex
              ? null
              : () => Navigator.pop(context, _chosen),
          child: const Text('Save correction'),
        ),
      ],
    );
  }
}

/// Failure dialog for a file that could not be read at all (corrupt
/// PDF / bad DOCX / unreadable file — v2 Req A). A snackbar alone
/// disappears; this dialog stays until the user reads it, and always
/// carries (1) the plain-language reason and (2) the concrete next
/// step. No AI option: there is no text to generate from.
Future<void> showFileFailureDialog(
  BuildContext context,
  String reason,
) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('File nahi parhi ja saki'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(reason),
            const SizedBox(height: 12),
            const Text(
              'What to do next:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              '• File dobara download karein — ye kharab ya incomplete '
              'download lagti hai.',
            ),
            const Text(
              '• Ya text PDF banayein (Word / Google Docs se "Save as '
              'PDF") ya .txt file upload karein.',
            ),
            const Text(
              '• Ya "Or paste MCQ text here" mein text paste karein.',
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// True when extracted text looks like an admission letter /
/// instructions sheet rather than a question book: it mentions an
/// admission and a roll number / candidate, and carries no MCQ
/// signals. Used ONLY to pick the honest "no MCQs" message and to
/// suppress the text preview (privacy: such letters carry personal
/// details). Never used to store or quote the letter's contents.
bool isAdmissionLetterText(String text) {
  final lower = text.toLowerCase();
  if (!lower.contains('admission')) return false;
  final hasCandidateMarker =
      lower.contains('roll no') ||
      lower.contains('roll number') ||
      lower.contains('candidate');
  final hasInstructionMarker =
      lower.contains('instructions') ||
      lower.contains('reporting time') ||
      lower.contains('test centre') ||
      lower.contains('test center') ||
      lower.contains('examination centre') ||
      lower.contains('examination center');
  return hasCandidateMarker && hasInstructionMarker;
}

/// Preview of the text actually read from a book, shown in the
/// "No MCQs found" dialog so the user can see what was read.
///
/// The text direction follows the preview's own first strong character
/// (Unicode bidi "first strong" rule): an Urdu/Arabic-script preview
/// reads right-to-left, a Latin preview keeps the app's ambient
/// direction. Flutter's bidi algorithm orders the runs either way, but
/// with an LTR base direction an Urdu-only preview is left-aligned and
/// its trailing punctuation (e.g. ؟) lands on the wrong side — which
/// is what made Urdu previews look reversed/garbled.
class ExtractedTextPreview extends StatelessWidget {
  const ExtractedTextPreview({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      // v1.2: theme surface, not Colors.black12 — the flat grey was
      // near-invisible in dark mode.
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        text,
        style: const TextStyle(fontSize: 12),
        textDirection: _previewTextDirection(text),
      ),
    );
  }
}

/// First strong directional character of [text]: RTL for Arabic-script
/// ranges (covers Urdu), null otherwise (Latin text keeps the app's
/// ambient direction; numbers/punctuation-only text has no strong
/// character, so the ambient direction is the right default).
TextDirection? _previewTextDirection(String text) {
  for (final rune in text.runes) {
    if ((rune >= 0x0590 && rune <= 0x08FF) ||
        (rune >= 0xFB50 && rune <= 0xFDFF) ||
        (rune >= 0xFE70 && rune <= 0xFEFF)) {
      return TextDirection.rtl;
    }
    if ((rune >= 0x41 && rune <= 0x5A) ||
        (rune >= 0x61 && rune <= 0x7A)) {
      return null;
    }
  }
  return null;
}
