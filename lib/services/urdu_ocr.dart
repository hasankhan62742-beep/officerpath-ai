import 'dart:io';
import 'dart:math' as math;

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

/// Picks the OCR text the parser sees for one camera-photo page.
/// The ML Kit line boxes (text + bounding box) are ordered
/// top-to-bottom and split into left/right columns by
/// [splitColumnsForOcr], so a two-column page reaches the parser
/// left column first, then right — the contract the parser needs.
/// When fewer than 4 line boxes were extracted the raw
/// [RecognizedText.text] stands (fail-open: a sparse or broken line
/// list must never lose the only read of the page). The caller also
/// falls back to the raw text if extracting the boxes throws.
String columnSplitOcrText(
  String rawText,
  List<({String text, double x, double y, double width})> lines,
) {
  if (lines.length < 4) return rawText;
  // Stable sort: lines on the same row keep ML Kit's order.
  final sorted = List.of(lines)..sort((a, b) => a.y.compareTo(b.y));
  return splitColumnsForOcr(
    sorted.map((l) => (text: l.text, x: l.x, width: l.width)).toList(),
  );
}

/// Whether a short line looks like a section heading ("Interjection",
/// "Parts of Speech Identification", "Gerund / Infinitives /
/// Participle") rather than a wrapped fragment of a question or
/// option. Headings are short (≤5 words, ≤45 chars), title-cased
/// (every lettered word starts uppercase, ignoring small words like
/// "of" and non-letter tokens like "/"), and never end in sentence
/// punctuation — a wrapped stem/option tail usually ends in ".", "?"
/// or "!" ("MS Word?", "the whole class.") or starts lowercase. A
/// capitalised tail with no trailing punctuation ("Quaid-e-Azam" as a
/// stem tail) can still be misread as a heading; that costs a split
/// stem, not a corrupted option cell, so the guard errs on the
/// heading side.
bool _looksLikeHeading(String text) {
  final trimmed = text.trim();
  if (trimmed.length > 45) return false;
  if (trimmed.endsWith('.') ||
      trimmed.endsWith('?') ||
      trimmed.endsWith('!')) {
    return false;
  }
  const small = {
    'of',
    'and',
    'the',
    'a',
    'an',
    'in',
    'on',
    'for',
    'to',
    'with',
    'by',
    'at',
    'from',
  };
  var words = 0;
  for (final token in trimmed.split(RegExp(r'\s+'))) {
    if (!RegExp(r'[A-Za-z\u0600-\u06FF]').hasMatch(token)) continue;
    words++;
    if (words > 5) return false;
    if (small.contains(token.toLowerCase())) continue;
    final firstLetter =
        RegExp(r'[A-Za-z\u0600-\u06FF]').firstMatch(token)!.group(0)!;
    final code = firstLetter.codeUnitAt(0);
    // ASCII lowercase start → not a heading word. Non-ASCII letters
    // (Urdu has no case) count as capitalised.
    if (code >= 97 && code <= 122) return false;
  }
  return words > 0;
}

