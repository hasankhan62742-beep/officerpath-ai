import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/urdu_ocr.dart';

/// Table reconstruction from ML Kit ELEMENT boxes (20 Nov 2026,
/// phase 2). Two owner photos:
///   (a) a grammar table — "Adjective and its Types": each row is
///       stem + 4 option columns + answer-letter + type label;
///   (b) "Computer Most Important Questions" (p.1 of 71): columns
///       Sr.# | Question | A | B | C | D | Ans, option cells carry
///       explicit "A." / "B." markers, the Ans column holds the
///       answer letter (the correct option is ALSO bold in some rows
///       — but ML Kit returns no style info, so bold is NOT in the
///       element data; the Ans letter is the key).
/// Synthetic ML Kit elements mimic the photos (page ~1300–1700 px
/// wide, text height 28). No device needed — the reconstruction is
/// pure; the parser integration test feeds the reconstructed '|' lines
/// into the existing table pass.
typedef _El = ({
  String text,
  double x,
  double y,
  double width,
  double height,
});

/// Lays one cell's words out from [x] at height [y]: each word is
/// (chars*8+6) wide with a 7 px inter-word gap — the same proportions
/// the reconstruction relies on (inter-word gaps ≪ column gutters).
List<_El> _cell(String text, double x, double y) {
  final out = <_El>[];
  var cx = x;
  for (final word in text.split(' ')) {
    final w = word.length * 8.0 + 6;
    out.add((text: word, x: cx, y: y, width: w, height: 28.0));
    cx += w + 7;
  }
  return out;
}

List<_El> _row(double y, List<(String, double)> cells) =>
    [for (final (text, x) in cells) ..._cell(text, x, y)];

/// Adjective-table columns (photo a): stem 40, options 500/650/800/
/// 950, key 1150, label 1230.
List<_El> _adjectiveElements() => [
      ..._cell('Adjective and its Types', 40, 40),
      ..._row(95, [
        ('Question', 40),
        ('A', 500),
        ('B', 650),
        ('C', 800),
        ('D', 950),
        ('Key', 1150),
        ('Type', 1230),
      ]),
      ..._row(150, [
        ('He is an ___ man.', 40),
        ('honest', 500),
        ('honesty', 650),
        ('honestly', 800),
        ('honestness', 950),
        ('A', 1150),
        ('Adjective', 1230),
      ]),
      ..._row(200, [
        ('She wore a ___ dress.', 40),
        ('beautiful', 500),
        ('beauty', 650),
        ('beautifully', 800),
        ('beautify', 950),
        ('A', 1150),
        ('Adjective', 1230),
      ]),
      ..._row(250, [
        ('The ___ soldier fought bravely.', 40),
        ('brave', 500),
        ('bravery', 650),
        ('bravely', 800),
        ('braveness', 950),
        ('A', 1150),
        ('Adjective', 1230),
      ]),
      // Row 4: the stem wraps — its tail sits on the next visual
      // row, in the stem column only.
      ..._row(300, [
        ('The teacher praised the ___ student in front of', 40),
        ('good', 500),
        ('bad', 650),
        ('honest', 800),
        ('brave', 950),
        ('C', 1150),
        ('Adjective', 1230),
      ]),
      ..._cell('the whole class.', 40, 342),
      ..._row(400, [
        ('___ sun rises in the east.', 40),
        ('A', 500),
        ('An', 650),
        ('The', 800),
        ('None of these', 950),
        ('C', 1150),
        ('Article', 1230),
      ]),
      ..._row(450, [
        ('___ apple a day keeps the doctor away.', 40),
        ('A', 500),
        ('An', 650),
        ('The', 800),
        ('None of these', 950),
        ('B', 1150),
        ('Article', 1230),
      ]),
    ];

