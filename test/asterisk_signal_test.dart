import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/pdf_import_service.dart';

/// Worker 4 — asterisk `*` as the correct-answer signal (v2
/// acceptance item, 19 Nov 2026).
///
/// The user photographed a printed MCQ page (Paper 60, Data Entry
/// Operator, Police) and the app rejected it: "No MCQs found — Read
/// 3310 characters... Block 2: skipped — has 4 options but no
/// usable answer". The book marks the correct option with an
/// asterisk after it — "(C) F5 *", "(B) HTML*", "(D) Public Domain
/// Software*", "(A) Flaming.*" — very common in Pakistani MCQ books.
///
/// Rules (acceptance):
/// * `*` after an option = that option is the correct answer.
///   Precedence: answer line > key > tick > bold > asterisk > AI.
/// * The `*` is STRIPPED from the displayed option text.
/// * Works in block + one-liner + OCR/photo paths.
/// * Two asterisked options in one question = conflict reported,
///   never silently pick one.
///
/// Fixture below is a HAND transcription of the real photo
/// (~/workspace/user/media_library/image/IMG_20261119_151817_041.jpg,
/// 2160x3840 JPEG, read 19 Nov 2026 ~15:25 PKT), in the photo's own
/// layout (two options per line where the book prints them so).
/// Q11's options are BELOW the photo's bottom edge, so the fixture
/// carries the stem only — the honest handling is "skipped, never
/// guessed" (it cannot even be answer-pending without options).
/// Q21 is cut off mid-question the same way. The photo also contains
/// fragments of the previous paper at the top (Q6 "Slide Show
/// Menu*" and the SUM/MAX/MIN/AVG* tail) — those are NOT in this
/// fixture; the real OCR text would include them, and integration
/// should check they parse (or are excluded) too.
///
/// STATUS (19 Nov 2026): NO asterisk handling exists in
/// lib/services/mcq_parser.dart yet (grep: zero matches) — the v1.3
/// coordinator owns the fix. These tests FAIL until it lands; that
/// failure is the acceptance signal, not a test bug.
void main() {
  /// Paper 60, Data Entry Operator (Police) — as photographed.
  /// Options are two-per-line exactly where the book prints them so.
  const paper60 = '''
Basic Computer Studies 639
PAPER 60
DATA ENTRY OPERATOR (Police)
1. Which key on the keyboard can be used to slide show?
(A) F1 (B) F2
(C) F5 * (D) F10
2. Which one is Hypertext language?
(A) XML (B) HTML*
(C) WML (D) HTTP
3. Another name for free software to:
(A) Encrypted Software
(B) Copy Rights Protect Software
(C) Customized Software
(D) Public Domain Software*
4. Which of the following is not used to access the web?
(A) ISDN (B) Modem
(C) UDP * (D) DSL
5. A computer on network is identified by its:
(A) Mac Address (B) Port Address
(C) IP Address* (D) Location Address
6. Which of the following is correct option for sending same letter to multiple persons?
(A) Mail merge* (B) Macros
(C) Template (D) Alignment
7. In MS Excel, to create a formula, you can use:
(A) Values but not cell references
(B) Cell references but not values
(C) Values or cell references although not both at the same time
(D) Both value and cell references*
8. Which programme is generally used in architectural design?
(A) Excel (B) Power Point
(C) Auto CAD * (D) MS Word
9. In MS Word, "Delete" key delete letters from the ____ side of curser.
(A) Right* (B) Up
(C) Down (D) Left
10. What lets you to create new presentation by selecting ready-made font color and graphics affects in PowerPoint?
(A) Presentation Template
(B) Master slide
(C) Design Template*
(D) Animation Scheme
11. Which of the following is not a function in Microsoft Excel?
12. When an Excel workbook is linked to a Word document:
(A) The Word document contains a copy of the actual data
(B) The word document cannot be edited
(C) The word document must contain a hyperlink
(D) The word document contains a reference to the original source application*
13. ______ users can open MS Excel 2016 file at the same time.
(A) 100 (B) 50
(C) 256 (D) None of these*
14. In MS Word 2016, to extend a selection to adjacent cells of the table:
(A) Hold down SHIFT and press an arrow key repeatedly*
(B) Press Alt + A
(C) Ctrl + Alt + H
(D) Alt + End
15. When you delete a text box object from a slide in PowrPoint Presentation:
(A) The object is deleted but text box and the text inside is left on the slide
(B) The text box is deleted and the text is pasted the slide
(C) The text box and text both are deleted*
(D) None of these
16. Which is a volatile memory?
(A) ROM (B) BIOS
(C) PROM (D) RAM*
17. ______ occurs when a person sends a message (or many messages) with angry or antagonistic content.
(A) Flaming.*
(B) Email Bankruptcy
(C) Email Phishing
(D) Email fatigue
18. Which of the following Excel feature allows users to evaluate values and return a result?
(A) Formulas* (B) Formatting
(C) Filters (D) Insertions
19. Common methods of Internet access by users include:
(A) Broadband over coaxial cable
(B) Fiber optics or copper wires
(C) Wi-Fi
(D) All of these*
20. In MS Excel 2016, zoom level of a page can only be:
(A) 10 percent to 300 percent
(B) 5 percent to 100 percent
(C) 10 percent to 400 percent*
(D) 5 percent to 300 percent
21. In MS Word, what is the function of CTRL + R?
(A) Open the print dialogue
''';

  ParseResult parsePaper60() => parseMcqs(
        paper60,
        sourceId: 'asterisk-paper60',
        sourceLabel: 'Paper 60 DEO',
      );

  group('REAL PAGE — Paper 60 asterisk MCQs (no AI)', () {
    test('19 questions parse with the acceptance answers', () {
      final r = parsePaper60();
      expect(r.parsed, 19);
      expect(r.questions.length, 19);
      // In document order the parsed questions are Q1–Q10 then
      // Q12–Q20 (Q11 has no options on the page, Q21 is cut off).
      const inOrder = [
        2, // Q1 C — F5
        1, // Q2 B — HTML
        3, // Q3 D — Public Domain Software
        2, // Q4 C — UDP
        2, // Q5 C — IP Address
        0, // Q6 A — Mail merge
        3, // Q7 D — Both value and cell references
        2, // Q8 C — Auto CAD
        0, // Q9 A — Right
        2, // Q10 C — Design Template
        3, // Q12 D — reference to the original source application
        3, // Q13 D — None of these
        0, // Q14 A — Hold down SHIFT and press an arrow key
        2, // Q15 C — The text box and text both are deleted
        3, // Q16 D — RAM
        0, // Q17 A — Flaming.
        0, // Q18 A — Formulas
        3, // Q19 D — All of these
        2, // Q20 C — 10 percent to 400 percent
      ];
      expect(
        [for (final q in r.questions) q.correctIndex],
        inOrder,
      );
      expect(r.answerSources['asterisk'], 19);
    });

    test('asterisk is stripped from every displayed option', () {
      final r = parsePaper60();
      for (final q in r.questions) {
        for (final o in q.options) {
          expect(o.contains('*'), isFalse, reason: 'option "$o"');
        }
        expect(q.text.contains('*'), isFalse);
      }
      // Spot checks: the exact option texts, asterisk-free.
      expect(r.questions[0].options[2], 'F5');
      expect(r.questions[1].options[1], 'HTML');
      expect(r.questions[2].options[3], 'Public Domain Software');
      expect(r.questions[15].options[0], 'Flaming.'); // Q17 is index 15
      expect(r.questions[16].options[0], 'Formulas'); // Q18 is index 16
      expect(r.questions[18].options[2], '10 percent to 400 percent'); // Q20 is index 18
    });

    test('Q11 (no asterisk, options off-photo) is never guessed', () {
      final r = parsePaper60();
      expect(
        r.questions.any(
          (q) => q.text.contains('not a function in Microsoft Excel'),
        ),
        isFalse,
      );
      expect(
        r.answerPending.any(
          (p) => p.text.contains('not a function in Microsoft Excel'),
        ),
        isFalse,
        reason: 'Q11 has no options on the page — it cannot even be '
            'pending; it must be skipped, never guessed',
      );
    });

    test('Q21 fragment (cut off mid-question) is never parsed', () {
      final r = parsePaper60();
      expect(
        r.questions.any((q) => q.text.contains('function of CTRL')),
        isFalse,
      );
    });

    test('photo path: mocked OCR text routes through OCR then parser',
        () async {
      final result = await PdfImportService.importImage(
        Uint8List.fromList([0xFF, 0xD8, 0xFF]),
        sourceId: 'img-paper60',
        sourceLabel: 'Paper 60 photo',
        onProgress: (_) {},
        isCancelled: () => false,
        runOcr: (jpegBytes) async => paper60,
      );
      expect(result.pageCount, 1);
      expect(result.ocrPages, [1]);
      expect(result.parsed, 19);
      expect(result.questions[0].correctIndex, 2);
      expect(result.questions[1].correctIndex, 1);
    });
  });

  group('asterisk — precedence + conflicts (synthetic)', () {
    test('one-liner with asterisk only: asterisk is the answer', () {
      const text = '''
1. Which one is Hypertext language? (a) XML (b) HTML* (c) WML (d) HTTP
2. Which key is used to slide show? (a) F1 (b) F2 (c) F5 * (d) F10
''';
      final r = parseMcqs(
        text,
        sourceId: 'ast-1',
        sourceLabel: 'Asterisk one-liner',
      );
      expect(r.parsed, 2);
      expect(r.questions[0].correctIndex, 1);
      expect(r.questions[1].correctIndex, 2);
      expect(r.answerSources['asterisk'], 2);
    });

    test('answer line beats asterisk', () {
      const text = '''
Q1. Which one is Hypertext language?
A) XML
B) HTML*
C) WML
D) HTTP
Answer: D
''';
      final r = parseMcqs(
        text,
        sourceId: 'ast-2',
        sourceLabel: 'Answer line vs asterisk',
      );
      expect(r.parsed, 1);
      expect(r.questions.first.correctIndex, 3);
      expect(r.questions.first.answerSource, 'answer-line');
    });

    test('tick beats asterisk', () {
      const text = '''
Q1. Which one is Hypertext language?
A) XML
B) HTML*
C) WML ✓
D) HTTP
''';
      final r = parseMcqs(
        text,
        sourceId: 'ast-3',
        sourceLabel: 'Tick vs asterisk',
      );
      expect(r.parsed, 1);
      expect(r.questions.first.correctIndex, 2);
      expect(r.questions.first.answerSource, 'tick');
    });

    test('two asterisked options: conflict reported, never picked', () {
      const text = '''
Q1. Which one is Hypertext language?
A) XML*
B) HTML*
C) WML
D) HTTP
Q2. Which key is used to slide show?
A) F1
B) F2
C) F5 *
D) F10
''';
      final r = parseMcqs(
        text,
        sourceId: 'ast-4',
        sourceLabel: 'Double asterisk',
      );
      // Q1 must NOT be saved with a guessed answer.
      expect(
        r.questions.any(
          (q) => q.text.contains('Hypertext language'),
        ),
        isFalse,
      );
      // The conflict is reported, not silently resolved.
      expect(r.conflicts, isNotEmpty);
      expect(
        r.conflicts.any(
          (c) => c.contains('asterisk') || c.contains('*'),
        ),
        isTrue,
      );
      // Q2 (single asterisk) still parses.
      expect(r.questions.any((q) => q.text.contains('slide show')),
          isTrue);
    });

    test('asterisk in the QUESTION (2 * 3) is not an answer signal',
        () {
      const text = '''
Q1. What is 2 * 3?
A) 5
B) 6
C) 7
D) 8
Answer: B
Q2. Which key is used to slide show?
A) F1
B) F2
C) F5 *
D) F10
''';
      final r = parseMcqs(
        text,
        sourceId: 'ast-5',
        sourceLabel: 'Asterisk in question',
      );
      expect(r.parsed, 2);
      expect(r.questions[0].text, contains('2 * 3'));
      expect(r.questions[0].correctIndex, 1);
      expect(r.questions[1].correctIndex, 2);
    });
  });
}
