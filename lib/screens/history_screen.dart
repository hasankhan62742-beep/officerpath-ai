import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/exam.dart';
import '../models/question.dart';
import '../services/storage_service.dart';
import '../widgets/developer_credit_footer.dart';
import '../widgets/upgrade_button.dart';
import '../widgets/history_folders.dart';
import '../widgets/history_groups.dart';
import '../widgets/result_export.dart';

/// History + progress, v1.2.
///
/// Same stored attempts as v1.1, organised on top of the existing
/// trend data (nothing replaced):
/// * [ImprovementCard] — overall trend chart + improvement vs the
///   last attempt + per-subject progress (all local, never invented).
/// * [HistoryFoldersView] — results in folders, by date (Today /
///   Yesterday / This Week / calendar date) or by book (exam/paper
///   title). Tapping a folder shows its results with count, best and
///   latest score.
/// * Downloads — one result, one whole folder, or a date range, as
///   PDF. v1.3 fix: a Download really downloads (MediaStore save to
///   the phone's Downloads folder); the share sheet is the fallback
///   when the save fails. Fully offline.
///   v1.2: a stored attempt records its book title (DB v3,
///   `AttemptRecord.bookTitle`), so book folders are truly per-book
///   for new attempts; pre-v1.2 attempts fall back to the exam title.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<AttemptRecord> _attempts = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final attempts = await StorageService.instance.getAttempts();
    if (!mounted) return;
    setState(() {
      _attempts = attempts;
      _loading = false;
    });
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text(
          'This deletes all saved attempts and progress.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await StorageService.instance.clearAttempts();
      await _load();
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// v1.3 fix: a "Download" action really downloads — save to the
  /// phone's Downloads folder first; only if that fails, fall back
  /// to the share sheet (so the user always has a way out).
  Future<void> _downloadAttempt(AttemptRecord a) async {
    final saved = await saveResultPdfToDownloads(a);
    if (saved != null) {
      if (mounted) {
        _showMessage('PDF Downloads mein save ho gaya: '
            '${resultPdfFileName(a)}');
      }
      return;
    }
    final ok = await shareResultPdf(a);
    if (!ok && mounted) {
      _showMessage('Could not save or share that result — try again.');
    }
  }

  Future<void> _downloadGroup(AttemptGroup group) async {
    if (group.attempts.isEmpty) return;
    final dates = group.attempts
        .map((a) => DateTime.tryParse(a.attemptedAtIso))
        .whereType<DateTime>()
        .toList();
    final from = dates.isEmpty
        ? DateTime.now()
        : dates.reduce((a, b) => a.isBefore(b) ? a : b);
    final to = dates.isEmpty
        ? DateTime.now()
        : dates.reduce((a, b) => a.isAfter(b) ? a : b);
    final saved = await saveResultsPdfToDownloads(group.attempts, from, to);
    if (saved != null) {
      if (mounted) {
        _showMessage('PDF Downloads mein save ho gaya: '
            '${resultsPdfFileName(from, to)}');
      }
      return;
    }
    final ok = await shareResultsPdf(group.attempts, from, to);
    if (!ok && mounted) {
      _showMessage('Could not save or share that folder — try again.');
    }
  }

  /// Date-range download: pick a from/to date, share one combined PDF
  /// with every result in the range, newest first.
  Future<void> _downloadRange() async {
    if (_attempts.isEmpty) {
      _showMessage('No results to download yet.');
      return;
    }
    final dates = _attempts
        .map((a) => DateTime.tryParse(a.attemptedAtIso))
        .whereType<DateTime>()
        .toList();
    if (dates.isEmpty) {
      _showMessage('No results to download yet.');
      return;
    }
    var from = dates.reduce((a, b) => a.isBefore(b) ? a : b);
    var to = dates.reduce((a, b) => a.isAfter(b) ? a : b);
    final fmt = DateFormat('dd MMM yyyy');
    final picked = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Download results by date'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'One combined PDF with every result in the range, '
                'newest first. Shared via the share sheet — pick '
                'Downloads, WhatsApp, Drive, etc.',
              ),
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('From'),
                subtitle: Text(fmt.format(from)),
                trailing: const Icon(Icons.calendar_month),
                onTap: () async {
                  final d = await showDatePicker(
                    context: ctx,
                    initialDate: from,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (d != null) setDialogState(() => from = d);
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('To'),
                subtitle: Text(fmt.format(to)),
                trailing: const Icon(Icons.calendar_month),
                onTap: () async {
                  final d = await showDatePicker(
                    context: ctx,
                    initialDate: to,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (d != null) setDialogState(() => to = d);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Download PDF'),
            ),
          ],
        ),
      ),
    );
    if (picked != true || !mounted) return;
    final dayFrom = DateTime(from.year, from.month, from.day);
    final dayTo = DateTime(to.year, to.month, to.day, 23, 59, 59);
    final inRange = _attempts.where((a) {
      final d = DateTime.tryParse(a.attemptedAtIso);
      return d != null && !d.isBefore(dayFrom) && !d.isAfter(dayTo);
    }).toList();
    if (inRange.isEmpty) {
      _showMessage('No results in that date range.');
      return;
    }
    final saved = await saveResultsPdfToDownloads(inRange, from, to);
    if (saved != null) {
      if (mounted) {
        _showMessage('PDF Downloads mein save ho gaya: '
            '${resultsPdfFileName(from, to)}');
      }
      return;
    }
    final ok = await shareResultsPdf(inRange, from, to);
    if (!ok && mounted) {
      _showMessage('Could not save or share those results — try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    // AUDIT F18: stored percents from before the v1.1 clamp could be
    // negative — the average and avatars floor at 0.
    final avg = _attempts.isEmpty
        ? 0.0
        : (_attempts.map((a) => a.percent.clamp(0, 100)).reduce(
                  (a, b) => a + b,
                ) /
                _attempts.length);
    final passed = _attempts.where((a) => a.passed).length;
    // AUDIT F15: the chart's pass line was hardcoded at 40%, but CSS
    // MPT passes at 33%. Use the most recent attempt's exam.
    final recentPass = _attempts.isEmpty
        ? 40.0
        : ExamPattern.byId(_attempts.first.examId).passPercent;
    return Scaffold(
      appBar: AppBar(
        title: const Text('History & Progress'),
        actions: [
          // v1.2 (user): RED UPGRADE button, top corner.
          const UpgradeAppBarButton(),
          if (_attempts.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.download),
              tooltip: 'Download results by date',
              onPressed: _downloadRange,
            ),
          if (_attempts.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Clear history',
              onPressed: _clear,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _attempts.isEmpty
              ? Column(
                  children: [
                    const Expanded(
                      child: Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'No attempts yet.\nTake your first test from the home screen!',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                    // v1.2: developer credit — empty state too.
                    const DeveloperCreditFooter(),
                  ],
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // Overall stats (v1.1) + improvement analytics (v1.2).
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          'Tests: ${_attempts.length} • '
                          'Average: ${avg.toStringAsFixed(1)}% • '
                          'Passed: $passed',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ImprovementCard(
                      attempts: _attempts,
                      passPercent: recentPass,
                    ),
                    const SizedBox(height: 16),
                    HistoryFoldersView(
                      attempts: _attempts,
                      onDownloadAttempt: _downloadAttempt,
                      onDownloadGroup: _downloadGroup,
                    ),
                    // v1.2: developer credit — last item of the scroll view.
                    const DeveloperCreditFooter(),
                  ],
                ),
    );
  }
}
