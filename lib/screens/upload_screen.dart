import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/exam.dart';
import '../models/question.dart';
import '../services/answer_key.dart';
import '../services/book_selection.dart';
import '../services/docx_text_extractor.dart';
import '../services/mcq_parser.dart';
import '../services/parse_validation.dart';
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
    String sourceId, {
    String? keyAttachMessage,
  }) async {
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
    // MASTER DIRECTIVE Part 10 (20 Nov 2026): validate the parse
    // BEFORE the preview shows. Errors block saving (a duplicated
    // question would corrupt a test); warnings/infos are shown as a
    // note. Never repairs, never drops — only reports. Built from the
    // working (post-selection) result, so a filtered-out problem
    // cannot block saving the selected part.
    final validation = validateParseResult(
      ParseResult(
        questions: working.questions,
        parsed: working.parsed,
        skipped: working.skipped,
        answerPending: working.answerPending,
        questionsMissingAnswers: working.questionsMissingAnswers,
        numberDuplicates: working.numberDuplicates,
        conflicts: working.conflicts,
        unmatchedKeyEntries: working.unmatchedKeyEntries,
        keyPaperReport: working.keyPaperReport,
      ),
    );
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
    // Key attribution (strict paper rule, 20 Nov 2026): which paper
    // each in-PDF key attached to — and any key whose paper has no
    // questions here (applied to nothing, said plainly).
    if (working.keyPaperReport.isNotEmpty) {
      lines.addAll(working.keyPaperReport.map((l) => '• $l'));
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
        keyAttachMessage: keyAttachMessage,
        validation: validation,
      ),
    );
    if (decision == null || decision.action == 'cancel') return;
    final corrected = _withQuestions(working, decision.questions);
    if (decision.action == 'manual') {
      await _runManualCorrection(corrected, title, sourceId);
      return;
    }
    if (decision.action == 'save-answerless') {
      await _saveAnswerless(corrected, title, sourceId);
      return;
    }
    if (decision.action == 'key') {
      await _runKeyAttach(corrected, title, sourceId);
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

  /// Saves the still-pending questions as ANSWERLESS questions
  /// (correctIndex -1) together with the answered ones — the
  /// "no-answers" mode (20 Nov 2026). Nothing is invented: the saved
  /// rows carry no answer, the test never scores them, and the result
  /// screen never shows a score for them. The user is told so in the
  /// confirmation message. Used both from the extraction preview
  /// ('save-answerless') and from the "No MCQs found" dialog (the
  /// all-pending case, where there are no answered questions at all).
  Future<void> _saveAnswerless(
    PdfImportResult result,
    String title,
    String sourceId,
  ) async {
    final answerless = result.answerPending
        .map(
          (p) => Question(
            text: p.text,
            options: p.options,
            correctIndex: -1,
            subject: p.subject,
            sourceId: sourceId,
            sourceLabel: title,
            explanation: p.explanation,
            page: p.page,
            part: p.part,
            answerSource: '',
          ),
        )
        .toList();
    final all = [...result.questions, ...answerless];
    final source = BookSource(
      id: sourceId,
      title: title,
      kind: _kind,
      addedAtIso: DateTime.now().toIso8601String(),
    );
    await StorageService.instance.addSource(source, all);
    _titleController.clear();
    _pasteController.clear();
    await _load();
    if (mounted) {
      _showMessage(
        'Saved ${all.length} MCQs from "$title" '
        '(${answerless.length} baghair jawab). '
        'Jawab ke baghair test mein result nahi dikhega — '
        'sahi/ghalat aur score sirf jawab wale questions ka hota hai.',
      );
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
      keyPaperReport: result.keyPaperReport,
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

  /// Attach-a-key flow (20 Nov 2026, "Jawab wali key attach karein"):
  /// the user attaches the answer key separately (typed/pasted text
  /// or a key photo/PDF — read through the same import path as the
  /// book, no new OCR engine). Answers fill by question NUMBER only
  /// ([applyAttachedKey]); the questions the key did not fill stay
  /// pending. The result message (green, pulsing) is shown as a
  /// snack bar AND at the top of the re-opened preview, with the
  /// still-missing numbers — so the owner can see exactly what the
  /// key did and what is left.
  Future<void> _runKeyAttach(
    PdfImportResult result,
    String title,
    String sourceId,
  ) async {
    if (result.answerPending.isEmpty || !mounted) return;
    final attach = await showDialog<KeyAttachResult>(
      context: context,
      builder: (ctx) => AttachAnswerKeyDialog(
        pending: result.answerPending,
        readKeyFile: _readKeyFileText,
      ),
    );
    if (attach == null || !mounted) return;
    final keyed = <Question>[];
    final still = <PendingQuestion>[];
    for (var i = 0; i < result.answerPending.length; i++) {
      final p = result.answerPending[i];
      final c = attach.filled[i];
      if (c == null) {
        still.add(p);
        continue;
      }
      keyed.add(
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
          answerSource: 'key',
        ),
      );
    }
    final message = keyAttachResultMessage(attach);
    _showMessage(message);
    final next = _withQuestions(
      result,
      [...result.questions, ...keyed],
      remainingPending: still,
    );
    await _importResult(next, title, sourceId, keyAttachMessage: message);
  }

  /// Reads an attached answer-key file and returns its raw text, or
  /// null when the user cancels picking. Throws when the file cannot
  /// be read, so the dialog can say so plainly. Same picker + same
  /// import path as the book import (see [_pickFile] and
  /// [PdfImportService.extractKeyText]); the MCQ parse the import
  /// also runs is discarded — a key page is not a question bank.
  Future<String?> _readKeyFileText() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'txt', 'docx', 'jpg', 'jpeg', 'png'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      throw Exception('dobara try karein.');
    }
    if (file.size > SubscriptionService.maxBookFileBytes) {
      throw Exception(
        'file ${(file.size / (1024 * 1024)).toStringAsFixed(0)} MB — '
        '100 MB se zyada hai.',
      );
    }
    final ext = (file.extension ?? '').toLowerCase();
    return PdfImportService.extractKeyText(
      bytes,
      extension: ext,
      urduBook: _urduBook,
      bestQualityOcr: _bestQualityOcr,
      visionOcr: _bestQualityOcr ? GeminiVisionOcr() : null,
    );
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
    } else if (action == 'key') {
      await _runKeyAttach(result, title, sourceId);
    } else if (action == 'save-answerless') {
      await _saveAnswerless(result, title, sourceId);
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
/// Pops 'manual' / 'save-answerless' / 'close'. A public widget so
/// widget tests can assert its contents.
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
    if (result.keyPaperReport.isNotEmpty) {
      diagnostics.addAll(result.keyPaperReport);
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
            // No-answers notice (20 Nov 2026): when EVERY parsed
            // question lacks an answer, the dialog must say so
            // plainly too — not only when some do.
            if (!isLetter && result.answerPending.isNotEmpty) ...[
              const SizedBox(height: 12),
              const NoAnswersNoticeBox(),
            ],
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
        // Attach-a-key (20 Nov 2026): a separate key photo/PDF or
        // typed key, matched by question number only.
        if (!isLetter && result.answerPending.isNotEmpty)
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(context, 'key'),
            icon: const Icon(Icons.key_outlined),
            label: const Text('Jawab wali key attach karein'),
          ),
        // No-answers mode (20 Nov 2026): save the pending questions
        // as answerless (correctIndex -1). Practise is possible; no
        // answer is invented and no result is ever shown for them.
        if (!isLetter && result.answerPending.isNotEmpty)
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(context, 'save-answerless'),
            icon: const Icon(Icons.save_outlined),
            label: const Text('Jawab ke baghair save karein'),
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
                      '${p.number != null ? 'Q${p.number}' : '${i + 1}'}. ${p.text}',
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
/// No-answers notice (20 Nov 2026, owner's words): shown whenever a
/// parse found questions whose answers are NOT attached — no bold, no
/// stars, no ABCD key, no tick. The user sent questions only, so
/// proper MCQs can only be made when the answers come with them. The
/// same text is used in the extraction preview and in the "No MCQs
/// found" dialog (the all-pending case), so the message is identical
/// wherever the user meets it. Kept as one constant so tests can
/// assert on it and the wording can never drift between dialogs.
const String noAnswersNotice =
    'Aap ne sirf questions bheje hain — jawab attach nahi hain '
    '(na bold, na stars, na ABCD key, na tick). Is liye MCQs tabhi '
    'mukammal banenge jab jawab bhi saath hon.\n'
    'You sent questions only — no answers attached (no bold, no stars, '
    'no ABCD key, no tick). Complete MCQs need the answers too.';

/// A gentle GREEN pulse (20 Nov 2026, owner's request: the notice
/// must be unmissable — it shines, the user cannot miss it). The
/// border glows and the background breathes on a slow ~1.8 s cycle.
/// Explicit greens (the app theme is navy-seeded, so the scheme's
/// primary is NOT green — the green is deliberate here). Static when
/// animations are disabled: no motion for users who asked for none.
/// The card background is always light green, so the text/icon
/// colours are fixed dark greens that read on it in both themes.
class _PulsingGreenCard extends StatefulWidget {
  const _PulsingGreenCard({required this.child});

  final Widget child;

  @override
  State<_PulsingGreenCard> createState() => _PulsingGreenCardState();
}

class _PulsingGreenCardState extends State<_PulsingGreenCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _pulse = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) {
      return _greenCard(0.5);
    }
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) => _greenCard(_pulse.value),
      child: widget.child,
    );
  }

  Widget _greenCard(double t) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Color.lerp(
          const Color(0xFFE8F5E9),
          const Color(0xFFC8E6C9),
          t,
        ),
        border: Border.all(
          color:
              Color.lerp(
                const Color(0xFF66BB6A),
                const Color(0xFF2E7D32),
                t,
              ) ??
              const Color(0xFF43A047),
          width: 1 + t,
        ),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF43A047).withValues(alpha: 0.10 + 0.14 * t),
            blurRadius: 6 + 6 * t,
            spreadRadius: t,
          ),
        ],
      ),
      child: widget.child,
    );
  }
}