/// Sr.#-table columns (photo b): Sr.# 40, stem 110, options 600/860/
/// 1140/1420, Ans 1660. (The stem sits at 110, not 90: "Sr.#" is
/// 38 px wide, so a stem at 90 would leave only a 12 px gutter —
/// an inter-word gap, not a column gap — and the two cells would
/// rightly merge. A real printed table gutters its columns wider.)
List<_El> _serialElements() => [
      ..._cell('Computer Most Important Questions', 40, 40),
      ..._row(95, [
        ('Sr.#', 40),
        ('Question', 110),
        ('A', 600),
        ('B', 860),
        ('C', 1140),
        ('D', 1420),
        ('Ans', 1660),
      ]),
      ..._row(150, [
        ('1', 40),
        ('Which language was used in the first computer?', 110),
        ('A. Latin', 600),
        ('B. German', 860),
        ('C. French', 1140),
        ('D. Arabic', 1420),
        ('A', 1660),
      ]),
      ..._row(200, [
        ('2', 40),
        ('Which device is used to store data?', 110),
        ('A. Monitor', 600),
        ('B. Keyboard', 860),
        ('C. Hard Disk', 1140),
        ('D. Printer', 1420),
        ('C', 1660),
      ]),
      ..._row(250, [
        ('3', 40),
        ('What does CPU stand for?', 110),
        ('A. Central Process Unit', 600),
        ('B. Central Processing Unit', 860),
        ('C. Computer Personal Unit', 1140),
        ('D. Central Program Unit', 1420),
        ('B', 1660),
      ]),
    ];

/// Interjection-table columns (photo: Q230–257, continuation page,
/// no header row): Sr.# 40, stem 110, options 620/820/1020/1220,
/// Ans 1460, label 1540. Bare options (no "A." markers), section
/// headings spanning the table, misnumbered rows in the book itself
/// (162, 164 after 251/253), stems AND options wrapping over
/// several visual lines.
List<_El> _interjectionElements() => [
      // Section heading at the top of the page (centred, x≈799).
      ..._cell('Interjection', 799, 40),
      // Row 230: stem + all four options wrap (3 visual lines).
      ..._row(95, [
        ('230', 40),
        ('Select the sentence with the correct', 110),
        ('Alas! he is dead', 620),
        ('Hurrah! we won', 820),
        ('Wow! what a', 1020),
        ('Oh! I am tired', 1220),
        ('A', 1460),
        ('Interjection', 1540),
      ]),
      ..._row(137, [
        ('interjection.', 110),
        ('indeed.', 620),
        ('the match.', 820),
        ('sight to', 1020),
        ('today.', 1220),
      ]),
      // Option C alone wraps to a third line.
      ..._cell('see.', 1020, 179),
      ..._row(230, [
        ('231', 40),
        ('Which word is an interjection?', 110),
        ('Alas', 620),
        ('Hurrah', 820),
        ('Wow', 1020),
        ('Bravo', 1220),
        ('B', 1460),
        ('Interjection', 1540),
      ]),
      // Heading placed exactly on the B-option band start (820): a
      // centred heading can land on a column start, and the
      // heading-shape guard must keep it out of option B.
      ..._cell('Parts of Speech Identification', 820, 280),
      ..._row(330, [
        ('232', 40),
        ('Identify the part of speech of \'quickly\'.', 110),
        ('Adjective', 620),
        ('Adverb', 820),
        ('Verb', 1020),
        ('Noun', 1220),
        ('B', 1460),
        ('Parts of Speech', 1540),
      ]),
      ..._cell('Gerund / Infinitives / Participle', 713, 430),
      ..._row(480, [
        ('251', 40),
        ('Choose the correct gerund.', 110),
        ('Swimming', 620),
        ('To swim', 820),
        ('Swam', 1020),
        ('Swims', 1220),
        ('A', 1460),
        ('Gerund', 1540),
      ]),
      ..._row(530, [
        ('253', 40),
        ('Choose the correct infinitive.', 110),
        ('To read', 620),
        ('Reading', 820),
        ('Read', 1020),
        ('Reads', 1220),
        ('A', 1460),
        ('Infinitive', 1540),
      ]),
      // Misnumbered in the book itself: 162, 164 after 251/253.
      ..._row(580, [
        ('162', 40),
        ('Choose the correct participle.', 110),
        ('Broken', 620),
        ('Break', 820),
        ('Breaking', 1020),
        ('Breaks', 1220),
        ('C', 1460),
        ('Past Participle', 1540),
      ]),
      ..._row(630, [
        ('164', 40),
        ('Choose the present participle.', 110),
        ('Going', 620),
        ('Gone', 820),
        ('Go', 1020),
        ('Goes', 1220),
        ('A', 1460),
        ('Gerund', 1540),
      ]),
      ..._cell('Present / Past / Perfect Tenses', 710, 680),
      ..._row(730, [
        ('240', 40),
        ('Choose the present perfect tense.', 110),
        ('Has gone', 620),
        ('Went', 820),
        ('Goes', 1020),
        ('Going', 1220),
        ('A', 1460),
        ('Tenses', 1540),
      ]),
      ..._row(780, [
        ('241', 40),
        ('Choose the past perfect tense.', 110),
        ('Had gone', 620),
        ('Has gone', 820),
        ('Went', 1020),
        ('Goes', 1220),
        ('A', 1460),
        ('Tenses', 1540),
      ]),
    ];

