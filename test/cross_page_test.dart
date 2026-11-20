// Cross-page MCQ stitching + numbering diagnostics (19 Nov 2026).
//
// The user rule: MCQs run in number order and a single question can
// be SPLIT ACROSS PAGES — the engine must follow the numbers and
// stitch the split into ONE complete question (stem + 4 options +
// answer), for text PDFs AND OCR/scanned pages alike. A continuation
// must never be a new question, never be dropped, never get the wrong
// number. Missing/duplicate numbers across a break must be reported
// in the preview diagnostics WITH page numbers.
//
// Parser-only (mocked/no-network). Page-aware path
// (`parseMcqsFromPages`) is what real PDFs use; the OCR re-parse
// path (`parseTextInBackground` with pages) is what scanned books
// use — both flatten pages into one line stream, so both must
// stitch the same way.
//
// What the code has (implemented 19 Nov 2026):
// - `flattenPages` (book_structure.dart:123) joins all pages into
//   ONE line stream with no page-boundary marker, and the block loop
//   in `_parseImpl` splits blocks ONLY at question-start lines — so
//   a split question's lines are consecutive and stitch naturally.
// - `_splitQuestionAndRest` joins a stem across ONE page break at a
//   time, skipping page furniture (footers / running headers) at the
//   boundary; the flashcard `walkBack` / `walkForward` do the same.
// - `_computeNumberGaps` / `_computeNumberDuplicates` report missing
//   and duplicated numbers WITH page numbers ("Q8 missing between
//   Q7 (page 1) and Q9 (page 2)"; "Q7 appears twice (page 1,
//   page 2)"), from a number→pages map. Both are carried to the
//   preview (`numberGaps` / `numberDuplicates`) and rendered in the
//   upload dialog (upload_screen.dart).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/book_structure.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';

