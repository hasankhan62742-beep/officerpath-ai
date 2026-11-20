import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'answer_key.dart';
import 'book_structure.dart';
import 'mcq_parser.dart';

/// Hardened, fast PDF text extractor — pure Dart, no dependencies.
///
/// The previous extractor (v1) did `latin1.decode()` on the WHOLE file
/// and ran lazy `[\s\S]*?` regexes across megabytes, including inflating
/// every stream — even image streams, which can inflate to tens of MB of
/// raster data. On a real phone that blocked the UI thread for seconds
/// and Android showed "isn't responding" (ANR) — even for a 2 MB PDF.
///
/// This version is different in every way that matters:
/// * **Byte-level, incremental:** the file is scanned for object/stream
///   markers with a small byte search. The whole file is NEVER decoded
///   into one giant string and NO lazy dot-all regex runs across
///   megabytes. Only the small object dictionaries and the streams a
///   page actually references are decoded.
/// * **Image streams are never inflated:** only streams referenced by a
///   page's `/Contents` are decompressed. Image XObjects (`/Subtype
///   /Image`) are skipped entirely — they are what made v1 slow.
/// * **Per-page results:** text is returned page by page, so pages with
///   no text layer can be sent to OCR individually.
/// * **Real content-stream interpreter:** literal strings, hex strings,
///   `Tj` / `TJ` / `'` / `"` operators, `Td` / `TD` / `Tm` / `T*` line
///   breaks (so the MCQ parser still sees one question/option per
///   line), and **ToUnicode CMaps** (`bfchar` / `bfrange`) so custom /
///   CID fonts decode to the right characters instead of garbage.
/// * **Filter chains:** a stream's `/Filter` list is decoded in order,
///   so ReportLab's `[ /ASCII85Decode /FlateDecode ]` content streams
///   (and ASCIIHex) extract instead of silently yielding nothing. The
///   CMap code length comes from its `begincodespacerange` — 2-byte
///   CID fonts start their codes at 1, and inferring the length from
///   the largest key would decode them as 1-byte codes (NUL-separated
///   garbage, which is what garbled Urdu previews).
/// * **Form XObjects:** content drawn via `/XObject /Fm Do` is
///   interpreted recursively (depth cap 8, cycle guard), with the
///   form's own /Resources merged over the enclosing stream's.
/// * **Object streams:** page/font/resource objects stored in
///   compressed object streams (`/ObjStm`) are unpacked and indexed
///   like regular objects, so those books no longer fall through to
///   OCR for every page.
/// * **Page order:** pages come back in /Pages /Kids order (recursing
///   into nested /Pages nodes), not file order — some producers emit
///   page objects out of order.
///
/// Known limits (honest):
/// * Encrypted PDFs (password-protected) cannot be read.
/// * Text drawn with exotic encodings and no ToUnicode map may still
///   decode imperfectly; the upload screen shows a preview + parsed
///   count before saving, so bad parses are never saved silently.
/// * A producer that lays Urdu/Arabic text out in VISUAL order (glyphs
///   in reading-reversed order, no ToUnicode map to recover the
///   logical order) cannot be un-reversed reliably — such a book still
///   needs its text layer re-exported in logical order.
/// * OCR for scanned pages reads Latin script only (ML Kit); a scanned
///   Urdu-script book still cannot be read.

/// Text of one PDF page, in document order. [page] is 1-based.
class PdfPageText {
  const PdfPageText({required this.page, required this.text});

  final int page;
  final String text;

  bool get hasText => text.trim().isNotEmpty;
}

/// Thrown when a PDF is corrupt / truncated (v1.2 fail-fast).
/// The app shows [message] and never ANRs or imports garbage from
/// such a file. [message] is already user-facing (Roman Urdu + plain
/// English), never a raw parser error.
class CorruptPdfException implements Exception {
  const CorruptPdfException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Checks a PDF's structure BEFORE any extraction or parsing runs
/// (fast: only the header + the last 8 KB + the xref object are
/// read). Returns null when the file looks structurally sound, or a
/// user-facing reason when it does not.
///
/// What it catches (File 4, Ayesha Jalal, 4.5 MB): the file HAS a
/// `%PDF-` header and a `startxref` pointer, but its xref stream
/// fails to decompress ("invalid distance too far back") — exactly
/// what `pdftotext` reports as "Couldn't find trailer dictionary /
/// Couldn't read xref table". Without this gate the extractor
/// returned 448 phantom pages / ~1,094,418 chars and the parser
/// imported 5 spurious questions from that garbage.
///
/// Rules:
/// * No `%PDF-` header → not a PDF.
/// * A `startxref` pointer that is out of range, or points at
///   neither an `xref` table nor a decodable `/Type /XRef` stream →
///   the index is broken (File 4: its xref stream fails to
///   decompress) → corrupt.
/// * NO `startxref` and NO `trailer` at all → NOT flagged: minimal
///   hand-built PDFs (the test fixtures, and some real producers)
///   carry no index, and the object-scan extractor still reads them
///   fine. Only a PRESENT-but-broken index is corruption — the
///   garbage gate below is the backstop for index-less garbage.
String? detectPdfCorruption(Uint8List bytes) {
  if (bytes.length < 8) {
    return 'File bahut chhoti hai — ye poori PDF nahi lagti.';
  }
  if (latin1.decode(bytes.sublist(0, 5)) != '%PDF-') {
    return 'Ye PDF file nahi lagti (PDF header nahi mila).';
  }
  final tailStart = bytes.length > 8192 ? bytes.length - 8192 : 0;
  final tail = latin1.decode(bytes.sublist(tailStart));
  final starts = RegExp(r'startxref\s*(\d+)').allMatches(tail).toList();
  if (starts.isEmpty) {
    // No index pointer at all: minimal/index-less PDFs are still
    // readable by the object-scan extractor — not corruption.
    return null;
  }
  final offset = int.tryParse(starts.last.group(1)!);
  if (offset == null || offset < 0 || offset >= bytes.length) {
    return 'Is PDF ka index kharab hai — file kharab ya incomplete '
        'download lagti hai. Dobara download karein.';
  }
  final headLen = offset + 16 > bytes.length ? bytes.length - offset : 16;
  final at = latin1.decode(bytes.sublist(offset, offset + headLen));
  if (at.startsWith('xref')) return null;
  final objMatch = RegExp(r'^(\d+)\s+\d+\s+obj').firstMatch(at);
  if (objMatch == null) {
    return 'Is PDF ka index (xref table) nahi parha gaya — file '
        'kharab ya incomplete download lagti hai. Dobara download '
        'karein.';
  }
  final num = int.parse(objMatch.group(1)!);
  var bodyStart = offset + objMatch.end;
  if (bodyStart < bytes.length && bytes[bodyStart] == 0x0D) bodyStart++;
  if (bodyStart < bytes.length && bytes[bodyStart] == 0x0A) bodyStart++;
  final endIdx = _indexOf(bytes, _endobjKw, bodyStart);
  final bodyEnd = endIdx < 0 ? bytes.length : endIdx;
  final obj = _Obj(num, bodyStart, bodyEnd);
  final dict = _dictText(bytes, obj);
  if (!dict.contains('/XRef')) {
    return 'Is PDF ka index (xref table) nahi parha gaya — file '
        'kharab ya incomplete download lagti hai. Dobara download '
        'karein.';
  }
  final streamBytes = _streamBytes(bytes, obj);
  if (streamBytes == null) return null; // Trailer-dict style: OK.
  if (_decodeStream(bytes, obj, streamBytes) == null) {
    return 'Is PDF ka index (xref table) nahi parha gaya — file '
        'kharab ya incomplete download lagti hai. Dobara download '
        'karein.';
  }
  return null;
}

/// Extracts text page by page. Pure Dart — safe to run in an isolate
/// (see [processPdfInBackground]).
///
/// Returns an empty list when no page objects could be found; callers
/// should then fall back to OCR.
List<PdfPageText> extractPdfPages(Uint8List bytes) {
  final objects = _allObjects(bytes);
  if (objects.isEmpty) return const [];

  final byNum = <int, _Obj>{};
  for (final o in objects) {
    byNum.putIfAbsent(o.num, () => o);
  }

  // Page objects, in /Pages /Kids order when the page tree is readable
  // (file order == document order in practice, but some producers emit
  // page objects out of order — the Kids order is authoritative).
  final pages = <_Obj>[];
  for (final o in objects) {
    final body = _bodyText(bytes, o);
    if (_isPageObject(body)) pages.add(o);
  }
  if (pages.isEmpty) {
    // Degenerate PDF: no page objects. Fall back to scanning streams.
    return _extractWithoutPages(bytes);
  }
  _orderPagesByTree(bytes, byNum, pages);

  final ctx = _InterpCtx(bytes, byNum);
  final out = <PdfPageText>[];
  for (var i = 0; i < pages.length; i++) {
    final pageObj = pages[i];
    final body = _bodyText(bytes, pageObj);
    final contentRefs = _contentRefs(bytes, byNum, body);
    final res = _pageResources(bytes, byNum, body);
    final pageLines = <_TextLine>[];
    for (final ref in contentRefs) {
      final streamObj = byNum[ref];
      if (streamObj == null) continue;
      final streamBytes = _streamBytes(bytes, streamObj);
      if (streamBytes == null) continue;
      final decoded = _decodeStream(bytes, streamObj, streamBytes);
      if (decoded == null) continue;
      // Content streams are byte-oriented; latin1 maps bytes 1:1 to
      // code units, which is what the tokenizer works on.
      pageLines.addAll(
        _interpretContentStream(latin1.decode(decoded), res, ctx),
      );
    }
    final ordered = _orderLinesForColumns(pageLines);
    out.add(
      PdfPageText(
        page: i + 1,
        text: _clean(ordered.map((l) => l.text).join('\n')),
      ),
    );
  }
  return out;
}

/// Fallback for degenerate PDFs with no page objects at all (e.g. a
/// lone content stream): interpret every non-image stream in file
/// order as a single page. Image streams are still never inflated.
List<PdfPageText> _extractWithoutPages(Uint8List bytes) {
  final objects = _allObjects(bytes);
  final byNum = <int, _Obj>{};
  for (final o in objects) {
    byNum.putIfAbsent(o.num, () => o);
  }
  final ctx = _InterpCtx(bytes, byNum);
  final pageLines = <_TextLine>[];
  for (final obj in objects) {
    if (obj.bodyBytes != null) continue; // ObjStm members have no streams.
    final dictEnd = _indexOf(bytes, _streamKw, obj.bodyStart);
    if (dictEnd < 0 || dictEnd > obj.bodyEnd) continue;
    final dict = latin1.decode(
      bytes.sublist(obj.bodyStart, dictEnd),
    );
    if (dict.contains('/Image')) continue;
    final streamBytes = _streamBytes(bytes, obj);
    if (streamBytes == null) continue;
    final decoded = _decodeStream(bytes, obj, streamBytes);
    if (decoded == null) continue;
    pageLines.addAll(
      _interpretContentStream(
        latin1.decode(decoded),
        _Resources.empty,
        ctx,
      ),
    );
  }
  final ordered = _orderLinesForColumns(pageLines);
  final text = _clean(ordered.map((l) => l.text).join('\n'));
  if (text.isEmpty) return const [];
  return [PdfPageText(page: 1, text: text)];
}

/// Backwards-compatible whole-document extraction (used by old tests).
/// Prefer [extractPdfPages] — it also tells you which pages are empty.
String extractTextFromPdfBytes(Uint8List bytes) {
  return extractPdfPages(bytes).map((p) => p.text).join('\n\n');
}

// ---------------------------------------------------------------------------
// Byte-level object index
// ---------------------------------------------------------------------------

class _Obj {
  const _Obj(this.num, this.bodyStart, this.bodyEnd, [this.bodyBytes]);