/// A prominent notice box for [noAnswersNotice]: GREEN and gently
/// pulsing (20 Nov 2026, owner's request — unmissable), with an icon,
/// so it cannot be missed above the summary lines.
class NoAnswersNoticeBox extends StatelessWidget {
  const NoAnswersNoticeBox({super.key});

  @override
  Widget build(BuildContext context) {
    return const _PulsingGreenCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_outlined, color: Color(0xFF2E7D32)),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              noAnswersNotice,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Color(0xFF1B5E20),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The key-attach result message ("N jawab key se lag gaye" + which
/// numbers are still missing), in the same green pulsing card as the
/// no-answers notice (20 Nov 2026) — the owner asked for the same
/// unmissable treatment for the key result.
class KeyAttachResultBox extends StatelessWidget {
  const KeyAttachResultBox({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return _PulsingGreenCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.key_outlined, color: Color(0xFF2E7D32)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Color(0xFF1B5E20),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Parse-validation findings in the upload preview (MASTER DIRECTIVE
/// Part 10, 20 Nov 2026): errors block saving (a duplicated question
/// would corrupt a test), warnings/infos are shown as a note. Never
/// repairs, never drops — only reports. A public widget so widget
/// tests can assert its contents.
class ValidationReportBox extends StatelessWidget {
  const ValidationReportBox({super.key, required this.report});

  final ValidationReport report;

  @override
  Widget build(BuildContext context) {
    if (report.issues.isEmpty) return const SizedBox.shrink();
    if (report.hasErrors) {
      final shown = report.errors.take(3).toList();
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFFFDECEA),
          border: Border.all(color: const Color(0xFFB3261E)),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Is import mein masla hai — save nahi ho sakta.',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Color(0xFF7A1F1A),
              ),
            ),
            const SizedBox(height: 4),
            ...shown.map(
              (i) => Text(
                '• ${i.detail}${i.questionRef == null ? '' : ' (${i.questionRef})'}',
                style: const TextStyle(color: Color(0xFF7A1F1A)),
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Duplicate sawal test ko kharab karte hain — file theek '
              'karke dobara import karein.',
              style: TextStyle(color: Color(0xFF7A1F1A)),
            ),
          ],
        ),
      );
    }
    // Warnings first (suspected fabrications, unmatched keys,
    // conflicts), then infos (missing answers — already headlined by
    // the no-answers notice); capped so a 100-pending book does not
    // flood the dialog.
    final ordered = [
      ...report.warnings,
      ...report.issues.where(
        (i) => i.severity == ValidationSeverity.info,
      ),
    ];
    final shown = ordered.take(5).toList();
    final rest = ordered.length - shown.length;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        border: Border.all(color: const Color(0xFF8D6E00)),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Check karne wali baatein:',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: Color(0xFF5D4700),
            ),
          ),
          const SizedBox(height: 4),
          ...shown.map(
            (i) => Text(
              '• ${i.detail}${i.questionRef == null ? '' : ' (${i.questionRef})'}',
              style: const TextStyle(color: Color(0xFF5D4700)),
            ),
          ),
          if (rest > 0)
            Text(
              '…aur $rest aur.',
              style: const TextStyle(color: Color(0xFF5D4700)),
            ),
        ],
      ),
    );
  }
}

