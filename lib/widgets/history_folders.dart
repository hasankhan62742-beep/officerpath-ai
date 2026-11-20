import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/question.dart';
import '../theme/app_theme.dart';
import 'history_groups.dart';
import 'progress_chart.dart';

/// Improvement analytics + in-app folders for the History screen.
///
/// Everything here renders data that already exists on the device.
/// Nothing is invented: one attempt shows "take another test to see
/// your trend", zero attempts shows an honest empty state, and the
/// improvement line always compares the last TWO real attempts.

/// Overall improvement card: trend chart (score % over attempts),
/// improvement indicator vs the last attempt, and per-subject
/// progress bars. Shown at the top of History.
class ImprovementCard extends StatelessWidget {
  const ImprovementCard({
    super.key,
    required this.attempts,
    this.passPercent = 40,
  });

  /// All attempts, any order (sorted inside).
  final List<AttemptRecord> attempts;

  /// Pass mark of the most recent attempt's exam, for the trend
  /// chart's pass line (CSS MPT passes at 33%, not 40%).
  final double passPercent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (attempts.isEmpty) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.trending_up),
          title: Text('Improvement — no results yet'),
          subtitle: Text(
            'Take your first test and your improvement trend will '
            'appear here. No fake chart until there is real data.',
          ),
        ),
      );
    }
    final delta = improvementDelta(attempts);
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
    final trend = sorted.reversed
        .take(10)
        .map((a) => a.percent.clamp(0.0, 100.0))
        .toList()
        .reversed
        .toList();
    final subjects = subjectImprovement(latest, delta.previous);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.trending_up, color: AppTheme.gold),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Improvement',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (!delta.hasPrevious) ...[
              Text(
                'Latest: ${latest.percent.toStringAsFixed(1)}% '
                '(${latest.examName}).',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                'Only 1 attempt so far — take another test and the '
                'improvement vs your last attempt will show here.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ] else ...[
              _DeltaLine(delta: delta),
              const SizedBox(height: 4),
              Text(
                delta.improved
                    ? 'Behtri aa rahi hai — isi tarah jari rakhein!'
                    : delta.declined
                    ? 'Neeche gaya — weak topics revise karein.'
                    : 'Barabar raha — agle test mein behtri ki koshish karein.',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Score trend — last ${trend.length} tests',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              ProgressChart(percents: trend, passPercent: passPercent),
              if (subjects.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  'Per-subject progress (latest vs previous test)',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                ...subjects.map((s) => _SubjectBar(delta: s)),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _DeltaLine extends StatelessWidget {
  const _DeltaLine({required this.delta});

  final ImprovementDelta delta;

  @override
  Widget build(BuildContext context) {
    final marks = delta.marksDelta;
    final sign = marks > 0
        ? '+'
        : '';
    final changeText = delta.percentChange == null
        ? '(from 0)'
        : '($sign${delta.percentChange!.toStringAsFixed(1)}%)';
    final label = delta.unchanged
        ? 'No change vs last attempt'
        : '$sign${marks.toStringAsFixed(0)} marks $changeText vs last attempt';    return Row(
      children: [
        Icon(
          delta.improved
              ? Icons.arrow_upward
              : delta.declined
              ? Icons.arrow_downward
              : Icons.remove,
          color: delta.improved
              ? AppTheme.success
              : delta.declined
              ? AppTheme.danger
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: delta.improved
                  ? AppTheme.success
                  : delta.declined
                  ? AppTheme.danger
                  : null,
            ),
          ),
        ),
      ],
    );
  }
}

class _SubjectBar extends StatelessWidget {
  const _SubjectBar({required this.delta});

  final SubjectDelta delta;

  @override
  Widget build(BuildContext context) {
    final d = delta.pointsDelta;
    final deltaText = d == null
        ? 'new'
        : d > 0
        ? '+${d.toStringAsFixed(0)} pts'
        : d < 0
        ? '${d.toStringAsFixed(0)} pts'
        : 'same';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  delta.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '${delta.latestPercent.toStringAsFixed(0)}%',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 8),
              Text(
                deltaText,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: d == null
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : d > 0
                      ? AppTheme.success
                      : d < 0
                      ? AppTheme.danger
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: (delta.latestPercent.clamp(0, 100)) / 100,
            color: delta.latestPercent >= 60
                ? AppTheme.success
                : delta.latestPercent >= 40
                ? Colors.amber
                : AppTheme.danger,
          ),
        ],
      ),
    );
  }
}