  final int num;
  final int bodyStart;
  final int bodyEnd;

  /// When non-null, the body lives in this buffer (a member of a
  /// compressed object stream) instead of in the file bytes.
  final Uint8List? bodyBytes;
}

const _objKw = [0x6F, 0x62, 0x6A]; // "obj"
const _endobjKw = [0x65, 0x6E, 0x64, 0x6F, 0x62, 0x6A]; // "endobj"

int _indexOf(Uint8List hay, List<int> needle, [int from = 0]) {
  if (needle.isEmpty || hay.length < needle.length) return -1;
  final last = hay.length - needle.length;
  for (var i = from < 0 ? 0 : from; i <= last; i++) {
    if (hay[i] != needle[0]) continue;
    var ok = true;
    for (var k = 1; k < needle.length; k++) {
      if (hay[i + k] != needle[k]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

List<int> _allIndices(Uint8List hay, List<int> needle) {
  final out = <int>[];
  var from = 0;
  while (true) {
    final idx = _indexOf(hay, needle, from);
    if (idx < 0) break;
    out.add(idx);
    from = idx + needle.length;
  }
  return out;
}

bool _isDigit(int b) => b >= 0x30 && b <= 0x39;

/// Finds every `N 0 obj` header in the file (object dictionaries only —
/// the header must start at a line start, so matches inside binary
/// stream data are rejected).
List<_Obj> _indexObjects(Uint8List bytes) {
  final endobjOffsets = _allIndices(bytes, _endobjKw);
  final out = <_Obj>[];
  var from = 0;
  while (true) {
    final idx = _indexOf(bytes, _objKw, from);
    if (idx < 0) break;
    from = idx + _objKw.length;
    // Walk back: spaces, gen number, spaces, obj number.
    var j = idx - 1;
    while (j >= 0 && (bytes[j] == 0x20 || bytes[j] == 0x09)) {
      j--;
    }
    final genEnd = j + 1;
    while (j >= 0 && _isDigit(bytes[j])) {
      j--;
    }
    if (j + 1 >= genEnd) continue;
    while (j >= 0 && (bytes[j] == 0x20 || bytes[j] == 0x09)) {
      j--;
    }
    final numEnd = j + 1;
    while (j >= 0 && _isDigit(bytes[j])) {
      j--;
    }
    if (j + 1 >= numEnd) continue;
    // The byte before the object number must be a line break (or BOF).
    if (j >= 0 && bytes[j] != 0x0A && bytes[j] != 0x0D) continue;
    final num = int.tryParse(
      latin1.decode(bytes.sublist(j + 1, numEnd)),
    );
    if (num == null) continue;
    var bodyStart = idx + _objKw.length;
    if (bodyStart < bytes.length && bytes[bodyStart] == 0x0D) {
      bodyStart++;
    }
    if (bodyStart < bytes.length && bytes[bodyStart] == 0x0A) {
      bodyStart++;
    }
    // Body ends at the first "endobj" after the header.
    var bodyEnd = bytes.length;
    for (final e in endobjOffsets) {
      if (e > bodyStart) {
        bodyEnd = e;
        break;
      }
    }
    out.add(_Obj(num, bodyStart, bodyEnd));
  }
  return out;
}

/// Every object in the file: regular `N 0 obj` objects plus the
/// members of compressed object streams (/ObjStm) — some producers
/// store page objects, fonts and resource dicts there, and the plain
/// index never sees them, so those books used to fall through to OCR
/// for every page.
List<_Obj> _allObjects(Uint8List bytes) {
  final objects = _indexObjects(bytes);
  if (objects.isEmpty) return objects;
  final seen = <int>{for (final o in objects) o.num};
  // Snapshot: members are appended to [objects] below, so the loop
  // must not iterate the list it grows (ConcurrentModificationError).
  for (final o in List.of(objects)) {
    for (final v in _objectStreamMembers(bytes, o)) {
      if (seen.add(v.num)) objects.add(v);
    }
  }
  return objects;
}

/// Members of one compressed object stream (/ObjStm): the stream holds
/// N object bodies back to back (no `obj`/`endobj` keywords), located
/// by the N (object number, byte offset) pairs at the start of the
/// stream. Streams cannot live inside an object stream, so members are
/// dictionary-only objects (page objects, fonts, resources) — exactly
/// the objects the plain index misses. Returns [] for anything
/// malformed; a corrupt object stream must never abort extraction.
List<_Obj> _objectStreamMembers(Uint8List bytes, _Obj obj) {
  final dictEnd = _indexOf(bytes, _streamKw, obj.bodyStart);
  if (dictEnd < 0 || dictEnd > obj.bodyEnd) return const [];
  final dict = latin1.decode(bytes.sublist(obj.bodyStart, dictEnd));
  if (!dict.contains('/ObjStm')) return const [];
  final nMatch = RegExp(r'/N\s+(\d+)').firstMatch(dict);
  final firstMatch = RegExp(r'/First\s+(\d+)').firstMatch(dict);
  if (nMatch == null || firstMatch == null) return const [];
  final n = int.parse(nMatch.group(1)!);
  final first = int.parse(firstMatch.group(1)!);
  if (n <= 0 || n > 10000 || first < 0) return const [];
  final streamBytes = _streamBytes(bytes, obj);
  if (streamBytes == null) return const [];
  final decoded = _decodeStream(bytes, obj, streamBytes);
  if (decoded == null || decoded.length <= first) return const [];
  // Header: N pairs of integers (object number, byte offset).
  final headerText = latin1.decode(decoded.sublist(0, first));
  final pairs = RegExp(r'(\d+)\s+(\d+)').allMatches(headerText).toList();
  if (pairs.length < n) return const [];
  final out = <_Obj>[];
  for (var i = 0; i < n; i++) {
    final num = int.parse(pairs[i].group(1)!);
    final off = int.parse(pairs[i].group(2)!);
    final start = first + off;
    final end = i + 1 < n
        ? first + int.parse(pairs[i + 1].group(2)!)
        : decoded.length;
    if (start < first || start >= end || end > decoded.length) continue;
    out.add(_Obj(num, start, end, decoded));
  }
  return out;
}

/// Page object numbers in /Pages /Kids order (recursing into nested
/// /Pages nodes), or [] when the page tree cannot be read. The Kids
/// order is the document order; file order is only a fallback.
List<int> _pageOrderFromTree(Uint8List bytes, Map<int, _Obj> byNum) {
  _Obj? catalog;
  for (final obj in byNum.values) {
    final body = _bodyText(bytes, obj);
    if (!body.contains('/Catalog')) continue;
    if (RegExp(r'/Type\s*/Catalog(?![A-Za-z])').hasMatch(body)) {
      catalog = obj;
      break;
    }
  }
  if (catalog == null) return const [];
  final pagesRef = RegExp(
    r'/Pages\s+(\d+)\s+\d+\s+R',
  ).firstMatch(_bodyText(bytes, catalog));
  if (pagesRef == null) return const [];
  return _collectKids(
    bytes,
    byNum,
    int.parse(pagesRef.group(1)!),
    <int>{},
  );
}

List<int> _collectKids(
  Uint8List bytes,
  Map<int, _Obj> byNum,
  int nodeNum,
  Set<int> seen,
) {
  if (!seen.add(nodeNum)) return const []; // cycle guard
  final node = byNum[nodeNum];
  if (node == null) return const [];
  final kids = RegExp(
    r'/Kids\s*\[([^\]]*)\]',
  ).firstMatch(_bodyText(bytes, node));
  if (kids == null) return const [];
  final out = <int>[];
  for (final m in RegExp(r'(\d+)\s+\d+\s+R').allMatches(kids.group(1)!)) {
    final childNum = int.parse(m.group(1)!);
    final child = byNum[childNum];
    if (child == null) continue;
    if (RegExp(r'/Type\s*/Pages(?![A-Za-z])')
        .hasMatch(_bodyText(bytes, child))) {
      out.addAll(_collectKids(bytes, byNum, childNum, seen));
    } else {
      out.add(childNum);
    }
  }
  return out;
}

/// Reorders [pages] (in place) into /Pages /Kids order. Pages missing
/// from the tree keep their relative file order, after the ordered
/// ones. A no-op when the tree cannot be read.
void _orderPagesByTree(
  Uint8List bytes,
  Map<int, _Obj> byNum,
  List<_Obj> pages,
) {
  final order = _pageOrderFromTree(bytes, byNum);
  if (order.isEmpty) return;
  final rank = <int, int>{};
  for (var i = 0; i < order.length; i++) {
    rank.putIfAbsent(order[i], () => i);
  }
  final fileIndex = <int, int>{};
  for (var i = 0; i < pages.length; i++) {
    fileIndex[pages[i].num] = i;
  }
  pages.sort((a, b) {
    final ra = rank[a.num] ?? order.length + (fileIndex[a.num] ?? 0);
    final rb = rank[b.num] ?? order.length + (fileIndex[b.num] ?? 0);
    return ra.compareTo(rb);
  });
}

/// Small latin1 decode of an object dictionary (never a whole file).
String _bodyText(Uint8List bytes, _Obj obj) {
  final src = obj.bodyBytes ?? bytes;
  final end = obj.bodyEnd <= src.length ? obj.bodyEnd : src.length;
  if (obj.bodyStart >= end) return '';
  // Dictionaries are short; cap the decode so a corrupt offset can't
  // turn this into a giant string.
  final len = end - obj.bodyStart;
  final capped = len > 65536 ? 65536 : len;
  return latin1.decode(src.sublist(obj.bodyStart, obj.bodyStart + capped));
}

/// Dictionary portion of an object (everything before `stream`, or the
/// whole body when there is no stream), as latin1 text. Used for
/// XObject / Resources dicts, where a match inside stream bytes would
/// be a false positive.
String _dictText(Uint8List bytes, _Obj obj) {
  final src = obj.bodyBytes ?? bytes;
  var end = obj.bodyEnd <= src.length ? obj.bodyEnd : src.length;
  final sIdx = _indexOf(src, _streamKw, obj.bodyStart);
  if (sIdx >= 0 && sIdx < end) end = sIdx;
  if (obj.bodyStart >= end) return '';
  final len = end - obj.bodyStart;
  final capped = len > 65536 ? 65536 : len;
  return latin1.decode(src.sublist(obj.bodyStart, obj.bodyStart + capped));
}

bool _isPageObject(String body) {
  // "/Type /Page" but not "/Type /Pages".
  return RegExp(r'/Type\s*/Page(?![A-Za-z])').hasMatch(body);
}

/// Object numbers referenced by a page's /Contents (single ref or array).
/// Content-stream refs for a page. /Contents may be a single ref, an
/// inline array of refs, or — as Skia / print-to-PDF emits — a ref to
/// an ARRAY object ("/Contents 321 0 R" where 321 is
/// "[ 319 0 R 22 0 R 320 0 R ]"). Array objects resolve recursively
/// (nested arrays, cycles guarded); a ref to a non-array object is a
/// single stream, as before. Stream refs are de-duplicated, in order.
List<int> _contentRefs(
  Uint8List bytes,
  Map<int, _Obj> byNum,
  String pageBody,
) {
  final m = RegExp(r'/Contents\s+').firstMatch(pageBody);
  if (m == null) return const [];
  final rest = pageBody.substring(m.end).trimLeft();
  final refs = <int>[];
  final seen = <int>{}; // Cycle guard for arrays + dedupe for streams.

  void expandRef(int num) {
    if (!seen.add(num)) return;
    final obj = byNum[num];
    if (obj == null) {
      // Dangling ref — the caller skips it (byNum lookup).
      refs.add(num);
      return;
    }
    final body = _bodyText(bytes, obj).trimLeft();
    if (!body.startsWith('[')) {
      refs.add(num);
      return;
    }
    // Array object: expand its member refs, recursively.
    for (final rm in RegExp(r'(\d+)\s+\d+\s+R').allMatches(body)) {
      expandRef(int.parse(rm.group(1)!));
    }
  }

  if (rest.startsWith('[')) {
    // Inline array: /Contents [ 4 0 R 5 0 R ].
    final end = rest.indexOf(']');
    final inner = end < 0 ? rest : rest.substring(0, end);
    for (final rm in RegExp(r'(\d+)\s+\d+\s+R').allMatches(inner)) {
      expandRef(int.parse(rm.group(1)!));
    }
  } else {
    final single = RegExp(r'^(\d+)\s+\d+\s+R').firstMatch(rest);
    if (single == null) return const [];
    expandRef(int.parse(single.group(1)!));
  }
  return refs;
}

// ---------------------------------------------------------------------------
// Fonts + ToUnicode CMaps
// ---------------------------------------------------------------------------

class _CMap {
  _CMap(this.map, this.codeLength, {this.identity = false});

  final Map<int, String> map;
  final int codeLength; // 1 or 2 bytes per code (4 is treated as 2 pairs)

  /// True when the CMap carries an identity range (`<lo> <hi> <lo>`):
  /// any code not in [map] decodes to itself (the code IS the
  /// Unicode code point). Identity CMaps (common for embedded subsets
  /// such as the Pace book's DejaVuSans) map the whole `<0000>`–`<FFFF>`
  /// range to itself, so the map is deliberately left empty — building
  /// 65,536 entries would be pure waste.
  final bool identity;
}

/// What a content stream may name: its fonts (with ToUnicode maps)
/// and its XObjects (name -> object number). Resolved from a
/// /Resources dictionary (inline or referenced). [fontBold] records,
/// per font resource name, whether the font is bold (its /BaseFont
/// contains "bold", e.g. DejaVuSans-Bold, Arial-BoldMT,
/// Helvetica-Bold) — the interpreter uses it to mark bold text runs,
/// which the parser reads as the "bold" answer signal.
class _Resources {
  const _Resources(this.fonts, this.xobjects, [this.fontBold = const {}]);

  final Map<String, _CMap?> fonts;
  final Map<String, int> xobjects;
  final Map<String, bool> fontBold;

  static const empty = _Resources({}, {});
}

/// Shared read-only state for one extraction: the file bytes and the
/// object index. Passed down into nested Form XObject interpretation.
class _InterpCtx {
  const _InterpCtx(this.bytes, this.byNum);

  final Uint8List bytes;
  final Map<int, _Obj> byNum;
}

/// Inner text of `/Key << ... >>` inside [text] (balanced `<<`/`>>`,
/// string literals skipped), or null when the key has no inline dict.
String? _findSubDict(String text, String key) {
  final m = RegExp('/$key\\s*<<').firstMatch(text);
  if (m == null) return null;
  var depth = 0;
  var i = m.end - 2; // at the opening '<<'
  final start = i + 2;
  while (i < text.length) {
    if (text.codeUnitAt(i) == 0x28) {
      i = _readLiteral(text, i).next;
      continue;
    }
    if (i + 1 < text.length &&
        text.codeUnitAt(i) == 0x3C &&
        text.codeUnitAt(i + 1) == 0x3C) {
      depth++;
      i += 2;
      continue;
    }
    if (i + 1 < text.length &&
        text.codeUnitAt(i) == 0x3E &&
        text.codeUnitAt(i + 1) == 0x3E) {
      depth--;
      i += 2;
      if (depth == 0) return text.substring(start, i - 2);
      continue;
    }
    i++;
  }
  return null;
}

/// Fonts + XObjects named by one /Resources dictionary's text.
/// /Font and /XObject may each be inline or an indirect reference.
_Resources _parseResources(
  Uint8List bytes,
  Map<int, _Obj> byNum,
  String text,
) {
  final fonts = <String, _CMap?>{};
  final xobjects = <String, int>{};
  final fontBold = <String, bool>{};

  String? dictFor(String key) {
    final inline = _findSubDict(text, key);
    if (inline != null) return inline;
    final ref = RegExp('/$key\\s+(\\d+)\\s+\\d+\\s+R').firstMatch(text);
    if (ref == null) return null;
    final obj = byNum[int.parse(ref.group(1)!)];
    if (obj == null) return null;
    return _dictText(bytes, obj);
  }

  final fontText = dictFor('Font');
  if (fontText != null) {
    for (final m in RegExp(r'/(\S+)\s+(\d+)\s+\d+\s+R')
        .allMatches(fontText)) {
      // Group 1 includes the leading slash ("/F1"); Tf names don't.
      final name = m.group(1)!.replaceFirst(RegExp(r'^/'), '');
      final fontObj = byNum[int.parse(m.group(2)!)];
      if (fontObj == null) {
        fonts[name] = null;
        continue;
      }
      fonts[name] = _fontCMap(bytes, byNum, fontObj);
      // Bold detection: the font's /BaseFont name contains "bold"
      // (subset prefixes like "MPDFAA+" are part of the name).
      final baseFont = RegExp(
        r'/BaseFont\s*/([^\s/>]+)',
      ).firstMatch(_bodyText(bytes, fontObj))?.group(1);
      fontBold[name] =
          baseFont != null && baseFont.toLowerCase().contains('bold');
    }
  }
  final xoText = dictFor('XObject');
  if (xoText != null) {
    for (final m in RegExp(r'/(\S+)\s+(\d+)\s+\d+\s+R').allMatches(xoText)) {
      final name = m.group(1)!.replaceFirst(RegExp(r'^/'), '');
      xobjects[name] = int.parse(m.group(2)!);
    }
  }
  return _Resources(fonts, xobjects, fontBold);
}

/// ToUnicode map of one font object, or null when it has none.
_CMap? _fontCMap(Uint8List bytes, Map<int, _Obj> byNum, _Obj fontObj) {
  final fontBody = _bodyText(bytes, fontObj);
  final uniRef = RegExp(
    r'/ToUnicode\s+(\d+)\s+\d+\s+R',
  ).firstMatch(fontBody);
  if (uniRef == null) return null;
  final cmapObj = byNum[int.parse(uniRef.group(1)!)];
  if (cmapObj == null) return null;
  final streamBytes = _streamBytes(bytes, cmapObj);
  if (streamBytes == null) return null;
  final decoded = _decodeStream(bytes, cmapObj, streamBytes);
  if (decoded == null) return null;
  return _parseCMap(latin1.decode(decoded));
}

/// Resolves a page's /Resources: the object its /Resources entry
/// points at, or the page dict itself when /Resources is inline.
/// (The old code searched the page body directly for the Font dict
/// with a non-greedy `>>` regex that could swallow the Font dict's
/// own closing `>>` and never match — the balanced scan above fixes
/// that too.)
_Resources _pageResources(
  Uint8List bytes,
  Map<int, _Obj> byNum,
  String pageBody,
) {
  final resRef = RegExp(r'/Resources\s+(\d+)\s+\d+\s+R').firstMatch(pageBody);
  if (resRef != null) {
    final resObj = byNum[int.parse(resRef.group(1)!)];
    if (resObj != null) {
      return _parseResources(bytes, byNum, _dictText(bytes, resObj));
    }
  }
  return _parseResources(bytes, byNum, pageBody);
}

/// Resources in effect inside a Form XObject: the form's own
/// /Resources when it has one (its names win), falling back to the
/// enclosing stream's resources for names the form does not define —
/// real producers split fonts between the two, and the spec lets a
/// form without /Resources inherit the enclosing resources outright.
_Resources _formResources(
  Uint8List bytes,
  Map<int, _Obj> byNum,
  _Obj formObj,
  _Resources parent,
) {
  final dict = _dictText(bytes, formObj);
  String? resText;
  final ref = RegExp(r'/Resources\s+(\d+)\s+\d+\s+R').firstMatch(dict);
  if (ref != null) {
    final resObj = byNum[int.parse(ref.group(1)!)];
    if (resObj != null) resText = _dictText(bytes, resObj);
  } else if (dict.contains('/Resources')) {
    resText = dict;
  }
  if (resText == null) return parent;
  final own = _parseResources(bytes, byNum, resText);
  return _Resources(
    {...parent.fonts, ...own.fonts},
    {...parent.xobjects, ...own.xobjects},
    {...parent.fontBold, ...own.fontBold},
  );
}

int _hexToInt(String hex) {
  var v = 0;
  for (var i = 0; i < hex.length; i++) {
    v = v * 16 + int.parse(hex[i], radix: 16);
  }
  return v;
}

/// Hex bytes -> Unicode string (UTF-16BE; handles surrogate pairs).
String _hexToUnicode(String hex) {
  var h = hex;
  if (h.length.isOdd) h += '0';
  final units = <int>[];
  for (var i = 0; i < h.length; i += 4) {
    final chunk = h.substring(i, i + 4 > h.length ? h.length : i + 4);
    units.add(int.parse(chunk.padLeft(4, '0'), radix: 16));
  }
  if (units.isEmpty) return '';
  return String.fromCharCodes(units);
}

/// A UTF-16 code point value -> string (used for bfrange destinations).
/// Out-of-range codes (negative, > U+10FFFF, or a lone surrogate —
/// a malformed CMap can carry them, e.g. the Examveda file) map to
/// U+FFFD instead of throwing: a bad CMap entry must never crash the
/// whole import.
String _codeToUnicode(int code) {
  if (code < 0 || code > 0x10FFFF) return '�';
  if (code >= 0xD800 && code <= 0xDFFF) return '�';
  if (code <= 0xFFFF) return String.fromCharCode(code);
  final v = code - 0x10000;
  return String.fromCharCodes([0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF)]);
}

_CMap? _parseCMap(String text) {
  final map = <int, String>{};
  // Longest key seen, in bytes (hex digits / 2). A key written as
  // <0050> is a 2-byte code even though its VALUE (0x50) fits in one
  // byte — inferring the length from the value alone wrongly decodes
  // 2-byte CID fonts as 1-byte codes (NUL-separated garbage).
  var maxKeyBytes = 1;
  var identity = false;
  final bfcharRe = RegExp(r'beginbfchar([\s\S]*?)endbfchar');
  for (final m in bfcharRe.allMatches(text)) {
    final body = m.group(1)!;
    for (final p in RegExp(
      r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>',
    ).allMatches(body)) {
      final keyLen = (p.group(1)!.length + 1) ~/ 2;
      if (keyLen > maxKeyBytes) maxKeyBytes = keyLen;
      map[_hexToInt(p.group(1)!)] = _hexToUnicode(p.group(2)!);
    }
  }
  final bfrangeRe = RegExp(r'beginbfrange([\s\S]*?)endbfrange');
  for (final m in bfrangeRe.allMatches(text)) {
    final body = m.group(1)!;
    // Array form: <lo> <hi> [<d1> <d2> ...]
    for (final a in RegExp(
      r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*\[([^\]]*)\]',
    ).allMatches(body)) {
      final lo = _hexToInt(a.group(1)!);
      final keyLen = (a.group(1)!.length + 1) ~/ 2;
      if (keyLen > maxKeyBytes) maxKeyBytes = keyLen;
      final dsts = RegExp(
        r'<([0-9A-Fa-f]+)>',
      ).allMatches(a.group(3)!).map((d) => _hexToUnicode(d.group(1)!));
      var k = 0;
      for (final d in dsts) {
        map[lo + k] = d;
        k++;
      }
    }
    // Single-destination form: <lo> <hi> <dst>
    for (final s in RegExp(
      r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>',
    ).allMatches(body)) {
      final lo = _hexToInt(s.group(1)!);
      final hi = _hexToInt(s.group(2)!);
      final base = _hexToInt(s.group(3)!);
      final keyLen = (s.group(1)!.length + 1) ~/ 2;
      if (keyLen > maxKeyBytes) maxKeyBytes = keyLen;
      if (hi - lo > 10000) {
        // Huge range: only an IDENTITY range (dst == lo, code maps to
        // itself, e.g. <0000> <FFFF> <0000>) is usable without building
        // 65k entries — record it as identity and decode codes to
        // themselves. A huge non-identity range stays skipped (corrupt
        // range guard).
        if (base == lo) identity = true;
        continue;
      }
      for (var code = lo; code <= hi; code++) {
        map[code] = _codeToUnicode(base + (code - lo));
      }
    }
  }
  // Code length comes from the codespacerange when present. Real
  // 2-byte CID fonts start their codes at 1, so inferring the length
  // from the largest key VALUE (all <= 0xFF) would wrongly decode them
  // as 1-byte codes — NUL-separated garbage, which is what garbled
  // Urdu previews. Only fall back to key inference when the CMap
  // carries no codespacerange at all.
  var codeLength = 1;
  var haveRange = false;
  final csrRe = RegExp(r'begincodespacerange([\s\S]*?)endcodespacerange');
  for (final m in csrRe.allMatches(text)) {
    for (final p in RegExp(
      r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>',
    ).allMatches(m.group(1)!)) {
      final len = (p.group(1)!.length + 1) ~/ 2; // hex digits -> bytes
      if (len > codeLength) codeLength = len;
      haveRange = true;
    }
  }
  // An identity range (or a codespacerange) is a usable CMap even
  // with an empty explicit map — returning null here would make the
  // decoder fall back to raw bytes (NUL-separated garbage).
  if (map.isEmpty && !identity && !haveRange) return null;
  if (!haveRange) {
    // Key LENGTH (hex digits), not key value: <0050> is 2 bytes.
    if (maxKeyBytes > codeLength) codeLength = maxKeyBytes;
    for (final k in map.keys) {
      if (k > 0xFFFF) {
        codeLength = 4;
      } else if (k > 0xFF && codeLength < 2) {
        codeLength = 2;
      }
    }
  }
  return _CMap(map, codeLength, identity: identity);
}

// ---------------------------------------------------------------------------
// Stream location + decoding (only for referenced streams)
// ---------------------------------------------------------------------------

const _streamKw = [0x73, 0x74, 0x72, 0x65, 0x61, 0x6D]; // "stream"
const _endstreamKw = [
  0x65, 0x6E, 0x64, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6D,
]; // "endstream"

/// Raw bytes of an object's stream, or null when the object has none.
/// The `stream` keyword must be followed by CRLF or LF (per spec).
/// Object-stream members never have streams — their offsets are into
/// the object-stream payload, not the file, so they return null here.
Uint8List? _streamBytes(Uint8List bytes, _Obj obj) {
  if (obj.bodyBytes != null) return null;
  var idx = _indexOf(bytes, _streamKw, obj.bodyStart);
  if (idx < 0 || idx > obj.bodyEnd) return null;
  var dataStart = idx + _streamKw.length;
  if (dataStart < bytes.length && bytes[dataStart] == 0x0D) {
    dataStart++;
  }
  if (dataStart < bytes.length && bytes[dataStart] == 0x0A) {
    dataStart++;
  } else if (dataStart == idx + _streamKw.length) {
    return null; // "stream" not followed by EOL — not a real stream
  }
  final endIdx = _indexOf(bytes, _endstreamKw, dataStart);
  if (endIdx < 0) return null;
  var dataEnd = endIdx;
  // Strip the EOL that precedes "endstream".
  if (dataEnd > dataStart && bytes[dataEnd - 1] == 0x0A) dataEnd--;
  if (dataEnd > dataStart && bytes[dataEnd - 1] == 0x0D) dataEnd--;
  if (dataEnd <= dataStart) return Uint8List(0);
  return bytes.sublist(dataStart, dataEnd);
}

/// Decodes a stream through its /Filter chain, in order
/// ("/Filter /FlateDecode", or ReportLab's
/// "/Filter [ /ASCII85Decode /FlateDecode ]"). Returns null for a
/// filter we cannot decode or for malformed data — the page then falls
/// through to OCR instead of producing garbage text.
Uint8List? _decodeStream(Uint8List bytes, _Obj obj, Uint8List stream) {
  final dictEnd = _indexOf(bytes, _streamKw, obj.bodyStart);
  final dict = dictEnd > 0
      ? latin1.decode(bytes.sublist(obj.bodyStart, dictEnd))
      : '';
  var current = stream;
  for (final filter in _filterChain(dict)) {
    final next = _applyFilter(filter, current);
    if (next == null) return null;
    current = next;
  }
  return current;
}

/// Filter names from a stream dict's /Filter entry, in order.
/// Empty when the stream is uncompressed.
List<String> _filterChain(String dict) {
  final m = RegExp(r'/Filter\s*(\[[^\]]*\]|/[A-Za-z0-9]+)').firstMatch(dict);
  if (m == null) return const [];
  return RegExp(
    r'/([A-Za-z0-9]+)',
  ).allMatches(m.group(1)!).map((x) => x.group(1)!).toList();
}

Uint8List? _applyFilter(String filter, Uint8List data) {
  switch (filter) {
    case 'FlateDecode':
    case 'Fl':
      try {
        return Uint8List.fromList(zlib.decode(data));
      } catch (_) {
        return null;
      }
    case 'ASCII85Decode':
    case 'A85':
      return _ascii85Decode(data);
    case 'ASCIIHexDecode':
    case 'AHx':
      return _asciiHexDecode(data);
    default:
      // Unknown filter (e.g. DCTDecode images) — cannot decode.
      return null;
  }
}

/// Decodes ASCII85 (Adobe variant: `~>` terminator, `z` = 4 zero
/// bytes). Returns null on malformed input. Whitespace is ignored.
Uint8List? _ascii85Decode(Uint8List data) {
  final out = <int>[];
  var acc = 0;
  var count = 0;
  for (var i = 0; i < data.length; i++) {
    final c = data[i];
    if (c == 0x7E) break; // '~' — terminator ("~>").
    if (c == 0x7A && count == 0) {
      // 'z' — 4 zero bytes, only as a whole group.
      out.addAll([0, 0, 0, 0]);
      continue;
    }
    if (c <= 0x20) continue; // Whitespace.
    if (c < 0x21 || c > 0x75) return null;
    acc = acc * 85 + (c - 0x21);
    count++;
    if (count == 5) {
      // A valid group never exceeds 2^32 - 1.
      if (acc > 0xFFFFFFFF) return null;
      out.addAll([
        (acc >> 24) & 0xFF,
        (acc >> 16) & 0xFF,
        (acc >> 8) & 0xFF,
        acc & 0xFF,
      ]);
      acc = 0;
      count = 0;
    }
  }
  if (count > 0) {
    // Final partial group: pad with 'u' (84) and emit count - 1 bytes.
    for (var j = count; j < 5; j++) {
      acc = acc * 85 + 84;
    }
    for (var j = 0; j < count - 1; j++) {
      out.add((acc >> (24 - 8 * j)) & 0xFF);
    }
  }
  return Uint8List.fromList(out);
}

/// Decodes ASCIIHex (hex pairs, `>` terminator, whitespace ignored).
/// Returns null on malformed input.
Uint8List? _asciiHexDecode(Uint8List data) {
  final nibbles = <int>[];
  for (final c in data) {
    if (c == 0x3E) break; // '>'.
    if (c <= 0x20) continue;
    final n = c >= 0x30 && c <= 0x39
        ? c - 0x30
        : c >= 0x41 && c <= 0x46
            ? c - 0x41 + 10
            : c >= 0x61 && c <= 0x66
                ? c - 0x61 + 10
                : -1;
    if (n < 0) return null;
    nibbles.add(n);
  }
  final out = <int>[];
  for (var i = 0; i < nibbles.length; i += 2) {
    final hi = nibbles[i];
    final lo = i + 1 < nibbles.length ? nibbles[i + 1] : 0;
    out.add((hi << 4) | lo);
  }
  return Uint8List.fromList(out);
}

// ---------------------------------------------------------------------------
// Content-stream tokenizer + interpreter
// ---------------------------------------------------------------------------

abstract class _Tok {
  const _Tok();
}

class _Num extends _Tok {
  const _Num(this.value);

  final double value;
}

class _Name extends _Tok {
  const _Name(this.value);

  final String value;
}

/// A literal string — raw bytes (latin1 code units == byte values).
class _Lit extends _Tok {
  const _Lit(this.bytes);

  final List<int> bytes;
}

/// A hex string — raw bytes.
class _Hex extends _Tok {
  const _Hex(this.bytes);

  final List<int> bytes;
}

class _Arr extends _Tok {
  const _Arr(this.items);

  final List<_Tok> items;
}

class _Op extends _Tok {
  const _Op(this.value);

  final String value;
}

bool _isWs(int c) =>
    c == 0x00 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D || c == 0x20;

bool _isDelim(int c) =>
    c == 0x28 ||
    c == 0x29 ||
    c == 0x3C ||
    c == 0x3E ||
    c == 0x5B ||
    c == 0x5D ||
    c == 0x7B ||
    c == 0x7D ||
    c == 0x2F ||
    c == 0x25;

({List<int> bytes, int next}) _readLiteral(String s, int start) {
  // start points at '('
  final out = <int>[];
  var i = start + 1;
  var depth = 1;
  while (i < s.length && depth > 0) {
    final c = s.codeUnitAt(i);
    if (c == 0x5C) {
      // Escape sequence.
      if (i + 1 >= s.length) break;
      final n = s.codeUnitAt(i + 1);
      if (n == 0x6E) {
        out.add(0x0A);
        i += 2;
      } else if (n == 0x72) {
        out.add(0x0D);
        i += 2;
      } else if (n == 0x74) {
        out.add(0x09);
        i += 2;
      } else if (n == 0x62) {
        out.add(0x08);
        i += 2;
      } else if (n == 0x66) {
        out.add(0x0C);
        i += 2;
      } else if (n == 0x28 || n == 0x29 || n == 0x5C) {
        out.add(n);
        i += 2;
      } else if (n >= 0x30 && n <= 0x37) {
        // Octal, up to 3 digits.
        var v = 0;
        var k = i + 1;
        var count = 0;
        while (k < s.length && count < 3) {
          final d = s.codeUnitAt(k);
          if (d < 0x30 || d > 0x37) break;
          v = v * 8 + (d - 0x30);
          k++;
          count++;
        }
        out.add(v & 0xFF);
        i = k;
      } else if (n == 0x0A) {
        i += 2; // line continuation
      } else if (n == 0x0D) {
        i += 2;
        if (i < s.length && s.codeUnitAt(i) == 0x0A) i++;
      } else {
        out.add(n);
        i += 2;
      }
    } else if (c == 0x28) {
      depth++;
      out.add(c);
      i++;
    } else if (c == 0x29) {
      depth--;
      if (depth > 0) out.add(c);
      i++;
    } else if (c == 0x0A || c == 0x0D) {
      // Bare CR / LF inside a literal string: some producers (the
      // Pace book) put a newline between EVERY glyph inside Tj
      // strings, e.g. `(\nP\na\ng\ne\n …)`. PDF text-showing does not
      // break lines on them and pdftotext drops them, so the
      // interpreter must too — otherwise the line splitter sees one
      // character per line and nothing matches. Escaped `\n` (a
      // backslash + 'n', handled above) still adds a real newline.
      i++;
    } else {
      out.add(c);
      i++;
    }
  }
  return (bytes: out, next: i);
}

({List<int> bytes, int next}) _readHex(String s, int start) {
  // start points at '<' (single, not '<<')
  final digits = StringBuffer();
  var i = start + 1;
  while (i < s.length && s.codeUnitAt(i) != 0x3E) {
    final c = s.codeUnitAt(i);
    if (!_isWs(c)) digits.writeCharCode(c);
    i++;
  }
  var h = digits.toString();
  if (h.length.isOdd) h += '0';
  final out = <int>[];
  for (var k = 0; k + 1 < h.length; k += 2) {
    final v = int.tryParse(h.substring(k, k + 2), radix: 16);
    if (v == null) break;
    out.add(v);
  }
  return (bytes: out, next: i + 1);
}

({List<_Tok> toks, int next}) _readArray(String s, int start) {
  // start points at '['
  final toks = <_Tok>[];
  var i = start + 1;
  while (i < s.length) {
    final res = _readToken(s, i);
    if (res == null) break;
    if (res.endArray) {
      // ']' — end of this array.
      return (toks: toks, next: res.next);
    }
    if (res.tok != null) toks.add(res.tok!);
    if (res.next <= i) break; // safety: never spin forever
    i = res.next;
  }
  return (toks: toks, next: i);
}

int _skipDict(String s, int start) {
  // start points at '<<'; returns index just past the matching '>>'.
  var depth = 0;
  var i = start;
  while (i < s.length) {
    if (s.codeUnitAt(i) == 0x28) {
      final lit = _readLiteral(s, i);
      i = lit.next;
      continue;
    }
    if (i + 1 < s.length &&
        s.codeUnitAt(i) == 0x3C &&
        s.codeUnitAt(i + 1) == 0x3C) {
      depth++;
      i += 2;
      continue;
    }
    if (i + 1 < s.length &&
        s.codeUnitAt(i) == 0x3E &&
        s.codeUnitAt(i + 1) == 0x3E) {
      depth--;
      i += 2;
      if (depth == 0) return i;
      continue;
    }
    i++;
  }
  return i;
}

/// Reads one token at [i]. Returns null token (with next past ']') when
/// the array this token belongs to ends; returns null entirely at EOF.
/// A stray delimiter (e.g. a lone ')') is skipped, never fatal — one
/// malformed byte must not abort the whole page's text.
({ _Tok? tok, int next, bool endArray })? _readToken(String s, int i) {
  var j = i;
  while (j < s.length) {
    final c = s.codeUnitAt(j);
    if (c == 0x25) {
      // Comment to end of line.
      while (j < s.length &&
          s.codeUnitAt(j) != 0x0A &&
          s.codeUnitAt(j) != 0x0D) {
        j++;
      }
    } else if (_isWs(c)) {
      j++;
    } else {
      break;
    }
  }
  if (j >= s.length) return null;
  final c = s.codeUnitAt(j);
  if (c == 0x28) {
    final r = _readLiteral(s, j);
    return (tok: _Lit(r.bytes), next: r.next, endArray: false);
  }
  if (c == 0x3C) {
    if (j + 1 < s.length && s.codeUnitAt(j + 1) == 0x3C) {
      return (tok: null, next: _skipDict(s, j), endArray: false);
    }
    final r = _readHex(s, j);
    return (tok: _Hex(r.bytes), next: r.next, endArray: false);
  }
  if (c == 0x5B) {
    final r = _readArray(s, j);
    return (tok: _Arr(r.toks), next: r.next, endArray: false);
  }
  if (c == 0x5D) {
    return (tok: null, next: j + 1, endArray: true); // end of array
  }
  if (c == 0x2F) {
    var k = j + 1;
    while (k < s.length &&
        !_isWs(s.codeUnitAt(k)) &&
        !_isDelim(s.codeUnitAt(k))) {
      k++;
    }
    return (tok: _Name(s.substring(j + 1, k)), next: k, endArray: false);
  }
  if (c == 0x3E || c == 0x29 || c == 0x7D) {
    // Stray '>' / ')' / '}' — skip one char, keep tokenizing.
    return (tok: null, next: j + 1, endArray: false);
  }
  var k = j;
  while (k < s.length &&
      !_isWs(s.codeUnitAt(k)) &&
      !_isDelim(s.codeUnitAt(k))) {
    k++;
  }
  if (k == j) {
    // Zero-length word (unexpected delimiter) — skip it, never stall.
    return (tok: null, next: j + 1, endArray: false);
  }
  final word = s.substring(j, k);
  final num = double.tryParse(word);
  if (num != null) return (tok: _Num(num), next: k, endArray: false);
  return (tok: _Op(word), next: k, endArray: false);
}

List<_Tok> _tokenize(String s) {
  final toks = <_Tok>[];
  var i = 0;
  while (i < s.length) {
    final r = _readToken(s, i);
    if (r == null) break;
    if (r.tok != null) toks.add(r.tok!);
    if (r.next <= i) break; // safety: never spin forever
    i = r.next;
  }
  return toks;
}

/// Decodes one string's bytes using the current font's ToUnicode map.
/// Falls back to UTF-16BE (BOM) and then plain latin1.
String _decodeStringBytes(List<int> bytes, _CMap? cmap) {
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    final units = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      units.add(bytes[i] * 256 + bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }
  if (cmap != null) {
    final out = StringBuffer();
    if (cmap.codeLength == 1) {
      for (final b in bytes) {
        out.write(cmap.map[b] ?? String.fromCharCode(b));
      }
      return out.toString();
    }
    // 2- or 4-byte codes.
    final step = cmap.codeLength >= 4 ? 2 : cmap.codeLength;
    for (var i = 0; i + step <= bytes.length; i += step) {
      var code = 0;
      for (var k = 0; k < step; k++) {
        code = code * 256 + bytes[i + k];
      }
      // Identity CMap: an unmapped code IS its own Unicode point.
      out.write(cmap.map[code] ?? (cmap.identity ? _codeToUnicode(code) : ''));
    }
    return out.toString();
  }
  return String.fromCharCodes(bytes);
}

/// Helvetica AFM widths (units per 1000 em) for printable ASCII 32–126.
/// Used only to estimate a drawn word's advance for the word-gap space
/// heuristic. Standard 14-font metrics; close enough for other Latin
/// fonts, and only the ~1.5 pt threshold depends on it.
const _helveticaWidths = <int>[
  // space ! " # $ % & ' ( ) * + , - . /
  278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278,
  278,
  // 0-9 : ; < = > ? @
  556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584,
  556, 1015,
  // A-Z
  667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
  667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611,
  // [ \ ] ^ _ `
  278, 278, 278, 469, 556, 333,
  // a-z
  556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
  556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500,
  // { | } ~
  334, 260, 334, 584,
];

/// Interprets one content stream (latin1-decoded; code units == bytes).
/// Returns the drawn text lines, each with its start position (text
/// space) and its estimated end-x — so the caller can separate
/// two-column layouts (see [_orderLinesForColumns]) instead of
/// interleaving the columns. Emits real line breaks on Td/TD/Tm/T* so
/// the MCQ parser sees one question / option per line. Form XObjects
/// drawn with `Do` are interpreted recursively ([_interpretXObject])
/// with their own resources — [depth]/[activeForms] cap nesting and
/// break cycles. A bold text run ends with the bold marker
/// ([boldRunMarker]) so the parser can read it as the "bold" answer
/// signal; the marker is zero-width and never reaches stored text.
class _TextLine {
  _TextLine(this.text, this.x, this.y, this.endX);

  /// Drawn text (may end with a bold-run marker).
  String text;

  /// x/y where the line starts (text space; y grows upward).
  final double x;
  final double y;

  /// Estimated x where the line's text ends (for the two-column check).
  double endX;
}

List<_TextLine> _interpretContentStream(
  String stream,
  _Resources res,
  _InterpCtx ctx, {
  int depth = 0,
  Set<int>? activeForms,
}) {
  final toks = _tokenize(stream);
  final lines = <_TextLine>[];
  final stack = <_Tok>[];
  String? font;
  // Line-break state: breaks come from the ABSOLUTE y of the line
  // being drawn, not the relative move. Producers either reset the
  // text matrix per word with BT (then Td carries an absolute y, e.g.
  // the `pdf` package) or move relatively inside one BT block.
  // Comparing the absolute line y against the y of the previously
  // drawn text handles both; the old `if (ty != 0) newline()` rule
  // newlined after every word of a pdf-package PDF.
  var lineY = 0.0; // y of the current line's start (text space)
  var lastTextY = 0.0; // absolute y where text was last drawn
  var haveTextY = false;
  // Word-gap state: many producers (e.g. the `pdf` package) emit one
  // word per Tj with a Td move and no space character between them.
  // The gap between the estimated end of the last drawn word and the
  // next word's x is the only space signal. Advances are estimated
  // with Helvetica AFM widths (most Latin fonts are close); a real
  // word space is ~3.3 pt at 12 pt, a split word repositions by ~0 pt,
  // so a 1.5 pt threshold separates them. Unknown chars fall back to
  // 0.5 em.
  var fontSize = 12.0;
  var lineX = 0.0; // x of the current line's start (text space)
  var cursorX = 0.0; // estimated x where the next glyph starts
  var haveCursorX = false;
  var pendingSpace = false;

  double estimateWidth(String s) {
    var w = 0.0;
    for (final c in s.codeUnits) {
      final idx = c - 32;
      final units = (idx >= 0 && idx < _helveticaWidths.length)
          ? _helveticaWidths[idx]
          : 500;
      w += units / 1000 * fontSize;
    }
    return w;
  }

  // The line currently being built. It is created by the first
  // writeText, so its x/y are the position of the first glyph — not a
  // stale reposition from the previous line.
  _TextLine? cur;

  void finishLine() {
    if (cur != null && cur!.text.isNotEmpty) {
      lines.add(cur!);
    }
    cur = null;
  }

  void newline() {
    finishLine();
  }

  void reposition(double newX, double newY) {
    final sameLine = haveTextY && (newY - lastTextY).abs() <= 1;
    if (sameLine) {
      if (haveCursorX && newX > cursorX + 1.5) pendingSpace = true;
    } else {
      if (haveTextY) newline();
      pendingSpace = false;
    }
    lastTextY = newY;
    lineY = newY;
    haveTextY = true;
    lineX = newX;
    cursorX = newX;
    haveCursorX = true;
  }

  void writeText(String s) {
    if (s.isEmpty) return;
    cur ??= _TextLine('', lineX, lineY, cursorX);
    if (pendingSpace && cur!.text.isNotEmpty) {
      if (!cur!.text.endsWith(' ')) cur!.text += ' ';
    }
    pendingSpace = false;
    cur!.text += s;
    // A bold run ends with the bold marker (see [boldRunMarker]).
    // Zero-width: it never advances cursorX and never affects the
    // word-gap heuristic.
    if (font != null && (res.fontBold[font] ?? false)) {
      cur!.text += boldRunMarker;
    }
    cursorX += estimateWidth(s);
    cur!.endX = cursorX;
  }

  String decode(_Tok t) {
    if (t is _Lit) return _decodeStringBytes(t.bytes, res.fonts[font]);
    if (t is _Hex) return _decodeStringBytes(t.bytes, res.fonts[font]);
    return '';
  }

  for (final t in toks) {
    if (t is _Op) {
      switch (t.value) {
        case 'BT':
          // BT resets the text matrix (and line matrix) to identity.
          // It does NOT reset the font: Tf is part of the text state,
          // which persists across BT/ET (producers such as the Pace
          // book set the font in one BT block and draw in a nested
          // BT after `q` — resetting here made every Tj decode with
          // no CMap, i.e. NUL-separated text and broken ligatures).
          lineY = 0; // BT resets the text matrix to identity.
          lineX = 0;
          stack.clear();
        case 'ET':
          stack.clear();
        case 'Tf':
          if (stack.isNotEmpty && stack.first is _Name) {
            font = (stack.first as _Name).value;
          }
          if (stack.length >= 2 && stack[1] is _Num) {
            fontSize = (stack[1] as _Num).value;
          }
          stack.clear();
        case 'Td':
        case 'TD':
          if (stack.length >= 2 &&
              stack[stack.length - 1] is _Num &&
              stack[stack.length - 2] is _Num) {
            // Td: tx ty — both relative to the line start.
            final tx = (stack[stack.length - 2] as _Num).value;
            final ty = (stack[stack.length - 1] as _Num).value;
            reposition(lineX + tx, lineY + ty);
          }
          stack.clear();
        case 'Tm':
          if (stack.length >= 6 &&
              stack[4] is _Num &&
              stack[5] is _Num) {
            // Tm: a b c d e f — e/f are the absolute x/y.
            reposition(
              (stack[4] as _Num).value,
              (stack[5] as _Num).value,
            );
          }
          stack.clear();
        case 'T*':
          newline();
          haveTextY = false;
          haveCursorX = false;
          pendingSpace = false;
          stack.clear();
        case 'Tj':
          for (var k = stack.length - 1; k >= 0; k--) {
            if (stack[k] is _Lit || stack[k] is _Hex) {
              writeText(decode(stack[k]));
              break;
            }
          }
          stack.clear();
        case 'TJ':
          for (var k = stack.length - 1; k >= 0; k--) {
            if (stack[k] is _Arr) {
              final chunk = StringBuffer();
              for (final el in (stack[k] as _Arr).items) {
                if (el is _Lit || el is _Hex) {
                  chunk.write(decode(el));
                } else if (el is _Num && el.value < -100) {
                  chunk.write(' ');
                }
              }
              writeText(chunk.toString());
              break;
            }
          }
          stack.clear();
        case "'":
          newline();
          haveTextY = false;
          haveCursorX = false;
          pendingSpace = false;
          for (var k = stack.length - 1; k >= 0; k--) {
            if (stack[k] is _Lit || stack[k] is _Hex) {
              writeText(decode(stack[k]));
              break;
            }
          }
          stack.clear();
        case '"':
          newline();
          haveTextY = false;
          haveCursorX = false;
          pendingSpace = false;
          for (var k = stack.length - 1; k >= 0; k--) {
            if (stack[k] is _Lit || stack[k] is _Hex) {
              writeText(decode(stack[k]));
              break;
            }
          }
          stack.clear();
        case 'Do':
          // Draw an XObject. Form XObjects carry their own content
          // stream (many real books put whole questions in them);
          // image XObjects have no text and return [].
          if (stack.isNotEmpty && stack.last is _Name) {
            final name = (stack.last as _Name).value;
            final ref = res.xobjects[name];
            if (ref != null) {
              final sub = _interpretXObject(
                res,
                ctx,
                ref,
                depth,
                activeForms,
              );
              if (sub.isNotEmpty) {
                finishLine();
                lines.addAll(sub);
              }
            }
          }
          stack.clear();
        default:
          stack.clear();
      }
    } else {
      stack.add(t);
    }
  }
  finishLine();
  return lines;
}

/// Interprets one Form XObject's content stream (recursively — forms
/// can contain forms). Returns its text lines, or [] when it is not a
/// form, is missing, too deep (cap 8), or part of a reference cycle.
/// Image XObjects have no content stream and return [].
List<_TextLine> _interpretXObject(
  _Resources parentRes,
  _InterpCtx ctx,
  int ref,
  int depth,
  Set<int>? activeForms,
) {
  if (depth >= 8) return const [];
  if (activeForms != null && activeForms.contains(ref)) return const [];
  final xobj = ctx.byNum[ref];
  if (xobj == null) return const [];
  final dict = _dictText(ctx.bytes, xobj);
  if (!RegExp(r'/Subtype\s*/Form(?![A-Za-z])').hasMatch(dict)) {
    return const [];
  }
  final streamBytes = _streamBytes(ctx.bytes, xobj);
  if (streamBytes == null) return const [];
  final decoded = _decodeStream(ctx.bytes, xobj, streamBytes);
  if (decoded == null) return const [];
  final res = _formResources(ctx.bytes, ctx.byNum, xobj, parentRes);
  final active = {...?activeForms, ref};
  return _interpretContentStream(
    latin1.decode(decoded),
    res,
    ctx,
    depth: depth + 1,
    activeForms: active,
  );
}

/// Two-column layout (the Pace book: Q.1 left, Q.2 right): when a
/// page's lines cluster into two x-groups with a clear gap, emit the
/// left column top-to-bottom (y descending — PDF y grows upward),
/// then the right column top-to-bottom. Otherwise keep content order.
/// Conservative: it only fires when both groups have ≥ 3 lines, the
/// start-x gap is > 60 pt, at most 20% of the left group's lines run
/// into the right column (a column's text stays in its column — an
/// indented option line runs to the same right margin as its question,
/// so indent never triggers this), and the groups' y-ranges overlap
/// (side-by-side columns, not stacked blocks). Lines at the same y
/// keep their content order.
List<_TextLine> _orderLinesForColumns(List<_TextLine> lines) {
  final nonEmpty = lines.where((l) => l.text.trim().isNotEmpty).toList();
  if (nonEmpty.length < 6) return lines;
  // Largest gap between consecutive sorted start-x values.
  final xs = nonEmpty.map((l) => l.x).toList()..sort();
  var bestGap = 0.0;
  var bestSplit = 0.0;
  for (var i = 1; i < xs.length; i++) {
    final gap = xs[i] - xs[i - 1];
    if (gap > bestGap) {
      bestGap = gap;
      bestSplit = (xs[i] + xs[i - 1]) / 2;
    }
  }
  if (bestGap <= 60) return lines;
  final left = nonEmpty.where((l) => l.x < bestSplit).toList();
  final right = nonEmpty.where((l) => l.x >= bestSplit).toList();
  if (left.length < 3 || right.length < 3) return lines;
  final rightMinX = right
      .map((l) => l.x)
      .reduce((a, b) => a < b ? a : b);
  final spanning = left.where((l) => l.endX >= rightMinX).length;
  if (spanning > left.length * 0.2) return lines;
  double minY(Iterable<_TextLine> ls) =>
      ls.map((l) => l.y).reduce((a, b) => a < b ? a : b);
  double maxY(Iterable<_TextLine> ls) =>
      ls.map((l) => l.y).reduce((a, b) => a > b ? a : b);
  final overlap =
      (maxY(left) < maxY(right) ? maxY(left) : maxY(right)) -
      (minY(left) > minY(right) ? minY(left) : minY(right));
  if (overlap <= 0) return lines;
  final indexed = nonEmpty.indexed.toList();
  int byColumnThenY(
    (int, _TextLine) a,
    (int, _TextLine) b,
  ) {
    final aLeft = a.$2.x < bestSplit;
    final bLeft = b.$2.x < bestSplit;
    if (aLeft != bLeft) return aLeft ? -1 : 1;
    final y = b.$2.y.compareTo(a.$2.y);
    if (y != 0) return y;
    return a.$1.compareTo(b.$1);
  }

  indexed.sort(byColumnThenY);
  return indexed.map((e) => e.$2).toList();
}

String _clean(String text) {
  final cleaned = text
      // NULs are never valid text — a 2-byte string decoded at the
      // wrong code length leaves one before every character; drop them
      // rather than letting them poison matching.
      .replaceAll('\x00', '')
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\n\s*\n\s*\n+'), '\n\n')
      .trim();
  // Single choke point for extracted page text: ligatures are
  // normalised here so every downstream consumer sees plain letters.
  return _normalizeLigatures(cleaned);
}

/// Ligatures (U+FB00–U+FB06, common in the Pace book: "oﬃcially",
/// "Aﬀairs") to plain letters, so question/option matching never
/// breaks on them. Applied to extracted page text (see [_clean]).
String _normalizeLigatures(String text) {
  if (!text.contains('\uFB00') &&
      !text.contains('\uFB01') &&
      !text.contains('\uFB02') &&
      !text.contains('\uFB03') &&
      !text.contains('\uFB04') &&
      !text.contains('\uFB05') &&
      !text.contains('\uFB06')) {
    return text;
  }
  return text
      .replaceAll('\uFB00', 'ff')
      .replaceAll('\uFB01', 'fi')
      .replaceAll('\uFB02', 'fl')
      .replaceAll('\uFB03', 'ffi')
      .replaceAll('\uFB04', 'ffl')
      .replaceAll('\uFB05', 'st')
      .replaceAll('\uFB06', 'st');
}

// ---------------------------------------------------------------------------
// Isolate entry points (top-level so `compute()` can call them)
// ---------------------------------------------------------------------------

/// Extracts + parses a PDF entirely off the UI thread.
/// Input: {'bytes', 'sourceId', 'sourceLabel'} — all values sendable.
/// Output: plain maps/lists only (safe across isolates). Parsing is
/// page-aware ([parseMcqsFromPages]) so every question carries its
/// page + part, and the result includes the detected parts and the
/// answer-key / signal diagnostics for the upload preview.
Map<String, dynamic> processPdfInBackground(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final sourceId = args['sourceId'] as String;
  final sourceLabel = args['sourceLabel'] as String;
  // Fail FAST on a corrupt / truncated PDF (File 4): never extract
  // garbage for seconds and never import spurious questions from it.
  final corruption = detectPdfCorruption(bytes);
  if (corruption != null) throw CorruptPdfException(corruption);
  final pages = extractPdfPages(bytes);
  final text = pages.map((p) => p.text).join('\n\n');
  // Garbage gate: a structurally-"fine" file whose text layer is
  // unreadable binary (replacement characters everywhere) is not a
  // book either — fail with the same clear message, never parse it.
  if (text.length > 1000) {
    var replacement = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0xFFFD) replacement++;
    }
    if (replacement / text.length > 0.02) {
      throw const CorruptPdfException(
        'Is PDF ka text parha nahi ja raha (kharab encoding) — file '
        'kharab ya incomplete download lagti hai. Dobara download '
        'karein.',
      );
    }
  }
  final parsed = parseMcqsFromPages(
    [for (final p in pages) PageText(p.page, p.text)],
    sourceId: sourceId,
    sourceLabel: sourceLabel,
  );
  return {
    'pages': pages
        .map((p) => {'page': p.page, 'text': p.text})
        .toList(),
    'text': text,
    'questions': parsed.questions.map((q) => q.toMap()).toList(),
    'parsed': parsed.parsed,
    'skipped': parsed.skipped,
    'errors': parsed.errors,
    'formats': parsed.formatCounts,
    'generatedOptions': parsed.generatedOptions,
    'excluded': parsed.excluded,
    'parts': parsed.parts.map((p) => p.toMap()).toList(),
    'keySectionsFound': parsed.keySectionsFound,
    'keyEntriesApplied': parsed.keyEntriesApplied,
    'questionsMissingAnswers': parsed.questionsMissingAnswers,
    'answerSources': parsed.answerSources,
    'conflicts': parsed.conflicts,
    'unmatchedKeyEntries': parsed.unmatchedKeyEntries,
    'notes': parsed.notes,
    'unmatchedNotes': parsed.unmatchedNotes,
    'fiveOptionNormalised': parsed.fiveOptionNormalised,
    'fiveOptionAnswerE': parsed.fiveOptionAnswerE,
    'numberGaps': parsed.numberGaps,
    'numberDuplicates': parsed.numberDuplicates,
    'noiseLinesFiltered': parsed.noiseLinesFiltered,
    'facts': parsed.facts.map((f) => f.toMap()).toList(),
    'answerPending': parsed.answerPending.map((p) => p.toMap()).toList(),
    'keyPaperReport': parsed.keyPaperReport,
  };
}

/// Parses plain text (TXT / pasted / OCR output) off the UI thread.
/// Input: {'text', 'sourceId', 'sourceLabel'} and/or {'pages':
/// [{'page', 'text'}]} — when 'pages' is present (the OCR re-parse
/// path, where page numbers are known) it parses page-aware; otherwise
/// it falls back to the plain-text parse.
///
/// Provenance (governing spec 19 Nov 2026): pass 'ocrPages' (the
/// 1-based page numbers whose text came from OCR) for the page-aware
/// path, or 'markProvenance': 'ocr' for the plain-text path (a camera
/// photo's OCR text). A tick/bold mark from an OCR page is UNVERIFIED
/// (it could be the student's pen); the default is 'printed'.
Map<String, dynamic> parseTextInBackground(Map<String, dynamic> args) {
  final sourceId = args['sourceId'] as String;
  final sourceLabel = args['sourceLabel'] as String;
  final pagesArg = args['pages'] as List?;
  final ocrPages = {
    for (final p in (args['ocrPages'] as List? ?? const []))
      (p as num).toInt(),
  };
  final markProvenance = args['markProvenance'] as String? ?? 'printed';
  // Req B (v2): the PDF text layer is normalised in [_clean], but
  // TXT / pasted / OCR / DOCX text reaches the parser through here
  // with no normalisation at all — a ligature ("oﬃcially") survived
  // into stored questions. Normalise here, the shared choke point
  // for every non-PDF-text-layer import, so all paths behave the
  // same. Only U+FB00–FB06 change; Urdu/Arabic script, math symbols,
  // dashes and ticks pass through untouched.
  final parsed = pagesArg != null
      ? parseMcqsFromPages(
          [
            for (final p in pagesArg.cast<Map<String, dynamic>>())
              PageText(
                p['page'] as int,
                _normalizeLigatures(p['text'] as String),
              ),
          ],
          sourceId: sourceId,
          sourceLabel: sourceLabel,
          ocrPages: ocrPages,
        )
      : parseMcqs(
          _normalizeLigatures(args['text'] as String),
          sourceId: sourceId,
          sourceLabel: sourceLabel,
          markProvenance: markProvenance,
        );
  return {
    'questions': parsed.questions.map((q) => q.toMap()).toList(),
    'parsed': parsed.parsed,
    'skipped': parsed.skipped,
    'errors': parsed.errors,
    'formats': parsed.formatCounts,
    'generatedOptions': parsed.generatedOptions,
    'excluded': parsed.excluded,
    'parts': parsed.parts.map((p) => p.toMap()).toList(),
    'keySectionsFound': parsed.keySectionsFound,
    'keyEntriesApplied': parsed.keyEntriesApplied,
    'questionsMissingAnswers': parsed.questionsMissingAnswers,
    'answerSources': parsed.answerSources,
    'conflicts': parsed.conflicts,
    'unmatchedKeyEntries': parsed.unmatchedKeyEntries,
    'notes': parsed.notes,
    'unmatchedNotes': parsed.unmatchedNotes,
    'fiveOptionNormalised': parsed.fiveOptionNormalised,
    'fiveOptionAnswerE': parsed.fiveOptionAnswerE,
    'numberGaps': parsed.numberGaps,
    'numberDuplicates': parsed.numberDuplicates,
    'noiseLinesFiltered': parsed.noiseLinesFiltered,
    'facts': parsed.facts.map((f) => f.toMap()).toList(),
    'answerPending': parsed.answerPending.map((p) => p.toMap()).toList(),
    'keyPaperReport': parsed.keyPaperReport,
  };
}
