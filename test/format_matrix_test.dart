import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';

// Format matrix (extraction hardening, v2.0.3). 24 layouts of MCQ
// books are rendered from ORIGINAL sample questions (no book content)
// and run through the real parser. Every layout must give all 24
// questions with the right answer. F07 ("(1)" numbering) is left out
// on purpose: "(1)" is also the numeric option marker, so reading it
// as a question number would corrupt numeric-option books.

// 24 ORIGINAL sample MCQs (invented here, not from any book).
final qs = <List<String>>[
  for (var i = 1; i <= 24; i++)
    [
      'Sample question number $i about topic ${String.fromCharCode(64 + (i % 5) + 1)}?',
      'Alpha $i',
      'Bravo $i',
      'Charlie $i',
      'Delta $i',
    ],
];
final ans = [
  for (var i = 0; i < 24; i++) (i * 7 + 1) % 4,
]; // pseudo-random 0..3
const L = ['A', 'B', 'C', 'D'];

String blocks({
  String Function(int n)? num,
  String Function(String l)? opt,
  String Function(int i)? after,
  int count = 24,
}) {
  final b = StringBuffer();
  for (var i = 0; i < count; i++) {
    b.writeln('${num != null ? num(i + 1) : '${i + 1}.'} ${qs[i][0]}');
    for (var k = 0; k < 4; k++) {
      b.writeln('${opt != null ? opt(L[k]) : '($k)'} ${qs[i][k + 1]}');
    }
    if (after != null) b.writeln(after(i));
  }
  return b.toString();
}

String optParen(String l) => '($l)';
String keyCompact() => [
  'ANSWER KEY',
  for (var i = 0; i < 24; i++) '${i + 1}-${L[ans[i]]}',
].join('\n');
String keyDotLines() => [
  'ANSWER KEY',
  for (var i = 0; i < 24; i++) '${i + 1}. ${L[ans[i]]}',
].join('\n');
String keyRow(int per, String sep) {
  final out = <String>['ANSWERS'];
  for (var i = 0; i < 24; i += per) {
    out.add(
      [for (var j = i; j < i + per && j < 24; j++) '${j + 1}$sep${L[ans[j]]}']
          .join('  '),
    );
  }
  return out.join('\n');
}

String keyParen() => [
  'Answer Key',
  for (var i = 0; i < 24; i++) '${i + 1}. (${L[ans[i]]}) ${qs[i][ans[i] + 1]}',
].join('\n');
String keyLower() => [
  'Key',
  for (var i = 0; i < 24; i += 6)
    [for (var j = i; j < i + 6; j++) '${j + 1}-${L[ans[j]].toLowerCase()}']
        .join(' '),
].join('\n');

