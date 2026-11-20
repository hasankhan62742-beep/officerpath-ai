import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../models/question.dart';
import 'history_groups.dart';

/// Downloadable results — PDF + PNG export, fully offline.
///
/// * One result → a one-page PDF result card, or a PNG of the same
///   card (captured from the on-screen card with [RenderRepaintBoundary],
///   no screenshot package).
/// * A day / date range → one combined multi-page PDF, one page per
///   result, newest first.
/// * TWO ways out: (a) [saveResultPdfToDownloads] writes the PDF
///   straight into the phone's public Downloads folder (MediaStore on
///   Android 10+, direct write below that — see MainActivity.kt);
///   (b) the share sheet ([SharePlus]) for WhatsApp / Drive / etc.
///   The "Download PDF" button is (a); sharing is a separate action.
///   Nothing is uploaded anywhere; no server is involved.
///
/// File names are fixed and human-readable, e.g.
/// `OfficerPath_Result_2026-11-19_PPSC.pdf`.

const _navy = PdfColor.fromInt(0xFF0B1F3A);
const _gold = PdfColor.fromInt(0xFFC9A227);
const _goldSoft = PdfColor.fromInt(0xFFF5EED3);

String _slug(String text) {
  final cleaned = text
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  return cleaned.isEmpty ? 'Result' : cleaned;
}

String _datePart(DateTime dt) => DateFormat('yyyy-MM-dd').format(dt);

DateTime _attemptDate(AttemptRecord a) =>
    DateTime.tryParse(a.attemptedAtIso) ?? DateTime.now();

/// e.g. `OfficerPath_Result_2026-11-19_PPSC.pdf`
String resultPdfFileName(AttemptRecord a) =>
    'OfficerPath_Result_${_datePart(_attemptDate(a))}_${_slug(a.examName)}.pdf';

/// e.g. `OfficerPath_Result_2026-11-19_PPSC.png`
String resultPngFileName(AttemptRecord a) =>
    'OfficerPath_Result_${_datePart(_attemptDate(a))}_${_slug(a.examName)}.png';

/// One day → `OfficerPath_Results_2026-11-19.pdf`;
/// a range → `OfficerPath_Results_2026-11-10_to_2026-11-19.pdf`.
String resultsPdfFileName(DateTime from, DateTime to) {
  final a = _datePart(from);
  final b = _datePart(to);
  return a == b
      ? 'OfficerPath_Results_$a.pdf'
      : 'OfficerPath_Results_${a}_to_$b.pdf';
}

/// Builds the one-page PDF result card for a single attempt:
/// score, date, exam/paper title, subject breakdown, correct / wrong /
/// skipped, time taken. Pass [compress] false in tests so the text
/// streams stay searchable.
Future<Uint8List> buildResultPdf(
  AttemptRecord a, {
  bool compress = true,
}) async {
  final doc = pw.Document(compress: compress, title: 'OfficerPath AI — Test Result');
  doc.addPage(_resultPage(a));
  return doc.save();
}

/// Builds the combined PDF for a day / date range: one page per
/// attempt, newest first, plus a summary line on each page.
/// [attempts] may be in any order; the file name should come from
/// [resultsPdfFileName] with the range's min/max dates.
Future<Uint8List> buildResultsPdf(
  List<AttemptRecord> attempts, {
  bool compress = true,
}) async {
  final sorted = attempts.toList()
    ..sort((a, b) {
      final da = DateTime.tryParse(a.attemptedAtIso);
      final db = DateTime.tryParse(b.attemptedAtIso);
      if (da == null && db == null) return 0;
      if (da == null) return 1;
      if (db == null) return -1;
      return db.compareTo(da);
    });
  final doc = pw.Document(compress: compress, title: 'OfficerPath AI — Test Results');
  for (final a in sorted) {
    doc.addPage(_resultPage(a));
  }
  return doc.save();
}

