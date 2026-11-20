import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Test helpers for building PDFs without a real PDF producer.
///
/// Hand-crafted PDFs here are intentionally minimal: object headers,
/// dictionaries and streams, no xref table. They exercise the
/// OfficerPath extractor (which scans objects directly); they are NOT
/// guaranteed to open in a strict PDF viewer.

/// Builds a PDF with one content stream per page (uncompressed).
/// [pageContents] are raw PDF content-stream programs, e.g.
/// `BT /F1 12 Tf 72 720 Td (Hello) Tj ET`.
Uint8List buildHandcraftedPdf(
  List<String> pageContents, {
  String fontDict =
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  List<String> extraObjects = const [],
}) {
  final buf = BytesBuilder();
  void add(String s) => buf.add(latin1.encode(s));

  final pageCount = pageContents.length;
  add('%PDF-1.4\n');
  // 1: catalog, 2: pages, 3: font. Extra objects (if any) must carry
  // their own numbers starting at 4; pages follow them.
  final firstPageObj = 4 + extraObjects.length;
  final contentObjNum = firstPageObj + pageCount;
  final kids = List.generate(
    pageCount,
    (i) => '${firstPageObj + i} 0 R',
  ).join(' ');
  add('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');
  add(
    '2 0 obj\n<< /Type /Pages /Kids [$kids] /Count $pageCount >>\nendobj\n',
  );
  add('3 0 obj\n$fontDict\nendobj\n');
  for (final extra in extraObjects) {
    add(extra);
  }
  for (var i = 0; i < pageCount; i++) {
    final contentNum = contentObjNum + i;
    add(
      '${firstPageObj + i} 0 obj\n<< /Type /Page /Parent 2 0 R '
      '/MediaBox [0 0 612 792] '
      '/Resources << /Font << /F1 3 0 R >> >> '
      '/Contents $contentNum 0 R >>\nendobj\n',
    );
  }
  for (var i = 0; i < pageCount; i++) {
    final content = pageContents[i];
    final bytes = latin1.encode(content);
    add(
      '${contentObjNum + i} 0 obj\n<< /Length ${bytes.length} >>\nstream\n',
    );
    buf.add(bytes);
    add('\nendstream\nendobj\n');
  }
  add('%%EOF\n');
  return buf.takeBytes();
}

/// Builds a PDF whose page 1 holds [content] and whose page 2 is an
/// image-only page (an image XObject, no text) — the scanned-PDF case.
Uint8List buildScannedStylePdf(String content) {
  final buf = BytesBuilder();
  void add(String s) => buf.add(latin1.encode(s));

  add('%PDF-1.4\n');
  add('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');
  add('2 0 obj\n<< /Type /Pages /Kids [4 0 R 5 0 R] /Count 2 >>\nendobj\n');
  add(
    '3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n',
  );
  add(
    '4 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
    '/Resources << /Font << /F1 3 0 R >> >> /Contents 6 0 R >>\nendobj\n',
  );
  // Page 2: only an image XObject, no text.
  add(
    '5 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
    '/Resources << /XObject << /Im1 7 0 R >> >> /Contents 8 0 R >>\nendobj\n',
  );
  final contentBytes = latin1.encode(content);
  add('6 0 obj\n<< /Length ${contentBytes.length} >>\nstream\n');
  buf.add(contentBytes);
  add('\nendstream\nendobj\n');
  // Fake image stream (1 MB of Flate-compressed zeros — the old extractor
  // inflated every stream like this; the new one must skip it entirely).
  // Pseudo-random image data: compresses poorly, so the PDF really is
  // megabytes on disk. (A naive LCG's low byte cycles with period 256
  // and zlib's it down to ~30 KB — the test would prove nothing.)
  final imageRaw = Uint8List(8 * 1024 * 1024);
  final rnd = Random(42);
  for (var i = 0; i < imageRaw.length; i++) {
    imageRaw[i] = rnd.nextInt(256);
  }
  final imageCompressed = zlib.encode(imageRaw);
  add(
    '7 0 obj\n<< /Type /XObject /Subtype /Image /Width 2480 /Height 3508 '
    '/ColorSpace /DeviceGray /BitsPerComponent 8 '
    '/Filter /FlateDecode /Length ${imageCompressed.length} >>\nstream\n',
  );
  buf.add(imageCompressed);
  add('\nendstream\nendobj\n');
  add('8 0 obj\n<< /Length 0 >>\nstream\n\nendstream\nendobj\n');
  add('%%EOF\n');
  return buf.takeBytes();
}

// --- Minimal PNG encoder (for realistic image pages in profile tests) ---

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}

void _pngChunk(BytesBuilder out, String type, List<int> data) {
  final typeBytes = latin1.encode(type);
  out.add([
    (data.length >> 24) & 0xFF,
    (data.length >> 16) & 0xFF,
    (data.length >> 8) & 0xFF,
    data.length & 0xFF,
  ]);
  out.add(typeBytes);
  out.add(data);
  final crc = _crc32([...typeBytes, ...data]);
  out.add([
    (crc >> 24) & 0xFF,
    (crc >> 16) & 0xFF,
    (crc >> 8) & 0xFF,
    crc & 0xFF,
  ]);
}

/// A noisy RGB PNG (poorly compressible — like a real scanned page).
/// Pixel values vary with x/y so the file stays big.
Uint8List makeNoisyPng(int w, int h) {
  final raw = <int>[];
  for (var y = 0; y < h; y++) {
    raw.add(0); // filter: none
    for (var x = 0; x < w; x++) {
      raw.add((x * 7 + y * 13) & 0xFF);
      raw.add((x * 3 + y * 29) & 0xFF);
      raw.add((x * 11 + y * 5) & 0xFF);
    }
  }
  final compressed = zlib.encode(raw);
  final out = BytesBuilder();
  out.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  _pngChunk(out, 'IHDR', [
    (w >> 24) & 0xFF,
    (w >> 16) & 0xFF,
    (w >> 8) & 0xFF,
    w & 0xFF,
    (h >> 24) & 0xFF,
    (h >> 16) & 0xFF,
    (h >> 8) & 0xFF,
    h & 0xFF,
    8, 2, 0, 0, 0, // 8-bit RGB, no interlace
  ]);
  _pngChunk(out, 'IDAT', compressed);
  _pngChunk(out, 'IEND', []);
  return out.takeBytes();
}