void main() {
  group('split question stitches across the page break', () {
    test('stem + options A-B on p1, C-D + answer on p2 → ONE question',
        () {
      const p1 = '''
Q7. Which planet is known as the Red Planet?
(A) Venus
(B) Jupiter
''';
      const p2 = '''
(C) Mars
(D) Saturn
Answer: C
Q8. What is the capital of France?
(A) London
(B) Berlin
(C) Paris
(D) Madrid
Answer: C
''';
      final r = parseMcqsFromPages(
        [PageText(1, p1), PageText(2, p2)],
        sourceId: 'xpage',
        sourceLabel: 'split',
      );
      expect(r.parsed, 2, reason: 'Q7 + Q8, no phantom question');
      final q7 = r.questions[0];
      expect(q7.text, contains('Red Planet'));
      expect(q7.text, isNot(contains('Q7')),
        reason: 'number prefix is stripped from stored text');
      expect(q7.options, ['Venus', 'Jupiter', 'Mars', 'Saturn']);
      expect(q7.correctIndex, 2);
      expect(q7.page, 1,
        reason: 'a split question reports its starting page');
      final q8 = r.questions[1];
      expect(q8.text, contains('capital of France'));
      expect(q8.options, ['London', 'Berlin', 'Paris', 'Madrid']);
      expect(q8.correctIndex, 2);
      expect(q8.page, 2);
      expect(r.numberGaps, isEmpty,
        reason: 'numbers 7, 8 are consecutive — no gap to report');
    });

    test('stem itself wraps across the page break', () {
      const p1 = '''
Q7. Which planet is known as the
''';
      const p2 = '''
Red Planet?
(A) Venus
(B) Jupiter
(C) Mars
(D) Saturn
Answer: C
Q8. What is the capital of France?
(A) London
(B) Berlin
(C) Paris
(D) Madrid
Answer: C
''';
      final r = parseMcqsFromPages(
        [PageText(1, p1), PageText(2, p2)],
        sourceId: 'xpage',
        sourceLabel: 'split-stem',
      );
      expect(r.parsed, 2);
      expect(r.questions[0].text, contains('Red Planet'));
      expect(r.questions[0].options,
        ['Venus', 'Jupiter', 'Mars', 'Saturn']);
      expect(r.questions[0].correctIndex, 2);
      expect(r.questions[0].page, 1);
    });

    test('bare page-number line between the split parts is ignored',
        () {
      const p1 = '''
Q7. Which planet is known as the Red Planet?
(A) Venus
(B) Jupiter
''';
      const p2 = '''
2
(C) Mars
(D) Saturn
Answer: C
''';
      final r = parseMcqsFromPages(
        [PageText(1, p1), PageText(2, p2)],
        sourceId: 'xpage',
        sourceLabel: 'split-footer',
      );
      expect(r.parsed, 1);
      expect(r.questions[0].options,
        ['Venus', 'Jupiter', 'Mars', 'Saturn']);
      expect(r.questions[0].correctIndex, 2);
    });

    test('same split through the OCR re-parse path (pages, not text)',
        () {
      const p1 = '''
Q7. Which planet is known as the Red Planet?
(A) Venus
(B) Jupiter
''';
      const p2 = '''
(C) Mars
(D) Saturn
Answer: C
Q8. What is the capital of France?
(A) London
(B) Berlin
(C) Paris
(D) Madrid
Answer: C
''';
      final maps = parseTextInBackground({
        'pages': [
          {'page': 1, 'text': p1},
          {'page': 2, 'text': p2},
        ],
        'sourceId': 'xpage',
        'sourceLabel': 'split-ocr',
      });
      expect(maps['parsed'], 2);
      final questions = (maps['questions'] as List).cast<Map>();
      expect(questions[0]['option_a'], 'Venus');
      expect(questions[0]['option_b'], 'Jupiter');
      expect(questions[0]['option_c'], 'Mars');
      expect(questions[0]['option_d'], 'Saturn');
      expect(questions[0]['correct_index'], 2);
      expect(questions[0]['page'], 1);
      expect(questions[1]['page'], 2);
    });
  });

  group('numbering diagnostics across a break', () {
    test('missing number across the break surfaces a diagnostic', () {
      const p1 = '''
Q7. Which planet is known as the Red Planet?
(A) Venus
(B) Jupiter
(C) Mars
(D) Saturn
Answer: C
''';
      const p2 = '''
Q9. What is the capital of France?
(A) London
(B) Berlin
(C) Paris
(D) Madrid
Answer: C
''';
      final r = parseMcqsFromPages(
        [PageText(1, p1), PageText(2, p2)],
        sourceId: 'xpage',
        sourceLabel: 'gap',
      );
      expect(r.parsed, 2);
      expect(r.numberGaps, isNotEmpty);
      expect(r.numberGaps.join(' '), contains('Q8'));
    });

    test('missing-number diagnostic names BOTH pages', () {
      const p1 = '''
Q7. Which planet is known as the Red Planet?
(A) Venus
(B) Jupiter
(C) Mars
(D) Saturn
Answer: C
''';
      const p2 = '''
Q9. What is the capital of France?
(A) London
(B) Berlin
(C) Paris
(D) Madrid
Answer: C
''';
      final r = parseMcqsFromPages(
        [PageText(1, p1), PageText(2, p2)],
        sourceId: 'xpage',
        sourceLabel: 'gap-pages',
      );
      // The user rule: the diagnostic names the pages ("Q8 missing
      // between page 1 and page 2"). Implemented 19 Nov 2026:
      // _computeNumberGaps takes the number→pages map, so the string
      // carries the bounding pages.
      expect(r.numberGaps, isNotEmpty);
      final text = r.numberGaps.join(' ');
      expect(text, contains('Q8'));
      expect(text.toLowerCase(), contains('page'),
        reason: 'diagnostic must name the pages around the break');
      expect(text, contains('1'),
        reason: 'diagnostic must name page 1 (last page with Q7)');
      expect(text, contains('2'),
        reason: 'diagnostic must name page 2 (first page with Q9)');
    });

    test('duplicate number across the break is reported', () {
      const p1 = '''
Q7. Which planet is known as the Red Planet?
(A) Venus
(B) Jupiter
(C) Mars
(D) Saturn
Answer: C
''';
      const p2 = '''
Q7. What is the capital of France?
(A) London
(B) Berlin
(C) Paris
(D) Madrid
Answer: C
''';
      final r = parseMcqsFromPages(
        [PageText(1, p1), PageText(2, p2)],
        sourceId: 'xpage',
        sourceLabel: 'dup',
      );
      // Two different questions both numbered Q7 (numbering restart
      // or a reprinted question). The duplicate is reported in the
      // dedicated `numberDuplicates` field (implemented 19 Nov 2026),
      // with its pages — never silently merged, never dropped.
      expect(r.parsed, 2,
        reason: 'both questions are kept, never merged');
      expect(r.numberDuplicates, isNotEmpty,
        reason: 'a duplicate Q7 must be reported, with its pages');
      final text = r.numberDuplicates.join(' ');
      expect(text, contains('Q7'));
      expect(text.toLowerCase(), contains('page'));
      expect(text, contains('1'));
      expect(text, contains('2'));
    });

    test('numberGaps is shown in the preview diagnostics', () {
      // Source-level check: the preview dialog in
      // lib/screens/upload_screen.dart builds its diagnostics lines
      // from the result — numberGaps and numberDuplicates are
      // rendered there (implemented 19 Nov 2026), so a missing Q8
      // or a duplicated Q7 is visible to the user. (A widget test
      // would need sqflite; the source assertion is the honest check
      // available on the VM.)
      expect(_uploadScreenShowsNumberGaps, isTrue,
        reason: 'preview must display the missing-number '
            'diagnostic with page numbers');
    });
  });

  group('running head inside a split question', () {
    test('running-head line at the top of page 2 must not pollute '
        'the split question', () {
      const p1 = '''
Q7. Which planet is known as the Red Planet?
(A) Venus
(B) Jupiter
''';
      const p2 = '''
Current Affairs
(C) Mars
(D) Saturn
Answer: C
''';
      final r = parseMcqsFromPages(
        [PageText(1, p1), PageText(2, p2)],
        sourceId: 'xpage',
        sourceLabel: 'split-head',
      );
      // A real book reprints its running head on every page. If that
      // line lands inside a split question it must be ignored — the
      // 4 options must come out exactly as printed, with no head
      // text glued onto option B or the stem.
      expect(r.parsed, 1);
      expect(r.questions[0].options,
        ['Venus', 'Jupiter', 'Mars', 'Saturn']);
      expect(r.questions[0].correctIndex, 2);
    });

    test('footer at the bottom of page 1 must not join the stem', () {
      // The stem ends at the bottom of page 1, a "Page 1" footer
      // follows it, and the continuation is at the top of page 2
      // under a running header. Before the fix the stem became
      // "Which river flows through Page 1" and the page-2
      // continuation was dropped entirely.
      const p1 = '''
Q5. Which river flows through
Page 1
''';
      const p2 = '''
Current Affairs 2026
Page 2
the city of London and is the longest river entirely in England?
(A) Thames (B) Severn (C) Trent (D) Mersey
Answer: A
''';
      final r = parseMcqsFromPages(
        [PageText(1, p1), PageText(2, p2)],
        sourceId: 'xpage',
        sourceLabel: 'split-stem-furniture',
      );
      expect(r.parsed, 1);
      expect(
        r.questions[0].text,
        'Which river flows through the city of London and is the '
        'longest river entirely in England?',
      );
      expect(r.questions[0].text, isNot(contains('Page')));
      expect(r.questions[0].options,
        ['Thames', 'Severn', 'Trent', 'Mersey']);
      expect(r.questions[0].correctIndex, 0);
      expect(r.questions[0].page, 1);
    });
  });

  group('flashcard split across a page break', () {
    test('flashcard question on page 1, answer on page 2', () {
      // A flashcard needs 3 OTHER distinct answers in the book to
      // build its 4 options (answer-pool rule), so the fixture has
      // 4 flashcards — the split one plus three more.
      const p1 = '''
1. Who was the first President of Pakistan?
''';
      const p2 = '''
Iskander Mirza
2. Who was the first Prime Minister of Pakistan?
Liaquat Ali Khan
3. Who was the first Chief Justice of Pakistan?
Abdul Rashid
4. Who was the first Governor General of Pakistan?
Muhammad Ali Jinnah
''';
      final r = parseMcqsFromPages(
        [PageText(1, p1), PageText(2, p2)],
        sourceId: 'xpage',
        sourceLabel: 'split-flashcard',
      );
      expect(r.parsed, 4);
      expect(r.questions[0].text, contains('first President'));
      expect(r.questions[0].options, contains('Iskander Mirza'));
      expect(r.questions[1].options, contains('Liaquat Ali Khan'));
    });
  });
}

/// Source-level check (see the numberGaps preview test above): does
/// the preview builder in upload_screen.dart render the numberGaps
/// diagnostics? Reads the screen source from disk: the preview lines
/// are built from `working.…` fields, so a rendered diagnostic would
/// reference `working.numberGaps`. Implemented 19 Nov 2026 — the
/// dialog renders both `working.numberGaps` and
/// `working.numberDuplicates`.
bool get _uploadScreenShowsNumberGaps {
  final source =
      File('lib/screens/upload_screen.dart').readAsStringSync();
  return source.contains('working.numberGaps');
}