/// Attach-an-answer-key dialog (20 Nov 2026, "Jawab wali key attach
/// karein"): the user types/pastes the key ("1-C 2-B 3-D …") or
/// attaches a key photo/PDF ([readKeyFile] reads it through the same
/// import path as the book — null means the user cancelled picking).
/// Applies the key to [pending] by question NUMBER only
/// ([applyAttachedKey] — never by position, never guessed) and pops
/// the [KeyAttachResult], or null on Cancel. When the key text has no
/// parseable entries at all, the dialog says so plainly and STAYS
/// OPEN — nothing is guessed and nothing is applied.
class AttachAnswerKeyDialog extends StatefulWidget {
  const AttachAnswerKeyDialog({
    super.key,
    required this.pending,
    required this.readKeyFile,
  });

  final List<PendingQuestion> pending;
  final Future<String?> Function() readKeyFile;

  @override
  State<AttachAnswerKeyDialog> createState() => _AttachAnswerKeyDialogState();
}

class _AttachAnswerKeyDialogState extends State<AttachAnswerKeyDialog> {
  final _keyController = TextEditingController();
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _attachFile() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final text = await widget.readKeyFile();
      if (text == null) return; // User cancelled picking.
      if (!mounted) return;
      setState(() => _keyController.text = text);
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _error =
            'Key file parhi nahi gayi. ${e.toString().replaceFirst('Exception: ', '')}',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _apply() {
    final result = applyAttachedKey(
      keyText: _keyController.text,
      pending: widget.pending,
    );
    if (result.parseFailed) {
      setState(() {
        _error = 'Key samajh nahi aayi — koi jawab nahi mila. '
            'Format: 1-C 2-B 3-D … (ya "1. C", "1: C", "Q1 C").';
      });
      return;
    }
    if (mounted) Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Jawab wali key attach karein'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.pending.length} question(s) ke jawab nahi hain. '
                'Key type karein, paste karein, ya key ki photo / PDF '
                'attach karein — jawab question NUMBER se lagenge, '
                'kabhi andaze se nahi.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _keyController,
                maxLines: 6,
                minLines: 3,
                decoration: const InputDecoration(
                  hintText: '1-C 2-B 3-D …',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : _attachFile,
                icon: const Icon(Icons.attach_file),
                label: Text(
                  _busy
                      ? 'Key parhi ja rahi hai…'
                      : 'Key ki photo / PDF attach karein',
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
          onPressed: _busy ? null : _apply,
          child: const Text('Key lagayein'),
        ),
      ],
    );
  }
}

