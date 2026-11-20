import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';

import 'pdf_test_helpers.dart';

/// Identity ToUnicode CMap + ligature regression (Pace file root
/// cause, 19 Nov 2026). The Pace producer's 24 ToUnicode CMaps are
/// all Identity CMaps (`begincodespacerange <0000> <FFFF>`,
/// `beginbfrange <0000> <FFFF> <0000>`) and its strings are
/// UTF-16BE-style 2-byte codes. Before the fix, the `hi - lo > 10000`
/// corrupt-range guard skipped the identity range, the map came back
/// empty, and every character decoded with a NUL before it — so no
/// question regex matched and ligatures decoded as 1-byte junk.
/// This test rebuilds that exact shape synthetically: a Type0 font
/// with an Identity ToUnicode CMap and a 2-byte string carrying a
/// U+FB03 "ﬃ" ligature. It must decode to plain text.
/// (Recreated 19 Nov 2026 — the scratch probe `tmp_identity_test.dart`
/// was deleted by another agent while cleaning up its own tmp files.)
void main() {
  test('Identity CMap + ligature decodes to plain text', () {
    // "Q.1: Which country officially" in UTF-16BE, with "ffi" as a
    // single U+FB03 ligature codepoint (0xFB03). Hex string: each
    // codepoint is 4 hex digits (2 bytes).
    const hex =
        '0051002E0031003A00200057006800690063006800200063006F0075006E'
        '0074007200790020006FFB03006300690061006C006C0079';
    final content = 'BT /F1 12 Tf 72 720 Td <$hex> Tj ET';
    final bytes = buildHandcraftedPdf(
      [content],
      fontDict:
          '<< /Type /Font /Subtype /Type0 /BaseFont /TestFont '
          '/Encoding /Identity-H /DescendantFonts [4 0 R] '
          '/ToUnicode 5 0 R >>',
      extraObjects: [
        // 4: the descendant CIDFont.
        '4 0 obj\n<< /Type /Font /Subtype /CIDFontType2 '
        '/BaseFont /TestFont '
        '/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) '
        '/Supplement 0 >> /FontDescriptor 6 0 R /DW 1000 >>\nendobj\n',
        // 5: the Identity ToUnicode CMap.
        '5 0 obj\n<< /Length 260 >>\nstream\n'
        '/CIDInit /ProcSet findresource begin\n'
        '12 dict begin\n'
        'begincmap\n'
        '/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) '
        '/Supplement 0 >> def\n'
        '/CMapName /Adobe-Identity-UCS def\n'
        '/CMapType 2 def\n'
        '1 begincodespacerange\n'
        '<0000> <FFFF>\n'
        'endcodespacerange\n'
        '1 beginbfrange\n'
        '<0000> <FFFF> <0000>\n'
        'endbfrange\n'
        'endcmap\n'
        'CMapName currentdict /CMap defineresource pop\n'
        'end\n'
        'end\n'
        'endstream\nendobj\n',
        // 6: a minimal FontDescriptor (referenced by the CIDFont).
        '6 0 obj\n<< /Type /FontDescriptor /FontName /TestFont '
        '/Flags 4 /FontBBox [0 0 1000 1000] /ItalicAngle 0 '
        '/Ascent 800 /Descent -200 /CapHeight 700 /StemV 80 >>\n'
        'endobj\n',
      ],
    );
    final pages = extractPdfPages(bytes);
    expect(pages.length, 1);
    final text = pages.first.text;
    // No NULs, no ligature codepoints, the question reads cleanly.
    expect(text.contains('\x00'), isFalse);
    expect(text.contains('\uFB03'), isFalse);
    expect(text.contains('Q.1: Which country officially'), isTrue);
    // And the parser sees it as a question start (the Pace Q.1: shape).
    final result = parseMcqs(
      text,
      sourceId: 'identity',
      sourceLabel: 'identity',
    );
    expect(result.parsed + result.skipped, greaterThan(0));
  });
}