/// Computer-table columns, page 5 of 71 (same book as the p.1
/// photo): Sr.# 40, stem 110, options 600/860/1140/1420, Ans 1660.
/// Header row, "A."-marked options, stems wrapping 2 lines, footer
/// "Page 5 of 71" and "Scanned with CamScanner" at the bottom.
List<_El> _computerP5Elements() => [
      ..._cell('Computer Most Important Questions', 40, 40),
      ..._row(95, [
        ('Sr.#', 40),
        ('Question', 110),
        ('A', 600),
        ('B', 860),
        ('C', 1140),
        ('D', 1420),
        ('Ans', 1660),
      ]),
      ..._row(150, [
        ('67', 40),
        ('Which tab is used to change the page', 110),
        ('A. Home tab', 600),
        ('B. Page Layout', 860),
        ('C. Insert tab', 1140),
        ('D. View tab', 1420),
        ('A', 1660),
      ]),
      // Stem tail + option B tail on one continuation row.
      ..._row(192, [
        ('layout in MS Word?', 110),
        ('tab', 860),
      ]),
      ..._row(250, [
        ('68', 40),
        ('What is the shortcut key for copy in', 110),
        ('A. Ctrl+C', 600),
        ('B. Ctrl+V', 860),
        ('C. Ctrl+X', 1140),
        ('D. Ctrl+Z', 1420),
        ('A', 1660),
      ]),
      // A 1-cell stem tail ending in "?" — it looks capitalised
      // ("MS Word?") but the trailing "?" keeps it out of the
      // heading guard, so it still merges into the stem.
      ..._cell('MS Word?', 110, 292),
      ..._row(350, [
        ('69', 40),
        ('Which device is known as the brain of', 110),
        ('A. Monitor', 600),
        ('B. Keyboard', 860),
        ('C. CPU', 1140),
        ('D. Mouse', 1420),
        ('C', 1660),
      ]),
      ..._cell('the computer?', 110, 392),
      ..._cell('Page 5 of 71', 791, 450),
      // Bottom-left, on the serial band start — but it follows the
      // footer line, so no merge is open and it stays its own line.
      ..._cell('Scanned with CamScanner', 40, 490),
    ];