/// Plain-language result of a key attach (20 Nov 2026): how many
/// answers the key filled, and which question numbers are STILL
/// missing (those stay pending — manual or test-without-answers). A
/// key that parsed but matched nothing says so plainly instead of
/// pretending it worked.
String keyAttachResultMessage(KeyAttachResult r) {
  final filled = r.filled.length;
  // Orphan-paper lines explain WHY nothing matched, so they belong in
  // the zero-filled message too — otherwise the reason is swallowed.
  String orphanLines() {
    return r.orphanKeyPapers
        .map(
          (paper) =>
              "Key '$paper' mili, lekin is import mein $paper ke sawal nahi — "
              'key nahi lagayi.',
        )
        .join(' ');
  }

  if (filled == 0) {
    final parts = <String>[
      'Key parhi gayi, lekin is se koi jawab nahi laga — number '
          'match nahi hue. Jawab khud lagayein ya baghair jawab test karein.',
    ];
    if (r.orphanKeyPapers.isNotEmpty) parts.add(orphanLines());
    return parts.join(' ');
  }
  final parts = <String>['$filled jawab key se lag gaye.'];
  if (r.stillMissingNumbers.isNotEmpty) {
    parts.add(
      'Abhi bhi jawab nahi: ${r.stillMissingNumbers.map((n) => 'Q$n').join(', ')}.',
    );
  }
  if (r.unnumberedStillMissing > 0) {
    parts.add(
      '${r.unnumberedStillMissing} question(s) ka number nahi tha — '
      'un ke jawab key se nahi lag sakte, khud lagayein.',
    );
  }
  if (r.unresolvedNumbers.isNotEmpty) {
    parts.add(
      'Key mein ${r.unresolvedNumbers.map((n) => 'Q$n').join(', ')} ka '
      'jawab samajh nahi aaya — woh bhi pending rahenge.',
    );
  }
  if (r.orphanKeyPapers.isNotEmpty) {
    parts.add(orphanLines());
  }
  return parts.join(' ');
}

