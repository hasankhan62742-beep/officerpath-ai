import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/models/exam.dart';
import 'package:officerpath_ai/models/question.dart';
import 'package:officerpath_ai/services/answer_key.dart';
import 'package:officerpath_ai/services/book_structure.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';

/// Permanent synthetic tests for the v1.2 parse pipeline signals.
/// Real-file assertions live in `real_book_test.dart`; these prove
/// each signal in isolation with deterministic inputs.

ParseResult parse(String text) => parseMcqs(
  text,
  sourceId: 'synthetic',
  sourceLabel: 'synthetic',
);

ParseResult parsePages(List<(int, String)> pages) => parseMcqsFromPages(
  [for (final (p, t) in pages) PageText(p, t)],
  sourceId: 'synthetic',
  sourceLabel: 'synthetic',
);

void main() {
  group('Answer key — two-paper segmentation', () {
    test('Paper 2 key never answers Paper 1 questions', () {
      const text = '''
Paper 1
1. What is the capital of Pakistan?
A) Lahore
B) Karachi
C) Islamabad
D) Quetta
2. Which is the largest ocean?
A) Atlantic
B) Pacific
C) Indian
D) Arctic
Paper 1 Answer Key
1. C
2. B
Paper 2
1. Which planet is the Red Planet?
A) Venus
B) Jupiter
C) Mars
D) Saturn
2. How many players in cricket?
A) 9
B) 10
C) 11
D) 12
Paper 2 Answer Key
1. C
2. C
''';
      final r = parsePages([(1, text)]);
      expect(r.parsed, 4);
      expect(r.keyEntriesApplied, 4);
      expect(r.questionsMissingAnswers, isEmpty);
      final byText = {for (final q in r.questions) q.text: q};
      expect(byText['What is the capital of Pakistan?']!.correctIndex, 2);
      expect(byText['Which is the largest ocean?']!.correctIndex, 1);
      expect(byText['Which planet is the Red Planet?']!.correctIndex, 2);
      expect(byText['How many players in cricket?']!.correctIndex, 2);
      // Parts are per-paper.
      expect(r.parts.map((p) => p.title), contains('Paper 1'));
      expect(r.parts.map((p) => p.title), contains('Paper 2'));
    });

    test('compact single-line key + text answers', () {
      const text = '''
1. What is the capital of Pakistan?
A) Lahore
B) Karachi
C) Islamabad
D) Quetta
2. Which is the largest ocean?
A) Atlantic
B) Pacific
C) Indian
D) Arctic
Answer Key
1.C 2.B
''';
      final r = parse(text);
      expect(r.parsed, 2);
      expect(r.keyEntriesApplied, 2);
      expect(r.questions.first.correctIndex, 2);
      expect(r.questions.last.correctIndex, 1);
    });

    test('text answer matched to options', () {
      const text = '''
1. What is the capital of Pakistan?
A) Lahore
B) Karachi
C) Islamabad
D) Quetta
Answer Key
1. Islamabad
''';
      final r = parse(text);
      expect(r.parsed, 1);
      expect(r.questions.first.correctIndex, 2);
      expect(r.questions.first.answerSource, 'key');
    });

    test('key with missing numbers reports the missing list', () {
      const text = '''
1. What is the capital of Pakistan?
A) Lahore
B) Karachi
C) Islamabad
D) Quetta
2. Which is the largest ocean?
A) Atlantic
B) Pacific
C) Indian
D) Arctic
Answer Key
1. C
''';
      final r = parse(text);
      expect(r.parsed, 1);
      expect(r.keyEntriesApplied, 1);
      expect(r.questionsMissingAnswers.length, 1);
      expect(r.questionsMissingAnswers.first, contains('Q2'));
    });

    test('a key section is never parsed as questions', () {
      const text = '''
1. What is the capital of Pakistan?
A) Lahore
B) Karachi
C) Islamabad
D) Quetta
Answer Key
1. C
2. B
3. A
''';
      final r = parse(text);
      expect(r.parsed, 1);
      // The extra key entries (2, 3) have no questions — reported as
      // unmatched, never as questions.
      expect(r.unmatchedKeyEntries.length, 2);
      expect(r.questions.every((q) => q.text != 'Answer Key'), isTrue);
    });
  });

  group('Tick + bold signals', () {
    test('tick-marked option is the answer (tick stripped)', () {
      const text = '''
1. Which is the largest ocean?
A) Atlantic
B) Pacific ✓
C) Indian
D) Arctic
''';
      final r = parse(text);
      expect(r.parsed, 1);
      final q = r.questions.first;
      expect(q.correctIndex, 1);
      expect(q.answerSource, 'tick');
      expect(q.options[1], 'Pacific');
    });

    test('bold option is the answer (boldOptions exposed)', () {
      const text = '''
1. Which is the largest ocean?
A) Atlantic
B) Pacific$boldRunMarker
C) Indian
D) Arctic
''';
      final r = parse(text);
      expect(r.parsed, 1);
      final q = r.questions.first;
      expect(q.correctIndex, 1);
      expect(q.answerSource, 'bold');
      expect(q.boldOptions, [false, true, false, false]);
    });

    test('two bold options → bold ignored, question answer-pending', () {
      const text = '''
1. Which is the largest ocean?
A) Atlantic$boldRunMarker
B) Pacific$boldRunMarker
C) Indian
D) Arctic
''';
      final r = parse(text);
      expect(r.parsed, 0);
      expect(r.questionsMissingAnswers.length, 1);
    });

    test('key beats tick on conflict, conflict recorded', () {
      const text = '''
1. Which is the largest ocean?
A) Atlantic
B) Pacific ✓
C) Indian
D) Arctic
Answer Key
1. C
''';
      final r = parse(text);
      expect(r.parsed, 1);
      final q = r.questions.first;
      expect(q.correctIndex, 2);
      expect(q.answerSource, 'key');
      expect(r.conflicts.length, 1);
      expect(r.conflicts.first, contains('tick'));
    });

    test('answer line beats tick on conflict, conflict recorded', () {
      const text = '''
1. Which is the largest ocean?
A) Atlantic
B) Pacific ✓
C) Indian
D) Arctic
Correct Answer: A) Atlantic
''';
      final r = parse(text);
      expect(r.parsed, 1);
      expect(r.questions.first.correctIndex, 0);
      expect(r.questions.first.answerSource, 'answer-line');
      expect(r.conflicts.length, 1);
    });
  });

  group('112 format — two options per line + NN. (X) key', () {
    test('two options per line split correctly', () {
      const text = '''
1. In which year was Pakistan founded?
(A) 1941 (B) 1942
(C) 1944 (D) 1946
Correct Answer: B) 1942
''';
      final r = parse(text);
      expect(r.parsed, 1);
      expect(r.questions.first.options, ['1941', '1942', '1944', '1946']);
      expect(r.questions.first.correctIndex, 1);
    });

    test('MPT-2026 shape: tight one-liner + "Correct Answer: (X) text"',
        () {
      // Format seen in the publicly posted CSS MPT 2026 solved paper:
      // options run together with no space after the paren, and the
      // answer line gives the letter AND the option text. Regression
      // test from the 19 Nov 2026 publisher-format research (Dogar /
      // JWT / Caravan / Ilmi) — no new pattern was found that the
      // parser did not already handle.
      const text = '''
Q. 1 Which is the largest ocean on Earth?
(A)Atlantic (B)Pacific (C)Indian (D)Arctic
Correct Answer: (B) Pacific

Q. 2 In which year did Pakistan come into being?
(A)1946 (B)1947 (C)1948 (D)1949
Correct Answer: (B) 1947
''';
      final r = parse(text);
      expect(r.parsed, 2);
      expect(r.questions[0].options,
          ['Atlantic', 'Pacific', 'Indian', 'Arctic']);
      expect(r.questions[0].correctIndex, 1);
      expect(r.questions[0].answerSource, 'answer-line');
      expect(r.questions[1].options, ['1946', '1947', '1948', '1949']);
      expect(r.questions[1].correctIndex, 1);
      expect(r.questions[1].answerSource, 'answer-line');
    });

    test('"NN. (X) text" key shape resolves by letter then text', () {
      const text = '''
61. What is 2 + 1?
A) 1
B) 2
C) 3
D) 4
62. What does PDF stand for?
A) Portable Document Format
B) Personal Document File
C) Public Data Format
D) Private Document Form
Answer Key
61. (C) 3
62. (A) Portable Document Format
''';
      final r = parse(text);
      expect(r.parsed, 2);
      expect(r.keyEntriesApplied, 2);
      expect(r.questions[0].correctIndex, 2);
      expect(r.questions[1].correctIndex, 0);
    });

    test('a decimal inside a key value is not a bogus entry', () {
      final entries = parseKeyEntries('74. (A) 43.75% English');
      expect(entries[74], '(A) 43.75% English');
      expect(entries.containsKey(43), isFalse);
    });

    test('mid-page key belongs to the previous paper, never the next', () {
      const text = '''
Paper 1
61. What is 2 + 1?
A) 1
B) 2
C) 3
D) 4
Answer Key
61. (C) 3
Paper 2
1. What is the capital of Pakistan?
A) Lahore
B) Karachi
C) Islamabad
D) Quetta
''';
      final r = parse(text);
      expect(r.parsed, 1);
      expect(r.questions.first.correctIndex, 2);
      // Paper 2's Q1 has no key entry — it is missing, not answered
      // by Paper 1's key.
      expect(r.questionsMissingAnswers.length, 1);
      expect(r.questionsMissingAnswers.first, contains('Paper 2 Q1'));
    });
  });

  group('Flashcards — three shapes, one pass', () {
    test('shape A: answer on the next line (Sir Tauqeer)', () {
      // Four pairs: the Q-only pool needs 3 distractors per question.
      const text = '''
Who won the 2026 Nobel Peace Prize?
Navanethem 'Navi' Pillay (South Africa)
When was United Nations Day observed in October 2026?
24 October 2026
Which country has developed first bionic eye?
Australia
Who is the current UN Secretary-General?
Antonio Guterres
''';
      final r = parse(text);
      expect(r.parsed, 4);
      final q = r.questions.first;
      expect(q.answerSource, 'flashcard');
      expect(q.text, 'Who won the 2026 Nobel Peace Prize?');
      expect(q.options, contains("Navanethem 'Navi' Pillay (South Africa)"));
    });

    test('shape B: dash-separated inline (US History)', () {
      const text = '''
1. America was named after — Amerigo Vespucci
2. How many British colonies declared independence in 1776? — 13
3. The Boston Tea Incident took place in — 1773
4. Who wrote the Declaration of Independence? — Thomas Jefferson
''';
      final r = parse(text);
      expect(r.parsed, 4);
      final byText = {for (final q in r.questions) q.text: q};
      expect(
        byText['America was named after']!.options,
        contains('Amerigo Vespucci'),
      );
      expect(
        byText['How many British colonies declared independence in 1776?']!
            .options,
        contains('13'),
      );
    });

    test('shape B: trailing dash takes the answer from the next line', () {
      const text = '''
1. Who succeeded President Abraham Lincoln? —
Andrew Johnson
2. Who was the first President of the United States? —
George Washington
3. When was the Declaration of Independence signed? —
1776
4. What was the first capital of the United States? —
New York
''';
      final r = parse(text);
      expect(r.parsed, 4);
      expect(r.questions.first.options, contains('Andrew Johnson'));
    });

    test('shape B: a plain hyphen is never a separator', () {
      const text = '''
1. The Truman Doctrine was mainly designed to extend economic assistance to — Turkey-Greece
2. The Rush-Bagot Agreement limited naval forces on — the Great Lakes
3. The Monroe Doctrine was proclaimed in — 1823
4. The Louisiana Purchase was made in — 1803
''';
      final r = parse(text);
      expect(r.parsed, 4);
      expect(r.questions.first.options, contains('Turkey-Greece'));
      // "Turkey-Greece" is ONE answer, not split on the hyphen.
      expect(
        r.questions.first.options.any((o) => o == 'Turkey'),
        isFalse,
      );
    });

    test('shape C: trailing "?" answer (GSA)', () {
      const text = '''
1. Who discovered the Solar System? Copernicus
2. Which planet is known as the 'Morning Star'? Venus
3. Which planet is known as the Red Planet? Mars
4. Which is the largest planet? Jupiter
''';
      final r = parse(text);
      expect(r.parsed, 4);
      final byText = {for (final q in r.questions) q.text: q};
      expect(
        byText['Who discovered the Solar System?']!.options,
        contains('Copernicus'),
      );
      expect(
        byText["Which planet is known as the 'Morning Star'?"]!.options,
        contains('Venus'),
      );
    });

    test('shape C: trailing ":" answer (GSA)', () {
      const text = '''
8. Bodies which usually fall from the sky on the Earth are called: Meteors
9. Solar eclipse occurs when: Moon comes between sun and earth
10. Lunar eclipse is caused when the: earth comes between the sun and the moon
11. The first ever artificial satellite was launched by: Russia
''';
      final r = parse(text);
      expect(r.parsed, 4);
      final byText = {for (final q in r.questions) q.text: q};
      expect(
        byText['Bodies which usually fall from the sky on the Earth are called:']!
            .options,
        contains('Meteors'),
      );
    });

    test('shape C: a time "10:30" never splits on the colon', () {
      final split = parse('''
1. The meeting starts at 10:30
''');
      // No trailing answer (the line is a question with no answer) —
      // it must not become a flashcard with answer "30".
      expect(
        split.questions
            .where((q) => q.options.any((o) => o == '30'))
            .isEmpty,
        isTrue,
      );
    });

    test('shape C: no trailing answer → Q-only pool, not dropped', () {
      const text = '''
1. Who discovered the Solar System?
''';
      final r = parse(text);
      // A bare "?" line with no answer is a Q-only candidate — it is
      // kept (answer pending) rather than silently dropped.
      expect(r.parsed + r.skipped, greaterThan(0));
    });

    test('roman numerals map to A–D, "All of these" is the answer', () {
      const text = '''
4. Mercury is i. The smallest planet ii. The fastest planet iii. The planet nearest to Sun iv. All of these
Correct Answer: D) All of these
''';
      final r = parse(text);
      expect(r.parsed, 1);
      expect(
        r.questions.first.options,
        [
          'The smallest planet',
          'The fastest planet',
          'The planet nearest to Sun',
          'All of these',
        ],
      );
      expect(r.questions.first.correctIndex, 3);
    });
  });

  group('Final Answer — solution blocks (110 edition)', () {
    test('maths question + Solution + "Final Answer: (C) 80"', () {
      const text = '''
19. What is 40 + 40?
A) 60
B) 70
C) 80
D) 90
Solution: Let x = 40 + 40.
x = 80.
Final Answer: (C) 80
''';
      final r = parse(text);
      expect(r.parsed, 1);
      final q = r.questions.first;
      expect(q.correctIndex, 2);
      expect(q.answerSource, 'answer-line');
      expect(q.explanation, contains('Let x = 40 + 40'));
    });

    test('OCR-noisy "Final Answer:(C)80" resolves by letter', () {
      const text = '''
19. What is 40 + 40?
A) 60
B) 70
C) 80
D) 90
Solution: working here.
Final Answer:(C)80 xyz
''';
      final r = parse(text);
      expect(r.parsed, 1);
      expect(r.questions.first.correctIndex, 2);
    });

    test('solution lines never become questions or options', () {
      const text = '''
19. What is 40 + 40?
A) 60
B) 70
C) 80
D) 90
Solution: Let x = 40 + 40.
The answer is 80 because 40 + 40 = 80.
Final Answer: (C) 80
20. What is 10 + 10?
A) 10
B) 20
C) 30
D) 40
Correct Answer: B) 20
''';
      final r = parse(text);
      expect(r.parsed, 2);
      expect(
        r.questions.map((q) => q.text),
        ['What is 40 + 40?', 'What is 10 + 10?'],
      );
    });

    test('Final Answer value matching a different option → conflict, letter wins', () {
      const text = '''
19. What is 40 + 40?
A) 60
B) 70
C) 80
D) 90
Solution: working.
Final Answer: (C) 70
''';
      final r = parse(text);
      expect(r.parsed, 1);
      // The letter (C = 80) wins; the value (70 = option B) conflicts.
      expect(r.questions.first.correctIndex, 2);
      expect(r.conflicts.isNotEmpty, isTrue);
    });
  });

  group('(Note: …) evidence (109 edition)', () {
    test('a note attaches to the nearest preceding question', () {
      // The note is EVIDENCE, not an answer — the question still
      // needs an answer line (or key/tick/bold) to be built; the note
      // is then preserved on its explanation field for the AI step.
      final r = parsePages([
        (
          1,
          '14. Who won the 2017 ATP 500 Barcelona Open doubles title?\n'
              'A) Aisam-ul-Haq Qureshi\n'
              'B) Roger Federer\n'
              'C) Rafael Nadal\n'
              'D) Novak Djokovic\n'
              'Correct Answer: A) Aisam-ul-Haq Qureshi\n'
              '(Note: Aisam-ul-Haq Qureshi won the 2017 ATP 500 Barcelona '
              'Open doubles title with Florin Mergea.)\n',
        ),
      ]);
      expect(r.parsed, 1);
      final q = r.questions.first;
      expect(q.explanation, contains('Note: Aisam-ul-Haq Qureshi won'));
      expect(r.notes.length, 1);
      expect(r.unmatchedNotes, isEmpty);
    });

    test('a note matching no question is kept in diagnostics', () {
      final r = parse(
        '(Note: This fact matches nothing in the book.)\n'
        '1. What is the capital of Pakistan?\n'
        'A) Lahore\n'
        'B) Karachi\n'
        'C) Islamabad\n'
        'D) Quetta\n'
        'Correct Answer: C) Islamabad\n',
      );
      expect(r.parsed, 1);
      expect(r.notes.length, 1);
      expect(r.unmatchedNotes.length, 1);
    });
  });

  group('MPT — "?", gaps, defective, bilingual', () {
    test('"?" key entry excludes the question, never guesses', () {
      const text = '''
1. What is the capital of Pakistan?
A) Lahore
B) Karachi
C) Islamabad
D) Quetta
3. What is the largest ocean?
A) Atlantic
B) Pacific
C) Indian
D) Arctic
Answer Key
1. C
3. ?
''';
      final r = parse(text);
      expect(r.parsed, 1);
      expect(r.questions.first.text, 'What is the capital of Pakistan?');
      expect(r.excluded.any((e) => e.contains('Q3') && e.contains('unknown')),
          isTrue);
      // The "?" token is consumed — it is not reported as unmatched.
      expect(r.unmatchedKeyEntries, isEmpty);
    });

    test('gap numbering is reported, never renumbered', () {
      const text = '''
1. What is the capital of Pakistan?
A) Lahore
B) Karachi
C) Islamabad
D) Quetta
2. Which is the largest ocean?
A) Atlantic
B) Pacific
C) Indian
D) Arctic
46. Which planet is the Red Planet?
A) Venus
B) Jupiter
C) Mars
D) Saturn
Answer Key
1. C
2. B
46. C
''';
      final r = parse(text);
      expect(r.parsed, 3);
      // Gap names the missing range AND the questions that bound it
      // (cross-page numbering, 19 Nov 2026). Page numbers appear
      // when the parse is page-aware; this is the plain-text path,
      // so there are no pages to name.
      expect(
        r.numberGaps,
        contains(
          'Q3–Q45 missing between Q2 and Q46 (43 questions missing)',
        ),
      );
    });

    test('defective "[cut off]" options exclude with reason', () {
      const text = '''
3. What is the capital of Pakistan?
A) Lahore
B) [cut off]
C) [cut off]
D) [cut off]
Answer Key
3. C
''';
      final r = parse(text);
      expect(r.parsed, 0);
      expect(r.excluded.any((e) => e.contains('defective')), isTrue);
    });

    test('defective "could not determine" note excludes with reason', () {
      const text = '''
106. What is the answer?
A) 240
B) 275
C) 250
D) 320
Could not determine — DEFECTIVE: the options are all wrong.
''';
      final r = parse(text);
      expect(r.parsed, 0);
      expect(r.excluded.any((e) => e.contains('defective')), isTrue);
    });

    test('bilingual Urdu parenthesis stays in the question text', () {
      const text = '''
1. In Islamic thought, the principal distinction between Deen and religion is that Deen ____. (Urdu: دین اور مذہب کے درمیان فرق)
A) concerns morality
B) regulates worship
C) operates only in institutions
D) provides guidance for individual and collective life together
Correct Answer: D) provides guidance for individual and collective life together
''';
      final r = parse(text);
      expect(r.parsed, 1);
      final q = r.questions.first;
      expect(q.text.contains('دین'), isTrue);
      expect(q.correctIndex, 3);
    });

    test('multi-column key table parses', () {
      final entries = parseKeyEntries(
        '1. D    58. B    73. A    88. B\n'
        '2. D    59. C    74. C    89. D',
      );
      expect(entries[1], 'D');
      expect(entries[58], 'B');
      expect(entries[73], 'A');
      expect(entries[88], 'B');
      expect(entries[2], 'D');
      expect(entries[59], 'C');
      expect(entries[74], 'C');
      expect(entries[89], 'D');
    });
  });

  group('Examveda — "Answer: Option X", 5 options, noise', () {
    test('"Answer: Option C" is an explicit answer line', () {
      const text = '''
1. What is the capital of Pakistan?
A. Lahore
B. Karachi
C. Islamabad
D. Quetta
Answer: Option C
''';
      final r = parse(text);
      expect(r.parsed, 1);
      expect(r.questions.first.correctIndex, 2);
      expect(r.questions.first.answerSource, 'answer-line');
    });

    test('5 options, answer A–D → drop E, report the count', () {
      const text = '''
1. What is the capital of Pakistan?
A. Lahore
B. Karachi
C. Islamabad
D. Quetta
E. None
Answer: Option C
''';
      final r = parse(text);
      expect(r.parsed, 1);
      expect(r.questions.first.options.length, 4);
      expect(r.questions.first.options, [
        'Lahore',
        'Karachi',
        'Islamabad',
        'Quetta',
      ]);
      expect(r.questions.first.correctIndex, 2);
      expect(r.fiveOptionNormalised, 1);
      expect(r.fiveOptionAnswerE, 0);
    });

    test('5 options, answer IS E → keep E as 4th, drop D', () {
      const text = '''
1. What is the capital of Pakistan?
A. Lahore
B. Karachi
C. Islamabad
D. Quetta
E. None of these
Answer: Option E
''';
      final r = parse(text);
      expect(r.parsed, 1);
      expect(r.questions.first.options.length, 4);
      expect(r.questions.first.options.last, 'None of these');
      expect(r.questions.first.correctIndex, 3);
      expect(r.fiveOptionNormalised, 1);
      expect(r.fiveOptionAnswerE, 1);
    });

    test('standalone digit lines + promo lines are filtered, not questions', () {
      const text = '''
1. What is the capital of Pakistan?
A) Lahore
B) Karachi
C) Islamabad
D) Quetta
Correct Answer: C) Islamabad
8
93
LIKE & FOLLOW FACEBOOK PAGE FOR MORE INFORMATIVE MATERIAL PPSC/FPSC/CSS/PMS
''';
      final r = parse(text);
      expect(r.parsed, 1);
      expect(r.noiseLinesFiltered, greaterThanOrEqualTo(3));
      expect(r.errors, isEmpty);
    });

    test('a real one-letter option and a numbered question survive the noise filter', () {
      const text = '''
8. What is the capital of Pakistan?
A) Lahore
B) Karachi
C) Islamabad
D) Quetta
Correct Answer: C) Islamabad
''';
      final r = parse(text);
      expect(r.parsed, 1);
      expect(r.questions.first.text, 'What is the capital of Pakistan?');
    });
  });

  group('Organisation facts (steer 16)', () {
    test('wide-gap label:value on one line joins into one fact', () {
      final r = parsePages([
        (2, 'UNITED NATIONS ORGANIZATION\n(UNO)\n'
            'ESTABLISHED OCTOBER 24. 1945\n'
            'MEMBER 193\n'
            'HEADQUARTER NEW YORK (US)\n'
            'GENERAL SECRATARY ANTANIO GUTERRES (PURTEEGAL)\n'),
      ]);
      expect(r.facts.length, 4);
      final byLabel = {for (final f in r.facts) f.label: f};
      expect(byLabel['ESTABLISHED']!.value, 'OCTOBER 24. 1945');
      expect(byLabel['MEMBER']!.value, '193');
      expect(byLabel['HEADQUARTER']!.value, 'NEW YORK (US)');
      // Source spellings preserved exactly as printed.
      expect(byLabel['GENERAL SECRATARY']!.value,
          'ANTANIO GUTERRES (PURTEEGAL)');
      expect(r.facts.every((f) => f.page == 2), isTrue);
    });

    test('label and value on separate lines join (same page)', () {
      final r = parsePages([
        (2, 'UNITED NATIONS ORGANIZATION\nESTABLISHED\nOCTOBER 24. 1945\n'),
      ]);
      expect(r.facts.length, 1);
      expect(r.facts.first.label, 'ESTABLISHED');
      expect(r.facts.first.value, 'OCTOBER 24. 1945');
    });

    test('org-card parts: two cards, facts assigned to the right card', () {
      final r = parsePages([
        (2, 'UNITED NATIONS ORGANIZATION\n(UNO)\n'
            'ESTABLISHED OCTOBER 24. 1945\n'),
        (3, 'FOOD AND AGRICULTURE ORGANIZATION (FAO)\n'
            'ESTABLISHED OCTOBER 16, 1945\n'),
      ]);
      expect(r.facts.length, 2);
      expect(r.facts[0].part, contains('UNITED NATIONS'));
      expect(r.facts[1].part, contains('FOOD AND AGRICULTURE'));
    });
  });

  group('Misc — Q.1: strip, toMap round-trip, negative letter, Skia', () {
    test('"Q.1:" prefix strips fully', () {
      const text = '''
Q.1: What is the capital of Pakistan?
A. Lahore
B. Karachi
C. Islamabad
D. Quetta
Correct Answer: C) Islamabad
''';
      final r = parse(text);
      expect(r.parsed, 1);
      expect(r.questions.first.text, 'What is the capital of Pakistan?');
    });

    test('Question toMap/fromMap round-trips page/part/source/bold', () {
      final q = Question(
        text: 'What is the capital of Pakistan?',
        options: ['Lahore', 'Karachi', 'Islamabad', 'Quetta'],
        correctIndex: 2,
        subject: Subject.gk,
        sourceId: 's',
        sourceLabel: 'book',
        page: 3,
        part: 'Pakistan Current Affairs',
        answerSource: 'key',
        boldOptions: [false, false, true, false],
      );
      final back = Question.fromMap(q.toMap());
      expect(back.page, 3);
      expect(back.part, 'Pakistan Current Affairs');
      expect(back.answerSource, 'key');
      expect(back.boldOptions, [false, false, true, false]);
      // A pre-v1.2 map (no new keys) reads back with defaults.
      final legacy = Question.fromMap({
        'text': 'Q?',
        'option_a': 'A',
        'option_b': 'B',
        'option_c': 'C',
        'option_d': 'D',
        'correct_index': 0,
        'subject': 'General Knowledge',
        'source_id': 's',
        'source_label': 'book',
      });
      expect(legacy.page, 0);
      expect(legacy.part, '');
      expect(legacy.answerSource, '');
      // The model's default for a missing bold_options is [] (no
      // bold info) — a pre-v1.2 row reads back as "no bold signal".
      expect(legacy.boldOptions, isEmpty);
    });

    test('synthetic admission letter → 0 parsed, single "Poori book" part', () {
      // Fake letter-shaped text (no real content, no real file path).
      final r = parsePages([
        (
          1,
          'PUNJAB PUBLIC SERVICE COMMISSION\n'
              'ADMISSION LETTER\n'
              'JUNIOR CLERK - 40H2025\n'
              'Candidate Name: Test Candidate\n'
              'Roll Number: 000000\n'
              'Test Date: 14 December 2025\n'
              'Centre: D.G. Khan\n',
        ),
        (2, 'Instructions for candidates:\n'
            'Bring your original CNIC and this letter.\n'
            'Report at the centre 30 minutes early.\n'),
      ]);
      expect(r.parsed, 0);
      expect(r.questions, isEmpty);
      expect(r.parts.length, 1);
      expect(r.parts.first.title, wholeBookPartTitle);
      // And the structure detector does not make a "Junior Clerk" part.
      final structure = detectBookStructure([
        const PageText(1, 'JUNIOR CLERK - 40H2025\nCandidate Name: X\n'),
      ]);
      expect(
        structure.parts.any((p) => p.title.toLowerCase().contains('clerk')),
        isFalse,
      );
    });

    test('Skia-style /Contents array resolves (nested arrays)', () {
      // A page whose /Contents is an ARRAY of stream refs (the
      // Skia/print-to-PDF case): object 4 is [5 0 R 9 0 R], object 9
      // is a nested array [6 0 R 7 0 R]. Stream 5 = header, 6 = two
      // questions, 7 = footer. All three must extract, in order.
      final buf = BytesBuilder();
      void add(String s) => buf.add(latin1.encode(s));
      add('%PDF-1.4\n');
      add('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');
      add('2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n');
      add(
        '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
        '/Resources << /Font << /F1 8 0 R >> >> '
        '/Contents 4 0 R >>\nendobj\n',
      );
      add('4 0 obj\n[ 5 0 R 9 0 R ]\nendobj\n');
      const header =
          'BT /F1 12 Tf 72 720 Td (PPSC PAST PAPER) Tj ET';
      add('5 0 obj\n<< /Length ${header.length} >>\nstream\n$header\n'
          'endstream\nendobj\n');
      const questions =
          'BT /F1 12 Tf 72 700 Td (1. What is the capital of Pakistan?) Tj ET\n'
          'BT /F1 12 Tf 72 680 Td (A. Lahore) Tj ET\n'
          'BT /F1 12 Tf 72 660 Td (B. Karachi) Tj ET\n'
          'BT /F1 12 Tf 72 640 Td (C. Islamabad) Tj ET\n'
          'BT /F1 12 Tf 72 620 Td (D. Quetta) Tj ET\n'
          'BT /F1 12 Tf 72 600 Td (Correct Answer: C) Tj ET\n'
          'BT /F1 12 Tf 72 580 Td (2. Which is the largest ocean?) Tj ET\n'
          'BT /F1 12 Tf 72 560 Td (A. Atlantic) Tj ET\n'
          'BT /F1 12 Tf 72 540 Td (B. Pacific) Tj ET\n'
          'BT /F1 12 Tf 72 520 Td (C. Indian) Tj ET\n'
          'BT /F1 12 Tf 72 500 Td (D. Arctic) Tj ET\n'
          'BT /F1 12 Tf 72 480 Td (Correct Answer: B) Tj ET\n';
      add('6 0 obj\n<< /Length ${questions.length} >>\nstream\n$questions\n'
          'endstream\nendobj\n');
      const footer = 'BT /F1 12 Tf 72 460 Td (Page 1) Tj ET';
      add('7 0 obj\n<< /Length ${footer.length} >>\nstream\n$footer\n'
          'endstream\nendobj\n');
      add('8 0 obj\n<< /Type /Font /Subtype /Type1 '
          '/BaseFont /Helvetica >>\nendobj\n');
      add('9 0 obj\n[ 6 0 R 7 0 R ]\nendobj\n');
      add('%%EOF\n');
      final bytes = buf.takeBytes();
      final pages = extractPdfPages(bytes);
      expect(pages.length, 1);
      final text = pages.first.text;
      // Header before Q1, footer after — the array resolved in order.
      expect(text.indexOf('PPSC PAST PAPER'), lessThan(text.indexOf('1.')));
      expect(text.indexOf('Page 1'), greaterThan(text.indexOf('2.')));
      final r = parseMcqs(
        text,
        sourceId: 'skia',
        sourceLabel: 'skia',
      );
      expect(r.parsed, 2);
      expect(r.questions[0].correctIndex, 2);
      expect(r.questions[1].correctIndex, 1);
    });
  });
}
