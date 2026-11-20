import 'dart:async';

import 'package:flutter/material.dart';

import '../models/exam.dart';
import '../models/question.dart';
import '../services/storage_service.dart';
import '../services/subscription_service.dart';
import '../services/test_generator.dart';
import '../services/test_progress_service.dart';
import '../theme/app_theme.dart';
import '../widgets/developer_credit_footer.dart';
import 'result_screen.dart';

/// Attempt screen — one question at a time, palette, mark-for-review,
/// countdown + auto-submit on timeout.
///
/// AUDIT C3: answers + remaining time are persisted to SharedPreferences
/// on every change, and the timer is a wall-clock deadline
/// (`startedAt + duration`), not a decrementing counter. If Android
/// kills the app mid-test, Home offers "Resume test" and the attempt
/// continues with the correct time left.
///
/// AUDIT C4: `isRetry` marks a "Retry Wrong Only" pass. Retries are
/// FREE (the original attempt already spent a test credit) and are
/// NOT saved as a new History attempt and do NOT affect the streak —
/// so the retry button can no longer bypass the 3/month paywall or
/// inflate tests-taken.
class TestScreen extends StatefulWidget {
  const TestScreen({
    super.key,
    required this.questions,
    required this.exam,
    required this.durationMinutes,
    this.isRetry = false,
    this.resume,
  });

  final List<Question> questions;
  final ExamPattern exam;
  final int durationMinutes;

  /// True for "Retry Wrong Only" — free, not saved to History.
  final bool isRetry;

  /// Saved progress to restore (Home "Resume test"). Null for a fresh test.
  final TestProgress? resume;

  @override
  State<TestScreen> createState() => _TestScreenState();
}

class _TestScreenState extends State<TestScreen> {
  int _index = 0;
  final Map<int, int?> _answers = {};
  final Set<int> _marked = {};
  late int _remainingSeconds;
  Timer? _timer;
  late final DateTime _startedAt;
  late final DateTime _deadline;
  bool _submitted = false;
  bool _dialogOpen = false;

  /// The section runs of this test (subject-grouped order, PPSC
  /// pattern): used to show a section banner when the section
  /// changes, e.g. "English — Q11–20".
  late final List<TestSection> _sections;

  /// The section that STARTS at [index] (0-based), or null when the
  /// question continues the previous section. A banner is shown only
  /// at a section start, so the user sees the grouping as the test
  /// progresses without a banner on every question.
  TestSection? _sectionStartingAt(int index) {
    for (final s in _sections) {
      if (s.start - 1 == index) return s;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _sections = testSections(widget.questions);
    final resume = widget.resume;
    _startedAt = resume?.startedAt ?? DateTime.now();
    _deadline = _startedAt.add(Duration(minutes: widget.durationMinutes));
    if (resume != null) {
      _answers.addAll(resume.answers);
      _marked.addAll(resume.marked);
    }
    _remainingSeconds = _deadline.difference(DateTime.now()).inSeconds;
    if (_remainingSeconds < 0) _remainingSeconds = 0;
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);
  }

  void _tick(Timer timer) {
    final left = _deadline.difference(DateTime.now()).inSeconds;
    if (left <= 0) {
      timer.cancel();
      if (mounted) setState(() => _remainingSeconds = 0);
      _submit(auto: true);
      return;
    }
    if (mounted) setState(() => _remainingSeconds = left);
  }

  @override
  void dispose() {
    _timer?.cancel();
    // Keep the attempt resumable if the user left without submitting.
    if (!_submitted && !widget.isRetry) _persistProgress();
    super.dispose();
  }

