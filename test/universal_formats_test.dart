import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/answer_key.dart';
import 'package:officerpath_ai/services/ai_generation.dart';
import 'package:officerpath_ai/services/book_structure.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/pdf_import_service.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';

import 'test_helpers.dart';

/// Worker 4 — universal format acceptance (v2 Rule 1: "dunia mein
/// jitni tarah ke bhi format hain, app unko accept kare").
///
/// EVERY format the parser must read, proven parser-only (no Gemini,
/// no network). Real-file tests use the 16 user files in
/// ~/workspace/user/files/ and the AUDIT_REPORT.md counts as the
/// documented expectation.
///
/// NOTE (19 Nov 2026, ~15:00 PKT): the v1.3 coordinator is STILL
/// editing lib/services/mcq_parser.dart live while this file was
/// written — several real-file counts below currently FAIL against
/// the in-progress table pass (it consumes non-table lines). Those
/// failures are the integration signal, not this file's fault: see
/// docs/universal-formats.md § gaps.
void main() {
  ParseResult parse(String text) => parseMcqs(
        text,
        sourceId: 'universal',
        sourceLabel: 'Universal formats',
      );

  group('local formats — synthetic', () {
    test('block: Q + 4 options + Answer line', () {
      const text = '''
Q1. What is the capital of Pakistan?
A) Lahore
B) Karachi
C) Islamabad
D) Quetta
Answer: C

Q2. Which is the largest ocean?
A) Atlantic
B) Pacific
C) Indian
D) Arctic
Answer: B
''';
      final r = parse(text);
      expect(r.parsed, 2);
      expect(r.formatCounts['block'], 2);
      expect(r.questions[0].correctIndex, 2);
      expect(r.questions[1].correctIndex, 1);
      expect(r.answerSources['answer-line'], 2);
    });

    test('one-liner: question + (a)–(d) on one line', () {
      const text = '''
1. What is the capital of France? (a) London (b) Paris (c) Rome (d) Berlin Ans: (b)
2. Which planet is the Red Planet? (a) Venus (b) Jupiter (c) Mars (d) Saturn Ans: (c)
''';
      final r = parse(text);
      expect(r.parsed, 2);
      expect(r.formatCounts['one-liner'], 2);
      expect(r.questions[0].correctIndex, 1);
      expect(r.questions[1].correctIndex, 2);
    });

    test('Q-only: options built from the book\'s own answer pool', () {
      const text = '''
Q1. What is the capital of Pakistan?
Ans: Islamabad
Q2. What is the capital of France?
Ans: Paris
Q3. What is the capital of Japan?
Ans: Tokyo
Q4. What is the capital of Italy?
Ans: Rome
Q5. What is the capital of Canada?
Ans: Ottawa
''';
      final r = parse(text);
      expect(r.parsed, 5);
      expect(r.formatCounts['q-only'], 5);
      // Distractors come from the book's own answers — never invented.
      final pool = {'Islamabad', 'Paris', 'Tokyo', 'Rome', 'Ottawa'};
      for (final q in r.questions) {
        expect(q.options.toSet().difference(pool), isEmpty);
        expect(q.options.length, 4);
      }
      expect(r.questions[0].options, contains('Islamabad'));
      expect(r.questions[0].correctIndex,
          r.questions[0].options.indexOf('Islamabad'));
    });

    test('flashcard dash-inline: "Q? — answer" on one line', () {
      // Numbered items ("1. ") — the flashcard scan requires them.
      const text = '''
1. Who won the 2026 Nobel Peace Prize? — Navanethem 'Navi' Pillay
2. Who is the largest ocean? — Pacific
3. Which country hosted the 2026 World Cup? — USA, Canada and Mexico
4. What is the capital of Australia? — Canberra
5. Who wrote the national anthem? — Hafeez Jalandhari
''';
      final r = parse(text);
      expect(r.parsed, 5);
      expect(r.formatCounts['q-only'], 5);
      expect(r.questions[0].options, contains("Navanethem 'Navi' Pillay"));
      expect(r.answerSources['flashcard'], 5);
    });

    test('flashcard answer-on-next-line: "Q?" then the answer', () {
      const text = '''
1. Who won the 2026 Nobel Peace Prize?
Navanethem 'Navi' Pillay (South Africa)
2. What is the largest desert in the world?
Sahara Desert
3. Who is the current UN Secretary-General?
Antonio Guterres
4. Which river is the longest in Asia?
Yangtze River
5. What is the capital of Canada?
Ottawa
''';
      final r = parse(text);
      expect(r.parsed, 5);
      expect(r.formatCounts['q-only'], 5);
      expect(r.answerSources['flashcard'], 5);
    });

    test('flashcard "?" trailing answer: "Q? answer" on one line', () {
      const text = '''
1. What is the capital of France? Paris
2. Which is the largest ocean? Pacific
3. Who is the founder of Pakistan? Quaid-e-Azam
4. What is the currency of Japan? Yen
5. Which planet is known as the Red Planet? Mars
''';
      final r = parse(text);
      expect(r.parsed, 5);
      expect(r.formatCounts['q-only'], 5);
      expect(r.questions[0].options, contains('Paris'));
    });

    test('tick-marked correct option (✓ stripped, answer = tick)', () {
      const text = '''
Q1. Which is the largest ocean?
A) Atlantic
B) Pacific ✓
C) Indian
D) Arctic
''';
      final r = parse(text);
      expect(r.parsed, 1);
      expect(r.questions.first.correctIndex, 1);
      expect(r.questions.first.answerSource, 'tick');
      expect(r.questions.first.options[1], 'Pacific');
    });

    test('per-paper key join: Paper 1 key never answers Paper 2', () {
      const text = '''
Paper 1
Q1. What is the capital of Pakistan?
A) Lahore
B) Karachi
C) Islamabad
D) Quetta
Q2. Which is the largest ocean?
A) Atlantic
B) Pacific
C) Indian
D) Arctic
Answer Key (Paper 1)
1. C
2. B
Paper 2
Q1. What is the capital of France?
A) London
B) Paris
C) Rome
D) Berlin
Q2. Which planet is the Red Planet?
A) Venus
B) Jupiter
C) Mars
D) Saturn
Answer Key (Paper 2)
1. B
2. C
''';
      final r = parse(text);
      expect(r.parsed, 4);
      expect(r.keyEntriesApplied, 4);
      expect(r.questionsMissingAnswers, isEmpty);
      expect(r.questions[0].correctIndex, 2);
      expect(r.questions[1].correctIndex, 1);
      expect(r.questions[2].correctIndex, 1);
      expect(r.questions[3].correctIndex, 2);
    });
  });

  group('table format — synthetic', () {
    test('table row-wise: 3 rows, standalone key letters, type labels',
        () {
      const text = '''
What is the capital of France?
London
Paris
Berlin
Madrid
B
Geography
Which is the largest ocean?
Atlantic
Pacific
Indian
Arctic
B
Geography
Which planet is known as the Red Planet?
Venus
Jupiter
Mars
Saturn
C
Science
''';
      final r = parse(text);
      expect(r.formatCounts['table'], 3);
      expect(r.parsed, 3);
      expect(r.answerSources['key'], 3);
      expect(r.questions[0].correctIndex, 1);
      // Type labels are structure — never an option or a question.
      for (final q in r.questions) {
        expect(q.options, isNot(contains('Geography')));
        expect(q.options, isNot(contains('Maths')));
        expect(q.text, isNot(contains('Geography')));
      }
      expect(
        r.questions.any((q) => q.text == 'Geography'),
        isFalse,
      );
    });

    test('GAP: table options that are bare numbers are eaten by the '
        'segmenter — currently 0', () {
      // KNOWN GAP for integration (lib/services/answer_key.dart,
      // isNoiseLine, lines 281-282): a bare-digit line ("3", "4") is
      // dropped as watermark/page-number noise before the table pass
      // ever sees it — so a row whose options are numbers ("What is
      // 2 + 2?" → 3/4/5/6) loses its options. Word options work.
      const text = '''
What is the capital of France?
London
Paris
Berlin
Madrid
B
Geography
Which is the largest ocean?
Atlantic
Pacific
Indian
Arctic
B
Geography
What is 2 + 2?
3
4
5
6
B
Maths
''';
      final r = parse(text);
      expect(r.formatCounts['table'], 3);
      expect(r.parsed, 3);
    });

    test('table column-wise: 5 rows in OCR order (questions, A, B, C, D, keys)',
        () {
      const text = '''
What is the capital of France?
Which is the largest ocean?
Which planet is the Red Planet?
What is the capital of Japan?
Which is the largest desert?
London
Atlantic
Venus
Tokyo
Sahara
Paris
Pacific
Jupiter
Kyoto
Gobi
Berlin
Indian
Mars
Osaka
Kalahari
Madrid
Arctic
Saturn
Nagoya
Thar
B
B
C
A
A
Geography
Geography
Science
Geography
Geography
''';
      final r = parse(text);
      expect(r.formatCounts['table'], 5);
      expect(r.parsed, 5);
      expect(r.questions[0].options, ['London', 'Paris', 'Berlin', 'Madrid']);
      expect(r.questions[0].correctIndex, 1);
      expect(r.questions[2].correctIndex, 2);
      expect(r.questions[4].correctIndex, 0);
      for (final q in r.questions) {
        expect(q.options, isNot(contains('Geography')));
      }
    });

    test('table with type labels: label never becomes an option', () {
      // Grammar-table shape: question + 4 bare options + key + type.
      const text = '''
An adjective modifies a
Noun
Verb
Adverb
Preposition
A
Adjective
Choose the correct article: ___ apple.
A
An
The
None of these
B
Article
Fill in the blank: She is ___ honest lady.
a
an
the
none
B
Article
''';
      final r = parse(text);
      expect(r.formatCounts['table'], 3);
      for (final q in r.questions) {
        expect(q.options, isNot(contains('Adjective')));
        expect(q.options, isNot(contains('Article')));
      }
      expect(r.questions[0].correctIndex, 0);
      expect(r.questions[1].correctIndex, 1);
    });

    test('table 5-option row normalises to 4; key on E keeps E', () {
      const text = '''
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
      final r = parse(text);
      expect(r.formatCounts['table'], 3);
      expect(r.fiveOptionNormalised, 3);
      expect(r.fiveOptionAnswerE, 1);
      expect(r.questions.first.options,
          ['Pacific', 'Atlantic', 'Indian', 'None of these']);
      expect(r.questions.first.correctIndex, 3);
    });

    test('table rows without a key become answer-pending, not dropped',
        () {
      const text = '''
What is the capital of France?
London
Paris
Berlin
Madrid
Geography
Which planet is known as the Red Planet?
Venus
Jupiter
Mars
Saturn
Science
What is H2O?
Water
Salt
Oxygen
Hydrogen
Science
''';
      final r = parse(text);
      expect(r.answerPending.length, 3);
      expect(r.answerPending.first.options,
          ['London', 'Paris', 'Berlin', 'Madrid']);
    });

    test('multi-column key table: "?" entries excluded, never guessed',
        () {
      const blob =
          '1. D 58. B 73. A 88. B 2. D 59. C 74. C 89. D '
          '3. ? 60. B 75. B 90. A 46. B 61. B 76. A 91. D '
          '106. ? 127. A 148. C 184. B';
      final entries = parseKeyEntries(blob);
      expect(entries.length, 20);
      expect(entries[3], '?');
      expect(entries[106], '?');
      expect(isUnknownKeyToken('?'), isTrue);
      expect(isUnknownKeyToken('D'), isFalse);
    });
  });

  group('paste fixtures — local parse first (no AI)', () {
    test('Urdu Prophet facts: local parse finds 0 MCQs, 16 facts', () {
      const urduText = '''PROPHET MUHAMMAD ﷺ
— رسول اللہ ﷺ کے اونٹنی کا نام قصواء تھا۔
— رسول اللہ ﷺ کے خچر کا نام دُلدُل تھا۔
— رسول اللہ ﷺ کے گدھے کا نام یعفور تھا۔
— رسول اللہ ﷺ کے تلواروں میں سب سے مشہور ذوالفقار تھی۔
— رسول اللہ ﷺ کے موزوں کا رنگ سیاہ تھا۔
— رسول اللہ ﷺ کی انگوٹھی پر کندہ تھا: محمد رسول اللہ''';
      final r = parse(urduText);
      // No MCQs locally → AI generation is the (asked-for) last resort.
      expect(r.parsed, 0);
      final pool = extractFactPool(urduText);
      expect(pool.length, 6);
      expect(pool.any((f) => f.label.contains('قصواء')), isTrue);
    });

    test('Largest/Longest list: local parse finds 0 MCQs, 33 facts', () {
      const largestText = '''Largest Ocean: Pacific
Largest Desert(hot): Sahara
Largest Country by area: Russia
Largest Democracy: India
Largest Island: Greenland
Longest Wall: Great Wall of China''';
      final r = parse(largestText);
      expect(r.parsed, 0);
      expect(extractFactPool(largestText).length, 6);
    });

    test('pasted real MCQs parse locally — never sent to AI', () {
      const text = '''
Q1. What is the capital of Pakistan?
A) Lahore
B) Karachi
C) Islamabad
D) Quetta
Answer: C
Q2. Which is the largest ocean?
A) Atlantic
B) Pacific
C) Indian
D) Arctic
Answer: B
''';
      final maps = parseTextInBackground({
        'text': text,
        'sourceId': 'paste',
        'sourceLabel': 'Pasted MCQs',
      });
      expect(maps['parsed'], 2);
    });
  });

  group('docx + image upload paths (mocked OCR, no network)', () {
    test('docx with MCQ paragraphs parses through importDocx', () async {
      final bytes = buildDocx([
        para('Q1. What is the capital of Pakistan?'),
        para('A) Lahore'),
        para('B) Karachi'),
        para('C) Islamabad'),
        para('D) Quetta'),
        para('Answer: C'),
        para('Q2. Which is the largest ocean?'),
        para('A) Atlantic'),
        para('B) Pacific'),
        para('C) Indian'),
        para('D) Arctic'),
        para('Answer: B'),
      ]);
      final result = await PdfImportService.importDocx(
        bytes,
        sourceId: 'docx-1',
        sourceLabel: 'Word bank',
        onProgress: (_) {},
        isCancelled: () => false,
      );
      expect(result.parsed, 2);
      expect(result.ocrPages, isEmpty);
      expect(result.questions.first.correctIndex, 2);
    });

    test('JPG/PNG upload routes through OCR then the parser', () async {
      final result = await PdfImportService.importImage(
        Uint8List.fromList([0xFF, 0xD8, 0xFF]),
        sourceId: 'img-1',
        sourceLabel: 'Page photo',
        onProgress: (_) {},
        isCancelled: () => false,
        runOcr: (jpegBytes) async =>
            'Q1. What is the capital of Pakistan?\n'
            'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\nAnswer: C\n',
      );
      expect(result.pageCount, 1);
      expect(result.ocrPages, [1]);
      expect(result.parsed, 1);
      expect(result.questions.first.correctIndex, 2);
    });
  });

  group('real files — documented counts (AUDIT_REPORT.md)', () {
    test('F1 PPSC 40 MCQs: 40/40', () async {
      final file = File(
        '/home/hatch/workspace/user/files/PPSC_Current_Affairs_40_MCQs.pdf',
      );
      if (skipIfFixtureMissing(file.path)) return;
      final bytes = await file.readAsBytes();
      final maps = processPdfInBackground({
        'bytes': bytes,
        'sourceId': 'real-f1',
        'sourceLabel': 'PPSC 40',
      });
      expect(maps['parsed'], 40);
      expect(maps['skipped'], 0);
    });

    test('F2 June 2025: 0 parsed, 28 answer-pending for AI inference',
        () async {
      final file = File(
        '/home/hatch/workspace/user/files/Current-Affairs-June-2025-in-PDF__1.pdf',
      );
      if (skipIfFixtureMissing(file.path)) return;
      final bytes = await file.readAsBytes();
      final maps = processPdfInBackground({
        'bytes': bytes,
        'sourceId': 'real-f2',
        'sourceLabel': 'June 2025',
      });
      expect(maps['parsed'], 0);
      // 20 Nov 2026 (was 25): the U+E000 fix in _splitQuestionAndRest
      // recovered the 10 two-line '?' stems whose questionText had
      // "Mcqsplanet.com" appended (the raw tail ends "?<U+E000>", so
      // the raw endsWith('?') test failed and the junk line was
      // swallowed into the stem, failing the pending gate); the
      // numberless split recovered 3 more. 28 = all 30 items minus
      // the 2 with no '?' stem (Sindh "is:", crypto) — verified by
      // reading the 28 pending texts (full stems, 2 known fragments).
      expect((maps['answerPending'] as List).length, 28);
    });

    test('F3 Pak Affairs prose: 186 MCQs (159 flashcard + 27 table)',
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
      // v1.2 audit said 162 (q-only only). v1.3 (measured 19 Nov 2026)
      // finds 19 more bold-resolved table rows on top: 162 + 19.
      // 20 Nov 2026 (was 181 = 162 + 19): the table fixes (Sr.#/Ans
      // headers, "A." marker strip, in-table heading/label handling)
      // recover 8 more real table rows (27), and 3 q-only items move
      // to the table pass — 159 + 27 = 186. Verified by reading the
      // 27 table rows (real book content; repeats are the book's own
      // repeated sections, counted the same way as the old 181).
      expect(maps['parsed'], 186);
      expect(maps['formats']['q-only'], 159);
      expect(maps['formats']['table'], 27);
    });

    test('F6 Pace two-column: 1442 parsed', () async {
      final file = File(
        '/home/hatch/workspace/user/files/Current_Affairs_Jan-Nov_2026_by_Pace_GK_Academy.pdf',
      );
      if (skipIfFixtureMissing(file.path)) return;
      final bytes = await file.readAsBytes();
      final maps = processPdfInBackground({
        'bytes': bytes,
        'sourceId': 'real-f6',
        'sourceLabel': 'Pace',
      });
      expect(maps['parsed'], 1442);
      // Two-column proof: Q.1/Q.2 interleave is resolved — a question
      // with option Japan (left column) and one with Australia exist.
      final pages = extractPdfPages(bytes);
      final r = parseMcqsFromPages(
        [for (final p in pages) PageText(p.page, p.text)],
        sourceId: 'real-f6',
        sourceLabel: 'Pace',
      );
      expect(r.questions.any((q) => q.options.contains('Japan')), isTrue);
    });

    test('F8 Sir Tauqeer flashcard book: 284 MCQs, 9 month parts',
        () async {
      final file = File(
        '/home/hatch/workspace/user/files/Current_Affairs_Year_2026_Complete__October-January__Sir_Tauqeer_0_sw7h.pdf',
      );
      if (skipIfFixtureMissing(file.path)) return;
      final bytes = await file.readAsBytes();
      final maps = processPdfInBackground({
        'bytes': bytes,
        'sourceId': 'real-f8',
        'sourceLabel': 'Sir Tauqeer',
      });
      // 284, not 277: cross-page stitching (19 Nov 2026)
      // finds 7 more flashcards whose answer is on the next page.
      expect(maps['parsed'], 284);
      expect((maps['parts'] as List).length, 9);
    });

    test('MPT: 143 parsed, "?" questions excluded', () async {
      final file = File(
        '/home/hatch/workspace/user/files/MPT-CSS-2027-Solved.pdf',
      );
      if (skipIfFixtureMissing(file.path)) return;
      final bytes = await file.readAsBytes();
      final maps = processPdfInBackground({
        'bytes': bytes,
        'sourceId': 'real-mpt',
        'sourceLabel': 'MPT',
      });
      // 20 Nov 2026 (was 142): the unfinished-question fix heals
      // ~45 fragment stems into full stems (a long numbered stem
      // >70 chars was judged "not a question", so its '?' tail split
      // it away from its head — MPT Q116/Q177). 143 = 140 block (all
      // with full stems + key answers; Q3/Q106 excluded by the book's
      // own defect notes, Q198 lost to column interleave in the PDF
      // text layer) + 3 loose-format q-only items (title / warning /
      // header lines — same loose q-only behaviour as F3's headings,
      // unverified). Skipped is back to 3 (was 48 mid-fix when the
      // splits fragmented blocks into separate skipped halves).
      expect(maps['parsed'], 143);
      expect(maps['skipped'], 3);
      final pages = extractPdfPages(bytes);
      final r = parseMcqsFromPages(
        [for (final p in pages) PageText(p.page, p.text)],
        sourceId: 'real-mpt',
        sourceLabel: 'MPT',
      );
      expect(
        r.questions.any((q) => q.text.contains('positive multiples')),
        isFalse,
        reason: 'MPT Q106 (key "?") must be excluded, never guessed',
      );
    });

    test('US History: 515 parsed (q-only flashcard, year parts)',
        () async {
      final file = File(
        '/home/hatch/workspace/user/files/US_History_solved_MCQs_by_SAK.pdf',
      );
      if (skipIfFixtureMissing(file.path)) return;
      final bytes = await file.readAsBytes();
      final maps = processPdfInBackground({
        'bytes': bytes,
        'sourceId': 'real-us',
        'sourceLabel': 'US History',
      });
      expect(maps['parsed'], 515);
      expect(maps['formats']['q-only'], 515);
    });

    test('Sir Rizwan GSA: 467 parsed (q-only 465 + one-liner 2)',
        () async {
      final file = File(
        '/home/hatch/workspace/user/files/Sir_Rizwan_GSA.pdf',
      );
      if (skipIfFixtureMissing(file.path)) return;
      final bytes = await file.readAsBytes();
      final maps = processPdfInBackground({
        'bytes': bytes,
        'sourceId': 'real-riz',
        'sourceLabel': 'Sir Rizwan GSA',
      });
      // Phase A (19 Nov 2026): 328 → 467. The G6 walkForward fix
      // (break on ANY '?' in the line) recovered the "➢" bullet
      // section — the old code swallowed each next flashcard as an
      // answer continuation, so those questions never even counted
      // as skipped (skipped stays 157). Measured breakdown: 295/376
      // "➢" bullet questions + 172/289 numbered-section questions
      // parse (ground truth 289 "N. " lines + 376 "➢" lines = 665
      // candidates; 467 = 70%). Spot-checked real with book-correct
      // answers (Photosphere, Neil Armstrong, Laika, Sputnik I).
      expect(maps['parsed'], 467);
    });

    test('Examveda 546pp: 3212 parsed, 1688 skipped', () async {
      final file = File(
        '/home/hatch/workspace/user/files/Examveda_GK_Comp_Eng_Sir_Waleed_0300_1111938.pdf',
      );
      if (skipIfFixtureMissing(file.path)) return;
      final bytes = await file.readAsBytes();
      final maps = processPdfInBackground({
        'bytes': bytes,
        'sourceId': 'real-exam',
        'sourceLabel': 'Examveda',
      });
      // v1.2 audit said 3180/1704; v1.3 (measured 19 Nov 2026,
      // parser md5 236e9602…) parses 3 more. The count flipped
      // 3183↔3184 between coordinator edits on 19 Nov (the asterisk
      // question landing / a fragment-guard removal); 3183 is the
      // value at the final measured md5 — re-measure if the parser
      // changes again.
      // Phase A (19 Nov 2026): 3183/1710 → 3202/1689. The
      // _splitOptionLine word-boundary fix (abbreviations like
      // "Sec." no longer split options) + the G7 2-row table
      // recovered 19 previously-skipped REAL questions (formats
      // block 3160→3177, q-only 7→8, table 16→17). Two verified
      // book-correct: "The Mistral is" → D ("All", book's own
      // "Answer: Option D"), "20th August is celebrated as" → B
      // (Sadbhavana Divas, book's "Answer: Option B").
      // 20 Nov 2026 (was 3202/1689): the numberless split + U+E000
      // fix + E-option guard + unfinished-question fix recover 10
      // more real questions (block 3177→3180, q-only 8→11, table
      // 17→21; the 6 flashcard items are unchanged in kind). The
      // E-option guard matters: without it the split cut 5-option
      // questions apart after D and the orphaned "E. …" line became
      // a fake q-only question (15+ fabrications, since removed).
      expect(maps['parsed'], 3212);
      expect(maps['skipped'], 1688);
    });

    test('organisation file: 0 MCQs, 180 facts (generation-only)',
        () async {
      final file = File(
        '/home/hatch/workspace/user/files/organization_Sir_Waleed_0300_1111938.pdf',
      );
      if (skipIfFixtureMissing(file.path)) return;
      final bytes = await file.readAsBytes();
      final maps = processPdfInBackground({
        'bytes': bytes,
        'sourceId': 'real-org',
        'sourceLabel': 'Organisation',
      });
      expect(maps['parsed'], 0);
      expect((maps['facts'] as List).length, 180);
    });

    test('junior_clerk admission letter: 0 MCQs, 1 answer-pending',
        () async {
      final file = File(
        '/home/hatch/workspace/user/files/junior_clerk.pdf',
      );
      if (skipIfFixtureMissing(file.path)) return;
      final bytes = await file.readAsBytes();
      final maps = processPdfInBackground({
        'bytes': bytes,
        'sourceId': 'real-letter',
        'sourceLabel': 'Admission letter',
      });
      expect(maps['parsed'], 0);
      expect((maps['answerPending'] as List).length, 1);
    });

    test('Ayesha Jalal: corrupt — fail fast, never parsed', () async {
      final file = File(
        '/home/hatch/workspace/user/files/Ayesha_Jalal_-_The_Struggle_for_Pakistan__A_Muslim_Homeland_and_Global_Politics__2014__Belknap_Press.pdf',
      );
      if (skipIfFixtureMissing(file.path)) return;
      final bytes = await file.readAsBytes();
      expect(detectPdfCorruption(bytes), isNotNull);
      expect(
        () => processPdfInBackground({
          'bytes': bytes,
          'sourceId': 'real-f4',
          'sourceLabel': 'Ayesha Jalal',
        }),
        throwsA(isA<CorruptPdfException>()),
      );
    });

    test('scanned books (112/109/110): text layer parses 0 — OCR needed',
        () async {
      for (final name in [
        '112_Edition.pdf',
        '109_edition_by_abbaSi.pdf',
        'PPSC_110_Edition__1_p7sh.pdf',
      ]) {
        final file = File(
          '/home/hatch/workspace/user/files/$name',
        );
        if (skipIfFixtureMissing(file.path)) return;
        final bytes = await file.readAsBytes();
        expect(detectPdfCorruption(bytes), isNull);
        final maps = processPdfInBackground({
          'bytes': bytes,
          'sourceId': 'real-scan',
          'sourceLabel': name,
        });
        expect(maps['parsed'], 0,
            reason: '$name has no text layer — OCR (phone) required');
      }
    });

    test('IDIOMS glossary: parses without crashing (count recorded)',
        () async {
      final file = File(
        '/home/hatch/workspace/user/files/IDIOMS_COMPILED_BY_Raj_Roy_Soni.pdf',
      );
      if (skipIfFixtureMissing(file.path)) return;
      final bytes = await file.readAsBytes();
      final maps = processPdfInBackground({
        'bytes': bytes,
        'sourceId': 'real-idioms',
        'sourceLabel': 'Idioms',
      });
      // No documented count exists for this file (AUDIT_REPORT.md:
      // "Not run in v1.2 automated tests"). v1.3 (measured 19 Nov
      // 2026) parses 1067 q-only flashcards ("idiom — meaning" lines
      // are dash-inline flashcards) — a human must confirm the rows
      // are real idioms, not glossary lines misread (see docs).
      // ignore: avoid_print
      print('IDIOMS parsed=${maps['parsed']} '
          'formats=${maps['formats']}');
      expect(maps['parsed'], greaterThan(0));
    });
  });
}

/// Minimal .docx builder (same shape as test/docx_test.dart's
/// [buildDocx] — duplicated because test files cannot import each
/// other). [paragraphs] is a list of paragraphs; each paragraph is a
/// list of (text, bold) runs.
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
      '<Relationships xmlns="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
      '</Relationships>';
  final document =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>$body</w:body></w:document>';
  final archive = Archive();
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
