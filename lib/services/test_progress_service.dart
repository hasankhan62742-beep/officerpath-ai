import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Mid-test progress (AUDIT C3).
///
/// Before this fix, answers + remaining time lived only in memory: if
/// Android killed the app mid-test (a 90–200 min test), or the phone
/// rebooted, the whole attempt was lost — and the free test was already
/// spent. Progress is now saved to SharedPreferences on every answer
/// or mark change, and Home offers "Resume test" while one is open.
///
/// The timer itself is a wall-clock deadline (`startedAt + duration`),
/// so backgrounding cannot drift it and the remaining time is always
/// recomputed from the clock — never from a decrementing counter.
class TestProgress {
  const TestProgress({
    required this.examId,
    required this.durationMinutes,
    required this.startedAtIso,
    required this.questionIds,
    required this.answers,
    required this.marked,
  });

  final String examId;
  final int durationMinutes;
  final String startedAtIso;

  /// Question ids in test order (db ids; sample-bank questions have
  /// ids after seeding).
  final List<int> questionIds;

  /// question index -> chosen option index.
  final Map<int, int> answers;
  final Set<int> marked;

  DateTime get startedAt =>
      DateTime.tryParse(startedAtIso) ?? DateTime.now();

  /// Remaining time from the wall-clock deadline. Never negative.
  Duration get remaining {
    final deadline = startedAt.add(Duration(minutes: durationMinutes));
    final left = deadline.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  Map<String, Object?> toMap() => {
    'examId': examId,
    'durationMinutes': durationMinutes,
    'startedAtIso': startedAtIso,
    'questionIds': questionIds,
    'answers': answers.map((k, v) => MapEntry(k.toString(), v)),
    'marked': marked.toList(),
  };

  factory TestProgress.fromMap(Map<String, Object?> map) {
    final rawAnswers = (map['answers'] as Map?) ?? {};
    final answers = <int, int>{};
    for (final e in rawAnswers.entries) {
      final k = int.tryParse(e.key.toString());
      final v = e.value is int
          ? e.value as int
          : int.tryParse(e.value.toString());
      if (k != null && v != null) answers[k] = v;
    }
    return TestProgress(
      examId: map['examId'] as String? ?? '',
      durationMinutes: (map['durationMinutes'] as num?)?.toInt() ?? 0,
      startedAtIso: map['startedAtIso'] as String? ?? '',
      questionIds:
          ((map['questionIds'] as List?) ?? [])
              .map((e) => (e as num).toInt())
              .toList(),
      answers: answers,
      marked:
          ((map['marked'] as List?) ?? [])
              .map((e) => (e as num).toInt())
              .toSet(),
    );
  }
}

class TestProgressService {
  TestProgressService._();
  static final TestProgressService instance = TestProgressService._();

  static const _kProgress = 'test_in_progress_v1';

  Future<TestProgress?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kProgress);
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, Object?>;
      final progress = TestProgress.fromMap(map);
      if (progress.questionIds.isEmpty) return null;
      return progress;
    } catch (_) {
      await prefs.remove(_kProgress);
      return null;
    }
  }

  Future<void> save(TestProgress progress) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kProgress, jsonEncode(progress.toMap()));
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kProgress);
  }
}