void main() {
  group('reconstructTableText — adjective table (photo a)', () {
    test('rows come out as one "|" line each, title kept, wrap merged',
        () {
      final text = reconstructTableText(_adjectiveElements());
      expect(text, isNotNull);
      expect(
        text,
        'Adjective and its Types\n'
        'Question | A | B | C | D | Key | Type\n'
        'He is an ___ man. | honest | honesty | honestly | honestness | A | Adjective\n'
        'She wore a ___ dress. | beautiful | beauty | beautifully | beautify | A | Adjective\n'
        'The ___ soldier fought bravely. | brave | bravery | bravely | braveness | A | Adjective\n'
        'The teacher praised the ___ student in front of the whole class. | good | bad | honest | brave | C | Adjective\n'
        '___ sun rises in the east. | A | An | The | None of these | C | Article\n'
        '___ apple a day keeps the doctor away. | A | An | The | None of these | B | Article',
      );
      // Every data row has exactly 7 cells.
      final lines = text!.split('\n');
      for (final line in lines.skip(2)) {
        expect(line.split('|').length, 7, reason: line);
      }
    });

    test('y-jitter inside a row does not split it', () {
      // One option word sits 3 px lower than its row — camera
      // perspective does this to real ML Kit boxes.
      final els = _adjectiveElements();
      final jittered = els.map((e) {
        if (e.text == 'honesty' && e.y == 150) {
          return (text: e.text, x: e.x, y: e.y + 3, width: e.width, height: e.height);
        }
        return e;
      }).toList();
      final text = reconstructTableText(jittered);
      expect(text, isNotNull);
      expect(text, contains('He is an ___ man. | honest | honesty | honestly | honestness | A | Adjective'));
    });
  });

  group('reconstructTableText — Sr.# table (photo b)', () {
    test('a row keeps all seven cells in order, Sr.# and Ans included',
        () {
      final text = reconstructTableText(_serialElements());
      expect(text, isNotNull);
      expect(
        text,
        'Computer Most Important Questions\n'
        'Sr.# | Question | A | B | C | D | Ans\n'
        '1 | Which language was used in the first computer? | A. Latin | B. German | C. French | D. Arabic | A\n'
        '2 | Which device is used to store data? | A. Monitor | B. Keyboard | C. Hard Disk | D. Printer | C\n'
        '3 | What does CPU stand for? | A. Central Process Unit | B. Central Processing Unit | C. Computer Personal Unit | D. Central Program Unit | B',
      );
      final lines = text!.split('\n');
      for (final line in lines.skip(2)) {
        final cells = line.split('|').map((c) => c.trim()).toList();
        expect(cells.length, 7, reason: line);
        expect(cells.first, matches(RegExp(r'^[0-9]+$')));
        expect(cells.last, matches(RegExp(r'^[A-D]$')));
      }
      // Explicit "A." markers stay inside their option cells —
      // they are not split off as separate cells.
      expect(text, contains('A. Latin'));
      expect(text, contains('B. Central Processing Unit'));
    });
  });

  group('reconstructTableText — not a table', () {
    test('a normal two-column prose page returns null (column path)',
        () {
      // Same words as prose lines in two columns: every visual row
      // is one cell, so no row ever reaches 5 cells.
      final els = <_El>[
        ..._cell('The quick brown fox jumps', 40, 100),
        ..._cell('A second column of text', 560, 100),
        ..._cell('over the lazy dog today', 40, 150),
        ..._cell('continues here as well', 560, 150),
        ..._cell('and runs away fast', 40, 200),
        ..._cell('with more words inside', 560, 200),
        ..._cell('one more line of prose', 40, 250),
        ..._cell('and one more over here', 560, 250),
      ];
      expect(reconstructTableText(els), isNull);
      // ...and the same page still takes the column-split path.
      final lines = [
        (text: 'A second column of text', x: 560.0, y: 100.0, width: 250.0),
        (text: 'The quick brown fox jumps', x: 40.0, y: 100.0, width: 250.0),
        (text: 'continues here as well', x: 560.0, y: 150.0, width: 250.0),
        (text: 'over the lazy dog today', x: 40.0, y: 150.0, width: 250.0),
        (text: 'with more words inside', x: 560.0, y: 200.0, width: 250.0),
        (text: 'and runs away fast', x: 40.0, y: 200.0, width: 250.0),
      ];
      expect(
        columnSplitOcrText('RAW', lines),
        'The quick brown fox jumps\n'
        'over the lazy dog today\n'
        'and runs away fast\n'
        'A second column of text\n'
        'continues here as well\n'
        'with more words inside',
      );
    });

    test('too few rows, or too few columns, returns null', () {
      // Only 1 data row: the header is a second wide row, but the
      // minimum is 3 wide rows — a header plus one row is not a
      // table, it is a fragment.
      final oneRow = [
        ..._cell('Adjective and its Types', 40, 40),
        ..._row(95, [
          ('Question', 40),
          ('A', 500),
          ('B', 650),
          ('C', 800),
          ('D', 950),
          ('Key', 1150),
          ('Type', 1230),
        ]),
        ..._row(150, [
          ('He is an ___ man.', 40),
          ('honest', 500),
          ('honesty', 650),
          ('honestly', 800),
          ('honestness', 950),
          ('A', 1150),
          ('Adjective', 1230),
        ]),
      ];
      expect(reconstructTableText(oneRow), isNull);
      // 3 rows but only 4 columns (stem + 3 options, no key, no
      // label) — below the 5-column minimum.
      final fourCols = [
        ..._row(150, [
          ('He is an ___ man.', 40),
          ('honest', 500),
          ('honesty', 650),
          ('honestly', 800),
        ]),
        ..._row(200, [
          ('She wore a ___ dress.', 40),
          ('beautiful', 500),
          ('beauty', 650),
          ('beautifully', 800),
        ]),
        ..._row(250, [
          ('The ___ soldier fought bravely.', 40),
          ('brave', 500),
          ('bravery', 650),
          ('bravely', 800),
        ]),
      ];
      expect(reconstructTableText(fourCols), isNull);
    });
  });

  group('reconstructTableText — interjection table (Q230–257)', () {
    test('wrapped rows regroup into logical rows, headings stay own lines',
        () {
      final text = reconstructTableText(_interjectionElements());
      expect(text, isNotNull);
      expect(
        text,
        'Interjection\n'
        '230 | Select the sentence with the correct interjection. | Alas! he is dead indeed. | Hurrah! we won the match. | Wow! what a sight to see. | Oh! I am tired today. | A | Interjection\n'
        '231 | Which word is an interjection? | Alas | Hurrah | Wow | Bravo | B | Interjection\n'
        'Parts of Speech Identification\n'
        '232 | Identify the part of speech of \'quickly\'. | Adjective | Adverb | Verb | Noun | B | Parts of Speech\n'
        'Gerund / Infinitives / Participle\n'
        '251 | Choose the correct gerund. | Swimming | To swim | Swam | Swims | A | Gerund\n'
        '253 | Choose the correct infinitive. | To read | Reading | Read | Reads | A | Infinitive\n'
        '162 | Choose the correct participle. | Broken | Break | Breaking | Breaks | C | Past Participle\n'
        '164 | Choose the present participle. | Going | Gone | Go | Goes | A | Gerund\n'
        'Present / Past / Perfect Tenses\n'
        '240 | Choose the present perfect tense. | Has gone | Went | Goes | Going | A | Tenses\n'
        '241 | Choose the past perfect tense. | Had gone | Has gone | Went | Goes | A | Tenses',
      );
      final lines = text!.split('\n');
      // Every data row has exactly 8 cells; headings are own lines.
      for (final line in lines) {
        if (line.startsWith(RegExp(r'\d'))) {
          expect(line.split('|').length, 8, reason: line);
        }
      }
      // The book's misnumbering (162, 164 after 251/253) does not
      // break the grouping — the rows keep their printed numbers.
      expect(lines[8], startsWith('162 |'));
      expect(lines[9], startsWith('164 |'));
      // The heading that starts on the B-option band was NOT merged
      // into row 231's option B.
      expect(lines[3], 'Parts of Speech Identification');
      expect(lines[2], isNot(contains('Parts of Speech')));
      expect(lines[2], contains('Hurrah | Wow'));
    });
  });

  group('reconstructTableText — computer table p.5 of 71 (Q67–81)', () {
    test('header kept, wraps merged, footer lines stay own lines', () {
      final text = reconstructTableText(_computerP5Elements());
      expect(text, isNotNull);
      expect(
        text,
        'Computer Most Important Questions\n'
        'Sr.# | Question | A | B | C | D | Ans\n'
        '67 | Which tab is used to change the page layout in MS Word? | A. Home tab | B. Page Layout tab | C. Insert tab | D. View tab | A\n'
        '68 | What is the shortcut key for copy in MS Word? | A. Ctrl+C | B. Ctrl+V | C. Ctrl+X | D. Ctrl+Z | A\n'
        '69 | Which device is known as the brain of the computer? | A. Monitor | B. Keyboard | C. CPU | D. Mouse | C\n'
        'Page 5 of 71\n'
        'Scanned with CamScanner',
      );
      final lines = text!.split('\n');
      for (final line in lines.skip(2).take(3)) {
        final cells = line.split('|').map((c) => c.trim()).toList();
        expect(cells.length, 7, reason: line);
        expect(cells.first, matches(RegExp(r'^[0-9]+$')));
        expect(cells.last, matches(RegExp(r'^[A-D]$')));
      }
      // The "MS Word?" tail merged into the stem (it is not a
      // standalone line) and option B's wrap stayed in option B.
      expect(lines.where((l) => l.trim() == 'MS Word?'), isEmpty);
      expect(text, contains('B. Page Layout tab'));
      expect(text, contains('copy in MS Word?'));
    });
  });
}