class PreviewDecision {
  const PreviewDecision(this.action, this.questions);

  /// 'cancel' | 'manual' (answer pending questions by hand) |
  /// 'key' (attach a separate answer key, then re-show the preview) |
  /// 'mpt' (use the CSS MPT pattern, then re-show the preview) |
  /// 'save' (save the answered questions) | 'save-answerless'
  /// (save answered questions PLUS the still-pending ones as
  /// answerless questions, correctIndex -1 — testable but never
  /// scored; see the no-answers notice, 20 Nov 2026).
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
    this.keyAttachMessage,
    this.validation,
  });

  final PdfImportResult result;
  final List<String> summaryLines;
  final bool showManual;
  final bool showMpt;

  /// The key-attach result message ("N jawab key se lag gaye" + still
  /// missing numbers), shown green + pulsing at the top when a key
  /// was just attached in this import.
  final String? keyAttachMessage;

  /// Parse-validation findings for this import (MASTER DIRECTIVE
  /// Part 10), or null when the dialog is built without validation
  /// (e.g. direct widget tests). Errors block saving; warnings and
  /// infos are shown as a note.
  final ValidationReport? validation;

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
              // No-answers notice (20 Nov 2026): whenever the parse
              // found questions without answers, say so FIRST and
              // plainly — the user sent questions only. The notice
              // shows even when SOME questions have answers; the
              // pending ones are listed by the manual flow.
              if (widget.result.answerPending.isNotEmpty) ...[
                const NoAnswersNoticeBox(),
                const SizedBox(height: 16),
              ],
              if (widget.keyAttachMessage != null) ...[
                KeyAttachResultBox(message: widget.keyAttachMessage!),
                const SizedBox(height: 16),
              ],
              // Parse validation (MASTER DIRECTIVE Part 10): errors
              // block saving (see the disabled Save button below);
              // warnings/infos are a note. Shown before the summary
              // so the user sees the problems before the counts.
              if (widget.validation != null &&
                  widget.validation!.issues.isNotEmpty) ...[
                ValidationReportBox(report: widget.validation!),
                const SizedBox(height: 16),
              ],
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
                    if (q.originalCorrectIndex != null &&
                        q.originalCorrectIndex != -1)
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
        // Attach-a-key (20 Nov 2026): a separate key photo/PDF or
        // typed key, matched by question number only.
        if (widget.result.answerPending.isNotEmpty)
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(
              context,
              PreviewDecision('key', _questions),
            ),
            icon: const Icon(Icons.key_outlined),
            label: const Text('Jawab wali key attach karein'),
          ),
        // No-answers mode (20 Nov 2026): save the pending questions
        // as answerless (correctIndex -1) together with the answered
        // ones. The user can practise them, but no answer is ever
        // invented and no result is ever shown for them. Blocked by
        // validation errors like Save (it saves the same questions).
        if (widget.result.answerPending.isNotEmpty)
          OutlinedButton(
            onPressed: widget.validation?.hasErrors == true
                ? null
                : () => Navigator.pop(
                      context,
                      PreviewDecision('save-answerless', _questions),
                    ),
            child: const Text('Jawab ke baghair save karein'),
          ),
        if (widget.showMpt)
          TextButton(
            onPressed: () =>
                Navigator.pop(context, PreviewDecision('mpt', _questions)),
            child: const Text('CSS MPT pattern use karein'),
          ),
        FilledButton(
          // Validation errors block saving (MASTER DIRECTIVE Part
          // 10): a duplicated question would corrupt the test.
          // Manual correction, key attach and Cancel stay available
          // — the user is never stuck without an exit.
          onPressed: widget.validation?.hasErrors == true
              ? null
              : () => Navigator.pop(
                    context,
                    PreviewDecision('save', _questions),
                  ),
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
                q.hasAnswer
                    ? 'Book ka jawab: ${q.correctLetter} (${q.answerSource} se). '
                          'Agar ye ghalat hai to sahi option chunein — pehla jawab '
                          'mehfooz rahega (preview mein "Pehla jawab" dikhega).'
                    : 'Is question ka jawab abhi nahi hai. Sahi option '
                          'chunein — jawab save ho jayega.',
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
