import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/answer_key.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

const _src = 'test-src';
const _label = 'Test Book';

void main() {
  test('key entry shapes: "1. C", "1-C", "1) C", "1: C", "Q1: C"', () {
    const text = 'Q1. Capital of Pakistan?\n'
        'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n'
        'Q2. Capital of France?\n'
        'A) London\nB) Paris\nC) Rome\nD) Berlin\n'
        'Q3. Capital of Italy?\n'
        'A) Madrid\nB) Rome\nC) Paris\nD) Athens\n'
        'Q4. Capital of Japan?\n'
        'A) Seoul\nB) Beijing\nC) Bangkok\nD) Tokyo\n'
        'Q5. Capital of Australia?\n'
        'A) Sydney\nB) Canberra\nC) Melbourne\nD) Perth\n'
        'ANSWER KEY\n'
        '1. C\n'
        '2-C\n'
        '3) B\n'
        '4: D\n'
        'Q5: B\n';
    final r = parseMcqs(text, sourceId: _src, sourceLabel: _label);
    expect(r.parsed, 5);
    expect(r.skipped, 0);
    expect(r.keySectionsFound, 1);
    expect(r.keyEntriesApplied, 5);
    expect(r.questionsMissingAnswers, isEmpty);
    expect(r.formatCounts['block'], 5);
    expect(
      r.questions.map((q) => q.correctIndex).toList(),
      [2, 2, 1, 3, 1],
    );
  });

  test('two papers: each key answers only its own paper', () {
    const text = 'Paper 1\n'
        'Q1. Capital of Pakistan?\n'
        'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n'
        'Q2. Capital of France?\n'
        'A) London\nB) Paris\nC) Rome\nD) Berlin\n'
        'Paper 1 Answer Key\n'
        '1. C\n'
        'Paper 2\n'
        'Q1. Capital of Italy?\n'
        'A) Madrid\nB) Rome\nC) Paris\nD) Athens\n'
        'Q2. Capital of Japan?\n'
        'A) Seoul\nB) Beijing\nC) Bangkok\nD) Tokyo\n'
        'Paper 2 Answer Key\n'
        '1. B\n'
        '2. D\n';
    final r = parseMcqs(text, sourceId: _src, sourceLabel: _label);
    // Paper 1 Q2 has NO entry in Paper 1's key — Paper 2's "2. D" must
    // NOT leak across to it.
    expect(r.parsed, 3);
    expect(r.skipped, 1);
    expect(r.keySectionsFound, 2);
    expect(r.keyEntriesApplied, 3);
    expect(
      r.questionsMissingAnswers,
      ['Paper 1 Q2 — no key entry'],
    );
    final p1q1 = r.questions.firstWhere(
      (q) => q.text.contains('Pakistan'),
    );
    expect(p1q1.correctIndex, 2);
    final p2q1 = r.questions.firstWhere((q) => q.text.contains('Italy'));
    expect(p2q1.correctIndex, 1);
    final p2q2 = r.questions.firstWhere((q) => q.text.contains('Japan'));
    expect(p2q2.correctIndex, 3);
  });

  test('compact single-line key: "1.C 2.A 3.B …"', () {
    const text = 'Q1. Capital of Pakistan?\n'
        'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n'
        'Q2. Capital of France?\n'
        'A) London\nB) Paris\nC) Rome\nD) Berlin\n'
        'Q3. Capital of Italy?\n'
        'A) Madrid\nB) Rome\nC) Paris\nD) Athens\n'
        'ANSWER KEY\n'
        '1.C 2.A 3.B\n';
    final r = parseMcqs(text, sourceId: _src, sourceLabel: _label);
    expect(r.parsed, 3);
    expect(r.keyEntriesApplied, 3);
    expect(
      r.questions.map((q) => q.correctIndex).toList(),
      [2, 0, 1],
    );
  });

  test('multi-column key: entries out of reading order still join', () {
    const text = 'Q1. Capital of Pakistan?\n'
        'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n'
        'Q2. Capital of France?\n'
        'A) London\nB) Paris\nC) Rome\nD) Berlin\n'
        'Q3. Capital of Italy?\n'
        'A) Madrid\nB) Rome\nC) Paris\nD) Athens\n'
        'Q4. Capital of Japan?\n'
        'A) Seoul\nB) Beijing\nC) Bangkok\nD) Tokyo\n'
        'ANSWER KEY\n'
        '1. C   3. B\n'
        '2. B   4. D\n';
    final r = parseMcqs(text, sourceId: _src, sourceLabel: _label);
    expect(r.parsed, 4);
    expect(
      r.questions.map((q) => q.correctIndex).toList(),
      [2, 1, 1, 3],
    );
  });

  test('text answers in the key match the question options', () {
    const text = 'Q1. Who is the President of Pakistan?\n'
        'A) Asif Ali Zardari\nB) Mamnoon Hussain\nC) Arif Alvi\nD) Pervez Musharraf\n'
        'Q2. Who wrote the national anthem?\n'
        'A) Allama Iqbal\nB) Hafeez Jalandhari\nC) Faiz Ahmed Faiz\nD) Ahmed Faraz\n'
        'Q3. Capital of Pakistan?\n'
        'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n'
        'ANSWER KEY\n'
        '1. Asif Ali Zardari\n'
        '2. B) Hafeez Jalandhari\n'
        '3. Islamabad\n';
    final r = parseMcqs(text, sourceId: _src, sourceLabel: _label);
    expect(r.parsed, 3);
    expect(r.keyEntriesApplied, 3);
    expect(
      r.questions.map((q) => q.correctIndex).toList(),
      [0, 1, 2],
    );
  });

  test('key with missing numbers: partial application + missing list', () {
    const text = 'Q1. Capital of Pakistan?\n'
        'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n'
        'Q2. Capital of France?\n'
        'A) London\nB) Paris\nC) Rome\nD) Berlin\n'
        'Q3. Capital of Italy?\n'
        'A) Madrid\nB) Rome\nC) Paris\nD) Athens\n'
        'ANSWER KEY\n'
        '1. C\n'
        '3. B\n';
    final r = parseMcqs(text, sourceId: _src, sourceLabel: _label);
    expect(r.parsed, 2);
    expect(r.skipped, 1);
    expect(r.keyEntriesApplied, 2);
    expect(
      r.questionsMissingAnswers,
      ['Paper 1 Q2 — no key entry'],
    );
  });

  test('a key section is never parsed as questions', () {
    const text = 'Q1. Capital of Pakistan?\n'
        'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n'
        'ANSWER KEY\n'
        '1. C\n'
        '2. A\n'
        '3. B\n';
    final r = parseMcqs(text, sourceId: _src, sourceLabel: _label);
    expect(r.parsed, 1);
    expect(r.skipped, 0);
    // Key entries 2 and 3 match no question: ignored, no crash, no
    // phantom questions.
    expect(r.questions.first.text, contains('Pakistan'));
  });

  test('key heading variants: Answers, Test 1 Key, Answers – Paper 1, '
      'Set A Key', () {
    // "Answers" (bare) + "Test 1 Key".
    const textA = 'Test 1\n'
        'Q1. Capital of Pakistan?\n'
        'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n'
        'Test 1 Key\n'
        '1. C\n';
    final ra = parseMcqs(textA, sourceId: _src, sourceLabel: _label);
    expect(ra.parsed, 1);
    expect(ra.keySectionsFound, 1);
    expect(ra.questions.first.correctIndex, 2);

    // "Answers – Paper 1" (paper ref after the key word).
    const textB = 'Q1. Capital of France?\n'
        'A) London\nB) Paris\nC) Rome\nD) Berlin\n'
        'Answers – Paper 1\n'
        '1. B\n';
    final rb = parseMcqs(textB, sourceId: _src, sourceLabel: _label);
    expect(rb.parsed, 1);
    expect(rb.keySectionsFound, 1);
    expect(rb.questions.first.correctIndex, 1);

    // "Set A Key" with a "Set A" paper heading.
    const textC = 'Set A\n'
        'Q1. Capital of Italy?\n'
        'A) Madrid\nB) Rome\nC) Paris\nD) Athens\n'
        'Set A Key\n'
        '1. B\n';
    final rc = parseMcqs(textC, sourceId: _src, sourceLabel: _label);
    expect(rc.parsed, 1);
    expect(rc.keySectionsFound, 1);
    expect(rc.questions.first.correctIndex, 1);
  });

  test('one-liner questions can also be answered from the key', () {
    const text =
        '1. Capital of Pakistan? (a) Lahore (b) Karachi (c) Islamabad (d) Quetta\n'
        '2. Capital of France? (a) London (b) Paris (c) Rome (d) Berlin\n'
        'ANSWER KEY\n'
        '1. C  2. B\n';
    final r = parseMcqs(text, sourceId: _src, sourceLabel: _label);
    expect(r.parsed, 2);
    expect(r.formatCounts['one-liner'], 2);
    expect(r.keyEntriesApplied, 2);
    expect(
      r.questions.map((q) => q.correctIndex).toList(),
      [2, 1],
    );
  });

  test('inline answer wins: the key never overrides it', () {
    const text = 'Q1. Capital of Pakistan?\n'
        'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n'
        'Answer: B\n'
        'ANSWER KEY\n'
        '1. C\n';
    final r = parseMcqs(text, sourceId: _src, sourceLabel: _label);
    expect(r.parsed, 1);
    expect(r.keyEntriesApplied, 0);
    expect(r.questions.first.correctIndex, 1);
  });

  test('key entry that matches no option is reported, not guessed', () {
    const text = 'Q1. Capital of Pakistan?\n'
        'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n'
        'ANSWER KEY\n'
        '1. Sydney\n';
    final r = parseMcqs(text, sourceId: _src, sourceLabel: _label);
    expect(r.parsed, 0);
    expect(r.skipped, 1);
    expect(r.keyEntriesApplied, 0);
    expect(
      r.questionsMissingAnswers,
      ['Paper 1 Q1 — key entry "Sydney" matches no option'],
    );
  });

  test('Urdu MCQs with English markers (regression) + Urdu via key', () {
    const urduInline = 'Q1. پاکستان کا دارالحکومت کون سا ہے؟\n'
        'A) لاہور\nB) کراچی\nC) اسلام آباد\nD) کوئٹہ\n'
        'Answer: C\n';
    final r1 = parseMcqs(urduInline, sourceId: _src, sourceLabel: 'Urdu');
    expect(r1.parsed, 1);
    expect(r1.questions.first.correctIndex, 2);

    const urduKey = 'Q1. پاکستان کا دارالحکومت کون سا ہے؟\n'
        'A) لاہور\nB) کراچی\nC) اسلام آباد\nD) کوئٹہ\n'
        'Q2. پاکستان کا سب سے بڑا شہر کون سا ہے؟\n'
        'A) لاہور\nB) کراچی\nC) اسلام آباد\nD) فیصل آباد\n'
        'ANSWER KEY\n'
        '1. C  2. B\n';
    final r2 = parseMcqs(urduKey, sourceId: _src, sourceLabel: 'Urdu');
    expect(r2.parsed, 2);
    expect(r2.keyEntriesApplied, 2);
    expect(
      r2.questions.map((q) => q.correctIndex).toList(),
      [2, 1],
    );
  });

  test('parseKeyEntries: token stream handles every entry shape', () {
    final entries = parseKeyEntries(
      '1. C 2-C 3) B 4: D Q5: A 6. Asif Ali Zardari 7. B) Hafeez Jalandhari '
      '61. (C) 3 62. (A) Portable Document Format 74. (A) 43.75% English '
      'Q8 C Q9: D',
    );
    expect(entries, {
      1: 'C',
      2: 'C',
      3: 'B',
      4: 'D',
      5: 'A',
      6: 'Asif Ali Zardari',
      // "Q8 C" (no separator after the number) normalises to "Q8: C".
      8: 'C',
      9: 'D',
      // Letter + text is kept WHOLE (the caller resolves letter-first);
      // "(C) 3" keeps its letter too, and "43.75%" is never read as a
      // bogus entry 43.
      7: 'B) Hafeez Jalandhari',
      61: '(C) 3',
      62: '(A) Portable Document Format',
      74: '(A) 43.75% English',
    });
    expect(entries.containsKey(43), isFalse);
  });

  test('parseKeyEntries: OCR comma separator ("13, (B)") is an entry',
      () {
    // Tesseract on the PPSC-66 key reads the entry period as a comma
    // ("13, (B) Should the poor", "41, (D) None of these" — 20 Nov
    // 2026). Those entries were silently lost. A comma is safe as a
    // separator because the lookahead still blocks thousands
    // separators ("138,000" — "138," is followed by "0").
    final entries = parseKeyEntries(
      '138,000 men marched 13, (B) Should the poor '
      '41, (D) None of these '
      '44,(C) To reverse the condition 56, (D) None of these',
    );
    expect(entries[13], '(B) Should the poor');
    expect(entries[41], '(D) None of these');
    expect(entries[44], '(C) To reverse the condition');
    expect(entries[56], '(D) None of these');
    expect(entries.containsKey(138), isFalse);
  });

  test('segmentText: key lines excluded, paper segments tracked', () {
    final seg = segmentText([
      'WHO is WHO in Pakistan',
      'Paper 1',
      'Q1. Capital?',
      'A) One',
      'ANSWER KEY',
      '1. C',
      'Paper 2',
      'Q1. Capital?',
      'A) One',
      'Paper 2 Answer Key',
      '1. B',
    ]);
    expect(seg.keySectionsFound, 2);
    expect(seg.keyEntries['Paper 1'], {1: 'C'});
    expect(seg.keyEntries['Paper 2'], {1: 'B'});
    expect(
      seg.questionLines.map((l) => l.text),
      [
        'WHO is WHO in Pakistan',
        'Q1. Capital?',
        'A) One',
        'Q1. Capital?',
        'A) One',
      ],
    );
    expect(seg.questionLines[1].paper, 'Paper 1');
    expect(seg.questionLines[3].paper, 'Paper 2');
  });

  test('synthetic real book end-to-end: front matter + 10 MCQs + key',
      () async {
    final bytes = await _buildKeyBook();
    final pages = extractPdfPages(bytes);
    expect(pages.length, 4);
    final text = pages.map((p) => p.text).join('\n\n');
    final result = parseMcqs(text, sourceId: 'diag', sourceLabel: 'Key Book');
    expect(result.parsed, 10);
    expect(result.keySectionsFound, 1);
    expect(result.keyEntriesApplied, 10);
    expect(result.questionsMissingAnswers, isEmpty);
    expect(result.formatCounts['block'], 10);
    for (final q in result.questions) {
      expect(q.options.length, 4);
      expect(q.correctIndex, 0, reason: 'key says A for every question');
    }
    // Only the front-matter block is dropped silently (it never looked
    // like a question); the key adds no skips.
    expect(result.skipped, 0);
    expect(result.errors, isEmpty);
  });

  // ------------------------------------------------------------------
  // Strict paper rule (20 Nov 2026, owner: a must, not a nice-to-have):
  // a key inside the same PDF applies ONLY to the paper with the SAME
  // title. Never one paper's key to another paper.
  // ------------------------------------------------------------------
  test('strict paper: key titled "Paper 60" fills only Paper 60', () {
    const text = 'Paper 60\n'
        'Q1. Capital of Pakistan?\n'
        'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n'
        'Q2. Capital of France?\n'
        'A) London\nB) Paris\nC) Rome\nD) Berlin\n'
        'Q3. Capital of Italy?\n'
        'A) Madrid\nB) Rome\nC) Paris\nD) Athens\n'
        'Paper 61\n'
        'Q1. Capital of Spain?\n'
        'A) Madrid\nB) Barcelona\nC) Seville\nD) Valencia\n'
        'Q2. Capital of Germany?\n'
        'A) Munich\nB) Hamburg\nC) Berlin\nD) Bonn\n'
        'Q3. Capital of Portugal?\n'
        'A) Porto\nB) Lisbon\nC) Faro\nD) Braga\n'
        'ANSWER KEY PAPER 60\n'
        '1. C\n'
        '2. B\n'
        '3. B\n';
    final r = parseMcqs(text, sourceId: _src, sourceLabel: _label);
    // Paper 60's three questions are answered by its own key; Paper
    // 61's three share Q-numbers (1–3) but stay pending — the key
    // must never leak across, even though the numbers match.
    expect(r.parsed, 3);
    expect(r.keyEntriesApplied, 3);
    expect(r.answerPending.length, 3);
    expect(
      r.questions.map((q) => q.correctIndex).toList(),
      [2, 1, 1],
    );
    expect(
      r.answerPending.map((p) => p.text).toList(),
      contains('Capital of Portugal?'),
    );
    expect(
      r.answerPending.every((p) => p.paper == 'Paper 61'),
      isTrue,
    );
    // The attribution names the paper the key attached to.
    expect(
      r.keyPaperReport.any(
        (l) => l.contains('Paper 60') && l.contains('3 jawab'),
      ),
      isTrue,
    );
    // The key text never appears in the parsed questions.
    for (final q in r.questions) {
      expect(q.text, isNot(contains('ANSWER KEY')));
      for (final o in q.options) {
        expect(o, isNot(contains('ANSWER KEY')));
      }
    }
    for (final p in r.answerPending) {
      expect(p.text, isNot(contains('ANSWER KEY')));
    }
  });

  test('strict paper: key for a paper not in the import applies to nothing',
      () {
    const text = 'Paper 61\n'
        'Q1. Capital of Spain?\n'
        'A) Madrid\nB) Barcelona\nC) Seville\nD) Valencia\n'
        'Q2. Capital of Germany?\n'
        'A) Munich\nB) Hamburg\nC) Berlin\nD) Bonn\n'
        'ANSWER KEY PAPER 60\n'
        '1. C\n'
        '2. B\n';
    final r = parseMcqs(text, sourceId: _src, sourceLabel: _label);
    expect(r.parsed, 0);
    expect(r.keyEntriesApplied, 0);
    expect(r.answerPending.length, 2);
    expect(
      r.keyPaperReport.any(
        (l) => l.contains('Paper 60') && l.contains('key nahi lagayi'),
      ),
      isTrue,
    );
  });

  test('strict paper: bare key attaches to the preceding paper, with attribution',
      () {
    const text = 'Paper 60\n'
        'Q1. Capital of Pakistan?\n'
        'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n'
        'Q2. Capital of France?\n'
        'A) London\nB) Paris\nC) Rome\nD) Berlin\n'
        'ANSWER KEY\n'
        '1. C\n'
        '2. B\n';
    final r = parseMcqs(text, sourceId: _src, sourceLabel: _label);
    expect(r.parsed, 2);
    expect(r.keyEntriesApplied, 2);
    expect(
      r.questions.map((q) => q.correctIndex).toList(),
      [2, 1],
    );
    expect(
      r.keyPaperReport.any(
        (l) => l.contains('Paper 60') && l.contains('2 jawab'),
      ),
      isTrue,
    );
  });

  test('merged key heading line opens the section (OCR line-merge)', () {
    // 20 Nov 2026, PHONE_MLKIT_REAL: the phone's ML Kit read merges
    // the key heading with the next line, so isAnswerKeyHeading
    // (whole-line match) fails, no section opens, and the Save dialog
    // says "no answers attached" although the key is on the page.
    // The heading words and the first entry are verbatim from the
    // real Paper 66 key (Tesseract read of p6: "ANSWER KEY:" then
    // "1. (B) Broke out"); only the line break between them is the
    // merge. Before the fix this parses 0 key sections and the entry
    // never applies.
    const text = 'Q1. Capital of Pakistan?\n'
        'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n'
        'Q2. Capital of France?\n'
        'A) London\nB) Paris\nC) Rome\nD) Berlin\n'
        'ANSWER KEY: 1. C\n'
        '2. B\n';
    final r = parseMcqs(text, sourceId: _src, sourceLabel: _label);
    expect(r.keySectionsFound, 1);
    expect(r.keyEntriesApplied, 2);
    expect(r.questionsMissingAnswers, isEmpty);
    expect(
      r.questions.map((q) => q.correctIndex).toList(),
      [2, 1],
    );
  });

  test('merged key heading with a subhead opens the section', () {
    // Same merge, but the heading merged with its subhead instead
    // of the first entry ("ANSWER KEY: English Grammar" — the real
    // Paper 66 subhead, verbatim from the Tesseract p6 read). The
    // subhead must reach the section buffer, not be dropped, and the
    // entries after it must still apply.
    const text = 'Q1. Capital of Pakistan?\n'
        'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n'
        'Q2. Capital of France?\n'
        'A) London\nB) Paris\nC) Rome\nD) Berlin\n'
        'ANSWER KEY: English Grammar\n'
        '1. C\n'
        '2. B\n';
    final r = parseMcqs(text, sourceId: _src, sourceLabel: _label);
    expect(r.keySectionsFound, 1);
    expect(r.keyEntriesApplied, 2);
    expect(r.questionsMissingAnswers, isEmpty);
  });

  test('prose starting with "Answers" does not open a key section', () {
    // Guard for keyHeadingRemainder: a prose line that merely begins
    // with the word "Answers" must never be treated as a merged
    // heading — the remainder is neither a key entry nor a
    // heading-like fragment.
    const text = 'Q1. Capital of Pakistan?\n'
        'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n'
        'Answers to the following questions are given below.\n'
        'Q2. Capital of France?\n'
        'A) London\nB) Paris\nC) Rome\nD) Berlin\n';
    final r = parseMcqs(text, sourceId: _src, sourceLabel: _label);
    expect(r.keySectionsFound, 0);
    expect(r.keyEntriesApplied, 0);
  });

  test('per-question "Answer: Option C" line never opens a key section', () {
    // Regression (20 Nov 2026): keyHeadingRemainder's first version
    // matched the bare word "Answer", so a standard answer line
    // ("Answer: Option C" / "Answer: C") opened a spurious key
    // section and swallowed every question after it — 17 suite
    // failures, incl. F1 40→2. The singular "Answer:" is an answer
    // line, never a heading.
    const text = 'Q1. Capital of Pakistan?\n'
        'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n'
        'Answer: Option C\n'
        'Q2. Capital of France?\n'
        'A) London\nB) Paris\nC) Rome\nD) Berlin\n'
        'Answer: Option B\n';
    final r = parseMcqs(text, sourceId: _src, sourceLabel: _label);
    expect(r.keySectionsFound, 0);
    expect(r.keyEntriesApplied, 0);
    expect(r.questions.length, 2);
  });
}

