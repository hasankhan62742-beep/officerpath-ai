import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:officerpath_ai/models/question.dart';
import 'package:officerpath_ai/services/image_preprocess.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';

// Camera-photo robustness (Worker 4, 19 Nov 2026).
//
// The real OCR fixtures below are REAL output, not hand-written:
//   test/fixtures/paper60_gemini_ocr.txt — Gemini vision OCR
//     (tools/gemini_vision_ocr.py, model gemini-2.5-flash, photo
//     downscaled to 1600 px) of
//     ~/workspace/user/media_library/image/IMG_20261119_151817_041.jpg
//     ("PAPER 60, DATA ENTRY OPERATOR (Police)", 2160x3840 camera
//     photo, curved page, shadows, handwritten margin notes).
//     3,547 chars, 21 asterisks read (21/21).
//   test/fixtures/table_photo_gemini_ocr.txt — same pipeline on
//     ~/workspace/user/media_library/image/ppsc123_1.jpg (table-format
//     photo, "Adjective and its Types" + "Article and its Types").
//     4,378 chars, 32 table rows.
//
// Parser-only tests (mocked/no-network, no Gemini calls): the OCR
// text is loaded from the fixture files and parsed locally.
//
// HONEST LIMIT — Q11 in the Paper 60 photo: the photo cuts Q11 off
// after its stem ("Which of the following is not a function in
// Microsoft Excel?"); its options are NOT visible on the page
// (verified by cropping the photo's bottom 20%). The vision OCR
// nevertheless returned "(A) SUM (B) MAX (C) MIN (D) AVG*" —
// plausible, standard, but NOT verifiable from the photo: a vision
// model can invent cut-off content from knowledge. No test below
// asserts Q11's answer as ground truth. The parser faithfully
// parses whatever the OCR text says; the hallucination is an OCR
// -layer risk, reported in docs/universal-formats.md.

ParseResult parseText(String text) => parseMcqs(
      text,
      sourceId: 'camera-photo-test',
      sourceLabel: 'camera photo',
    );

String fixture(String name) =>
    File('test/fixtures/$name').readAsStringSync();

/// Finds the parsed question whose stem contains [needle], or null.
Question? findQ(ParseResult r, String needle) {
  for (final q in r.questions) {
    if (q.text.contains(needle)) return q;
  }
  return null;
}