/// Date-wise / book-wise folders for History.
///
/// Two views, switched with a segmented control:
/// * Date — Today / Yesterday / This Week / calendar-date folders.
/// * Book — one folder per book the test was drawn from (DB v3
///   `AttemptRecord.bookTitle`; pre-v1.2 attempts fall back to the
///   exam title, so old folders still read as exam-title folders).
/// Tapping a folder expands it to its results; each folder shows its
/// attempt count, best score and latest score. The download callbacks
/// hand the file work to the History screen (share sheet).
class HistoryFoldersView extends StatefulWidget {
  const HistoryFoldersView({
    super.key,
    required this.attempts,
    required this.onDownloadAttempt,
    required this.onDownloadGroup,
  });

  final List<AttemptRecord> attempts;

  /// Share one result's PDF.
  final void Function(AttemptRecord attempt) onDownloadAttempt;

  /// Share a whole folder's combined PDF.
  final void Function(AttemptGroup group) onDownloadGroup;

  @override
  State<HistoryFoldersView> createState() => _HistoryFoldersViewState();
}

enum _FolderView { date, book }

class _HistoryFoldersViewState extends State<HistoryFoldersView> {
  _FolderView _view = _FolderView.date;
  final Set<String> _expanded = {};

  @override
  Widget build(BuildContext context) {
    final groups = _view == _FolderView.date
        ? groupAttemptsByDate(widget.attempts)
        : groupAttemptsByExam(widget.attempts);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Results folders',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            SegmentedButton<_FolderView>(
              segments: const [
                ButtonSegment(
                  value: _FolderView.date,
                  label: Text('By date'),
                  icon: Icon(Icons.calendar_month, size: 18),
                ),
                ButtonSegment(
                  value: _FolderView.book,
                  label: Text('By book'),
                  icon: Icon(Icons.book, size: 18),
                ),
              ],
              selected: {_view},
              onSelectionChanged: (s) => setState(() => _view = s.first),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _view == _FolderView.date
              ? 'Tap a folder to see its results — or download the whole day as one PDF.'
              : 'One folder per exam / paper title. (A stored result knows '
                    'its exam, not the book it was drawn from.)',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        ...groups.map((g) => _FolderCard(
              group: g,
              expanded: _expanded.contains(g.id),
              onToggle: () => setState(() {
                if (_expanded.contains(g.id)) {
                  _expanded.remove(g.id);
                } else {
                  _expanded.add(g.id);
                }
              }),
              onDownloadAttempt: widget.onDownloadAttempt,
              onDownloadGroup: widget.onDownloadGroup,
            )),
      ],
    );
  }
}

class _FolderCard extends StatelessWidget {
  const _FolderCard({
    required this.group,
    required this.expanded,
    required this.onToggle,
    required this.onDownloadAttempt,
    required this.onDownloadGroup,
  });

  final AttemptGroup group;
  final bool expanded;
  final VoidCallback onToggle;
  final void Function(AttemptRecord attempt) onDownloadAttempt;
  final void Function(AttemptGroup group) onDownloadGroup;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final delta = improvementDelta(group.attempts);
    final dateFmt = DateFormat('dd MMM, hh:mm a');
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: Icon(
              expanded ? Icons.folder_open : Icons.folder,
              color: AppTheme.gold,
            ),
            title: Text(
              group.title,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(group.subtitle),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.download),
                  tooltip: 'Download folder as PDF',
                  onPressed: () => onDownloadGroup(group),
                ),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                ),
              ],
            ),
            onTap: onToggle,
          ),
          if (expanded) ...[
            if (delta.hasPrevious)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: _DeltaLine(delta: delta),
              ),
            const Divider(height: 1),
            ...group.attempts.map((a) {
              final when = DateTime.tryParse(a.attemptedAtIso);
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor:
                      a.passed ? AppTheme.success : AppTheme.danger,
                  foregroundColor: Colors.white,
                  child: Text(
                    a.percent.clamp(0, 100).toStringAsFixed(0),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                title: Text(
                  '${a.examName} — ${a.score.toStringAsFixed(1)} / ${a.totalQuestions}',
                ),
                subtitle: Text(
                  '${a.correct} correct • ${a.wrong} wrong • '
                  '${a.skipped} skipped • '
                  '${when == null ? 'Unknown date' : dateFmt.format(when)}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Chip(
                      label: Text(a.passed ? 'PASS' : 'FAIL'),
                      backgroundColor: a.passed
                          ? scheme.primaryContainer
                          : scheme.errorContainer,
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      icon: const Icon(Icons.download),
                      tooltip: 'Download this result (PDF)',
                      onPressed: () => onDownloadAttempt(a),
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }
}
