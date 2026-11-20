import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/models/exam.dart';
import 'package:officerpath_ai/models/question.dart';
import 'package:officerpath_ai/services/test_generator.dart';

// Subject-grouped test order (PPSC pattern, user 19 Nov 2026):
// questions are GROUPED BY SUBJECT in sequence — all GK, then all
// English, then all Maths — never randomly interleaved.

Question _q(
  String text, {
  required String part,
  required Subject subject,
  required String src,
  int correct = 0,
}) => Question(
  text: text,
  options: ['A', 'B', 'C', 'D'],
  correctIndex: correct,
  subject: subject,
  sourceId: src,
  sourceLabel: src,
  part: part,
);

/// The canonical index of a question's section (for the
/// "never goes backwards" assertions).
int _canonicalIndex(Question q) {
  final idx = canonicalSubjectOrder.indexOf(sectionLabelFor(q));
  return idx == -1 ? canonicalSubjectOrder.length : idx;
}

/// Asserts the question list is grouped: the canonical index of the
/// section never decreases as you walk the test.
void _expectGrouped(List<Question> test) {
  var prev = -1;
  for (final q in test) {
    final idx = _canonicalIndex(q);
    expect(idx, greaterThanOrEqualTo(prev));
    prev = idx;
  }
}

void main() {
  group('generateTest — subject-grouped order (PPSC pattern)', () {
    test('mixed-subject multi-source test is grouped in canonical order',
        () {
      // Bank in SCRAMBLED order (Maths first, then English, then GK)
      // across TWO sources — the test must still come out GK, then
      // English, then Maths (canonical PPSC order).
      final bank = <Question>[
        for (var i = 0; i < 10; i++)
          _q('M$i', part: 'Maths', subject: Subject.mathsComputer, src: 'a'),
        for (var i = 0; i < 10; i++)
          _q('E$i', part: 'English', subject: Subject.english, src: 'b'),
        for (var i = 0; i < 10; i++)
          _q(
            'G$i',
            part: 'General Knowledge',
            subject: Subject.gk,
            src: 'a',
          ),
      ];
      final test = generateTest(
        bank: bank,
        sourceIds: {'a', 'b'},
        count: 30,
        seed: 42,
      );
      expect(test.length, 30);
      _expectGrouped(test);
      // Exactly 10 per subject, in sequence: 10 GK, then 10 English,
      // then 10 Maths — the user's example.
      final labels = test.map(sectionLabelFor).toList();
      expect(labels.sublist(0, 10).toSet(), {'General Knowledge'});
      expect(labels.sublist(10, 20).toSet(), {'English'});
      expect(labels.sublist(20, 30).toSet(), {'Mathematics'});
    });

    test('different seeds still keep groups intact; same seed repeats',
        () {
      final bank = <Question>[
        for (var i = 0; i < 12; i++)
          _q('G$i', part: 'General Knowledge', subject: Subject.gk, src: 'a'),
        for (var i = 0; i < 12; i++)
          _q('E$i', part: 'English', subject: Subject.english, src: 'b'),
        for (var i = 0; i < 12; i++)
          _q('M$i', part: 'Maths', subject: Subject.mathsComputer, src: 'a'),
      ];
      final t1 = generateTest(
        bank: bank,
        sourceIds: {'a', 'b'},
        count: 30,
        seed: 1,
      );
      final t2 = generateTest(
        bank: bank,
        sourceIds: {'a', 'b'},
        count: 30,
        seed: 2,
      );
      _expectGrouped(t1);
      _expectGrouped(t2);
      // Same seed → the same test (deterministic for tests).
      final t1again = generateTest(
        bank: bank,
        sourceIds: {'a', 'b'},
        count: 30,
        seed: 1,
      );
      expect(
        t1again.map((q) => q.text).toList(),
        t1.map((q) => q.text).toList(),
      );
    });

    test('single-paper test preserves the paper\'s own section order',
        () {
      // ONE paper whose sections run English, then General Knowledge,
      // then Maths — NOT canonical order. The paper's own order wins
      // (it is the PPSC order by construction).
      final bank = <Question>[
        for (var i = 0; i < 8; i++)
          _q(
            'E$i',
            part: 'English',
            subject: Subject.english,
            src: 'paper-109',
          ),
        for (var i = 0; i < 8; i++)
          _q(
            'G$i',
            part: 'General Knowledge',
            subject: Subject.gk,
            src: 'paper-109',
          ),
        for (var i = 0; i < 8; i++)
          _q(
            'M$i',
            part: 'Mathematics',
            subject: Subject.mathsComputer,
            src: 'paper-109',
          ),
      ];
      final test = generateTest(
        bank: bank,
        sourceIds: {'paper-109'},
        count: 24,
        seed: 7,
      );
      expect(test.length, 24);
      final labels = test.map(sectionLabelFor).toList();
      expect(labels.sublist(0, 8).toSet(), {'English'});
      expect(labels.sublist(8, 16).toSet(), {'General Knowledge'});
      expect(labels.sublist(16, 24).toSet(), {'Mathematics'});
    });

    test('distribution sums to count; a small group is redistributed',
        () {
      final bank = <Question>[
        for (var i = 0; i < 2; i++)
          _q('G$i', part: 'General Knowledge', subject: Subject.gk, src: 'a'),
        for (var i = 0; i < 10; i++)
          _q('E$i', part: 'English', subject: Subject.english, src: 'b'),
        for (var i = 0; i < 10; i++)
          _q('M$i', part: 'Maths', subject: Subject.mathsComputer, src: 'a'),
      ];
      // 15 across 3 groups: even split is 5 each, but GK has only 2
      // → its 3 shortfall goes to English and Maths (in group order).
      final test = generateTest(
        bank: bank,
        sourceIds: {'a', 'b'},
        count: 15,
        seed: 3,
      );
      expect(test.length, 15);
      final counts = <String, int>{};
      for (final q in test) {
        counts[sectionLabelFor(q)] =
            (counts[sectionLabelFor(q)] ?? 0) + 1;
      }
      expect(counts, {
        'General Knowledge': 2,
        'English': 7,
        'Mathematics': 6,
      });
      _expectGrouped(test);
    });

    test('count larger than the pool returns the whole pool, grouped',
        () {
      final bank = <Question>[
        for (var i = 0; i < 4; i++)
          _q('G$i', part: 'General Knowledge', subject: Subject.gk, src: 'a'),
        for (var i = 0; i < 3; i++)
          _q('E$i', part: 'English', subject: Subject.english, src: 'a'),
      ];
      final test = generateTest(
        bank: bank,
        sourceIds: {'a'},
        count: 100,
        seed: 5,
      );
      expect(test.length, 7);
      _expectGrouped(test);
    });

    test('name variants map to the same canonical group', () {
      final bank = <Question>[
        for (var i = 0; i < 5; i++)
          _q(
            'PA$i',
            part: 'Pakistan Affairs',
            subject: Subject.pakStudies,
            src: 'a',
          ),
        for (var i = 0; i < 5; i++)
          _q(
            'PS$i',
            part: 'Pakistan Studies',
            subject: Subject.pakStudies,
            src: 'b',
          ),
        for (var i = 0; i < 5; i++)
          _q('G$i', part: 'GK', subject: Subject.gk, src: 'a'),
      ];
      final test = generateTest(
        bank: bank,
        sourceIds: {'a', 'b'},
        count: 15,
        seed: 9,
      );
      expect(test.length, 15);
      // "Pakistan Affairs" and "Pakistan Studies" are ONE group
      // ("Pakistan Studies"); "GK" is "General Knowledge".
      final labels = test.map(sectionLabelFor).toList();
      expect(labels.sublist(0, 5).toSet(), {'General Knowledge'});
      expect(labels.sublist(5, 15).toSet(), {'Pakistan Studies'});
      expect(
        testSections(test).map((s) => s.label).toList(),
        ['General Knowledge', 'Pakistan Studies'],
      );
      expect(
        testSections(test).map((s) => '${s.start}-${s.end}').toList(),
        ['1-5', '6-15'],
      );
    });

    test('options are still shuffled per question', () {
      final bank = <Question>[
        for (var i = 0; i < 10; i++)
          _q('G$i', part: 'General Knowledge', subject: Subject.gk, src: 'a'),
      ];
      final test = generateTest(
        bank: bank,
        sourceIds: {'a'},
        count: 10,
        seed: 42,
      );
      // The correct answer TEXT stays the same after the shuffle …
      for (final q in test) {
        expect(q.options[q.correctIndex], 'A');
      }
      // … but at least one question's option order actually moved.
      final moved = test.where(
        (q) => q.options.join() != 'ABCD',
      );
      expect(moved.length, greaterThan(0));
    });

    test('perSubject follows the same group order', () {
      final bank = <Question>[
        for (var i = 0; i < 6; i++)
          _q('M$i', part: 'Maths', subject: Subject.mathsComputer, src: 'a'),
        for (var i = 0; i < 6; i++)
          _q('E$i', part: 'English', subject: Subject.english, src: 'b'),
        for (var i = 0; i < 6; i++)
          _q('G$i', part: 'General Knowledge', subject: Subject.gk, src: 'a'),
      ];
      final test = generateTest(
        bank: bank,
        sourceIds: {'a', 'b'},
        count: 18,
        seed: 11,
      );
      // All correct.
      final answers = <int, int?>{
        for (var i = 0; i < test.length; i++) i: test[i].correctIndex,
      };
      final result = scoreAttempt(
        questions: test,
        answers: answers,
        markedForReview: {},
        exam: ExamPattern.byId('ppsc'),
        durationSeconds: 600,
      );
      expect(result.correct, 18);
      // The breakdown is in test (group) order, not alphabetical
      // and not insertion-accident: GK, English, Maths & Computer.
      expect(result.perSubject.keys.toList(), [
        'General Knowledge',
        'English',
        'Maths & Computer',
      ]);
      expect(result.perSubject['General Knowledge']!['total'], 6);
      expect(result.perSubject['English']!['total'], 6);
      expect(result.perSubject['Maths & Computer']!['total'], 6);
    });
  });
}