void main() {
  group('REAL camera photo — Paper 60 (Gemini vision OCR fixture)', () {
    late String ocr;
    late ParseResult r;
    setUpAll(() {
      ocr = fixture('paper60_gemini_ocr.txt');
      r = parseText(ocr);
    });

    test('fixture is real OCR output, not a hand transcription', () {
      // The vision read has the photo's own artefacts: the previous
      // paper's Q6 at the top, page numbers 639/640, diamond
      // separators, the facing page's garbled Q22–Q30 fragments, and
      // the handwritten margin notes it was asked to prefix.
      expect(ocr.contains('639'), isTrue);
      expect(ocr.contains('640'), isTrue);
      expect(ocr.contains('♦'), isTrue);
      expect(ocr.contains('HANDWRITTEN:'), isTrue);
      expect(ocr.contains('Wh'), isTrue); // garbled facing-page fragment
      expect('*'.allMatches(ocr).length, 21);
    });

    test('verifiable asterisk answers parse WITHOUT AI', () {
      // Q1–Q20 + the previous paper's Q6 at the top = 21 asterisked
      // answers. Q11 IS asserted (its options "(A) SUM (B) MAX
      // (C) MIN (D) AVG*" are printed at the top of the RIGHT column,
      // p.639 — verified by cropping the photo 19 Nov 2026; the
      // file header's "OCR-invented" note is wrong for this photo).
      // Q12/Q14 parse now that wrapped-option continuations are
      // joined (the `*` sat on the continuation line).
      const expected = {
        'Animation Scheme, custom Animation': 3, // top-of-page Q6, D
        'slide show': 2, // Q1 C — F5
        'Hypertext language': 1, // Q2 B — HTML
        'Another name for free software': 3, // Q3 D
        'not used to access the': 2, // Q4 C — UDP
        'identified by its': 2, // Q5 C — IP Address
        'sending same letter': 0, // Q6 A — Mail merge
        'create a formula': 3, // Q7 D
        'architectural design': 2, // Q8 C — Auto CAD
        'Delete" key delete': 0, // Q9 A — Right
        'ready-made font color': 2, // Q10 C — Design Template
        'not a function in Microsoft Excel': 3, // Q11 D — AVG
        'linked to a Word document': 3, // Q12 D
        'users can open MS Excel 2016': 3, // Q13 D — None of these
        'extend a selection': 0, // Q14 A — Hold down SHIFT…
        'delete a text box object': 2, // Q15 C
        'volatile memory': 3, // Q16 D — RAM
        'angry or antagonistic': 0, // Q17 A — Flaming
        'evaluate values and return a result': 0, // Q18 A — Formulas
        'Common methods of Internet access': 3, // Q19 D
        'zoom level of a page': 2, // Q20 C
      };
      for (final e in expected.entries) {
        final q = findQ(r, e.key);
        expect(q, isNotNull, reason: 'missing: ${e.key}');
        expect(q!.correctIndex, e.value, reason: e.key);
        expect(q.answerSource, 'asterisk', reason: e.key);
      }
      expect(r.answerSources['asterisk'], 21);
    });

    test('asterisk is stripped from every displayed option', () {
      for (final q in r.questions) {
        for (final o in q.options) {
          expect(o.contains('*'), isFalse, reason: 'option "$o"');
        }
        expect(q.text.contains('*'), isFalse);
      }
    });

    test('handwritten notes + page furniture never become questions',
        () {
      for (final q in r.questions) {
        expect(q.text.contains('Dot Matrix'), isFalse);
        expect(q.text.contains('impact printer'), isFalse);
        expect(q.text.contains('HANDWRITTEN'), isFalse);
        expect(q.text.contains('639'), isFalse);
        expect(q.text.contains('640'), isFalse);
        expect(q.text.contains('♦'), isFalse);
      }
      expect(
        r.answerPending.any((p) => p.text.contains('Dot Matrix')),
        isFalse,
      );
    });

    test('every parsed question is well-formed (4 options, valid index)',
        () {
      expect(r.questions, isNotEmpty);
      for (final q in r.questions) {
        expect(q.options.length, 4, reason: q.text);
        expect(q.correctIndex, inInclusiveRange(0, 3), reason: q.text);
        expect(q.text.trim().isNotEmpty, isTrue);
      }
    });

    test('GAP: asterisk on a WRAPPED option continuation line is missed',
        () {
      // Q12 "(D) ... reference to the original source application*"
      // and Q14 "(A) Hold down SHIFT ... key repeatedly*" wrap over
      // two OCR lines; the `*` sits on the continuation line, so both
      // land in answer-pending instead of parsing with D / A.
      // Gap: lib/services/mcq_parser.dart, _parseStandardBlock
      // (~line 3698) via _extractOption (~line 2688) only checks the
      // option's own line for the asterisk, never its continuation.
      final q12 = findQ(r, 'linked to a Word');
      expect(q12, isNotNull);
      expect(q12!.correctIndex, 3);
      final q14 = findQ(r, 'extend a selection');
      expect(q14, isNotNull);
      expect(q14!.correctIndex, 0);
    });

    test('GAP: garbled facing-page fragments must NOT become questions',
        () {
      // The OCR tail "22. Wh / to e / (A) (B) (C) (D) / 23. All /
      // follo / ..." is facing-page debris. The parser currently
      // turns 5 fragments into fake q-only questions ("Wh to e",
      // "All follo", "Bi", "T", "T") with pool-built options and
      // invented answers (answer-line source).
      // Gap: lib/services/mcq_parser.dart — _answerTokenFromLines
      // (~line 3599) treats a bare "(A)" line as an answer via
      // _bareAnswerRe (~line 3471), and the (c) Q-only path
      // (~lines 2165–2195) has no minimum stem length/quality guard.
      for (final junk in ['Wh to e', 'All follo', 'Bi']) {
        expect(findQ(r, junk), isNull, reason: 'fake question: $junk');
      }
      expect(
        r.questions.where((q) => q.text.trim() == 'T').length,
        0,
        reason: 'single-letter "T" must never be a question',
      );
    });
  });

  group('REAL table photo — ppsc123_1.jpg (Gemini vision OCR fixture)',
      () {
    late String ocr;
    late ParseResult r;
    setUpAll(() {
      ocr = fixture('table_photo_gemini_ocr.txt');
      r = parseText(ocr);
    });

    test('all 32 table rows parse with the key answers', () {
      expect(r.formatCounts['table'], 32);
      final keyed = [
        for (final q in r.questions) if (q.answerSource == 'key') q,
      ];
      expect(keyed.length, 32);
      const inOrder = [
        0, 0, 2, 0, 1, 1, 0, 2, 1, 2, // adjective rows 1–10
        0, 2, 3, 1, 2, 0, 3, 3, 0, 0, // adjective rows 11–20
        2, 1, 2, 0, 0, 1, 0, 0, 1, 0, // adjective 21–25 + article 1–7
        1, 0, // article rows 6–7
      ];
      expect(
        [for (final q in keyed) q.correctIndex],
        inOrder,
      );
    });

    test('type labels never become (extra) options', () {
      // This book is adversarial: the trailing type label often
      // DUPLICATES a real option ("Quantitative adjective" is both
      // row 7's option A and its trailing label). The rule is not
      // "the label word never appears" — it is "the trailing 7th
      // column is never added as a 5th option". So: every table
      // question has exactly 4 options, and the spot-checked rows
      // have exactly the 4 content columns.
      for (final q in r.questions) {
        expect(q.options.length, 4, reason: q.text);
        for (final o in q.options) {
          expect(o.contains('|'), isFalse, reason: 'pipe in "$o"');
        }
      }
      // Row 1: trailing label "Adjective" is not a 5th option.
      final row1 = findQ(r, 'An adjective modifies a');
      expect(row1, isNotNull);
      expect(row1!.options, ['Noun', 'Verb', 'Adverb', 'Preposition']);
      // Row 7: "Quantitative adjective" is a real option once, not
      // twice (label + option).
      final row7 = findQ(r, 'much effort for little work');
      expect(row7, isNotNull);
      expect(row7!.options, [
        'Quantitative adjective',
        'Qualitative adjective',
        'Subjective adjective',
        'None of these',
      ]);
      // Row 9: trailing label "Qualitative adjective" is not added.
      final row9 = findQ(r, 'people have');
      expect(row9, isNotNull);
      expect(row9!.options, [
        'Very few, some',
        'A few, some',
        'Few, Little',
        'A few, very little',
      ]);
    });

    test('GAP: the "HANDWRITTEN:" watermark must not become a question',
        () {
      // The OCR prefix "HANDWRITTEN: CS Scanned with CamScanner"
      // currently parses as a flashcard ("HANDWRITTEN:" question +
      // "CS Scanned with CamScanner" answer) via the shape-(c)
      // trailing-answer split, which accepts a 1-word "question".
      // Gap: lib/services/mcq_parser.dart, _scanFlashcards
      // (~line 2969) shape (c) requires only qPart.length >= 10.
      expect(findQ(r, 'HANDWRITTEN'), isNull);
      expect(findQ(r, 'CamScanner'), isNull);
    });

    test('GAP: a previous row\'s type label must not leak into the '
        'next question', () {
      // Row 26's trailing label "article a/is" currently prefixes
      // row 27's stem: "article a/is Yesterday, I met ____ European".
      // Gap: lib/services/mcq_parser.dart, table row-wise joining
      // (_parseTableRowWise, ~line 1212).
      final q = findQ(r, 'Yesterday, I met');
      expect(q, isNotNull);
      expect(q!.text.startsWith('Yesterday'), isTrue);
    });
  });

  group('noise tolerance — synthetic OCR-shaped inputs', () {
    test('garbled fragments between good blocks are skipped', () {
      const text = '''
1. Which key is used for a slide show?
(A) F1
(B) F2
(C) F5*
(D) F10

Wh to
AIL fo
639
♦♦♦♦♦♦♦♦♦♦

2. Which one is Hypertext language?
(A) XML
(B) HTML*
(C) WML
(D) HTTP
''';
      final r = parseText(text);
      expect(r.questions.length, 2);
      expect(findQ(r, 'slide show')!.correctIndex, 2);
      expect(findQ(r, 'Hypertext')!.correctIndex, 1);
      expect(findQ(r, 'Wh to'), isNull);
      expect(findQ(r, 'AIL fo'), isNull);
    });

    test('GAP: fragment block with bare option letters must not '
        'become a question', () {
      // Same shape as the real facing-page debris, but with 3 real
      // questions first so the answer pool is big enough to build
      // distractors (otherwise the fake is excluded vacuously).
      // Gap: same _bareAnswerRe / (c) Q-only path as the Paper 60
      // fragment test above.
      const text = '''
1. Which key is used for a slide show?
(A) F1
(B) F2
(C) F5*
(D) F10

2. Which one is Hypertext language?
(A) XML
(B) HTML*
(C) WML
(D) HTTP

3. Which is a volatile memory?
(A) ROM
(B) BIOS
(C) PROM
(D) RAM*

22. Wh
to e
(A)
(B)
(C)
(D)

23. All
follo
(A)
(B)
(C)
(D)
''';
      final r = parseText(text);
      expect(r.questions.length, 3);
      // The needles must be the joined fragment text ("Wh to e",
      // "All follo") — a bare 'Wh' would substring-match the REAL
      // question "Which key is used for a slide show?".
      expect(findQ(r, 'Wh to e'), isNull);
      expect(findQ(r, 'All follo'), isNull);
    });

    test('a handwritten note line inside a block is ignored', () {
      const text = '''
1. What is the capital of France?
Dot Matrix printer
(A) Paris*
(B) London
(C) Rome
(D) Berlin
''';
      final r = parseText(text);
      final q = findQ(r, 'capital of France');
      expect(q, isNotNull);
      expect(q!.correctIndex, 0);
      expect(q.options, contains('Paris'));
    });

    test('GAP: a colon note must not become a flashcard question', () {
      // The note must sit in a heading-led block (the shape the real
      // table photo has: section headings, then the note line) — a
      // note trailing a good question's block is swallowed as debris
      // and does not reproduce the bug. Here the headings + note form
      // their own block, and shape (c) currently splits at the colon
      // into a 1-phrase "question" + answer, then the pool builder
      // gives it invented options.
      // Gap: _scanFlashcards shape (c) (~line 3095+) needs a real
      // question (ends with ? / : + verb phrase), not any colon line.
      const text = '''
Adjective and its Types
Article and its Types
HANDWRITTEN note: remember this

1. Which key is used for a slide show?
(A) F1
(B) F2
(C) F5*
(D) F10

2. Which one is Hypertext language?
(A) XML
(B) HTML*
(C) WML
(D) HTTP

3. Which is a volatile memory?
(A) ROM
(B) BIOS
(C) PROM
(D) RAM*
''';
      final r = parseText(text);
      expect(r.questions.length, 3);
      expect(findQ(r, 'HANDWRITTEN'), isNull);
      expect(
        r.questions.any((q) => q.options.contains('remember this')),
        isFalse,
      );
    });

    test('GAP: an option wrapped over two lines keeps its full text',
        () {
      // Mirrors the real Q15 wrap: "(A) The object is deleted but
      // text box and the" + "text is pasted the slide". The parser
      // currently truncates the option at the line break.
      // Gap: lib/services/mcq_parser.dart, _parseStandardBlock
      // (~line 3698) does not join wrapped option continuation lines.
      const text = '''
1. When you delete a text box object from a slide:
(A) The object is deleted but text box and the
text is pasted the slide
(B) The text box is deleted and the text is
pasted the slide
(C) The text box and text both are deleted*
(D) None of these
''';
      final r = parseText(text);
      final q = findQ(r, 'delete a text box');
      expect(q, isNotNull);
      expect(q!.correctIndex, 2);
      expect(
        q.options[0],
        'The object is deleted but text box and the text is pasted '
        'the slide',
      );
      expect(
        q.options[1],
        'The text box is deleted and the text is pasted the slide',
      );
    });

    test('a page of pure noise parses to 0, never crashes', () {
      const text = '''
639
♦♦♦♦♦♦♦♦♦♦
Wh to e
AIL fo
Bi
T
26.
(A)
(B)
CS Scanned with CamScanner
''';
      final r = parseText(text);
      expect(r.questions, isEmpty);
      expect(r.answerPending, isEmpty);
      expect(r.parsed, 0);
    });
  });

  group('camera preprocessing — preprocessForOcr', () {
    test('a valid JPEG comes back a valid JPEG, same size', () {
      final original = img.Image(width: 24, height: 16);
      img.fill(original, color: img.ColorRgb8(200, 40, 40));
      final bytes = Uint8List.fromList(img.encodeJpg(original));
      final out = preprocessForOcr(bytes);
      expect(out, isNotEmpty);
      final decoded = img.decodeImage(out);
      expect(decoded, isNotNull);
      expect(decoded!.width, 24);
      expect(decoded.height, 16);
      // Grayscale + autocontrast + sharpen actually changed pixels.
      expect(out, isNot(bytes));
    });

    test('garbage bytes pass through unchanged, never throws', () {
      final garbage = Uint8List.fromList([0, 1, 2, 3, 255, 254]);
      expect(preprocessForOcr(garbage), garbage);
      expect(preprocessForOcr(Uint8List(0)), isEmpty);
    });

    test('a degenerate 1x1 image passes through unchanged', () {
      final tiny = img.Image(width: 1, height: 1);
      final bytes = Uint8List.fromList(img.encodeJpg(tiny));
      expect(preprocessForOcr(bytes), bytes);
    });
  });
}
