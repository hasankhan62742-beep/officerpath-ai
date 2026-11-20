import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'answer_key.dart';
import 'book_structure.dart';

/// .docx MCQ-bank extraction (v1.2, steer 18).
///
/// A .docx is a ZIP of XML. The text lives in `word/document.xml` as
/// paragraphs (`w:p`) of runs (`w:r` → `w:t`). Paragraph breaks are
/// the line boundaries the parser needs, so they are preserved
/// (paragraphs are joined with '\n', in document order).
///
/// Bold runs (`w:r` with `w:rPr/w:b`) are the bold-answer signal —
/// the same signal as a bold font in PDF. A bold run is marked by
/// appending [boldRunMarker] (U+E000, private use) at its END, the
/// same convention as the PDF extractor; the parser strips the marker
/// and uses it for the bold signal ([hasBoldMarker] /
/// [stripBoldMarkers]).
///
/// Page tracking: a .docx has NO fixed pages (Word reflows text), so
/// pages are approximated as chunks of [paragraphsPerPage] paragraphs
/// (50). The page number is therefore approximate — it exists so part
/// page ranges and per-page progress work, not as a print fidelity
/// claim. A short bank (≤ 50 paragraphs) is a single page.
///
/// Fail-fast: a corrupt ZIP, a missing `word/document.xml`, or a
/// document with no paragraphs throws [DocxImportException] with a
/// clear message — never an ANR, never a silent empty import.

/// Paragraphs per approximated page (see the note above).
const int docxParagraphsPerPage = 50;

/// Thrown when a .docx cannot be read (not a ZIP, no document.xml,
/// no text). The message is user-facing — keep it plain.
class DocxImportException implements Exception {
  const DocxImportException(this.message);

  final String message;

  @override
  String toString() => 'DocxImportException: $message';
}

/// Extracts the paragraphs of a .docx, in document order, each as
/// its plain text (bold runs marked with [boldRunMarker]).
/// Throws [DocxImportException] on a corrupt / empty file.
List<String> extractDocxParagraphs(Uint8List bytes) {
  Archive archive;
  try {
    // A ZIP file starts with "PK" — anything else is not a .docx at
    // all (ZipDecoder does not throw on garbage bytes, it returns an
    // empty archive, so check the signature explicitly).
    if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4B) {
      throw const FormatException('not a ZIP');
    }
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw const DocxImportException(
      'This file is not a valid .docx (the ZIP could not be read). '
      'Please re-save it from Word and try again.',
    );
  }
  final docFile = archive.findFile('word/document.xml');
  if (docFile == null) {
    throw const DocxImportException(
      'This file is not a valid Word document (word/document.xml '
      'is missing). Please re-save it from Word and try again.',
    );
  }
  XmlDocument doc;
  try {
    // NB: UTF-8, not String.fromCharCodes — the XML is UTF-8 bytes
    // and fromCharCodes would garble every non-ASCII character
    // (Urdu) into two Latin-1 chars.
    doc = XmlDocument.parse(utf8.decode(docFile.content));
  } catch (_) {
    throw const DocxImportException(
      'This Word document could not be read (its text is damaged). '
      'Please re-save it from Word and try again.',
    );
  }
  final paragraphs = <String>[];
  // Walk the document body in order: paragraphs AND table cells
  // (a table cell's paragraphs are content too — an MCQ bank in a
  // table must not lose its questions).
  for (final node in doc.descendants) {
    if (node is! XmlElement) continue;
    if (node.name.local != 'p') continue;
    final text = _paragraphText(node);
    if (text.trim().isEmpty) continue;
    paragraphs.add(text);
  }
  if (paragraphs.isEmpty) {
    throw const DocxImportException(
      'This Word document has no text in it. Add your MCQs and '
      'try again.',
    );
  }
  return paragraphs;
}

/// The plain text of one paragraph: its runs' `w:t` texts joined,
/// with [boldRunMarker] appended at the end of each bold run.
/// `w:tab` becomes a space, `w:br` a line break (a forced break
/// inside a paragraph is a new line for the parser). Runs wrapped in
/// a hyperlink / smart tag (`w:hyperlink > w:r`) are content too and
/// are read in document order.
String _paragraphText(XmlElement p) {
  final buf = StringBuffer();
  for (final child in p.children) {
    if (child is! XmlElement) continue;
    final local = child.name.local;
    if (local == 'r') {
      _appendRun(child, buf);
    } else if (local == 'hyperlink' ||
        local == 'smartTag' ||
        local == 'sdt') {
      for (final run in child.findElements('r')) {
        _appendRun(run, buf);
      }
    }
  }
  return buf.toString();
}

/// Appends one run's text to [buf] (with [boldRunMarker] at the end
/// when the run is bold). A run is bold when it carries `<w:b/>`
/// (or `<w:b w:val="true"/>`); `<w:b w:val="false"/>` ("0"/"off")
/// is explicitly NOT bold.
void _appendRun(XmlElement run, StringBuffer buf) {
  var runText = '';
  var bold = false;
  for (final child in run.children) {
    if (child is! XmlElement) continue;
    final local = child.name.local;
    if (local == 'rPr') {
      // A <w:b/> child marks a bold run. (findElements('b') does not
      // match the namespaced <w:b/> here, so walk the children and
      // compare the local name.)
      for (final prop in child.children) {
        if (prop is XmlElement && prop.name.local == 'b') {
          final val = prop.getAttribute('val');
          if (val == null ||
              val.toLowerCase() == 'true' ||
              val == '1' ||
              val.toLowerCase() == 'on') {
            bold = true;
          }
        }
      }
    } else if (local == 't') {
      runText += child.innerText;
    } else if (local == 'tab') {
      runText += ' ';
    } else if (local == 'br') {
      runText += '\n';
    }
  }
  if (runText.isEmpty) return;
  buf.write(runText);
  if (bold) buf.write(boldRunMarker);
}

/// Extracts a .docx into [PageText]s (paragraphs chunked into
/// approximated pages of [docxParagraphsPerPage]).
List<PageText> extractDocxPages(Uint8List bytes) {
  final paras = extractDocxParagraphs(bytes);
  final pages = <PageText>[];
  for (var start = 0; start < paras.length; start += docxParagraphsPerPage) {
    final end = (start + docxParagraphsPerPage).clamp(0, paras.length);
    final pageNo = pages.length + 1;
    pages.add(PageText(pageNo, paras.sublist(start, end).join('\n')));
  }
  return pages;
}

/// The full text of a .docx (paragraphs joined with '\n').
String extractDocxText(Uint8List bytes) {
  return extractDocxParagraphs(bytes).join('\n');
}

/// Isolate entry point (mirrors `processPdfInBackground`): extracts
/// a .docx off the UI thread and returns its pages + text.
/// `args` = {'bytes': Uint8List}. Returns {'pages': [{page, text}],
/// 'text': String, 'paragraphCount': int, 'pageCount': int}.
/// Throws [DocxImportException] (propagated to the caller) on a
/// corrupt / empty file.
Map<String, dynamic> processDocxInBackground(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final pages = extractDocxPages(bytes);
  final text = pages.map((p) => p.text).join('\n');
  return {
    'pages': [
      for (final p in pages) {'page': p.page, 'text': p.text},
    ],
    'text': text,
    'paragraphCount': pages.fold<int>(
      0,
      (a, p) => a + p.text.split('\n').length,
    ),
    'pageCount': pages.length,
  };
}