pw.Page _resultPage(AttemptRecord a) {
  final date = _attemptDate(a);
  final dateLabel = DateFormat('dd MMM yyyy, hh:mm a').format(date);
  final minutes = a.durationSeconds ~/ 60;
  final seconds = a.durationSeconds % 60;
  final subjects = decodePerSubject(a.perSubjectJson);
  final subjectRows = subjects.entries.toList()
    ..sort((x, y) => x.key.compareTo(y.key));

  pw.Widget stat(String label, String value) => pw.Column(
        children: [
          pw.Text(
            value,
            style: pw.TextStyle(
              font: pw.Font.helveticaBold(),
              fontSize: 20,
              color: _navy,
            ),
          ),
          pw.Text(label, style: const pw.TextStyle(fontSize: 10)),
        ],
      );

  return pw.Page(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(36),
    build: (pw.Context context) {
      return pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          // Header band.
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(16),
            decoration: pw.BoxDecoration(
              color: _navy,
              borderRadius: pw.BorderRadius.circular(10),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'OFFICERPATH AI',
                  style: pw.TextStyle(
                    font: pw.Font.helveticaBold(),
                    fontSize: 20,
                    color: _gold,
                    letterSpacing: 1.2,
                  ),
                ),
                pw.Text(
                  'Apni book se officer tak ka rasta',
                  style: pw.TextStyle(
                    fontSize: 11,
                    color: PdfColors.white,
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 20),
          pw.Text(
            // NOTE: Helvetica (the built-in PDF font) only covers
            // WinAnsi — no em dash / bullet glyphs. Plain '-' and '|'
            // are used here so nothing is silently dropped.
            'Test Result - ${a.examName}',
            style: pw.TextStyle(
              font: pw.Font.helveticaBold(),
              fontSize: 18,
              color: _navy,
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Text(dateLabel, style: const pw.TextStyle(fontSize: 12)),
          pw.SizedBox(height: 16),
          // Score block.
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(16),
            decoration: pw.BoxDecoration(
              color: _goldSoft,
              borderRadius: pw.BorderRadius.circular(10),
            ),
            child: pw.Column(
              children: [
                pw.Text(
                  '${a.percent.toStringAsFixed(1)}%',
                  style: pw.TextStyle(
                    font: pw.Font.helveticaBold(),
                    fontSize: 36,
                    color: _navy,
                  ),
                ),
                pw.Text(
                  a.passed ? 'PASS' : 'FAIL',
                  style: pw.TextStyle(
                    font: pw.Font.helveticaBold(),
                    fontSize: 16,
                    color: a.passed
                        ? PdfColors.green900
                        : PdfColors.red900,
                  ),
                ),
                pw.SizedBox(height: 4),
                pw.Text(
                  'Score: ${a.score.toStringAsFixed(2)} / ${a.totalQuestions}',
                  style: const pw.TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 16),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
            children: [
              stat('Correct', '${a.correct}'),
              stat('Wrong', '${a.wrong}'),
              stat('Skipped', '${a.skipped}'),
              stat('Time', '${minutes}m ${seconds}s'),
            ],
          ),
          pw.SizedBox(height: 20),
          pw.Text(
            'Subject-wise breakdown',
            style: pw.TextStyle(
              font: pw.Font.helveticaBold(),
              fontSize: 14,
              color: _navy,
            ),
          ),
          pw.SizedBox(height: 8),
          if (subjectRows.isEmpty)
            pw.Text(
              'No subject breakdown recorded for this attempt.',
              style: const pw.TextStyle(fontSize: 12),
            )
          else
            pw.Table(
              border: pw.TableBorder.all(color: PdfColors.grey400),
              columnWidths: {
                0: const pw.FlexColumnWidth(3),
                1: const pw.FlexColumnWidth(1),
                2: const pw.FlexColumnWidth(1),
              },
              children: [
                pw.TableRow(
                  decoration: const pw.BoxDecoration(color: _goldSoft),
                  children: [
                    _cell('Subject', bold: true),
                    _cell('Correct', bold: true),
                    _cell('Score', bold: true),
                  ],
                ),
                for (final e in subjectRows)
                  pw.TableRow(
                    children: [
                      _cell(e.key),
                      _cell('${e.value['correct']} / ${e.value['total']}'),
                      _cell(
                        e.value['total'] == 0
                            ? '—'
                            : '${(e.value['correct']! / e.value['total']! * 100).toStringAsFixed(0)}%',
                      ),
                    ],
                  ),
              ],
            ),
          pw.Spacer(),
          pw.Divider(color: _gold, thickness: 1),
          pw.Text(
            'Developed by Muhammad Abdul Qadeer  |  OfficerPath AI',
            style: pw.TextStyle(
              font: pw.Font.helveticaBold(),
              fontSize: 10,
              color: _navy,
            ),
          ),
        ],
      );
    },
  );
}

pw.Widget _cell(String text, {bool bold = false}) => pw.Padding(
      padding: const pw.EdgeInsets.all(6),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          font: bold ? pw.Font.helveticaBold() : pw.Font.helvetica(),
          fontSize: 12,
        ),
      ),
    );

/// Captures the widget under [boundaryKey] (a [RepaintBoundary]
/// around the on-screen result card) as PNG bytes. Returns null when
/// the boundary is not mounted yet. No screenshot package needed.
/// The caller must await a frame first (e.g. after `pumpAndSettle`
/// in tests, or after the card is on screen in the app).
Future<Uint8List?> capturePng(GlobalKey boundaryKey) async {
  final boundary =
      boundaryKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
  if (boundary == null) return null;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  return byteData?.buffer.asUint8List();
}

/// The native Downloads channel (MainActivity.kt): saves bytes into
/// the phone's public Downloads folder — MediaStore on Android 10+
/// (no permission), direct write on Android 9 and below. Returns
/// where the file landed (a content URI on 10+, a path below that).
/// The native side VERIFIES the file exists (MediaStore row re-query
/// / file size check) before returning success, so a non-null return
/// means the file is really in Downloads.
/// Visible for tests (a fake channel can be installed with
/// TestDefaultBinaryMessengerBinding).
@visibleForTesting
const downloadsChannel =
    MethodChannel('com.qadeerautomations.officerpath/downloads');