/// Reconstructs a printed MCQ table from ML Kit ELEMENT boxes (words
/// with their own bounding boxes — a table row can be one ML Kit line
/// or several, but its words always carry their own boxes). Returns
/// one `'|'`-separated line per LOGICAL row — the exact shape
/// [_tableCells] (mcq_parser.dart) already consumes for PDF text — or
/// null when the page is not table-like. Table-like means: ≥3 rows
/// with ≥5 cells each, ≥5 column bands shared by ≥3 rows each, and
/// the table rows hold at least half the page's elements (a small
/// table on a prose page must not eat the prose).
///
/// CRITICAL: this runs INSTEAD of the left/right column split — a
/// table spans the full width, and splitting it in the middle would
/// destroy its rows (stems left, options right). The caller detects
/// tables first and only column-splits when this returns null.
///
/// How it works: elements are grouped into visual rows by vertical
/// overlap, each row is split into cells at wide horizontal gaps
/// (inter-cell gutters are far wider than inter-word spaces), and
/// cell starts from MULTI-CELL rows only are clustered into column
/// bands across rows (a 1-cell heading/footer must not become a
/// band — a centred heading starts wherever its length puts it).
/// Visual rows are then grouped into LOGICAL rows: a row is new when
/// it carries a serial number in the serial band (the leftmost band
/// with ≥3 bare-number cells — the numbers themselves are ignored,
/// the book misnumbers rows, e.g. 162/164 after 251/253), or, when
/// no serial band exists, when it has ≥5 cells; a visual row without
/// a serial CONTINUES the previous logical row, appending each of
/// its cells to the same-band cell there (stems and options wrap
/// over 2–4 visual lines in these books). A header row ("Sr.# |
/// Question | A | B | C | D | Ans") has no serial but follows a
/// title, not a data row, so it still starts a new row.
///
/// One-cell rows: a lettered row before the first data row is a
/// title; a 1-cell row aligned with a band of the previous row and
/// directly below it is a wrapped tail and is merged into THAT
/// band's cell (not necessarily the first cell — an option can wrap
/// on its own line) — unless it looks like a section heading (see
/// [_looksLikeHeading]), in which case it is emitted as its own line
/// (the parser skips headings); any other lettered 1-cell row
/// mid-page (footer "Page 5 of 71", "Scanned with CamScanner") is
/// likewise its own line, and a bare number is dropped. A stem that
/// wraps with a WIDE gap still merges via that rule; a tight wrap
/// (next line < ~0.3 text heights below) is already the same visual
/// row.
///
/// Known limit: a data row whose serial number was clipped off the
/// page edge (or missed by ML Kit) looks exactly like a wrap
/// continuation of the row above, so it merges into that row instead
/// of starting a new one. Nothing in the geometry can tell the two
/// apart; the phone re-test is what shows whether it happens.
String? reconstructTableText(
  List<({String text, double x, double y, double width, double height})>
      elements,
) {
  final els =
      elements.where((e) => e.text.trim().isNotEmpty).toList();
  // ≥3 rows × ≥5 cells needs at least 15 cells, one element each.
  if (els.length < 15) return null;
  final heights = els.map((e) => e.height).toList()..sort();
  final h = heights[heights.length ~/ 2];
  if (h <= 0) return null;
  final pageWidth =
      els.map((e) => e.x + e.width).reduce((a, b) => a > b ? a : b);

  // 1. Visual rows: sort by top, group by vertical overlap.
  final sorted = List.of(els)..sort((a, b) => a.y.compareTo(b.y));
  final rows =
      <List<({String text, double x, double y, double width, double height})>>[];
  var rowBottom = double.negativeInfinity;
  for (final el in sorted) {
    if (rows.isEmpty || el.y > rowBottom + h * 0.3) {
      rows.add([el]);
      rowBottom = el.y + el.height;
    } else {
      rows.last.add(el);
      if (el.y + el.height > rowBottom) rowBottom = el.y + el.height;
    }
  }

  // 2. Cells within each row: sort by x, split at wide gaps.
  // Inter-word spaces are ~0.3 text heights; column gutters are
  // far wider, so 0.6 heights separates cells without splitting words.
  final cellGap = math.max(10.0, h * 0.6);
  final rowCells = <List<({String text, double x})>>[];
  for (final row in rows) {
    final byX = List.of(row)..sort((a, b) => a.x.compareTo(b.x));
    final cells = <({String text, double x})>[];
    var cellWords = <String>[];
    var cellX = 0.0;
    var cellRight = double.negativeInfinity;
    for (final el in byX) {
      if (cellWords.isEmpty) {
        cellWords.add(el.text);
        cellX = el.x;
        cellRight = el.x + el.width;
      } else if (el.x - cellRight > cellGap) {
        cells.add((text: cellWords.join(' '), x: cellX));
        cellWords = [el.text];
        cellX = el.x;
        cellRight = el.x + el.width;
      } else {
        cellWords.add(el.text);
        if (el.x + el.width > cellRight) cellRight = el.x + el.width;
      }
    }
    if (cellWords.isNotEmpty) {
      cells.add((text: cellWords.join(' '), x: cellX));
    }
    rowCells.add(cells);
  }

  // 3. Column bands from MULTI-CELL rows only: cluster every
  // cell's x-start; a band is "shared" when cells from ≥3 different
  // rows start in it. A real table repeats its columns row after
  // row; justified prose does not. Each cell records its band, so
  // later lookups are exact, not nearest-band guesses.
  final bandGap = math.max(20.0, pageWidth * 0.02);
  final starts = <({double x, int row, int cell})>[];
  for (var r = 0; r < rowCells.length; r++) {
    if (rowCells[r].length < 2) continue;
    for (var ci = 0; ci < rowCells[r].length; ci++) {
      starts.add((x: rowCells[r][ci].x, row: r, cell: ci));
    }
  }
  starts.sort((a, b) => a.x.compareTo(b.x));
  final bandStarts = <double>[];
  final bandRows = <Set<int>>[];
  final rowCellBands = <List<int?>>[
    for (final cells in rowCells) List<int?>.filled(cells.length, null),
  ];
  for (final s in starts) {
    int band;
    if (bandStarts.isEmpty || s.x - bandStarts.last > bandGap) {
      bandStarts.add(s.x);
      bandRows.add({s.row});
      band = bandStarts.length - 1;
    } else {
      band = bandStarts.length - 1;
      bandRows.last.add(s.row);
    }
    rowCellBands[s.row][s.cell] = band;
  }
  var sharedBands = 0;
  for (final rowsInBand in bandRows) {
    if (rowsInBand.length >= 3) sharedBands++;
  }

  // Nearest band within bandGap, for 1-cell rows (which took no part
  // in band building). The merge rule's own ≤20 px gate is the real
  // check; this only narrows the candidate.
  int? bandIndexFor(double x) {
    var best = -1;
    var bestDist = double.infinity;
    for (var b = 0; b < bandStarts.length; b++) {
      final d = (x - bandStarts[b]).abs();
      if (d < bestDist) {
        bestDist = d;
        best = b;
      }
    }
    return bestDist <= bandGap ? best : null;
  }

  // 4. Table-like?
  var wideRows = 0;
  var wideElements = 0;
  for (var r = 0; r < rowCells.length; r++) {
    if (rowCells[r].length >= 5) {
      wideRows++;
      wideElements += rows[r].length;
    }
  }
  if (wideRows < 3 || sharedBands < 5) return null;
  if (wideElements * 2 < els.length) return null;

  // 5. Serial band: the leftmost band holding a bare number
  // (Sr.# cell) in ≥3 rows. The numbers themselves do not matter —
  // the book misnumbers rows (162, 164 after 251/253 in the
  // Interjection table), so only "numeric, in the same band, ≥3
  // times" is checked.
  final serialRe = RegExp(r'^\d{1,4}[.)]?$');
  int? serialBand;
  for (var b = 0; b < bandStarts.length; b++) {
    final numericRows = <int>{};
    for (var r = 0; r < rowCells.length; r++) {
      if (rowCells[r].length < 2) continue;
      for (var ci = 0; ci < rowCells[r].length; ci++) {
        if (rowCellBands[r][ci] == b &&
            serialRe.hasMatch(rowCells[r][ci].text.trim())) {
          numericRows.add(r);
        }
      }
    }
    if (numericRows.length >= 3) {
      serialBand = b;
      break;
    }
  }

  bool rowHasSerial(int r) {
    if (serialBand == null) return false;
    for (var ci = 0; ci < rowCells[r].length; ci++) {
      if (rowCellBands[r][ci] == serialBand &&
          serialRe.hasMatch(rowCells[r][ci].text.trim())) {
        return true;
      }
    }
    return false;
  }

  // 6. Emit LOGICAL rows (see the doc comment for the grouping and
  // one-cell-row rules).
  final out = <List<({String text, double x})>>[];
  final outBands = <List<int?>>[]; // band per cell, parallel to out
  final outIsData = <bool>[]; // row carries a serial cell
  var lastVisualRow = -1;
  var mergeOpen = false; // last emitted row is a table row a tail may join
  for (var r = 0; r < rowCells.length; r++) {
    final cells = rowCells[r];
    if (cells.length >= 2) {
      final isContinuation = serialBand != null &&
          !rowHasSerial(r) &&
          out.isNotEmpty &&
          outIsData.last &&
          r == lastVisualRow + 1;
      if (isContinuation) {
        // Append each cell to the same-band cell of the previous
        // logical row; a cell in a band the row does not have (should
        // not happen for a genuine wrap) is kept as a new cell in
        // band order rather than dropped.
        final prevCells = out.last;
        final prevBands = outBands.last;
        for (var ci = 0; ci < cells.length; ci++) {
          final band = rowCellBands[r][ci];
          final at = band == null ? -1 : prevBands.indexOf(band);
          if (at >= 0) {
            prevCells[at] = (
              text: '${prevCells[at].text} ${cells[ci].text}',
              x: prevCells[at].x,
            );
          } else {
            var insertAt = prevBands.length;
            for (var i = 0; i < prevBands.length; i++) {
              if (band != null &&
                  prevBands[i] != null &&
                  prevBands[i]! > band) {
                insertAt = i;
                break;
              }
            }
            prevCells.insert(insertAt, cells[ci]);
            prevBands.insert(insertAt, band);
          }
        }
        lastVisualRow = r;
        // mergeOpen stays true: a stem tail may still follow.
        continue;
      }
      out.add(List.of(cells));
      outBands.add(List.of(rowCellBands[r]));
      outIsData.add(rowHasSerial(r));
      lastVisualRow = r;
      mergeOpen = true;
      continue;
    }
    if (cells.length == 1) {
      final only = cells.single;
      final lettered =
          RegExp(r'[A-Za-z\u0600-\u06FF]').hasMatch(only.text);
      if (out.isEmpty) {
        // Page-top area: a lettered line is a title; a bare number
        // is a page number.
        if (lettered) {
          out.add(List.of(cells));
          outBands.add([bandIndexFor(only.x)]);
          outIsData.add(false);
          lastVisualRow = r;
          mergeOpen = false; // a title is not a stem to wrap into
        }
        continue;
      }
      // Wrap tail? Merge into the SAME-band cell of the last emitted
      // row — not necessarily the first cell (an option can wrap on
      // its own line). Requires immediacy, a band the row has, and a
      // start within 20 px of that band; a heading-shaped line is
      // never a tail, even when a centred heading happens to start
      // on a band.
      final band = bandIndexFor(only.x);
      if (mergeOpen &&
          band != null &&
          outBands.last.contains(band) &&
          r == lastVisualRow + 1 &&
          (only.x - bandStarts[band]).abs() <= 20 &&
          !_looksLikeHeading(only.text)) {
        final at = outBands.last.indexOf(band);
        final target = out.last[at];
        out.last[at] =
            (text: '${target.text} ${only.text}', x: target.x);
        lastVisualRow = r;
        continue;
      }
      if (lettered) {
        // Mid-page heading ("Interjection", "Parts of Speech
        // Identification") or footer ("Page 5 of 71"): its own
        // line — the parser skips headings and discards a trailing
        // buffer, so both are harmless there.
        out.add(List.of(cells));
        outBands.add([band]);
        outIsData.add(false);
        lastVisualRow = r;
        mergeOpen = false;
      }
      // A bare number mid-page is a page number: dropped.
    }
  }
  return out.map((row) => row.map((c) => c.text).join(' | ')).join('\n');
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
