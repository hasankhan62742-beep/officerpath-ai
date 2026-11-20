import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/models/exam.dart';
import 'package:officerpath_ai/services/answer_key.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/urdu_ocr.dart';

/// Parser end of the table chain (photo a, "Adjective and its
/// Types"): the reconstructed '|' lines from
/// test/ocr_table_reconstruct_test.dart go into the existing table
/// pass. NOTE: this file duplicates the small element builders from
/// that file on purpose, so it runs on its own.
/// BLOCKED 2026-11-20 ~09:31 PKT: does not load — a sibling agent is
/// mid-edit on lib/services/answer_key.dart, whose line 59
/// `import 'question.dart'` dangles (there is no
/// lib/services/question.dart; PendingQuestion lives in
/// lib/models/question.dart). The existing test/answer_key_test.dart
/// fails to load with the same error, so this is not specific to
/// this file. Re-run once that import is fixed.
typedef _El = ({
  String text,
  double x,
  double y,
  double width,
  double height,
});

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

void main() {
  group('table reconstruction → parser (photo a)', () {
    test('the existing table pass parses the reconstructed rows', () {
      final text = reconstructTableText(_adjectiveElements())!;
      final lines = text.split('\n').indexed.map((e) {
        final (i, line) = e;
        return SegmentedLine(line, 'test', 0, i);
      }).toList();
      final result = parseTableFormat(
        lines,
        sourceId: 'test',
        sourceLabel: 'test',
      );
      expect(result.questions.length, 6);
      final qs = result.questions;
      // Key letter = correct answer.
      expect(qs[0].correctIndex, 0); // A
      expect(qs[3].correctIndex, 2); // C — the wrapped row
      expect(qs[4].correctIndex, 2); // C
      expect(qs[5].correctIndex, 1); // B
      // Options are exactly the 4 option cells; the type label is
      // never an option.
      expect(qs[0].options, ['honest', 'honesty', 'honestly', 'honestness']);
      expect(qs[4].options, ['A', 'An', 'The', 'None of these']);
      for (final q in qs) {
        expect(q.options, isNot(contains('Adjective')));
        expect(q.options, isNot(contains('Article')));
        expect(q.answerSource, 'key');
        expect(q.subject, Subject.english);
      }
      // The wrapped stem survived whole.
      expect(
        qs[3].text,
        'The teacher praised the ___ student in front of the whole class.',
      );
    });
  });
}
