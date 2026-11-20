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
      '61. (C) 3 62. (A) Portable Document Format 74. (A) 43.75% English',
    );
    expect(entries, {
      1: 'C',
      2: 'C',
      3: 'B',
      4: 'D',
      5: 'A',
      6: 'Asif Ali Zardari',
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
