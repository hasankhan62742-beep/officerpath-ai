import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/models/exam.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';

/// Table-format MCQs (v1.3): the user's CamScanner grammar page
/// ("Adjective and its Types" / "Article and its Types"), 32 rows.
/// The fixtures are the REAL OCR text of ppsc123_1.jpg — transcribed
/// from the Gemini-vision row dump (32 rows, one per line, as
/// `<question> || <A> || <B> || <C> || <D> || <key> || <type>`), not
/// invented text. The column-wise fixture is the ML Kit / Tesseract
/// reading order (all questions, then all A-options, then B, C, D,
/// then the key letters, then the type labels); the row-wise fixture
/// is the same 32 rows in row order (a text PDF / Gemini-vision rows).
/// The question wraps ("In the sentence … / kitchen table,…",
/// "…word :" / "much", "He is the" / "___ in the class.") are the
/// real line breaks on the page.
void main() {
  // ------------------------------------------------------------------
  // Column-wise fixture (ML Kit / Tesseract order).
  // ------------------------------------------------------------------
  const columnWiseTable = r'''
Adjective and its Types
An adjective modifies a
Classify "friendly" based on its part of speech.
In the sentence "My bag is under the
kitchen table," what is the underlined word's part of
speech?
Better to be untaught than (ill-taught). ill taught
is:
"I think the later part of the movie was interesting." The word "later" is
The metal plate is hard. Hard is which part of speech:
There was much effort for little work. Identify the parts of speech word :
much
The hand has five fingers. In this sentence five is:
Fill in the blank with suitable words: _____people have _____ knowledge of physics.
He gave me _____ quantity of milk.
Bring me _____ water.
The doctor recommended _____ tablets and asked to drink _____ of water.
Choose the correct words from the options to complete the sentence correctly: Khalid is _____ Naveed
Which of the following is a comparative degree?
Ali is my best friend. Best is which part of speech?
_____ dangerously a person lives _____ chances of his death in young age.
Choose the correct sentence
Choose the correct sentence: This cloth is more superior than that.
Choose one correct sentence: She is more prettier than her sister.
Choose the correct one:
The students in our school are _____in other schools
This is _____ of all trees:
Correct sentence: "This is the elder tree in the forest".
He is the
___ in the class.
She is older _____Amina but _ oldest of the all.
Article and its Types
___ Turkish delegation including two persons ____ visiting Pakistan.
Yesterday, I met ___European
Choose the suitable word to fill in the blanks: I met___ European?
She bought ___more expensive car than I do
___baby likes ___ funny story.
He is ____ M.A English.
When she goes outside she takes ____Umbrella?
Noun
Adjective
Noun
Adjective
Adverb
Adverb
Quantitative adjective
Noun
Very few, some
A small
Some
-/a lot
Not as tall
Angry
Noun
The more/the more
The higher you go, the cooler it gets
This cloth is more superior than that.
She is prettier than her sister
This is a perfect example
Smarter
more shortest
Old
Best
than/the
the/is
A
A
an
a/a
A
An
Verb
Noun
Verb
Noun
Adjective
Adjective
Qualitative adjective
Adverb
A few, some
small
Little
-/lot
As tall
Taller
Verb
the most/the more
The higher you go, the cooler it is
This cloth is superior than that.
She is most prettier than her sister
This is a most perfect example
smarter than
shortest
elder
Top
an/a
a/is
An
The
a
The/a
An
A
Adverb
Verb
Adjective
Verb
Verb
Noun
Subjective adjective
Adjective
Few, Little
a little
A little
Some/plenty
As if not
Bad
Adjective
the most/the most
The high you go, the cooler it is:
This cloth is more superior to that.
She has prettier than her sister
This is most perfect example
smarter than those
most shortest
Oldest
Prime
than/a
the/are
The
Some
No article is used
-/-
At
Of
Preposition
Adverb
Adverb
None of these
None of these
None of these
None of these
None of these
A few, very little
None of these
None of these
None of these
As tall as
Worst
Adverb
None of these
The higher you go, the coolest it is:
This cloth is superior to that
None of these
None of these
smarter than
None of these
None of these
Leading
a/the
None of these
None of these
An
the
An/a
None of these
None of these
A
A
C
A
B
B
A
C
B
C
A
C
D
B
C
A
D
D
A
A
C
B
C
A
A
B
A
A
B
A
B
A
Adjective
Adjective
Attributive Adjective
Attributive Adjective
Attributive Adjective
Predicative Adjective
Quantitative adjective
Quantitative adjective
Qualitative adjective
Qualitative adjective
Qualitative adjective
Qualitative adjective
Comparative adjective (as/as degree)
Comparative. adjective
Superlative adjective
Degree of Adjective
Comparative adjective
Degree of Adjective
Comparative adjective
Degree of Adjective
Comparative adjective
Superlative adjective
Superlative adjective
Superlative adjective
Degree of Adjective
article a/is
Indefinite Article
Indefinite Article
Indefinite Article
Indefinite Article
Indefinite Article
Indefinite Article
''';

  // ------------------------------------------------------------------
  // Row-wise fixture (a text PDF / Gemini-vision rows): the same 32
  // rows, each as question line(s) + 4 bare option lines + key letter
  // + type label.
  // ------------------------------------------------------------------
  const rowWiseTable = r'''
Adjective and its Types
An adjective modifies a
Noun
Verb
Adverb
Preposition
A
Adjective
Classify "friendly" based on its part of speech.
Adjective
Noun
Verb
Adverb
A
Adjective
In the sentence "My bag is under the
kitchen table," what is the underlined word's part of
speech?
Noun
Verb
Adjective
Adverb
C
Attributive Adjective
Better to be untaught than (ill-taught). ill taught
is:
Adjective
Noun
Verb
None of these
A
Attributive Adjective
"I think the later part of the movie was interesting." The word "later" is
Adverb
Adjective
Verb
None of these
B
Attributive Adjective
The metal plate is hard. Hard is which part of speech:
Adverb
Adjective
Noun
None of these
B
Predicative Adjective
There was much effort for little work. Identify the parts of speech word :
much
Quantitative adjective
Qualitative adjective
Subjective adjective
None of these
A
Quantitative adjective
The hand has five fingers. In this sentence five is:
Noun
Adverb
Adjective
None of these
C
Quantitative adjective
Fill in the blank with suitable words: _____people have _____ knowledge of physics.
Very few, some
A few, some
Few, Little
A few, very little
B
Qualitative adjective
He gave me _____ quantity of milk.
A small
small
a little
None of these
C
Qualitative adjective
Bring me _____ water.
Some
Little
A little
None of these
A
Qualitative adjective
The doctor recommended _____ tablets and asked to drink _____ of water.
-/a lot
-/lot
Some/plenty
None of these
C
Qualitative adjective
Choose the correct words from the options to complete the sentence correctly: Khalid is _____ Naveed
Not as tall
As tall
As if not
As tall as
D
Comparative adjective (as/as degree)
Which of the following is a comparative degree?
Angry
Taller
Bad
Worst
B
Comparative. adjective
Ali is my best friend. Best is which part of speech?
Noun
Verb
Adjective
Adverb
C
Superlative adjective
_____ dangerously a person lives _____ chances of his death in young age.
The more/the more
the most/the more
the most/the most
None of these
A
Degree of Adjective
Choose the correct sentence
The higher you go, the cooler it gets
The higher you go, the cooler it is
The high you go, the cooler it is:
The higher you go, the coolest it is:
D
Comparative adjective
Choose the correct sentence: This cloth is more superior than that.
This cloth is more superior than that.
This cloth is superior than that.
This cloth is more superior to that.
This cloth is superior to that
D
Degree of Adjective
Choose one correct sentence: She is more prettier than her sister.
She is prettier than her sister
She is most prettier than her sister
She has prettier than her sister
None of these
A
Comparative adjective
Choose the correct one:
This is a perfect example
This is a most perfect example
This is most perfect example
None of these
A
Degree of Adjective
The students in our school are _____in other schools
Smarter
smarter than
smarter than those
smarter than
C
Comparative adjective
This is _____ of all trees:
more shortest
shortest
most shortest
None of these
B
Superlative adjective
Correct sentence: "This is the elder tree in the forest".
Old
elder
Oldest
None of these
C
Superlative adjective
He is the
___ in the class.
Best
Top
Prime
Leading
A
Superlative adjective
She is older _____Amina but _ oldest of the all.
than/the
an/a
than/a
a/the
A
Degree of Adjective
Article and its Types
___ Turkish delegation including two persons ____ visiting Pakistan.
the/is
a/is
the/are
None of these
B
article a/is
Yesterday, I met ___European
A
An
The
None of these
A
Indefinite Article
Choose the suitable word to fill in the blanks: I met___ European?
A
The
Some
An
A
Indefinite Article
She bought ___more expensive car than I do
an
a
No article is used
the
B
Indefinite Article
___baby likes ___ funny story.
a/a
The/a
-/-
An/a
A
Indefinite Article
He is ____ M.A English.
A
An
At
None of these
B
Indefinite Article
When she goes outside she takes ____Umbrella?
An
A
Of
None of these
A
Indefinite Article
''';

  // ------------------------------------------------------------------
  // Noisy fixture: what tesseract.js v5 (eng, PSM 3) actually read
  // from ppsc123_1.jpg — 2960 chars, column-major but garbled: the
  // key-letter column is lost (only ~4 standalone A–D lines), option
  // values are merged with type labels ("Adverb A", "A small a
  // little"), and question wraps are split across lines. The table
  // parser must NOT crash and must NOT invent rows from this — it
  // returns the table hint instead, so the dialog can suggest the
  // Gemini ("best quality") OCR path.
  // ------------------------------------------------------------------
  const noisyOcrTable = r'''
In the sentence "My bag is under the kitchen
table,” what is the underlined word's part of
speech?

1s:

“I think the later part of the movie was
interesting.” The word “later” is

The metal plate is hard. Hard is which part of

There was much effort for little work. Identify

the parts of speech word : much
The hand has five fingers. In this sentence
five is:

Fill in the blank with suitable words:
people have

water.

Bring me__

The doctor recommended
asked to drink of water.

complete the sentence correctly: Khalid
is Naveed

dangerously a person lives
of his death in young age.

Choose the correct sentence

Choose the correct sentence: This cloth is more

superior than that. ‘
Choose one correct sentence: She is more

prettier than her sister.
Choose the correct one:

The students in our school are
schools

This is of all trees: : i

Correct sentence: “This is the elder tree in the

forest”.

+ | Heis the in the class.
She isolder ____Amina but oldest of the
all,

——— visiting Pakistan.

' | Yesterday, | met __European

Choose the suitable word to fill in the blanks: |

met____ European?

——_baby likes funny story.

Heis ____

M.A English.

An adjective modifies a

Better to be untaught than (ill-taught). ill taught

knowledge of physics.

He gave me _____ quantity of milk.

tablets and

Choose the correct words from the options to

Ali is my best friend. Best is which part of
speech?

——_ Turkish delegation including two persons

She bought ___more expensive car than | do

Adjective and its Types

Verb

Adjective

Adverb A

Adjective

Adverb Attributive Adjective

None of these Attributive Adjective

Attributive Adjective

e | Predicative Adjective

None of these

None of these

Subjective adjective

Quantitative Qualitative
adjective adjective

A small a little

sSepiTy

The high you go, thi
‘cooler it is:
This cloth is
“{'more superior to
“| that.

s most prettier _| She has prettier than
{| than her sister ‘| her sister

This cloth is more :
superior than that.

She is prettier
than her sister

This is most
| perfect example...

al | smarter than those
ERTS “1 Oldest

This is a perfect
example .....

yg

No article is

used

EEE Er
EE ET

None of these

Quantitative adjective

EER rE Cr Samad Sjection
1 aN A few, very little e | Qualitative adjective

Qualitative adjective
+ Jose]
Qualitative adjective
Jim
4 (as/as degree)

p |

Comparative. adjective

None of these

iw

&

Degree of Adjective

Comparative adjective

The higher you go, the

3

coolest it is: :

Degree of Adjective

Comparative adjective

- v a | Degree of Adjective
Comparative adjective
» e | Superlative adjective

ET
El

Superlative adjective

Superlative adjective

Degree of Adjective

‘Leading

article a/is

Indefinite Article

Indefinite Article

Indefinite Article

An/a

Indefinite Article

CG AGRE

Indefinite Article

None of these

? | When she goes outside she takes ___ Umbrella? wy JE of

Indefinite Article

None of these
''';

  ParseResult parseTableText(String text) => parseMcqs(
        text,
        sourceId: 'table-fixture',
        sourceLabel: 'Grammar table',
      );

  test('column-wise table (ML Kit order): 32 rows, keys resolve', () {
    final r = parseTableText(columnWiseTable);
    expect(r.formatCounts['table'], 32, reason: 'all 32 rows parsed');
    expect(r.parsed, 32);
    expect(r.skipped, 0);
    expect(r.answerSources['key'], 32);
    // First question: the 4 options, key A = "Noun".
    final first = r.questions.first;
    expect(first.text, 'An adjective modifies a');
    expect(first.options, ['Noun', 'Verb', 'Adverb', 'Preposition']);
    expect(first.correctIndex, 0);
    expect(first.options[first.correctIndex], 'Noun');
    expect(first.answerSource, 'key');
    // Row 3 (Attributive Adjective): key C = "Adjective".
    final third = r.questions[2];
    expect(
      third.text,
      startsWith('In the sentence "My bag is under the kitchen table,"'),
    );
    expect(third.options, ['Noun', 'Verb', 'Adjective', 'Adverb']);
    expect(third.correctIndex, 2);
    // Row 9 (fill-in-the-blank): key B = "A few, some".
    final ninth = r.questions[8];
    expect(ninth.options, [
      'Very few, some',
      'A few, some',
      'Few, Little',
      'A few, very little',
    ]);
    expect(ninth.correctIndex, 1);
    // Row 27 (article "a" as option A): key A = "A".
    final row27 = r.questions[26];
    expect(row27.text, 'Yesterday, I met ___European');
    expect(row27.options, ['A', 'An', 'The', 'None of these']);
    expect(row27.correctIndex, 0);
    // Last row: key A = "An".
    final last = r.questions.last;
    expect(last.text, 'When she goes outside she takes ____Umbrella?');
    expect(last.options, ['An', 'A', 'Of', 'None of these']);
    expect(last.correctIndex, 0);
    // Grammar tables are English; no question was stolen by q-only.
    expect(r.formatCounts['q-only'] ?? 0, 0);
    expect(r.questions.every((q) => q.subject == Subject.english), isTrue);
  });

  test('row-wise table: 32 rows, keys resolve', () {
    final r = parseTableText(rowWiseTable);
    expect(r.formatCounts['table'], 32, reason: 'all 32 rows parsed');
    expect(r.parsed, 32);
    expect(r.skipped, 0);
    expect(r.answerSources['key'], 32);
    final first = r.questions.first;
    expect(first.text, 'An adjective modifies a');
    expect(first.options, ['Noun', 'Verb', 'Adverb', 'Preposition']);
    expect(first.correctIndex, 0);
    // Row 7: the "much" tail belongs to the question, not the options.
    final seventh = r.questions[6];
    expect(seventh.text, contains('word : much'));
    expect(seventh.options, [
      'Quantitative adjective',
      'Qualitative adjective',
      'Subjective adjective',
      'None of these',
    ]);
    expect(seventh.correctIndex, 0);
    // Row 13: key D = "As tall as".
    final row13 = r.questions[12];
    expect(row13.options, ['Not as tall', 'As tall', 'As if not', 'As tall as']);
    expect(row13.correctIndex, 3);
    // Row 27: single-letter option "A" is the article, not the key.
    final row27 = r.questions[26];
    expect(row27.options, ['A', 'An', 'The', 'None of these']);
    expect(row27.correctIndex, 0);
    expect(r.formatCounts['q-only'] ?? 0, 0);
  });

  test('noisy tesseract OCR: no invented table rows, hint shown', () {
    final r = parseTableText(noisyOcrTable);
    // The key column is lost in this OCR text, so no table row may be
    // invented from it — but the parse must not crash either.
    expect(r.formatCounts['table'] ?? 0, 0);
    // The text IS table-shaped (many type labels), so the dialog gets
    // an actionable hint instead of a bare "No MCQs found".
    expect(
      r.errors.any((e) => e.contains('Table format lagta hai')),
      isTrue,
    );
  });

  test('5-option row normalises to 4; key on E keeps E as 4th', () {
    // A 10-column-style table: question + 5 options + key + type.
    // Answer on E ("None of these") is kept as the 4th option and D
    // is dropped, per the Examveda rule. (3 rows: the table parser
    // needs ≥ 3 rows to accept a table at all.)
    const fiveOption = r'''
Which is the largest ocean?
Pacific
Atlantic
Indian
Arctic
None of these
E
Geography
Which is the longest river?
Nile
Amazon
Yangtze
Mississippi
Danube
B
Geography
Which is the largest desert?
Sahara
Gobi
Kalahari
Mojave
Thar
A
Geography
''';
    final r = parseTableText(fiveOption);
    expect(r.formatCounts['table'], 3);
    expect(r.fiveOptionNormalised, 3);
    expect(r.fiveOptionAnswerE, 1);
    final first = r.questions.first;
    expect(first.options, ['Pacific', 'Atlantic', 'Indian', 'None of these']);
    expect(first.correctIndex, 3);
    final second = r.questions[1];
    expect(second.options, ['Nile', 'Amazon', 'Yangtze', 'Mississippi']);
    expect(second.correctIndex, 1);
    final third = r.questions[2];
    expect(third.options, ['Sahara', 'Gobi', 'Kalahari', 'Mojave']);
    expect(third.correctIndex, 0);
  });

  test('table rows without a key become answer-pending, not dropped', () {
    // A table with options + type labels but no key column: the rows
    // are kept for AI inference, never silently dropped.
    const noKey = r'''
What is the capital of France?
London
Paris
Berlin
Madrid
Geography
What is two plus two?
Three
Four
Five
Six
Maths
What is H2O?
Water
Salt
Oxygen
Hydrogen
Science
''';
    final r = parseTableText(noKey);
    expect(r.answerPending.length, 3);
    expect(r.answerPending.first.text, 'What is the capital of France?');
    expect(r.answerPending.first.options, [
      'London',
      'Paris',
      'Berlin',
      'Madrid',
    ]);
    expect(r.formatCounts['table'] ?? 0, 0);
  });

  // ------------------------------------------------------------------
  // Computer table (20 Nov 2026): the owner's "Computer Most Important
  // Questions" photo, Q67–81, "Page 5 of 71". Faithful transcription
  // of the photo's rows as '|' text (one line per row). Option cells
  // carry explicit markers ("A. Home tab"); the answer letter sits
  // in an "Ans" column; the correct option is ALSO bold in some rows
  // (Q69 "B. 1.25", Q70 "A. clip art", Q71 "D. Delete" — the bold
  // is a second, agreeing signal; the Ans letter decides). The header
  // is "Sr#" (no dot). The "Page 5 of 71" footer overlaps the bottom
  // of the Q81 row in the photo; in OCR text it is its own line.
  // ------------------------------------------------------------------
  const computerTable = r'''
Sr# | Question | A | B | C | D | Ans
67 | From where you can access Save command in Microsoft Word? | A. Home tab | B. Insert tab | C. Review tab | D. None of above | D
68 | To verify that the note text is positioned correctly on the page, switch to ____ view or display the document in print preview | A. normal | B. print layout | C. page layout | D. page edit | B
69 | What is the default left margins in word 2003 document? | A. 1 | B. 1.25 | C. 1.5 | D. 2 | B
70 | Ms Word includes a series of predefined graphics called ____ that can be inserted into a Word document. | A. clip art | B. hyperlinks | C. captions | D. bookmarks | A
71 | Which key deletes the character to the right of the cursor in Ms Word? | A. End | B. Backspace | C. Home | D. Delete | D
72 | To exit from the Resume Wizard and return to the document window without creating a resume, click the ____ button in any panel in the Resume Wizard dialog box. | A. Cancel | B. Back | C. Next | D. Finish | D
73 | A ____ is not attached to an edge of the Word window; that is, it displays in the middle of the Word window and can be moved anywhere in the window | A. floating toolbar | B. scroll bar | C. status toolbar | D. menu bar | A
74 | Ctrl + J Shortcut key is used in Microsoft Word to ____? | A. Align Justify | B. Insert Hyperlink | C. Search | D. Print | A
75 | Which of the following is not essential component to perform a mail merge operation? | A. Main document | B. Data source | C. Merge fields | D. Word fields | D
76 | When you save a file as a Web page, Word converts the contents of the document into ____. | A. Java | B. Perl | C. HTML | D. Unix | C
77 | Although it is not shown in normal view, to view a header, click ____ on the menu bar and then click Header and Footer. | A. View | B. Edit | C. Format | D. Tools | A
78 | By default, your document prints with ____? | A. 1 inch top and bottom margins | B. a portrait orientation | C. 1.25 inches left and right margins | D. all of the above | D
79 | When typing in a word field manually, what must you press to insert the code's brackets? | A. Ctrl + F6 | B. Ctrl + F9 | C. Alt + F11 | D. Shift + F12 | B
80 | What would you do when you want to update the data in an embedded worksheet range? | A. double click the worksheet range object | B. right click worksheet range object & choose format object | C. edit the data in the destination document | D. edit the data in the source document. | A
81 | who invented the difference engine and analytical engine? | A. Vint cerf | B. Mark zukerberg | C. Charles Babbage | D. None | C
Page 5 of 71
''';

  test('computer table Q67–81: markers stripped, Ans decides, footer skipped',
      () {
    final r = parseTableText(computerTable);
    expect(r.formatCounts['table'], 15, reason: 'all 15 rows parsed');
    expect(r.parsed, 15);
    expect(r.skipped, 0);
    expect(r.answerPending, isEmpty);
    for (final q in r.questions) {
      expect(q.text, isNot(contains('Page 5 of 71')));
      expect(q.text, isNot(contains('Sr#')));
      for (final o in q.options) {
        expect(o, isNot(startsWith('A. ')));
        expect(o, isNot(startsWith('B. ')));
        expect(o, isNot(startsWith('C. ')));
        expect(o, isNot(startsWith('D. ')));
      }
    }
    // Q67: markers stripped, Ans D.
    final q67 = r.questions[0];
    expect(q67.text, startsWith('From where you can access Save command'));
    expect(q67.options,
        ['Home tab', 'Insert tab', 'Review tab', 'None of above']);
    expect(q67.correctIndex, 3);
    // Q69: numeric option text after the marker; bold agrees with Ans B.
    final q69 = r.questions[2];
    expect(q69.options, ['1', '1.25', '1.5', '2']);
    expect(q69.correctIndex, 1);
    // Q70: bold "A. clip art" agrees with Ans A.
    final q70 = r.questions[3];
    expect(q70.options, ['clip art', 'hyperlinks', 'captions', 'bookmarks']);
    expect(q70.correctIndex, 0);
    // Q80: the 9-word B option ("right click worksheet range object &
    // choose format object") must not break the row.
    final q80 = r.questions[13];
    expect(q80.options[1],
        'right click worksheet range object & choose format object');
    expect(q80.correctIndex, 0);
    // Q81: last row before the footer; footer must not join it.
    final q81 = r.questions[14];
    expect(q81.text,
        'who invented the difference engine and analytical engine?');
    expect(q81.options,
        ['Vint cerf', 'Mark zukerberg', 'Charles Babbage', 'None']);
    expect(q81.correctIndex, 2);
  });

  test('computer table: option-marker mismatch goes pending, never guessed',
      () {
    const mismatch = r'''
Sr.# | Question | A | B | C | D | Ans
1 | What is the capital of France? | A. London | B. Paris | C. Berlin | D. Madrid | B
2 | What is two plus two? | A. Three | B. Four | C. Five | D. Six | B
3 | What is the colour of the sky? | A. Blue | C. Green | C. Red | D. Yellow | B
''';
    final r = parseTableText(mismatch);
    expect(r.parsed, 2);
    expect(r.answerPending.length, 1);
    final pending = r.answerPending.single;
    expect(pending.text, 'What is the colour of the sky?');
    expect(pending.options, ['Blue', 'Green', 'Red', 'Yellow']);
    expect(pending.reason, 'option-marker-mismatch');
    expect(r.errors.any((e) => e.contains('marker')), isTrue);
  });

  // ------------------------------------------------------------------
  // Interjection table (20 Nov 2026): the owner's Q230–257 photo.
  // Faithful transcription of the photo's rows as '|' text, with the
  // in-table section headings on their own lines. Bare options (no
  // markers), an Ans letter, and a topic-label last column. Two rows
  // are made key-less on purpose: Q249 (normal number — stays
  // pending WITH its number) and Q162 (misnumbered — stays pending
  // with NO number). Q258 is a synthetic continuation past the last
  // heading, proving that heading is skipped too.
  // ------------------------------------------------------------------
  const interjectionTable = r'''
230 | Choose the right one | Neither Ali nor Aslam has taken his test | Neither Ali nor Aslam have taken his test | Neither Ali nor Aslam has taken their test | None of these | A | Corelative Conjunction
231 | He is ____ worried about his car issue ____ he gets to the garage | so much/that | so/- | -/the | None of these | A | Corelative Conjunction
232 | He have had ____ trouble ____ he parked the car in the garage. | Much/and | Some/that | So much/that | None of these | C | Corelative Conjunction
233 | He is looking for a residence ____ in a hostel or in a room? | Or | Either | And | Nor | B | Corelative Conjunction
234 | His behavior was unprofessional enough ____ he terminated immediately. | That | so | though | None of these | B | Corelative Conjunction
Interjection
235 | Which part of speech can act as an independently complete sentence? | Interjection | Conjunction | Noun | Preposition | A | Interjection
236 | well! I don't think I will be home before 6 pm. In this sentence well is: | Adverb | Adjective | Interjection | None of these | C | Interjection
237 | WOW! is an: | Adverb | Adjective | Interjection | Conjunction | C | Interjection
238 | Well is which part of speech: | Conjunction | Interjection | Noun | None of these | B | Interjection
239 | Identify the underlined parts of speech: Wow! It is a beautiful symphony. | Interjection | Adjective | Article | Conjunction | A | Interjection
Parts of Speech Identification
240 | Identify the underlined parts of speech: He also likes to eat strawberries. | Noun | Adverb | Adjective | Verb | D | Identification of Parts of Speech
241 | Identify the underlined parts of speech: He also likes to eat strawberries. | Noun | Adverb | Adjective | Verb | D | Identification of Parts of Speech
242 | The cat was ____ by him. | Kill | Killed | Has kill | None of these | B | Identification of Parts of Speech
243 | Choose the subject used in sentence: 'I met the old beggar across the road': | I | Old | Beggar | Road | A | Identification of Parts of Speech
244 | I helped him. Here subject is: | I | Helped | Him | I helped | A | Identification of Parts of Speech
245 | In the sentence 'I know all the people sitting in the hall,' the complete object is: | I know | People | All the people sitting in the hall | In the hall | C | Identification of Parts of Speech
246 | How many parts of speech? | 7 | 8 | 9 | None of these | B | Identification of Parts of Speech
247 | Identify the underline part of speech: Faint heart never won fair lady. | Verb | Adjective | Adverb | Noun | A | Identification of Parts of Speech
Gerund / Infinitives / Participle
248 | I enjoy ____ tennis. | to playing | Playing | Plays | to play | B | Gerund
249 | I am ____ to weekend. | Look forward | Look forwarded | Looking forward | None of these | Gerund
250 | I don't mind ____ if you are tired. | driving | to drive | drive | None of these | A | Gerund
251 | A ____ is a verb in its present participle form ("ing") that acts as a noun in a sentence | verb | adjective | gerund | adverb | C | Gerund
252 | 'Ing' used in a sentence. It is called | Gerund | Command | Exclamation | None of these | A | Gerund
253 | She wants --- a complaint about the waiter. | To make | Making | Made | Makes | A | Infinitive
162 | I used to ____ hardship of life: | Embrace | Facing | To Face | Face | Infinitive
164 | Do you want something--- now? | To drink | drinking | for drink | None of these | A | Infinitive
254 | He wants ____ a cold drink. | Drink | To drink | Drinking | Drinks | B | Infinitive
255 | 'To help' is which type of verb? | Participle | Infinitive | Gerund | Modal | B | Infinitive
256 | Replace the underlined word 'He is very obliged.' | Much | many | So | None of these | A | Past Participle
257 | I am very obliged to him. Correct the following Sentence | Many obliged | Much obliged | So obliged | None of these | B | Past Participle
Present / Past / Perfect Tenses
258 | He ___ to school daily. | go | goes | went | gone | B | Present Tense
''';

  test('interjection table Q230–258: headings skipped, labels kept out, '
      'misnumbering distrusted', () {
    final r = parseTableText(interjectionTable);
    expect(r.parsed, 29, reason: '31 rows minus the 2 key-less pending');
    expect(r.answerPending.length, 2);
    expect(r.formatCounts['table'], 29);
    expect(r.skipped, 0);
    // No heading or topic label may appear in any question or pending.
    const forbidden = [
      'Parts of Speech Identification',
      'Gerund / Infinitives / Participle',
      'Present / Past / Perfect Tenses',
      'Corelative Conjunction',
      'Identification of Parts of Speech',
      'Past Participle',
      'Present Tense',
    ];
    for (final q in r.questions) {
      for (final f in forbidden) {
        expect(q.text, isNot(contains(f)), reason: 'heading/label in stem');
        for (final o in q.options) {
          expect(o, isNot(contains(f)), reason: 'heading/label in option');
        }
      }
    }
    for (final p in r.answerPending) {
      for (final f in forbidden) {
        expect(p.text, isNot(contains(f)));
      }
    }
    // Q230: the 8-word options parse.
    final q230 = r.questions[0];
    expect(q230.text, 'Choose the right one');
    expect(q230.options, [
      'Neither Ali nor Aslam has taken his test',
      'Neither Ali nor Aslam have taken his test',
      'Neither Ali nor Aslam has taken their test',
      'None of these',
    ]);
    expect(q230.correctIndex, 0);
    // Q235: first row after the "Interjection" heading — clean stem.
    final q235 = r.questions[5];
    expect(q235.text,
        'Which part of speech can act as an independently complete sentence?');
    expect(q235.correctIndex, 0);
    // Q237: short stem ending in ':'.
    final q237 = r.questions[7];
    expect(q237.text, 'WOW! is an:');
    expect(q237.correctIndex, 2);
    // Q243/Q244: the pronoun "I" is an option value, not a stem.
    final q243 = r.questions[13];
    expect(q243.options, ['I', 'Old', 'Beggar', 'Road']);
    expect(q243.correctIndex, 0);
    final q244 = r.questions[14];
    expect(q244.options, ['I', 'Helped', 'Him', 'I helped']);
    expect(q244.correctIndex, 0);
    // Q246: numeric options.
    final q246 = r.questions[16];
    expect(q246.text, 'How many parts of speech?');
    expect(q246.options, ['7', '8', '9', 'None of these']);
    expect(q246.correctIndex, 1);
    // Q248: first row after the "Gerund / Infinitives / Participle"
    // heading — clean stem.
    final q248 = r.questions[18];
    expect(q248.text, 'I enjoy ____ tennis.');
    expect(q248.correctIndex, 1);
    // Q253, then the misnumbered rows: their Ans answers are
    // positional, so the number distrust must not touch them.
    final q253 = r.questions[22];
    expect(q253.correctIndex, 0);
    final q164 = r.questions[23];
    expect(q164.text, startsWith('Do you want something'));
    expect(q164.correctIndex, 0);
    final q254 = r.questions[24];
    expect(q254.correctIndex, 1);
    // Q258: first row after the last heading — clean stem.
    final q258 = r.questions[28];
    expect(q258.text, 'He ___ to school daily.');
    expect(q258.correctIndex, 1);
    // Pending: Q249 keeps its number; Q162 (out of sequence) has none.
    final pending249 = r.answerPending.firstWhere(
        (p) => p.text == 'I am ____ to weekend.');
    expect(pending249.number, 249);
    final pending162 = r.answerPending
        .firstWhere((p) => p.text.startsWith('I used to'));
    expect(pending162.number, isNull);
    // The break is reported plainly.
    expect(r.errors.any((e) => e.contains('162 after 253')), isTrue);
  });
}
