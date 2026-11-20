import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/book_structure.dart';
import 'package:officerpath_ai/services/docx_text_extractor.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/pdf_import_service.dart';

/// Builds a minimal .docx in memory: a ZIP with the three parts Word
/// requires. [paragraphs] is a list of paragraphs; each paragraph is
/// a list of (text, bold) runs. XML-escapes the text.
Uint8List buildDocx(List<List<(String, bool)>> paragraphs) {
  String esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  final body = StringBuffer();
  for (final para in paragraphs) {
    body.write('<w:p>');
    for (final (text, bold) in para) {
      body.write('<w:r>');
      if (bold) body.write('<w:rPr><w:b/></w:rPr>');
      body.write('<w:t xml:space="preserve">${esc(text)}</w:t>');
      body.write('</w:r>');
    }
    body.write('</w:p>');
  }
  const contentTypes =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '</Types>';
  const rels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
      '</Relationships>';
  final document =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>$body</w:body></w:document>';
  final archive = Archive();
  // NB: UTF-8 bytes, not .codeUnits — a .docx ZIP stores UTF-8, and
  // .codeUnits would truncate every non-ASCII character (Urdu) to one
  // byte and garble it.
  archive.addFile(
    ArchiveFile('[Content_Types].xml', utf8.encode(contentTypes).length,
        utf8.encode(contentTypes)),
  );
  archive.addFile(
    ArchiveFile('_rels/.rels', utf8.encode(rels).length, utf8.encode(rels)),
  );
  archive.addFile(
    ArchiveFile('word/document.xml', utf8.encode(document).length,
        utf8.encode(document)),
  );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

List<(String, bool)> para(String text, {bool bold = false}) =>
    [(text, bold)];

void main() {
  group('DOCX — sample fixture (Scribd shapes)', () {
    test('sample_mcq_bank.docx parses 6/6 with correct answers', () async {
      final bytes = await File(
        '/home/hatch/workspace/officerpath-ai/test/fixtures/sample_mcq_bank.docx',
      ).readAsBytes();
      final pages = extractDocxPages(bytes);
      expect(pages.length, 1);
      final result = parseMcqsFromPages(
        [for (final p in pages) PageText(p.page, p.text)],
        sourceId: 'docx',
        sourceLabel: 'sample_mcq_bank',
      );
      expect(result.parsed, 6);
      expect(result.skipped, 0);
      expect(result.questionsMissingAnswers, isEmpty);
      // 5 inline answers (incl. the lowercase "Ans. c" shape) + 1 key.
      expect(result.answerSources['answer-line'], 5);
      expect(result.answerSources['key'], 1);
      expect(result.keyEntriesApplied, 1);
      final byText = {
        for (final q in result.questions) q.text: q,
      };
      expect(byText['What is the capital of Pakistan?']!.correctIndex, 2);
      expect(byText['Which is the largest ocean?']!.correctIndex, 1);
      expect(
        byText['Who wrote the national anthem of Pakistan?']!.correctIndex,
        1,
      );
      expect(
        byText['Which planet is known as the Red Planet?']!.correctIndex,
        2,
      );
      expect(
        byText['How many players are there in a cricket team?']!
            .correctIndex,
        2,
      );
      expect(
        byText['What is the chemical symbol for gold?']!.correctIndex,
        2,
      );
      // Page tracking: a short bank is one approximated page.
      expect(result.questions.every((q) => q.page == 1), isTrue);
    });

    test('importDocx end-to-end returns a PdfImportResult', () async {
      final bytes = await File(
        '/home/hatch/workspace/officerpath-ai/test/fixtures/sample_mcq_bank.docx',
      ).readAsBytes();
      final result = await PdfImportService.importDocx(
        bytes,
        sourceId: 'docx',
        sourceLabel: 'sample_mcq_bank',
        onProgress: (_) {},
        isCancelled: () => false,
      );
      expect(result.parsed, 6);
      expect(result.pageCount, 1);
      expect(result.ocrPages, isEmpty);
      expect(result.text.contains('What is the capital of Pakistan?'),
          isTrue);
    });
  });

  group('DOCX — bold answer signal', () {
    test('a bold correct option resolves via the bold signal', () async {
      final bytes = buildDocx([
        para('1. Which is the largest planet?'),
        para('(A) Venus'),
        para('(B) Jupiter', bold: true),
        para('(C) Mars'),
        para('(D) Saturn'),
      ]);
      final pages = extractDocxPages(bytes);
      final result = parseMcqsFromPages(
        [for (final p in pages) PageText(p.page, p.text)],
        sourceId: 'docx-bold',
        sourceLabel: 'docx-bold',
      );
      expect(result.parsed, 1);
      final q = result.questions.first;
      expect(q.correctIndex, 1);
      expect(q.answerSource, 'bold');
      expect(q.boldOptions, [false, true, false, false]);
      expect(q.options[1], 'Jupiter');
    });
  });

  group('DOCX — Urdu text', () {
    test('Urdu question text survives extraction and parses', () async {
      final bytes = buildDocx([
        para('1. پاکستان کا دارالحکومت کون سا ہے؟'),
        para('(A) لاہور'),
        para('(B) کراچی'),
        para('(C) اسلام آباد'),
        para('(D) کوئٹہ'),
        para('Correct answer : C'),
      ]);
      final pages = extractDocxPages(bytes);
      final text = pages.first.text;
      expect(text.contains('پاکستان'), isTrue);
      final result = parseMcqsFromPages(
        [for (final p in pages) PageText(p.page, p.text)],
        sourceId: 'docx-urdu',
        sourceLabel: 'docx-urdu',
      );
      expect(result.parsed, 1);
      final q = result.questions.first;
      expect(q.correctIndex, 2);
      expect(q.text.contains('پاکستان'), isTrue);
      expect(q.options[2], 'اسلام آباد');
    });
  });

  group('DOCX — corrupt / empty fails fast', () {
    test('not a ZIP throws a clear DocxImportException', () {
      expect(
        () => extractDocxParagraphs(
          Uint8List.fromList('this is not a docx'.codeUnits),
        ),
        throwsA(
          isA<DocxImportException>().having(
            (e) => e.message,
            'message',
            contains('not a valid .docx'),
          ),
        ),
      );
    });

    test('a ZIP without word/document.xml throws', () {
      final archive = Archive();
      archive.addFile(
        ArchiveFile('hello.txt', 5, 'hello'.codeUnits),
      );
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
      expect(
        () => extractDocxParagraphs(bytes),
        throwsA(
          isA<DocxImportException>().having(
            (e) => e.message,
            'message',
            contains('word/document.xml'),
          ),
        ),
      );
    });

    test('a document with no paragraphs throws', () {
      final bytes = buildDocx([]);
      expect(
        () => extractDocxParagraphs(bytes),
        throwsA(isA<DocxImportException>()),
      );
    });
  });
}
