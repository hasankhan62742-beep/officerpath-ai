import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/book_structure.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';

// Phone failure, 20 Nov 2026: the white-on-black "MODEL PAPER 66"
// heading is not read by on-device OCR, every question lands under the
// default paper and all 100 key entries came back "no matching
// question". The key is now adopted for the unlabelled questions when
// that is provably safe, and refused when it is not.

const _fx = 'test-fixtures/ppsc66';
String _load(int p) => File('$_fx/ocr-p$p.txt').readAsStringSync();

String _cut67(String t) {
  final i = t.indexOf(RegExp('MODEL PAPER 67', caseSensitive: false));
  return i < 0 ? t : t.substring(0, i);
}

List<PageText> _pages({required bool dropHeading, required bool only66}) => [
  for (var p = 1; p <= 7; p++)
    PageText(p, () {
      var t = _load(p);
      if (only66 && p == 7) t = _cut67(t);
      if (dropHeading) {
        t = t
            .split('\n')
            .where(
              (l) => !RegExp(
                r'^\s*MODEL PAPER \d+\s*$',
                caseSensitive: false,
              ).hasMatch(l),
            )
            .join('\n');
      }
      return t;
    }()),
];

ParseResult _parse(List<PageText> pages) => parseMcqsFromPages(
  pages,
  sourceId: 's',
  sourceLabel: 'x',
  ocrPages: {1, 2, 3, 4, 5, 6, 7},
);

void main() {
  test('heading present: 100 of 100 answered (unchanged behaviour)', () {
    final r = _parse(_pages(dropHeading: false, only66: true));
    expect(r.questions.length, 100);
    expect(r.questions.where((q) => q.correctIndex >= 0).length, 100);
  });

  test('heading NOT read: key is adopted, 100 of 100 answered', () {
    final r = _parse(_pages(dropHeading: true, only66: true));
    expect(r.questions.length, 100);
    expect(r.questions.where((q) => q.correctIndex >= 0).length, 100);
    expect(r.unmatchedKeyEntries, isEmpty);
  });

  test('two papers merged with no headings: refused, never guessed', () {
    // Paper 67's questions repeat numbers 1..10, so adopting Paper
    // 66's key would put its answers on the wrong paper.
    final r = _parse(_pages(dropHeading: true, only66: false));
    expect(r.questions.where((q) => q.correctIndex >= 0).length, 0);
  });
}
