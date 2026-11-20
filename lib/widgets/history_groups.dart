import 'dart:convert';

import 'package:intl/intl.dart';

import '../models/question.dart';

/// Pure history logic — grouping, improvement maths, subject decoding.
///
/// No widgets, no storage, no I/O: every function here is a pure
/// function of the [AttemptRecord]s passed in, so it is unit-testable
/// without sqflite. The History screen only renders what these
/// functions return. Nothing here invents data: single-attempt and
/// empty inputs are reported as such, never faked into a trend.

/// One folder/section in the History screen — a date bucket or one
/// exam (paper) title. Attempts are newest-first.
class AttemptGroup {
  const AttemptGroup({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.attempts,
  });

  /// Stable id (e.g. `date:2026-11-19` or `exam:PPSC`).
  final String id;
  final String title;

  /// e.g. "3 attempts • Best 78% • Latest 65%".
  final String subtitle;
  final List<AttemptRecord> attempts;

  int get count => attempts.length;

  double get bestPercent => attempts.isEmpty
      ? 0
      : attempts
            .map((a) => a.percent.clamp(0.0, 100.0))
            .reduce((a, b) => a > b ? a : b);

  double get latestPercent =>
      attempts.isEmpty ? 0 : attempts.first.percent.clamp(0.0, 100.0);

  /// Chronological (oldest-first) percents, for the trend chart.
  List<double> get trendPercents =>
      attempts.reversed.map((a) => a.percent.clamp(0.0, 100.0)).toList();
}

String _groupSubtitle(List<AttemptRecord> attempts) {
  if (attempts.isEmpty) return 'No attempts';
  final best = attempts
      .map((a) => a.percent.clamp(0, 100))
      .reduce((a, b) => a > b ? a : b);
  final latest = attempts.first.percent.clamp(0, 100);
  return '${attempts.length} attempt${attempts.length == 1 ? '' : 's'}'
      ' • Best ${best.toStringAsFixed(0)}%'
      ' • Latest ${latest.toStringAsFixed(0)}%';
}