/// Replica of the user's real book shape (from the v1.1 diagnosis):
/// front matter + 10 MCQs with options but NO inline answers + a
/// trailing ANSWER KEY page.
Future<Uint8List> _buildKeyBook() async {
  final doc = pw.Document();
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('WHO is WHO in Pakistan'),
          pw.Text('Updated till March 2025 - Free Version'),
          pw.Text('Pray for Palestine'),
          pw.Text('Special Offer Paid Files'),
          pw.Text('Current Affairs Pack 2025, English MCQs Pack 2025'),
          pw.Text('For Package details click on this link:'),
          pw.Text('https://mcqsplanet.com/contact-us/'),
        ],
      ),
    ),
  );
  // 10 MCQs, options on separate lines, NO answers inline.
  for (var i = 0; i < 2; i++) {
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (ctx) {
          final lines = <pw.Widget>[];
          for (var q = 1; q <= 5; q++) {
            final n = i * 5 + q;
            lines.addAll([
              pw.Text('Q$n. Who is the President of Pakistan?'),
              pw.Text('A) Asif Ali Zardari'),
              pw.Text('B) Mamnoon Hussain'),
              pw.Text('C) Arif Alvi'),
              pw.Text('D) Pervez Musharraf'),
              pw.SizedBox(height: 8),
            ]);
          }
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: lines,
          );
        },
      ),
    );
  }
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('ANSWER KEY'),
          pw.Text('1. A  2. A  3. A  4. A  5. A'),
          pw.Text('6. A  7. A  8. A  9. A  10. A'),
        ],
      ),
    ),
  );
  return doc.save();
}