final formats = <String, String Function()>{
  'F01 block (A) opts + key "1-B" lines': () =>
      blocks(opt: optParen) + keyCompact(),
  'F02 block A. opts + key "1. B" lines': () =>
      blocks(opt: (l) => '$l.') + keyDotLines(),
  'F03 block a) opts + key grid 6/row "1-B"': () =>
      blocks(opt: (l) => '${l.toLowerCase()})') + keyRow(6, '-'),
  'F04 block A) opts + key "1. (B) text"': () =>
      blocks(opt: (l) => '$l)') + keyParen(),
  'F05 block (a) opts + lowercase key': () =>
      blocks(opt: (l) => '(${l.toLowerCase()})') + keyLower(),
  'F06 block Q1. numbering + key': () =>
      blocks(num: (n) => 'Q$n.', opt: optParen) + keyCompact(),
  'F07 block "(1)" numbering + key': () =>
      blocks(num: (n) => '($n)', opt: optParen) + keyCompact(),
  'F08 block 1) numbering + key': () =>
      blocks(num: (n) => '$n)', opt: optParen) + keyCompact(),
  'F09 inline "Ans: B" after each': () =>
      blocks(opt: optParen, after: (i) => 'Ans: ${L[ans[i]]}'),
  'F10 inline "Answer: (B)"': () =>
      blocks(opt: optParen, after: (i) => 'Answer: (${L[ans[i]]})'),
  'F11 inline "Correct Answer: B"': () =>
      blocks(opt: optParen, after: (i) => 'Correct Answer: ${L[ans[i]]}'),
  'F12 tick on correct option': () {
    final b = StringBuffer();
    for (var i = 0; i < 24; i++) {
      b.writeln('${i + 1}. ${qs[i][0]}');
      for (var k = 0; k < 4; k++) {
        b.writeln('(${L[k]}) ${qs[i][k + 1]}${k == ans[i] ? ' ✓' : ''}');
      }
    }
    return b.toString();
  },
  'F13 star on correct option': () {
    final b = StringBuffer();
    for (var i = 0; i < 24; i++) {
      b.writeln('${i + 1}. ${qs[i][0]}');
      for (var k = 0; k < 4; k++) {
        b.writeln('(${L[k]}) ${qs[i][k + 1]}${k == ans[i] ? ' *' : ''}');
      }
    }
    return b.toString();
  },
  'F14 options inline one line + key': () {
    final b = StringBuffer();
    for (var i = 0; i < 24; i++) {
      b.writeln(
        '${i + 1}. ${qs[i][0]} (A) ${qs[i][1]} (B) ${qs[i][2]} (C) ${qs[i][3]} (D) ${qs[i][4]}',
      );
    }
    return b.toString() + keyCompact();
  },
  'F15 key "1 B 2 C" space-separated rows': () =>
      blocks(opt: optParen) + keyRow(8, ' '),
  'F16 key rows "1.B 2.C"': () => blocks(opt: optParen) + keyRow(8, '.'),
  'F17 key rows "1(B) 2(C)"': () {
    final out = <String>['ANSWERS'];
    for (var i = 0; i < 24; i += 8) {
      out.add(
        [for (var j = i; j < i + 8; j++) '${j + 1}(${L[ans[j]]})'].join(' '),
      );
    }
    return blocks(opt: optParen) + out.join('\n');
  },
  'F18 two papers, key at end each': () {
    final p1 = blocks(opt: optParen, count: 12);
    return 'PAPER 1\n${p1}ANSWER KEY PAPER 1\n${[for (var i = 0; i < 12; i++) '${i + 1}-${L[ans[i]]}'].join('\n')}\n'
        'PAPER 2\n${[
          for (var i = 12; i < 24; i++) '${i - 11}. ${qs[i][0]}\n${[for (var k = 0; k < 4; k++) '(${L[k]}) ${qs[i][k + 1]}'].join('\n')}',
        ].join('\n')}\n'
        'ANSWER KEY PAPER 2\n${[for (var i = 12; i < 24; i++) '${i - 11}-${L[ans[i]]}'].join('\n')}\n';
  },
  'F19 subject headings + continuous numbering + key': () =>
      'ENGLISH\n${blocks(opt: optParen, count: 12)}GENERAL KNOWLEDGE\n${[
        for (var i = 12; i < 24; i++) '${i + 1}. ${qs[i][0]}\n${[for (var k = 0; k < 4; k++) '(${L[k]}) ${qs[i][k + 1]}'].join('\n')}',
      ].join('\n')}\n${keyCompact()}',
  'F20 chapter-wise "Answers:" after each 8': () {
    final b = StringBuffer();
    for (var c = 0; c < 3; c++) {
      b.writeln('Chapter ${c + 1}');
      for (var i = c * 8; i < c * 8 + 8; i++) {
        b.writeln('${i - c * 8 + 1}. ${qs[i][0]}');
        for (var k = 0; k < 4; k++) {
          b.writeln('(${L[k]}) ${qs[i][k + 1]}');
        }
      }
      b.writeln(
        'Answers: ${[for (var i = c * 8; i < c * 8 + 8; i++) '${i - c * 8 + 1}-${L[ans[i]]}'].join(', ')}',
      );
    }
    return b.toString();
  },
  'F21 5 options (A-E) + key': () {
    final b = StringBuffer();
    for (var i = 0; i < 24; i++) {
      b.writeln('${i + 1}. ${qs[i][0]}');
      for (var k = 0; k < 4; k++) {
        b.writeln('(${L[k]}) ${qs[i][k + 1]}');
      }
      b.writeln('(E) None of these');
    }
    return b.toString() + keyCompact();
  },
  'F22 blank lines between questions + key': () =>
      blocks(opt: optParen, after: (i) => '') + keyCompact(),
  'F23 page headers/footers noise + key': () {
    final b = StringBuffer();
    for (var i = 0; i < 24; i++) {
      if (i % 6 == 0) b.writeln('Page ${i ~/ 6 + 1}   Advanced MCQs Volume 2');
      b.writeln('${i + 1}. ${qs[i][0]}');
      for (var k = 0; k < 4; k++) {
        b.writeln('(${L[k]}) ${qs[i][k + 1]}');
      }
    }
    return b.toString() + keyCompact();
  },
  'F24 Urdu-script stems (English opts) + key': () {
    final b = StringBuffer();
    for (var i = 0; i < 24; i++) {
      b.writeln('${i + 1}. پاکستان کا سوال نمبر ${i + 1} کیا ہے؟');
      for (var k = 0; k < 4; k++) {
        b.writeln('(${L[k]}) ${qs[i][k + 1]}');
      }
    }
    return b.toString() + keyCompact();
  },
};

void main() {
  group('format matrix', () {
    formats.forEach((name, gen) {
      if (name.startsWith('F07')) return;
      test(name, () {
        final r = parseMcqs(gen(), sourceId: 's', sourceLabel: 'x');
        expect(r.questions.length, 24);
        for (final q in r.questions) {
          final m = RegExp(r'(\d+)').firstMatch(q.options.first)!;
          final idx = int.parse(m.group(1)!) - 1;
          expect(
            q.correctIndex >= 0,
            isTrue,
            reason: 'no answer for Q${idx + 1}',
          );
          expect(q.options[q.correctIndex], qs[idx][ans[idx] + 1]);
        }
      });
    });
  });
}