DateTime _dayOf(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

/// Groups attempts by DATE, newest group first:
/// Today, Yesterday, This Week (2–6 days ago), then one group per
/// older calendar date ("12 Nov 2026"). Empty buckets are omitted.
List<AttemptGroup> groupAttemptsByDate(
  List<AttemptRecord> attempts, {
  DateTime? now,
}) {
  final today = _dayOf(now ?? DateTime.now());
  final yesterday = today.subtract(const Duration(days: 1));
  final weekStart = today.subtract(const Duration(days: 6));
  final buckets = <String, List<AttemptRecord>>{};
  final order = <String>[];

  String bucketId(DateTime day) {
    if (day == today) return 'date:today';
    if (day == yesterday) return 'date:yesterday';
    if (!day.isBefore(weekStart)) return 'date:this-week';
    return 'date:${DateFormat('yyyy-MM-dd').format(day)}';
  }

  String bucketTitle(DateTime day) {
    if (day == today) return 'Today';
    if (day == yesterday) return 'Yesterday';
    if (!day.isBefore(weekStart)) return 'This Week';
    return DateFormat('dd MMM yyyy').format(day);
  }

  // Newest first overall, so each bucket's first item is its latest.
  final sorted = attempts.toList()
    ..sort((a, b) {
      final da = DateTime.tryParse(a.attemptedAtIso);
      final db = DateTime.tryParse(b.attemptedAtIso);
      if (da == null && db == null) return 0;
      if (da == null) return 1;
      if (db == null) return -1;
      return db.compareTo(da);
    });
  for (final a in sorted) {
    final parsed = DateTime.tryParse(a.attemptedAtIso);
    final day = parsed == null ? today : _dayOf(parsed);
    final id = bucketId(day);
    if (!buckets.containsKey(id)) {
      buckets[id] = [];
      order.add(id);
    }
    buckets[id]!.add(a);
  }
  // "This Week" must come before older dated groups even when an older
  // date sorts earlier — order buckets by their newest attempt instead.
  final groups = order
      .map(
        (id) => AttemptGroup(
          id: id,
          title: bucketTitle(
            _dayOf(
              DateTime.tryParse(buckets[id]!.first.attemptedAtIso) ?? today,
            ),
          ),
          subtitle: _groupSubtitle(buckets[id]!),
          attempts: buckets[id]!,
        ),
      )
      .toList();
  return groups;
}

/// Groups attempts by BOOK (the book the test was drawn from).
///
/// v1.2: attempts store `bookTitle` (the questions' source label), so
/// folders are truly per-book. Attempts recorded before v1.2 have no
/// book title (''), so they fall back to the exam title — the folder
/// is then an exam-title folder, exactly as before.
List<AttemptGroup> groupAttemptsByExam(List<AttemptRecord> attempts) {
  final buckets = <String, List<AttemptRecord>>{};
  for (final a in attempts) {
    final key = a.bookTitle.trim().isNotEmpty ? a.bookTitle : a.examName;
    buckets.putIfAbsent(key, () => []).add(a);
  }
  final groups = buckets.entries.map((e) {
    final sorted = e.value.toList()
      ..sort((a, b) {
        final da = DateTime.tryParse(a.attemptedAtIso);
        final db = DateTime.tryParse(b.attemptedAtIso);
        if (da == null && db == null) return 0;
        if (da == null) return 1;
        if (db == null) return -1;
        return db.compareTo(da);
      });
    final isBook = e.value.any((a) => a.bookTitle.trim().isNotEmpty);
    return AttemptGroup(
      id: '${isBook ? 'book' : 'exam'}:${e.key}',
      title: e.key,
      subtitle: _groupSubtitle(sorted),
      attempts: sorted,
    );
  }).toList();
  groups.sort((a, b) {
    final da = DateTime.tryParse(a.attempts.first.attemptedAtIso);
    final db = DateTime.tryParse(b.attempts.first.attemptedAtIso);
    if (da == null && db == null) return 0;
    if (da == null) return 1;
    if (db == null) return -1;
    return db.compareTo(da);
  });
  return groups;
}

/// Improvement between the last two attempts (chronological order).
/// `hasPrevious` is false for 0–1 attempts — the UI must say so
/// instead of showing a trend.
class ImprovementDelta {
  const ImprovementDelta({
    required this.hasPrevious,
    required this.marksDelta,
    required this.percentChange,
    required this.pointsDelta,
    required this.latest,
    required this.previous,
  });

  /// False when fewer than two attempts exist.
  final bool hasPrevious;

  /// Latest score − previous score, in marks (e.g. 45 − 24 = +21).
  final double marksDelta;

  /// Relative change of the score vs the previous attempt, in percent
  /// (e.g. +21 on 24 = +87.5%). Null when the previous score was 0
  /// (division by zero — the UI says "from 0" instead).
  final double? percentChange;

  /// Latest percent − previous percent, in percentage points.
  final double pointsDelta;

  final AttemptRecord? latest;
  final AttemptRecord? previous;

  bool get improved => hasPrevious && marksDelta > 0;
  bool get declined => hasPrevious && marksDelta < 0;
  bool get unchanged => hasPrevious && marksDelta == 0;
}

/// Latest vs previous attempt from a list in ANY order. Returns
/// `hasPrevious: false` for 0–1 attempts.
ImprovementDelta improvementDelta(List<AttemptRecord> attempts) {
  const none = ImprovementDelta(
    hasPrevious: false,
    marksDelta: 0,
    percentChange: null,
    pointsDelta: 0,
    latest: null,
    previous: null,
  );
  if (attempts.length < 2) return none;
  final sorted = attempts.toList()
    ..sort((a, b) {
      final da = DateTime.tryParse(a.attemptedAtIso);
      final db = DateTime.tryParse(b.attemptedAtIso);
      if (da == null && db == null) return 0;
      if (da == null) return 1;
      if (db == null) return -1;
      return da.compareTo(db);
    });
  final latest = sorted.last;
  final previous = sorted[sorted.length - 2];
  final marksDelta = latest.score - previous.score;
  final percentChange = previous.score == 0
      ? null
      : (marksDelta / previous.score.abs()) * 100;
  return ImprovementDelta(
    hasPrevious: true,
    marksDelta: marksDelta,
    percentChange: percentChange,
    pointsDelta: latest.percent - previous.percent,
    latest: latest,
    previous: previous,
  );
}

/// Per-subject progress: latest attempt's % per subject vs the
/// previous attempt's %, for the subjects in either attempt.
/// A corrupt/empty JSON decodes to an empty map — never a crash.
Map<String, Map<String, int>> decodePerSubject(String json) {
  try {
    final raw = jsonDecode(json);
    if (raw is! Map) return {};
    final out = <String, Map<String, int>>{};
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is Map) {
        out[entry.key.toString()] = {
          'correct': (value['correct'] as num?)?.toInt() ?? 0,
          'total': (value['total'] as num?)?.toInt() ?? 0,
        };
      }
    }
    return out;
  } catch (_) {
    return {};
  }
}

class SubjectDelta {
  const SubjectDelta({
    required this.label,
    required this.latestPercent,
    required this.previousPercent,
  });

  final String label;

  /// Latest attempt's % in this subject (0–100).
  final double latestPercent;

  /// Previous attempt's % (null when the subject wasn't in it).
  final double? previousPercent;

  double? get pointsDelta {
    final prev = previousPercent;
    return prev == null ? null : latestPercent - prev;
  }
}

/// Latest vs previous per-subject %, sorted worst-first so the
/// weakest subjects show at the top. Empty when fewer than two
/// attempts exist or neither attempt recorded subjects.
List<SubjectDelta> subjectImprovement(
  AttemptRecord latest,
  AttemptRecord? previous,
) {
  if (previous == null) return [];
  final cur = decodePerSubject(latest.perSubjectJson);
  final prev = decodePerSubject(previous.perSubjectJson);
  final labels = {...cur.keys, ...prev.keys}.toList()..sort();
  final out = <SubjectDelta>[];
  for (final label in labels) {
    final c = cur[label];
    final p = prev[label];
    final latestPct = c == null || c['total'] == 0
        ? 0.0
        : (c['correct']! / c['total']!) * 100;
    final prevPct = p == null || p['total'] == 0
        ? null
        : (p['correct']! / p['total']!) * 100;
    out.add(
      SubjectDelta(
        label: label,
        latestPercent: latestPct,
        previousPercent: prevPct,
      ),
    );
  }
  out.sort((a, b) => a.latestPercent.compareTo(b.latestPercent));
  return out;
}