  String get _timeLabel {
    final m = _remainingSeconds ~/ 60;
    final s = _remainingSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  int get _answered => _answers.values.where((v) => v != null).length;

  /// Saves current progress for Home "Resume test". Skipped for retries
  /// and when any question has no db id (resume needs stable ids).
  Future<void> _persistProgress() async {
    if (widget.isRetry || _submitted) return;
    final ids = widget.questions.map((q) => q.id).toList();
    if (ids.any((id) => id == null)) return;
    await TestProgressService.instance.save(
      TestProgress(
        examId: widget.exam.id,
        durationMinutes: widget.durationMinutes,
        startedAtIso: _startedAt.toIso8601String(),
        questionIds: ids.whereType<int>().toList(),
        answers: {
          for (final e in _answers.entries)
            if (e.value != null) e.key: e.value!,
        },
        marked: _marked,
      ),
    );
  }

  Future<void> _submit({bool auto = false}) async {
    if (_submitted) return;
    _submitted = true;
    _timer?.cancel();
    final durationSeconds = DateTime.now().difference(_startedAt).inSeconds;
    final result = scoreAttempt(
      questions: widget.questions,
      answers: _answers,
      markedForReview: _marked,
      exam: widget.exam,
      durationSeconds: durationSeconds,
    );
    // AUDIT F9: a failing save must never strand the user on this
    // screen. The result is shown even if the save fails (Result
    // shows a "could not be saved" banner); _submitted is reset so a
    // retry is possible if navigation itself fails.
    // No-answers mode (20 Nov 2026): a test whose questions ALL lack
    // answers has no result at all — there is nothing honest to
    // record in History (a 0% FAIL would be a lie), and no score to
    // sync to the server. Mixed tests save normally (scored counts
    // only); the Result screen states how many were unscored.
    var saveFailed = false;
    if (!widget.isRetry && !result.allUnscored) {
      try {
        final record = result.toRecord(
          examId: widget.exam.id,
          examName: widget.exam.shortName,
          attemptedAtIso: DateTime.now().toIso8601String(),
        );
        await StorageService.instance.saveAttempt(record);
        // v2.0.0: best-effort cloud backup + server monthly count.
        // Fire-and-forget on purpose — a slow/failed sync must never
        // delay the Result screen. Offline or signed out, this is a
        // no-op; the local history is the source of truth.
        unawaited(
          SubscriptionService.instance.syncTestResultToServer(
            examName: record.examName,
            score: record.score.round(),
            total: record.totalQuestions,
            bookTitle: record.bookTitle.isEmpty ? null : record.bookTitle,
          ),
        );
      } catch (_) {
        saveFailed = true;
        _submitted = false;
      }
    }
    await TestProgressService.instance.clear();
    if (!mounted) return;
    // AUDIT F10: if the timer fired under an open dialog, dismiss the
    // dialog first — otherwise it stays on top of the Result screen.
    if (_dialogOpen) {
      Navigator.of(context).pop();
      _dialogOpen = false;
    }
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ResultScreen(
          result: result,
          exam: widget.exam,
          autoSubmitted: auto,
          saveFailed: saveFailed,
        ),
      ),
    );
  }

  Future<bool> _confirmExit() async {
    _dialogOpen = true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave the test?'),
        content: const Text(
          'Your progress is saved — you can resume this test from Home. '
          'It will not be counted as finished.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    _dialogOpen = false;
    return leave == true;
  }

  Future<void> _confirmSubmit() async {
    final unanswered = widget.questions.length - _answered;
    _dialogOpen = true;
    final submit = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Submit test?'),
        content: Text(
          'Answered: $_answered\n'
          'Unanswered: $unanswered\n'
          'Marked for review: ${_marked.length}\n'
          'Time left: $_timeLabel',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep solving'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Submit'),
          ),
        ],
      ),
    );
    _dialogOpen = false;
    if (submit == true) await _submit();
  }

  void _openPalette() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Question palette',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            // AUDIT m11: the legend was a fixed Row — it clipped at
            // large font scale. Wrap lets it flow to a second line.
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: const [
                _LegendDot(color: Colors.green, label: 'Answered'),
                _LegendDot(color: Colors.amber, label: 'Marked'),
                _LegendDot(color: Colors.grey, label: 'Not answered'),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(
              child: GridView.builder(
                shrinkWrap: true,
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 6,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                itemCount: widget.questions.length,
                itemBuilder: (c, i) {
                  final answered = _answers[i] != null;
                  final marked = _marked.contains(i);
                  final scheme = Theme.of(c).colorScheme;
                  return InkWell(
                    onTap: () {
                      setState(() => _index = i);
                      Navigator.pop(ctx);
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: answered
                            ? Colors.green
                            : marked
                                ? Colors.amber
                                : scheme.surfaceContainerHighest,
                        border: i == _index
                            ? Border.all(color: scheme.onSurface, width: 2)
                            : null,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(
                          // v1.2: navy text on the amber "marked" cell
                          // — white on amber was unreadable.
                          color: answered
                              ? Colors.white
                              : marked
                                  ? AppTheme.navyDark
                                  : scheme.onSurface,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // AUDIT F17: an empty question list used to crash (RangeError +
    // 0/0 = NaN progress). Setup guards it, but TestScreen must not
    // trust its caller.
    if (widget.questions.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Test')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 12),
                const Text(
                  'No questions in this test.',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 8),
                const Text(
                  'The question bank may have changed. Go back and '
                  'generate the test again.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Go back'),
                ),
                // v1.2: developer credit (empty-state screen too).
                const DeveloperCreditFooter(),
              ],
            ),
          ),
        ),
      );
    }
    final q = widget.questions[_index];
    final lowTime = _remainingSeconds <= 5 * 60;
    final chosen = _answers[_index];
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmExit()) {
          if (context.mounted) Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('Q ${_index + 1} / ${widget.questions.length}'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Chip(
                avatar: const Icon(Icons.timer, size: 18),
                visualDensity: VisualDensity.compact,
                label: Text(
                  _timeLabel,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: lowTime ? Colors.red : null,
                  ),
                ),
              ),
            ),
            // v1.2: icon instead of the "Submit" text button — the old
            // title + timer chip + text button overflowed the AppBar
            // at 360px / large text. Same action, same confirm dialog.
            IconButton(
              icon: const Icon(Icons.check),
              tooltip: 'Submit test',
              onPressed: _confirmSubmit,
            ),
          ],
        ),
        body: Column(
          children: [
            LinearProgressIndicator(
              value: widget.questions.isEmpty
                  ? 0
                  : _answered / widget.questions.length,
            ),
            // Exam mode banner — negative marking is always on in v1.
            // (There is NO practice mode in v1, so scores are never confused.)
            // v1.2: wraps to two lines instead of clipping at 360px.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                vertical: 6,
                horizontal: 8,
              ),
              color: AppTheme.goldSoft,
              child: const Text(
                'EXAM MODE  •  Correct +1  •  Wrong −0.25  •  Skipped 0',
                textAlign: TextAlign.center,
                softWrap: true,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: AppTheme.navy,
                ),
              ),
            ),
            // No-answers mode (20 Nov 2026): say so plainly while the
            // user is still answering — these questions can never be
            // marked right or wrong, so no result can be shown for them.
            if (widget.questions.any((q) => !q.hasAnswer))
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 6,
                  horizontal: 8,
                ),
                color: Theme.of(
                  context,
                ).colorScheme.errorContainer,
                child: Text(
                  '${widget.questions.where((q) => !q.hasAnswer).length} '
                  'question(s) ke jawab nahi hain — un ka score nahi '
                  'hoga (na sahi, na ghalat), aur un ka result nahi '
                  'dikhega.',
                  textAlign: TextAlign.center,
                  softWrap: true,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.05, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: ListView(
                  key: ValueKey<int>(_index),
                  padding: const EdgeInsets.all(16),
                  children: [
                    // Section banner — shown when the section changes
                    // (the test is subject-grouped: all GK, then all
                    // English, then all Maths, …). "English — Q11–20"
                    // tells the user where they are in the paper.
                    if (_sectionStartingAt(_index) case final section?)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 12,
                        ),
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: AppTheme.navy,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${section.label}  •  Q${section.start}–${section.end}',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    Row(
                      children: [
                        Chip(label: Text(q.subject.label)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            q.sourceLabel,
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (_marked.contains(_index))
                          const Chip(
                            label: Text(
                              'Marked',
                              style: TextStyle(
                                color: AppTheme.navyDark,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            backgroundColor: Colors.amber,
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      q.text,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 20,
                      ),
                    ),
                    const SizedBox(height: 16),
                    ...List.generate(4, (opt) {
                      final selected = chosen == opt;
                      return Card(
                        color: selected
                            ? Theme.of(context).colorScheme.primaryContainer
                            : null,
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          leading: CircleAvatar(
                            backgroundColor: selected
                                ? Theme.of(context).colorScheme.primary
                                : scheme.surfaceContainerHighest,
                            // v1.2: onPrimary, not white — in dark mode
                            // the primary is gold and white text on gold
                            // was unreadable.
                            foregroundColor: selected
                                ? Theme.of(context).colorScheme.onPrimary
                                : scheme.onSurface,
                            child: Text(String.fromCharCode(65 + opt)),
                          ),
                          title: Text(
                            q.options[opt],
                            style: const TextStyle(fontSize: 16),
                          ),
                          onTap: () {
                            setState(() => _answers[_index] = opt);
                            _persistProgress();
                          },
                        ),
                      );
                    }),
                    if (chosen != null)
                      TextButton(
                        onPressed: () {
                          setState(() => _answers.remove(_index));
                          _persistProgress();
                        },
                        child: const Text('Clear answer'),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              // AUDIT m11: four Expanded buttons in one Row clipped at
              // large font scale. A 2×2 Wrap keeps every label readable.
              child: LayoutBuilder(
                builder: (ctx, constraints) {
                  final w = (constraints.maxWidth - 8) / 2;
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      SizedBox(
                        width: w,
                        child: OutlinedButton(
                          onPressed: _index > 0
                              ? () => setState(() => _index--)
                              : null,
                          child: const Text('Previous'),
                        ),
                      ),
                      SizedBox(
                        width: w,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            setState(() {
                              if (_marked.contains(_index)) {
                                _marked.remove(_index);
                              } else {
                                _marked.add(_index);
                              }
                            });
                            _persistProgress();
                          },
                          icon: const Icon(Icons.flag_outlined),
                          label: Text(
                            _marked.contains(_index) ? 'Unmark' : 'Mark',
                          ),
                        ),
                      ),
                      SizedBox(
                        width: w,
                        child: OutlinedButton(
                          onPressed: _openPalette,
                          child: const Text('Palette'),
                        ),
                      ),
                      SizedBox(
                        width: w,
                        child: FilledButton(
                          onPressed: _index < widget.questions.length - 1
                              ? () => setState(() => _index++)
                              : _confirmSubmit,
                          child: Text(
                            _index < widget.questions.length - 1
                                ? 'Next'
                                : 'Submit',
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            // v1.2: developer credit — below the buttons, never over
            // the timer, options or submit button. The question list
            // above is Expanded, so this only shrinks it slightly.
            const DeveloperCreditFooter(),
          ],
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
