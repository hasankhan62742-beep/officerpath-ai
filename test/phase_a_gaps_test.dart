import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/book_structure.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';

import 'test_helpers.dart';

/// Phase A gap regressions (19 Nov 2026). Each test pins one W4 gap
/// fix in lib/services/mcq_parser.dart; a revert must turn its test
/// red, never silently re-open the gap.
///
/// G6 note: a flashcard SET still needs ≥ 4 distinct answers in the
/// book before 4 options can be built from the book's own answers
/// (never invented) — a 3-item list is honestly EXCLUDED with its
/// reason, not parsed. The G6 bug was the SCAN (walkForward swallowed
/// the next flashcard as an answer continuation); the pool rule is
/// the governing spec, not a bug.
void main() {
  ParseResult p(String text) => parseMcqs(
        text,
        sourceId: 'phase-a',
        sourceLabel: 'phase-a',
      );

  // Six distinct Q&As per shape — enough answers in the pool for the
  // 3 distractors each question needs (4+ distinct answers).
  const sixDash = 'What is the capital of France? — Paris\n'
      'Who wrote Hamlet? — Shakespeare\n'
      'What is the largest planet? — Jupiter\n'
      'What is the chemical symbol for gold? — Au\n'
      'Who painted the Mona Lisa? — Leonardo da Vinci\n'
      'What is the longest river in the world? — Nile\n';
  const sixNextLine = 'What is the capital of France?\nParis\n'
      'Who wrote Hamlet?\nShakespeare\n'
      'What is the largest planet?\nJupiter\n'
      'What is the chemical symbol for gold?\nAu\n'
      'Who painted the Mona Lisa?\nLeonardo da Vinci\n'
      'What is the longest river in the world?\nNile\n';
  const sixTrailing = 'What is the capital of France? Paris\n'
      'Who wrote Hamlet? Shakespeare\n'
      'What is the largest planet? Jupiter\n'
      'What is the chemical symbol for gold? Au\n'
      'Who painted the Mona Lisa? Leonardo da Vinci\n'
      'What is the longest river in the world? Nile\n';
  const expectedAnswers = {
    'What is the capital of France?': 'Paris',
    'Who wrote Hamlet?': 'Shakespeare',
    'What is the largest planet?': 'Jupiter',
    'What is the chemical symbol for gold?': 'Au',
    'Who painted the Mona Lisa?': 'Leonardo da Vinci',
    'What is the longest river in the world?': 'Nile',
  };

  void expectSixFlashcards(ParseResult r) {
    expect(r.parsed, 6, reason: 'excluded: ${r.excluded}');
    expect(r.formatCounts['q-only'], 6);
    for (final q in r.questions) {
      expect(
        expectedAnswers[q.text],
        q.options[q.correctIndex],
        reason: 'answer polluted or lost for "${q.text}"',
      );
    }
    // No answer carries the NEXT question's text (the old
    // walkForward swallow: "Paris Who wrote Hamlet? — Shakespeare").
    for (final q in r.questions) {
      expect(q.options[q.correctIndex].contains('?'), isFalse);
    }
  }

  group('G6 unnumbered flashcards', () {
    test('dash-inline: 6/6, answers exact, none swallowed', () {
      expectSixFlashcards(p(sixDash));
    });

    test('answer-on-next-line: 6/6, answers exact', () {
      expectSixFlashcards(p(sixNextLine));
    });

    test('trailing-answer: 6/6, answers exact', () {
      expectSixFlashcards(p(sixTrailing));
    });

    test('3-item list: honestly excluded (pool too small), never guessed',
        () {
      final r = p('What is the capital of France?\nParis\n'
          'Who wrote Hamlet?\nShakespeare\n'
          'What is the largest planet?\nJupiter\n');
      expect(r.parsed, 0);
      expect(r.excluded.length, 3);
      expect(r.excluded.join(' '), contains('need 3'));
    });
  });

  group('G9 ligature normalisation in direct parseMcqs', () {
    test('U+FB03 ffi ligature becomes "ffi" in the stored question', () {
      const lig = '\uFB03';
      final r = p('1. What is the o${lig}cial capital of Australia?\n'
          'A) Sydney\nB) Melbourne\nC) Canberra\nD) Perth\nAnswer: C\n');
      expect(r.parsed, 1);
      expect(r.questions.single.text, contains('official'));
      expect(r.questions.single.text.contains('\uFB03'), isFalse);
    });

    test('parseMcqsFromPages normalises too', () {
      final r = parseMcqsFromPages(
        [const PageText(1, '1. What is the oﬃcial capital of Australia?\n'
            'A) Sydney\nB) Melbourne\nC) Canberra\nD) Perth\nAnswer: C\n')],
        sourceId: 'phase-a',
        sourceLabel: 'phase-a',
      );
      expect(r.parsed, 1);
      expect(r.questions.single.text, contains('official'));
    });
  });

  group('G2 table answer-source labelling', () {
    test('F3 Pak Affairs: 27 table rows count as bold, not key',
        () async {
      final file = File(
        '/home/hatch/workspace/user/files/Pak_Affairs_by_CSPs.pdf',
      );
      if (skipIfFixtureMissing(file.path)) return;
      final bytes = await file.readAsBytes();
      final maps = processPdfInBackground({
        'bytes': bytes,
        'sourceId': 'real-f3',
        'sourceLabel': 'Pak Affairs',
      });
      // 20 Nov 2026 (was 181/19): table fixes recover 8 more real
      // table rows; all 27 still resolve by bold, not by key.
      expect(maps['parsed'], 186);
      final sources = maps['answerSources'] as Map;
      expect(sources['bold'], 27);
    });
  });

  group('G1 column-wise table tick/bold', () {
    // 5-row column-wise table (ML Kit / Tesseract order): 5 questions,
    // then A-column, B, C, D, then the key run, then type labels.
    // Row 3's key says C (Bright) but its A-option (Cherry) is ticked.
    const columnWiseTick = '''
Adjective and its Types
Which word is a noun in this sentence here?
Which word is a verb in this sentence here?
Which word is an adjective in this sentence here?
Which word is an adverb in this sentence here?
Which word is a pronoun in this sentence here?
Apple
Banana
Cherry ✓
Grape
Mango
Run
Jump
Swim
Walk
Sing
Happy
Sad
Bright
Calm
Brave
Quickly
Slowly
Softly
Loudly
Fast
B
A
C
D
B
Noun
Verb
Adjective
Adverb
Pronoun
''';

    test('key-vs-tick conflict is recorded, key wins, tick not dropped',
        () {
      final r = p(columnWiseTick);
      expect(r.parsed, 5, reason: 'errors: ${r.errors}');
      expect(r.formatCounts['table'], 5);
      final row3 = r.questions[2];
      expect(row3.text, contains('adjective'));
      expect(row3.correctLetter, 'C');
      expect(row3.answerSource, 'key');
      expect(r.conflicts, isNotEmpty);
      expect(r.conflicts.join(' '), contains('tick is on A'));
    });

    test('bold option in a column-wise row resolves when it agrees '
        'with the key', () {
      // Same table, but the tick is removed and row 1's key option
      // (B = Run) is bold-marked (U+E000, the extractor's marker).
      final bolded = columnWiseTick
          .replaceFirst('Cherry ✓', 'Cherry')
          .replaceFirst('Run', 'Run\uE000');
      final r = p(bolded);
      expect(r.parsed, 5, reason: 'errors: ${r.errors}');
      expect(r.questions[0].correctLetter, 'B');
      expect(r.conflicts, isEmpty);
    });
  });

  group('failure loop: PakMCQs bare-numbered Q-only ("3 What …?")', () {
    // Digits + space, no dot — the whole book collapsed into ONE
    // block and only the first Q&A was found (0/500 on the real file).
    test('bare-numbered Q-only list parses, number stripped from text',
        () {
      const text = '1 What is the capital of France?\nAns: Paris.\n'
          '2 Who wrote Hamlet?\nAns: Shakespeare.\n'
          '3 What is the largest planet?\nAns: Jupiter.\n'
          '4 What is the chemical symbol for gold?\nAns: Au.\n'
          '5 Who painted the Mona Lisa?\nAns: Leonardo da Vinci.\n'
          '6 What is the longest river in the world?\nAns: Nile.\n';
      final r = p(text);
      expect(r.parsed, 6, reason: 'excluded: ${r.excluded}');
      expect(
        r.questions.map((q) => q.text),
        contains('What is the capital of France?'),
      );
      expect(
        r.questions.every((q) => !RegExp(r'^\d+\s').hasMatch(q.text)),
        isTrue,
        reason: 'bare number must be stripped from the stored text',
      );
    });

    test('guard: a bare number that is NOT a question never splits', () {
      // List item + year line: no '?' terminator, no capital after
      // the number — neither becomes a question, nothing parses.
      const text = '3 apples are red.\n'
          '1917 was a year of change.\n'
          'The shop sells 5 mangoes a day.\n';
      final r = p(text);
      expect(r.parsed, 0);
    });

    test('answer token: watermark URL stripped from the answer', () {
      const text = '1 What is the capital of France?\nAns: Paris.\n'
          '2 Who wrote Hamlet?\nAns: Shakespeare www.pakmcqs.com.pk.\n'
          '3 What is the largest planet?\nAns: Jupiter.\n'
          '4 What is the chemical symbol for gold?\nAns: Au.\n'
          '5 Who painted the Mona Lisa?\nAns: Leonardo da Vinci.\n'
          '6 What is the longest river in the world?\nAns: Nile.\n';
      final r = p(text);
      expect(r.parsed, 6);
      final hamlet = r.questions.firstWhere(
        (q) => q.text.contains('Hamlet'),
      );
      expect(hamlet.options[hamlet.correctIndex], 'Shakespeare');
      expect(
        r.questions.every(
          (q) => !q.options.any((o) => o.contains('www.')),
        ),
        isTrue,
        reason: 'no option may carry the watermark URL',
      );
    });

    test('answer token: merged next-question text is cut off', () {
      const text = '1 What is the capital of France?\nAns: Paris.\n'
          '2 How many rings on the Olympic flag?\n'
          'Ans: Six. 39 which film had song Springtime for Hitler?\n'
          '3 What is the largest planet?\nAns: Jupiter.\n'
          '4 What is the chemical symbol for gold?\nAns: Au.\n'
          '5 Who painted the Mona Lisa?\nAns: Leonardo da Vinci.\n'
          '6 What is the longest river in the world?\nAns: Nile.\n';
      final r = p(text);
      expect(r.parsed, 6);
      final rings = r.questions.firstWhere(
        (q) => q.text.contains('Olympic flag'),
      );
      expect(rings.options[rings.correctIndex], 'Six.');
    });

    test('answer token guard: a numbered answer without "?" stays whole',
        () {
      const text = '1 What is the capital of France?\nAns: Paris.\n'
          '2 Who wrote Hamlet?\nAns: Shakespeare.\n'
          '3 Which chapter is this?\nAns: Chapter 5 Summary.\n'
          '4 What is the chemical symbol for gold?\nAns: Au.\n'
          '5 Who painted the Mona Lisa?\nAns: Leonardo da Vinci.\n'
          '6 What is the longest river in the world?\nAns: Nile.\n';
      final r = p(text);
      expect(r.parsed, 6);
      final chapter = r.questions.firstWhere(
        (q) => q.text.contains('chapter'),
      );
      expect(chapter.options[chapter.correctIndex], 'Chapter 5 Summary.');
    });

    test('answer token: page-number + next-question bleed is cut off',
        () {
      const text = '1 What is the capital of France?\nAns: Paris.\n'
          '2 Which country is Goa in?\n'
          'Ans: American 48 6 Goa used to be a colony of which nation?\n'
          '3 What is the largest planet?\nAns: Jupiter.\n'
          '4 What is the chemical symbol for gold?\nAns: Au.\n'
          '5 Who painted the Mona Lisa?\nAns: Leonardo da Vinci.\n'
          '6 What is the longest river in the world?\nAns: Nile.\n';
      final r = p(text);
      expect(r.parsed, 6);
      final goa = r.questions.firstWhere(
        (q) => q.text.contains('Goa in'),
      );
      expect(goa.options[goa.correctIndex], 'American');
    });

    test('answer token: bare number + question stem bleed is cut off',
        () {
      const text = '1 What is the capital of France?\nAns: Paris.\n'
          '2 Which Norwegian word means traitor?\n'
          'Ans: Mustard 228 Which Norwegian politicians name became a '
          'word for traitor?\n'
          '3 What is the largest planet?\nAns: Jupiter.\n'
          '4 What is the chemical symbol for gold?\nAns: Au.\n'
          '5 Who painted the Mona Lisa?\nAns: Leonardo da Vinci.\n'
          '6 What is the longest river in the world?\nAns: Nile.\n';
      final r = p(text);
      expect(r.parsed, 6);
      final traitor = r.questions.firstWhere(
        (q) => q.text.contains('traitor'),
      );
      expect(traitor.options[traitor.correctIndex], 'Mustard');
    });

    test('answer token guard: "Henry 8" survives the stem-bleed cut',
        () {
      const text = '1 What is the capital of France?\nAns: Paris.\n'
          '2 Which king founded the Church of England?\n'
          'Ans: Henry 8 364 Which country was the first to abolish '
          'capital punishment?\n'
          '3 What is the largest planet?\nAns: Jupiter.\n'
          '4 What is the chemical symbol for gold?\nAns: Au.\n'
          '5 Who painted the Mona Lisa?\nAns: Leonardo da Vinci.\n'
          '6 What is the longest river in the world?\nAns: Nile.\n';
      final r = p(text);
      expect(r.parsed, 6);
      final king = r.questions.firstWhere(
        (q) => q.text.contains('Church of England'),
      );
      expect(king.options[king.correctIndex], 'Henry 8');
    });

    test('answer token guard: footer debris is never the answer', () {
      // The "answer" is only a page indicator — the question is
      // skipped honestly instead of being answered "- 2 of 62".
      // (The other 5 questions parse normally, so the pool stays
      // big enough for 4 options each.)
      const text = '1 What is the capital of France?\n'
          'Ans: www.pakmcqs.com.pk www.pakmcqs.com.pk - 2 of 62.\n'
          '2 Who wrote Hamlet?\nAns: Shakespeare.\n'
          '3 What is the largest planet?\nAns: Jupiter.\n'
          '4 What is the chemical symbol for gold?\nAns: Au.\n'
          '5 Who painted the Mona Lisa?\nAns: Leonardo da Vinci.\n'
          '6 What is the longest river in the world?\nAns: Nile.\n';
      final r = p(text);
      expect(r.parsed, 5);
      expect(
        r.questions.every(
          (q) => !q.options.any((o) => o.contains('of 62')),
        ),
        isTrue,
        reason: 'no option may be page-indicator debris',
      );
    });
  });

  group('failure loop: PPSC numbering — bare number is recorded', () {
    test('a parsed bare-numbered question is NOT reported missing',
        () {
      // PPSC Foodgrains 2013 shape: Q52 is bare-numbered ("52 Who
      // founded …?") between dotted Q51 and Q53. Before the fix the
      // preview reported "Q52 missing" although Q52 had parsed.
      const text = '51. What is the capital of France?\n'
          '(A) Paris ✓\n(B) London\n(C) Berlin\n(D) Rome\n'
          '52 Who founded Central Muhammadan Association in 1877?\n'
          '(A) Sir Syed ✓\n(B) Jinnah\n(C) Iqbal\n(D) Liaquat\n'
          '53. What is the largest planet?\n'
          '(A) Jupiter ✓\n(B) Mars\n(C) Venus\n(D) Saturn\n';
      final r = p(text);
      expect(r.parsed, 3);
      expect(r.numberGaps, isEmpty);
    });

    test('a genuinely missing number IS still reported', () {
      const text = '51. What is the capital of France?\n'
          '(A) Paris ✓\n(B) London\n(C) Berlin\n(D) Rome\n'
          '53. What is the largest planet?\n'
          '(A) Jupiter ✓\n(B) Mars\n(C) Venus\n(D) Saturn\n';
      final r = p(text);
      expect(r.parsed, 2);
      expect(r.numberGaps, hasLength(1));
      expect(r.numberGaps.first, contains('Q52 missing'));
    });
  });

  group('failure loop: PPSC Foodgrains 2013 "Sec." phantom option', () {
    // "(B) 80 Sec. ✓" used to split at the "c." of "Sec." — option B
    // became "80 Se", option C became empty ("✓"), and the tick
    // landed on the empty C. The marker must start at a word boundary.
    test('abbreviation in option text is not an option marker', () {
      const text = '4. What is the total duration of National Anthem?\n'
          '(A) 60 Sec.\n(B) 80 Sec. ✓\n(C) 100 Sec.\n(D) 120 Sec.\n';
      final r = p(text);
      expect(r.parsed, 1);
      final q = r.questions.single;
      expect(q.options, ['60 Sec.', '80 Sec.', '100 Sec.', '120 Sec.']);
      expect(q.correctIndex, 1);
      expect(q.answerSource, 'tick');
    });

    test('other a–d abbreviations (St., No., Rs.) behave the same', () {
      const text = '1. Which street is the longest?\n'
          '(A) Main St.\n(B) King Rd.\n(C) Queen St. ✓\n(D) Lake Rd.\n';
      final r = p(text);
      expect(r.parsed, 1);
      expect(r.questions.single.options[2], 'Queen St.');
      expect(r.questions.single.correctIndex, 2);
    });

    test('real inline options still split (one-liner unaffected)', () {
      const text =
          '1. Capital of Pakistan? (a) Lahore (b) Karachi (c) Islamabad (d) Quetta\nAns: (c)\n';
      final r = p(text);
      expect(r.parsed, 1);
      expect(r.questions.single.options[2], 'Islamabad');
      expect(r.questions.single.correctIndex, 2);
    });
  });

  group('G7 table minimums and stem cap', () {
    test('2-row row-wise table parses (was: minimum 3)', () {
      const rows = 'Adjective and its Types\n'
          'What is the capital of France?\nParis\nLondon\nBerlin\nRome\nA\nGeography\n'
          'What is the capital of Italy?\nParis\nLondon\nBerlin\nRome\nC\nGeography\n';
      final r = p(rows);
      expect(r.parsed, 2, reason: 'errors: ${r.errors}');
      expect(r.formatCounts['table'], 2);
    });

    test('3-row column-wise table parses (was: key run minimum 5)', () {
      const table = '''
Adjective and its Types
Which word is a noun in this sentence here?
Which word is a verb in this sentence here?
Which word is an adjective in this sentence here?
Apple
Banana
Cherry
Run
Jump
Swim
Happy
Sad
Bright
Quickly
Slowly
Softly
B
A
C
Noun
Verb
Adjective
''';
      final r = p(table);
      expect(r.parsed, 3, reason: 'errors: ${r.errors}');
      expect(r.formatCounts['table'], 3);
    });

    test('table stem over 200 chars parses (was: 200-char cap)', () {
      // 247-char stem: a full example sentence as the question.
      const stem = 'In the sentence "The quick brown fox jumps over the lazy '
          'dog near the river bank on a bright sunny morning while the birds '
          'sing in the tall green trees", what is the underlined word and '
          'which part of speech does it belong to in this context?';
      final rows = List.generate(3, (i) {
        return '$stem\nAlpha$i\nBeta$i\nGamma$i\nDelta$i\nB\nNoun\n';
      }).join('\n');
      final r = p('Adjective and its Types\n$rows');
      expect(stem.length, greaterThan(200));
      expect(r.parsed, 3, reason: 'errors: ${r.errors}');
      expect(r.questions[0].text, contains('quick brown fox'));
    });

    test('guard: 2-row table WITHOUT keys is rejected (F16 org file)', () {
      // Fact-list shape: 2 bold-anchored "rows", type labels, no key
      // letters. This is the organisation file's shape — without the
      // small-table guard it parses as 2 fake MCQs (org_realfile_test
      // went 0 → 2). With the guard it is not a table at all.
      const rows = 'Adjective and its Types\n'
          'Competitive Exam ESTABLISHED MARCH 17, 1958\nMEMBER 174\n'
          'HEADQUARTER LONDON, ENGLAND\nIMO DAY MARCH 17\n'
          'SECRETARY GENERAL KITACH LIM\nGeography\n'
          'Competitive Exam ESTABLISHED 1985 MEMBER 10\n'
          'HEADQUARTER TEHRAN, IRAN\nECO DAY NOVEMBER 28\n'
          'SECRETARY GENERAL DR. HADI SALIEMANPOUR\nSUMMIT 14\nGeography\n';
      final r = p(rows);
      expect(r.formatCounts['table'] ?? 0, 0);
      expect(r.parsed, 0);
      // And no pending rows either: the guard rejects the table
      // outright (empty result), so the lines fall through to the
      // normal block handling instead of becoming pending "rows".
      expect(r.answerPending, isEmpty);
    });

    test('guard: bare "(A)"–"(D)" lines never become table options',
        () {
      // Paper 60 OCR tail shape (camera_photo_test GAP): fragment
      // questions with bare option-letter lines. The G7 minimum
      // 3→2 briefly let them parse as a 2-row "table" (the "(A)"
      // lines served as both option cells and key anchors).
      const text = '22. Wh\nto e\n(A)\n(B)\n(C)\n(D)\n'
          '23. All\nfollo\n(A)\n(B)\n(C)\n(D)\n'
          '24. Bi\n(A)\n(B)\n(C)\n(D)\n25.\n';
      final r = p(text);
      expect(r.formatCounts['table'] ?? 0, 0);
      expect(r.parsed, 0);
      expect(
        r.questions.where((q) => q.text.contains('follo')).length,
        0,
        reason: '"All follo" must never be a question',
      );
    });

    test('guard: prose with 3 stray key letters is NOT a table', () {
      const prose = 'The history of Pakistan is long and rich.\n'
          'Many leaders played their part in the movement.\n'
          'The resolution was passed in nineteen forty.\n'
          'Students should read the book with care.\n'
          'A\nB\nC\n';
      final r = p(prose);
      expect(r.formatCounts['table'] ?? 0, 0);
      expect(r.parsed, 0);
    });
  });
}