/// Writes [bytes] as [fileName] into the public Downloads folder.
/// Returns where it landed, or null when the save failed. Never
/// throws — a platform miss / error is logged in debug and returns
/// null, so the caller can fall back to the share sheet.
Future<String?> saveBytesToDownloads(
  Uint8List bytes,
  String fileName,
) async {
  if (bytes.isEmpty) {
    debugPrint('saveBytesToDownloads: refusing empty bytes for $fileName');
    return null;
  }
  try {
    final saved = await downloadsChannel.invokeMethod<String>(
      'saveToDownloads',
      {'fileName': fileName, 'bytes': bytes},
    );
    if (saved == null || saved.isEmpty) {
      debugPrint('saveBytesToDownloads: native save returned nothing '
          'for $fileName');
      return null;
    }
    return saved;
  } on PlatformException catch (e) {
    // The real cause, in debug only — the UI shows a plain SnackBar.
    debugPrint('saveBytesToDownloads: ${e.code} ${e.message} ($fileName)');
    return null;
  } on MissingPluginException {
    debugPrint('saveBytesToDownloads: Downloads channel not implemented '
        'on this platform ($fileName)');
    return null;
  }
}

/// Builds one result's PDF and saves it to Downloads. Returns where
/// it landed, or null on failure.
Future<String?> saveResultPdfToDownloads(AttemptRecord a) async {
  try {
    final bytes = await buildResultPdf(a);
    return saveBytesToDownloads(bytes, resultPdfFileName(a));
  } catch (e) {
    debugPrint('saveResultPdfToDownloads: $e');
    return null;
  }
}

/// Builds the combined PDF for a day / date range and saves it to
/// Downloads. Returns where it landed, or null (empty list / failure).
Future<String?> saveResultsPdfToDownloads(
  List<AttemptRecord> attempts,
  DateTime from,
  DateTime to,
) async {
  if (attempts.isEmpty) return null;
  try {
    final bytes = await buildResultsPdf(attempts);
    return saveBytesToDownloads(bytes, resultsPdfFileName(from, to));
  } catch (e) {
    debugPrint('saveResultsPdfToDownloads: $e');
    return null;
  }
}

/// Stages [bytes] under [fileName] in the temp directory and opens
/// the system share sheet so the user can send it to WhatsApp, Drive,
/// etc. Returns false (instead of throwing) when the bytes are empty,
/// the staged file is missing/empty, or sharing fails — and logs the
/// real cause in debug, so a failure is diagnosable instead of a
/// silent "try again". (Sharing is NOT a download: for a real
/// download use [saveBytesToDownloads].)
Future<bool> shareFileBytes(
  Uint8List bytes,
  String fileName, {
  String? text,
}) async {
  if (bytes.isEmpty) {
    debugPrint('shareFileBytes: refusing empty bytes for $fileName');
    return false;
  }
  try {
    final dir = await getTemporaryDirectory();
    final file = await File('${dir.path}/$fileName').writeAsBytes(bytes);
    if (!await file.exists() || await file.length() == 0) {
      debugPrint('shareFileBytes: staged file missing/empty: ${file.path}');
      return false;
    }
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        text: text,
        subject: fileName,
      ),
    );
    return true;
  } catch (e) {
    debugPrint('shareFileBytes: $e ($fileName)');
    return false;
  }
}

/// Convenience: build one result's PDF and share it. Returns false
/// (instead of throwing) when sharing is unavailable, so callers can
/// show a SnackBar. The cause is logged in debug by [shareFileBytes].
Future<bool> shareResultPdf(AttemptRecord a) async {
  try {
    final bytes = await buildResultPdf(a);
    return await shareFileBytes(
      bytes,
      resultPdfFileName(a),
      text: 'My ${a.examName} result — ${a.percent.toStringAsFixed(1)}% '
          '(${a.correct}/${a.totalQuestions} correct). Via OfficerPath AI.',
    );
  } catch (e) {
    debugPrint('shareResultPdf: $e');
    return false;
  }
}

/// Convenience: capture the on-screen result card and share it as PNG.
Future<bool> shareResultPng(
  GlobalKey boundaryKey,
  AttemptRecord a,
) async {
  try {
    final bytes = await capturePng(boundaryKey);
    if (bytes == null) return false;
    return await shareFileBytes(bytes, resultPngFileName(a));
  } catch (e) {
    debugPrint('shareResultPng: $e');
    return false;
  }
}

/// Convenience: build the combined PDF for a day / date range and
/// share it. Returns false when there is nothing to share or sharing
/// fails.
Future<bool> shareResultsPdf(
  List<AttemptRecord> attempts,
  DateTime from,
  DateTime to,
) async {
  if (attempts.isEmpty) return false;
  try {
    final bytes = await buildResultsPdf(attempts);
    return await shareFileBytes(bytes, resultsPdfFileName(from, to));
  } catch (e) {
    debugPrint('shareResultsPdf: $e');
    return false;
  }
}
