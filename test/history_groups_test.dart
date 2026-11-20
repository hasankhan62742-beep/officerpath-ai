import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/models/question.dart';
import 'package:officerpath_ai/widgets/history_groups.dart';

/// v1.2 history folders + improvement analytics — pure-logic tests.
/// No widgets, no storage: every case is real stored-attempt data.

AttemptRecord _attempt({
  required String exam,
  required double score,
  required double percent,
  required int total,
  required DateTime when,
  String perSubjectJson = '{}',
}) => AttemptRecord(
  examId: exam.toLowerCase().replaceAll(' ', '_'),
  examName: exam,
  totalQuestions: total,
  correct: score.toInt(),
  wrong: total - score.toInt(),
  skipped: 0,
  score: score,
  percent: percent,
  passed: percent >= 40,
  durationSeconds: 600,
  attemptedAtIso: when.toIso8601String(),
  perSubjectJson: perSubjectJson,
);

void main() {
  group('groupAttemptsByDate', () {
    test('buckets are Today / Yesterday / This Week / calendar date', () {
      final now = DateTime.now();
      final attempts = [
        _attempt(exam: 'PPSC', score: 45, percent: 45, total: 100, when: now),
        _attempt(
          exam: 'PPSC',
          score: 24,
          percent: 24,
          total: 100,
          when: now.subtract(const Duration(days: 1)),
        ),
        _attempt(
          exam: 'FPSC',
          score: 60,
          percent: 60,
          total: 100,
          when: now.subtract(const Duration(days: 4)),
        ),
        _attempt(
          exam: 'PPSC',
          score: 30,
          percent: 30,
          total: 100,
          when: now.subtract(const Duration(days: 20)),
        ),
      ];
      final groups = groupAttemptsByDate(attempts, now: now);
      expect(groups.map((g) => g.title).toList().sublist(0, 3), [
        'Today',
        'Yesterday',
        'This Week',
      ]);
      expect(groups[0].count, 1);
      expect(groups[1].count, 1);
      expect(groups[2].count, 1);
      expect(groups[3].count, 1);
      // The old date group is labelled with its calendar date.
      expect(
        groups[3].title,
        '${now.subtract(const Duration(days: 20)).day} '
        '${[
          'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
        ][now.subtract(const Duration(days: 20)).month - 1]} '
        '${now.subtract(const Duration(days: 20)).year}',
      );
    });

    test('empty buckets are omitted; empty input gives no groups', () {
      expect(groupAttemptsByDate([]), isEmpty);
      final now = DateTime.now();
      final groups = groupAttemptsByDate([
        _attempt(exam: 'PPSC', score: 10, percent: 10, total: 100, when: now),
      ]);
      expect(groups.length, 1);
      expect(groups.first.title, 'Today');
    });

    test('folder subtitle shows count, best and latest', () {
      final now = DateTime.now();
      final groups = groupAttemptsByDate([
        _attempt(exam: 'PPSC', score: 45, percent: 45, total: 100, when: now),
        _attempt(
          exam: 'PPSC',
          score: 24,
          percent: 24,
          total: 100,
          when: now.subtract(const Duration(hours: 2)),
        ),
      ], now: now);
      expect(groups.length, 1);
      expect(groups.first.subtitle, '2 attempts • Best 45% • Latest 45%');
      expect(groups.first.bestPercent, 45);
    });
  });

  group('groupAttemptsByExam', () {
    test('one folder per exam title, newest attempt first inside', () {
      final now = DateTime.now();
      final groups = groupAttemptsByExam([
        _attempt(exam: 'PPSC', score: 45, percent: 45, total: 100, when: now),
        _attempt(
          exam: 'CSS MPT',
          score: 120,
          percent: 60,
          total: 200,
          when: now,
        ),
        _attempt(
          exam: 'PPSC',
          score: 24,
          percent: 24,
          total: 100,
          when: now.subtract(const Duration(days: 1)),
        ),
      ]);
      expect(groups.map((g) => g.title).toList(), ['PPSC', 'CSS MPT']);
      expect(groups.first.count, 2);
      expect(groups.first.latestPercent, 45);
      expect(groups.first.bestPercent, 45);
    });
  });

  group('improvementDelta', () {
    test('user example: 24/100 then 45/100 = +21 marks (+87.5%)', () {
      final now = DateTime.now();
      final delta = improvementDelta([
        // Earlier attempt: 24. Later attempt: 45.
        _attempt(
          exam: 'PPSC',
          score: 24,
          percent: 24,
          total: 100,
          when: now.subtract(const Duration(days: 1)),
        ),
        _attempt(exam: 'PPSC', score: 45, percent: 45, total: 100, when: now),
      ]);
      expect(delta.hasPrevious, isTrue);
      expect(delta.improved, isTrue);
      expect(delta.marksDelta, 21);
      expect(delta.percentChange, closeTo(87.5, 0.01));
      expect(delta.pointsDelta, 21);
    });

    test('a fall shows a negative delta', () {
      final now = DateTime.now();
      final delta = improvementDelta([
        _attempt(exam: 'PPSC', score: 30, percent: 30, total: 100, when: now),
        _attempt(
          exam: 'PPSC',
          score: 50,
          percent: 50,
          total: 100,
          when: now.subtract(const Duration(days: 1)),
        ),
      ]);
      expect(delta.declined, isTrue);
      expect(delta.marksDelta, -20);
      expect(delta.percentChange, closeTo(-40, 0.01));
    });

    test('same score is unchanged, not a fake improvement', () {
      final now = DateTime.now();
      final delta = improvementDelta([
        _attempt(exam: 'PPSC', score: 40, percent: 40, total: 100, when: now),
        _attempt(
          exam: 'PPSC',
          score: 40,
          percent: 40,
          total: 100,
          when: now.subtract(const Duration(days: 1)),
        ),
      ]);
      expect(delta.unchanged, isTrue);
      expect(delta.marksDelta, 0);
    });

    test('previous score 0 gives no percent change (no divide by zero)', () {
      final now = DateTime.now();
      final delta = improvementDelta([
        _attempt(exam: 'PPSC', score: 10, percent: 10, total: 100, when: now),
        _attempt(
          exam: 'PPSC',
          score: 0,
          percent: 0,
          total: 100,
          when: now.subtract(const Duration(days: 1)),
        ),
      ]);
      expect(delta.marksDelta, 10);
      expect(delta.percentChange, isNull);
    });

    test('single attempt and empty list report no previous (never faked)',
        () {
      final now = DateTime.now();
      expect(
        improvementDelta([
          _attempt(exam: 'PPSC', score: 45, percent: 45, total: 100, when: now),
        ]).hasPrevious,
        isFalse,
      );
      expect(improvementDelta([]).hasPrevious, isFalse);
    });
  });

  group('decodePerSubject + subjectImprovement', () {
    test('corrupt JSON decodes to empty, never a crash', () {
      expect(decodePerSubject('not json'), isEmpty);
      expect(decodePerSubject(''), isEmpty);
      expect(decodePerSubject('{"GK": {"correct": 5, "total": 10}}')['GK'],
          {'correct': 5, 'total': 10});
    });

    test('per-subject deltas compare latest vs previous', () {
      final now = DateTime.now();
      final latest = _attempt(
        exam: 'PPSC',
        score: 45,
        percent: 45,
        total: 100,
        when: now,
        perSubjectJson:
            '{"General Knowledge": {"correct": 8, "total": 10}, '
            '"English": {"correct": 2, "total": 10}}',
      );
      final previous = _attempt(
        exam: 'PPSC',
        score: 24,
        percent: 24,
        total: 100,
        when: now.subtract(const Duration(days: 1)),
        perSubjectJson:
            '{"General Knowledge": {"correct": 6, "total": 10}, '
            '"English": {"correct": 5, "total": 10}}',
      );
      final deltas = subjectImprovement(latest, previous);
      expect(deltas.length, 2);
      // Worst first: English 20% is the weakest.
      expect(deltas.first.label, 'English');
      expect(deltas.first.latestPercent, 20);
      expect(deltas.first.pointsDelta, closeTo(-30, 0.01));
      expect(deltas.last.label, 'General Knowledge');
      expect(deltas.last.pointsDelta, closeTo(20, 0.01));
    });

    test('a subject missing from the previous attempt has no delta', () {
      final now = DateTime.now();
      final deltas = subjectImprovement(
        _attempt(
          exam: 'PPSC',
          score: 45,
          percent: 45,
          total: 100,
          when: now,
          perSubjectJson: '{"Urdu": {"correct": 7, "total": 10}}',
        ),
        _attempt(
          exam: 'PPSC',
          score: 24,
          percent: 24,
          total: 100,
          when: now.subtract(const Duration(days: 1)),
          perSubjectJson: '{}',
        ),
      );
      expect(deltas.length, 1);
      expect(deltas.first.previousPercent, isNull);
      expect(deltas.first.pointsDelta, isNull);
    });

    test('no previous attempt means no subject deltas', () {
      final now = DateTime.now();
      expect(
        subjectImprovement(
          _attempt(
            exam: 'PPSC',
            score: 45,
            percent: 45,
            total: 100,
            when: now,
            perSubjectJson: '{"GK": {"correct": 5, "total": 10}}',
          ),
          null,
        ),
        isEmpty,
      );
    });
  });
}
