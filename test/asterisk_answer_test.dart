import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/image_preprocess.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';

/// Asterisk-marked answers (v1.3): Dogar-style Pakistani MCQ books print
/// a `*` after the correct option instead of an answer key, e.g.
/// "(C) F5 *", "(B) HTML*", "(A) Flaming.*". The fixtures are the REAL
/// OCR text of the user's camera photo of the DATA ENTRY OPERATOR
/// (Police) PAPER 60 page (Basic Computer Studies p.639-640, 19 Nov
/// 2026) — not invented text:
/// * [geminiPhotoOcr] is the Gemini-vision ("best quality") reading:
///   21 questions, every asterisk preserved.
/// * [tesseractPhotoOcr] is the tesseract.js PSM 3 reading of the SAME
///   photo: the `*` is misread as `§` / `"` / `®` / `'` or dropped, and
///   option markers garble ((B) -> (8), (D) -> (0)). The parser must
///   degrade gracefully on it — no crash, no invented answers — while
///   the questions it CAN read still parse.
void main() {
  // ------------------------------------------------------------------
  // Real photo OCR (Gemini vision, "best quality" tier).
  // ------------------------------------------------------------------
  const geminiPhotoOcr = r'''
6. Which menu provides you options like Animation Scheme, custom Animation, Slide Transition?
(A) Insert Menu
(B) Format Menu
(C) Tools Menu
(D) Slide Show Menu*

PAPER 60
DATA ENTRY OPERATOR (Police)
1. Which key on the keyboard can be used to slide show?
(A) F1
(B) F2
(C) F5 *
(D) F10

2. Which one is Hypertext language?
(A) XML
(B) HTML*
(C) WML
(D) HTTP

3. Another name for free software to:
(A) Encrypted Software
(B) Copy Rights Protect Software
(C) Customized Software
(D) Public Domain Software*

4. Which of the following is not used to access the web?
(A) ISDN
(B) Modem
(C) UDP *
(D) DSL

5. A computer on network is identified by its:
(A) Mac Address
(B) Port Address
(C) IP Address*
(D) Location Address

6. Which of the following is correct option for sending same letter to multiple persons?
(A) Mail merge*
(B) Macros
(C) Template
(D) Alignment

7. In MS Excel, to create a formula, you can use:
(A) Values but not cell references
(B) Cell references but not values
(C) Values or cell references although not both at the same time
(D) Both value and cell references*

8. Which programme is generally used in architectural design?
(A) Excel
(B) Power Point
(C) Auto CAD *
(D) MS Word

9. In MS Word, "Delete" key delete letters from the side of curser.
(A) Right*
(B) Up
(C) Down
(D) Left

10. What lets you to create new presentation by selecting ready-made font color and graphics affects in PowerPoint?
(A) Presentation Template
(B) Master slide
(C) Design Template*
(D) Animation Scheme

11. Which of the following is not a function in Microsoft Excel?
(A) SUM
(B) MAX
(C) MIN
(D) AVG*

12. When an Excel workbook is linked to a Word document:
(A) The Word document contains a copy of the actual data
(B) The word document cannot be edited
(C) The word document must contain a hyperlink
(D) The word document contains a reference to the original source application*

13. _____ users can open MS Excel 2016 file at the same time.
(A) 100
(B) 50
(C) 256
(D) None of these*

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
(A) ROM
(B) BIOS
(C) PROM
(D) RAM*

17. _____ occurs when a person sends a message (or many messages) with angry or antagonistic content.
(A) Flaming.*
(B) Email Bankruptcy
(C) Email Phishing
(D) Email fatigue

18. Which of the following Excel feature allows users to evaluate values and return a result?
(A) Formulas*
(B) Formatting
(C) Filters
(D) Insertions

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
(A) Open the print dialogue''';

  // ------------------------------------------------------------------
  // Real photo OCR (tesseract.js PSM 3, the weak on-device tier).
  // ------------------------------------------------------------------
  const tesseractPhotoOcr = r'''
lke

ylions
Obl o glide

ies ou
. ! pimation,

we Ww provi
Which menu | ustom A

Animation Scheme, ©
Transition?
A) ‘Insert Menu
(B) Format Menu
¢) Tools Menu }
(D) Slide Show Menu

TY XXX ¢od

PAPER 60

CALLED =

DATA ENTRY OPERATOR (

board can be used

police)
ide
Which key on the key to sli
show?
A) F1 (8) F2
(C) F§* (D) F10

op. Which one is Hypertext language? :

(A) XML B) HTML
(C) WML (D) HTTP
Another name for free software to:
(A) Encrypted Software :
(B) Copy Rights Protect Software
C) Customized Software
(D) Public Domain Software*

4. Which of the following is not used to access the

web?
(A) ISDN (B) Modem
(C) UDP" (0) DSL

A computer on network is identified by its:
(A) Mac Address (B) Port Address
(Cc) IP Address® (D) Location Address

6. Which of the following is correct: option for
sending same letter to multiple persons?
(A) Mail merge’ (B) Macros °
(C) Template (D) - Alignment

7. In MS Excel, to createa formula, you can, use:
(A) Values but not cell references
(B) Cell references but not values
(C) Values or cell references although not both

, atthe same time :
(D) ‘Both value and cell references”

8. Which programme ‘is generally used in

architectural design? ~~
(A) Excel . (B) Power Paint
(C) Auto CAD * (D) MS Word

8. In MS Word. ‘Delete’ key delete letters from the

__._ side of curser.
(A) Right" B) Up
(C) Down (D) Left

10, What lets you to create new presentation by

selecting ready-made font color and i
jes in PowerPoint? al
resentation Template
& Master di V4 Fins
/Design Template*
-(D) Animation ier i

11. Which of th au :
Microsoft SA 6 Tot 8 Junpion i

12.

15.
- (C) The text box and text both are dei

163

U7.

18.

19.

20.

In MS Word 2016, to extend a

‘ 2)
A) SUM PR
¢) MIN {0} bax,

when an Excel workbook [g |
document: a: fl Wor
(A) The Word document containg

actual data : “ORY oy
(B) The word document cannot be gd :

Cc) The word document mys leg

ao fest i t Conta, :

J) e wor ocum :

reference to the origioaing ;
application al $Oireq

users can open M

al the same time. ~~ S Excel 2016,

(A) 100 (B) 50

(C) 256 (0) None of theges

adjacent li of ie table: Selection 1,

(A) Hold down SHIFT and pr ;
key repeatedly press

(B) Press Alt+A

(C) Ctrl+ Alt +H

(0) Alt +End

When you delete a text box object fr ii
in PowrPoint Presentation: ject from a sig
(A) The object is deleted but text box ang je
text inside is left on the slide oe and the
(B) The text box is deleted and th
pasted the slide

amoy ;

e text is

(D) None of these
Which is a volatile memory? i
(A) ROM ‘(8) ‘BIOS
(C) PROM (0) RAM*

occurs when a person
message (or many messages) wi
antagonistic-content. Ci
(A). Flaming * ;
(B) Email Bankruptcy
(C) Email Phishing
(D) Emailfatigue :
Which of the following Excel f
users to evaluate values and retu
(A) Formulas*
(C). Filters

Common methods of Internet ac
include: ur Tig
(A) Broadband over coaxial cable
(B) Fiber optics or copper wires
(C) Wi-Fi oh ;
(Dy. All of these" i=.
‘In MS Excel 2016, zoom leve
only be: ge
(A) 10 percent to 300 percent
(B) 5 percent to 100 percent
(C) 10 percent to 400 percent’
(D) & percent to 300 percent

"In MS Word, what is the function
(A) Open the print dialogue

Nn
a

BS
B ®
Se. D7 Sy Tae Soave Vy J Cm M4 N71 §

N''';

  test('camera photo (Gemini OCR): 21 asterisked questions, all correct', () {
    final r = parseMcqs(
      geminiPhotoOcr,
      sourceId: 'photo-deo',
      sourceLabel: 'DATA ENTRY OPERATOR',
    );
    // 20 questions of PAPER 60 (Q1-Q20) + the previous paper's Q6
    // ("Slide Show Menu*") at the top of the page. Q21 is cut off at
    // the page bottom (only option A visible) — correctly skipped.
    expect(r.parsed, 21);
    expect(r.answerPending, isEmpty);
    expect(r.answerSources['asterisk'], 21);
    expect(r.formatCounts['block'], 21);
    // The `*` is stripped from the displayed option text — never
    // shown as "HTML*" or "F5 *".
    for (final q in r.questions) {
      expect(
        q.options.any((o) => o.contains('*')),
        isFalse,
        reason: 'asterisk leaked into an option of "${q.text}"',
      );
    }
    // Answers from the photo (Q11 = D, "AVG*", is in the photo too —
    // its options sit at the top of the right column).
    const expected = {
      'Which menu provides you options': 3, // D — Slide Show Menu*
      'Which key on the keyboard': 2, // C — F5*
      'Which one is Hypertext language': 1, // B — HTML*
      'Another name for free software': 3, // D — Public Domain Software*
      'not used to access the web': 2, // C — UDP*
      'computer on network is identified': 2, // C — IP Address*
      'sending same letter to multiple persons': 0, // A — Mail merge*
      'to create a formula, you can use': 3, // D — Both value and cell references*
      'generally used in architectural design': 2, // C — Auto CAD*
      'Delete" key delete letters': 0, // A — Right*
      'create new presentation by selecting': 2, // C — Design Template*
      'not a function in Microsoft Excel': 3, // D — AVG*
      'Excel workbook is linked to a Word': 3, // D — reference to the original source*
      'users can open MS Excel 2016 file': 3, // D — None of these*
      'extend a selection to adjacent cells': 0, // A — Hold down SHIFT…*
      'delete a text box object': 2, // C — text box and text both are deleted*
      'volatile memory': 3, // D — RAM*
      'occurs when a person sends a message': 0, // A — Flaming.*
      'evaluate values and return a result': 0, // A — Formulas*
      'Common methods of Internet access': 3, // D — All of these*
      'zoom level of a page can only be': 2, // C — 10 percent to 400 percent*
    };
    for (final entry in expected.entries) {
      final q = r.questions.firstWhere(
        (q) => q.text.contains(entry.key),
        orElse: () => throw TestFailure('missing question "${entry.key}"'),
      );
      expect(
        q.correctIndex,
        entry.value,
        reason: '"${entry.key}" should be '
            '${String.fromCharCode(65 + entry.value)}',
      );
      expect(q.answerSource, 'asterisk');
    }
    // Q21 (CTRL + R) is incomplete on the page — skipped, not guessed.
    expect(
      r.questions.any((q) => q.text.contains('CTRL + R')),
      isFalse,
    );
  });

  test('asterisk before trailing period: "Flaming.*" answers A', () {
    const text = '''
1. _____ occurs when a person sends a message with angry content.
(A) Flaming.*
(B) Email Bankruptcy
(C) Email Phishing
(D) Email fatigue
''';
    final r = parseMcqs(text, sourceId: 'syn', sourceLabel: 'syn');
    expect(r.parsed, 1);
    expect(r.questions.single.correctIndex, 0);
    expect(r.questions.single.answerSource, 'asterisk');
    // The period is kept, the asterisk is gone: "Flaming." not "Flaming.*".
    expect(r.questions.single.options[0], 'Flaming.');
  });

  test('asterisk with a space: "F5 *" and no-space "HTML*" both work', () {
    const text = '''
1. Which key shows the slide show?
(A) F1
(B) F2
(C) F5 *
(D) F10
2. Which one is Hypertext language?
(A) XML
(B) HTML*
(C) WML
(D) HTTP
''';
    final r = parseMcqs(text, sourceId: 'syn', sourceLabel: 'syn');
    expect(r.parsed, 2);
    expect(r.questions[0].correctIndex, 2);
    expect(r.questions[0].options[2], 'F5');
    expect(r.questions[1].correctIndex, 1);
    expect(r.questions[1].options[1], 'HTML');
  });

  test('one-liner with an asterisked option', () {
    const text = 'Which is the capital of France? (a) London (b) Paris* (c) Berlin (d) Madrid';
    final r = parseMcqs(text, sourceId: 'syn', sourceLabel: 'syn');
    expect(r.parsed, 1);
    expect(r.questions.single.correctIndex, 1);
    expect(r.questions.single.answerSource, 'asterisk');
    expect(r.questions.single.options[1], 'Paris');
  });

  test('two asterisked options: conflict recorded, never silently picked', () {
    const text = '''
1. Which is the capital of France?
(A) London*
(B) Paris*
(C) Berlin
(D) Madrid
''';
    final r = parseMcqs(text, sourceId: 'syn', sourceLabel: 'syn');
    // No scored question — the asterisk signal is ambiguous.
    expect(r.parsed, 0);
    expect(
      r.conflicts.any((c) => c.contains('asterisked')),
      isTrue,
    );
    // The question is kept as answer-pending for AI, not dropped.
    expect(r.answerPending.length, 1);
  });

  test('precedence: answer line beats asterisk, key beats asterisk', () {
    // Answer line says B; the asterisk is on C — the answer line wins.
    const withAnswerLine = '''
1. Which is the capital of France?
(A) London
(B) Paris
(C) Berlin*
(D) Madrid
Answer: B
''';
    final r1 = parseMcqs(
      withAnswerLine,
      sourceId: 'syn',
      sourceLabel: 'syn',
    );
    expect(r1.parsed, 1);
    expect(r1.questions.single.correctIndex, 1);
    expect(r1.questions.single.answerSource, 'answer-line');
    expect(
      r1.conflicts.any((c) => c.contains('asterisk')),
      isTrue,
    );
  });

  test('a mid-text asterisk (multiplication) is not an answer marker', () {
    const text = '''
1. What is 2 * 3?
(A) 5
(B) 6*
(C) 7
(D) 8
''';
    final r = parseMcqs(text, sourceId: 'syn', sourceLabel: 'syn');
    expect(r.parsed, 1);
    // The answer is B (the trailing `*` on option B); the `*` inside
    // the question ("2 * 3") is untouched.
    expect(r.questions.single.correctIndex, 1);
    expect(r.questions.single.text, contains('2 * 3'));
    expect(r.questions.single.options[1], '6');
  });

  test('camera photo (tesseract OCR): graceful degradation, no invented answers', () {
    final r = parseMcqs(
      tesseractPhotoOcr,
      sourceId: 'photo-deo-tess',
      sourceLabel: 'DATA ENTRY OPERATOR',
    );
    // Tesseract misreads the `*` (as § / " / ® / ' or drops it) and
    // garbles some option markers, so most questions lose their answer
    // signal. The parse must still complete, must not invent a wrong
    // answer, and must keep the unanswered questions as answer-pending
    // for AI instead of dropping them silently.
    expect(r.parsed, greaterThanOrEqualTo(1));
    expect(r.answerPending, isNotEmpty);
    // Every scored question got its answer from a real signal.
    for (final q in r.questions) {
      expect(
        ['asterisk', 'answer-line', 'key', 'tick', 'bold'],
        contains(q.answerSource),
      );
    }
    // The handwritten note at the bottom of the photo ("Dot Matrix
    // printer / impact printer") is never a question.
    expect(
      r.questions.any(
        (q) =>
            q.text.toLowerCase().contains('matrix') ||
            q.text.toLowerCase().contains('printer'),
      ),
      isFalse,
    );
    expect(
      r.answerPending.any(
        (p) =>
            p.text.toLowerCase().contains('matrix') ||
            p.text.toLowerCase().contains('printer'),
      ),
      isFalse,
    );
  });

  test('preprocessForOcr: returns valid JPEG, never throws on garbage', () {
    // A tiny 16x16 red PNG (real image bytes, generated once).
    const pngBase64 =
        'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP8z0AaYCJR/aiGUQ1DSAMAQC4BH2bjRnMAAAAASUVORK5CYII=';
    final png = base64Decode(pngBase64);
    final out = preprocessForOcr(png);
    expect(out, isNotEmpty);
    expect(out.lengthInBytes, greaterThan(0));
    // JPEG magic bytes (FF D8 FF).
    expect(out[0], 0xFF);
    expect(out[1], 0xD8);
    expect(out[2], 0xFF);
    // Garbage bytes come back unchanged — never a crash, never corrupt.
    final garbage = Uint8List.fromList([1, 2, 3, 4, 5]);
    expect(preprocessForOcr(garbage), garbage);
    expect(preprocessForOcr(Uint8List(0)), isEmpty);
  });
}
