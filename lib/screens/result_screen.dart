import 'package:flutter/material.dart';

import '../models/exam.dart';
import '../services/test_generator.dart';
import '../widgets/developer_credit_footer.dart';
import '../widgets/result_export.dart';
import 'home_screen.dart';
import 'review_screen.dart';
import 'setup_screen.dart';
import 'test_screen.dart';

/// Result + evaluation: score with negative marking, pass/fail,
/// subject-wise breakdown, weak topics, time per question.
///
/// v1.2: the score ring animates in (arc sweep + count-up, ~900 ms);
/// the score line, PASS/FAIL badge and breakdown are static and
/// visible from the first frame, so the animation never delays the
/// result. Reduced motion shows the final ring at once.
/// The score card is wrapped in a [RepaintBoundary] so it can be
/// shared as a PNG; the PDF / PNG buttons below share the result.
class ResultScreen extends StatelessWidget {
  ResultScreen({
    super.key,
    required this.result,
    required this.exam,
    this.autoSubmitted = false,
    this.saveFailed = false,
  });

  final AttemptResult result;
  final ExamPattern exam;

  /// True when the timer ran out (AUDIT F10 — the auto-submit message
  /// used to be a SnackBar on the dying Test screen and was never seen).
  final bool autoSubmitted;

  /// True when the attempt could not be saved to History (AUDIT F9) —
  /// the score is still shown, with an honest banner.
  final bool saveFailed;

  /// Boundary around the score card, for the PNG export.
  final GlobalKey _cardKey = GlobalKey();

  Future<void> _downloadPdf(BuildContext context) async {
    final record = result.toRecord(
      examId: exam.id,
      examName: exam.shortName,
      attemptedAtIso: DateTime.now().toIso8601String(),
    );
    final fileName = resultPdfFileName(record);
    final saved = await saveResultPdfToDownloads(record);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          saved != null
              ? 'PDF Downloads mein save ho gaya: $fileName'
              : 'PDF save nahi ho saka — Share se try karein.',
        ),
      ),
    );
  }

  Future<void> _sharePdf(BuildContext context) async {
    final record = result.toRecord(
      examId: exam.id,
      examName: exam.shortName,
      attemptedAtIso: DateTime.now().toIso8601String(),
    );
    final ok = await shareResultPdf(record);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not share the PDF — try again.'),
        ),
      );
    }
  }

  Future<void> _sharePng(BuildContext context) async {
    final record = result.toRecord(
      examId: exam.id,
      examName: exam.shortName,
      attemptedAtIso: DateTime.now().toIso8601String(),
    );
    final ok = await shareResultPng(_cardKey, record);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not capture the card — try again.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pct = result.percent.clamp(0, 100) / 100;
    final minutes = result.durationSeconds ~/ 60;
    final seconds = result.durationSeconds % 60;
    return Scaffold(
      appBar: AppBar(title: const Text('Result — Natija')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (autoSubmitted)
            const Card(
              child: ListTile(
                leading: Icon(Icons.timer_off_outlined),
                title: Text('Time khatam — test auto-submit ho gaya.'),
              ),
            ),
          if (saveFailed)
            const Card(
              child: ListTile(
                leading: Icon(Icons.warning_amber_outlined),
                title: Text(
                  'Result could not be saved to History (storage error). '
                  'Your score above is correct — take a screenshot.',
                ),
              ),
            ),
          RepaintBoundary(
            key: _cardKey,
            child: Card(
              color: result.passed
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    // v1.2: animated score ring. The arc sweeps and the
                    // % counts up; the score line + PASS/FAIL below are
                    // static, so the result is readable immediately.
                    TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: pct),
                      duration:
                          MediaQuery.of(context).disableAnimations
                          ? Duration.zero
                          : const Duration(milliseconds: 900),
                      curve: Curves.easeOut,
                      builder: (context, value, _) {
                        return SizedBox(
                          width: 130,
                          height: 130,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              SizedBox.expand(
                                child: CircularProgressIndicator(
                                  value: value,
                                  strokeWidth: 10,
                                  color: result.passed
                                      ? Colors.green
                                      : Colors.red,
                                  backgroundColor: theme
                                      .colorScheme
                                      .surfaceContainerHighest,
                                ),
                              ),
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '${(value * 100).toStringAsFixed(1)}%',
                                    style: theme.textTheme.headlineSmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.bold,
                                        ),
                                  ),
                                  Text(
                                    result.passed ? 'PASS' : 'FAIL',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      // v1.2: theme containers, not
                                      // green/red.shade800 — the shades
                                      // were unreadable on the dark-mode
                                      // tinted card.
                                      color: result.passed
                                          ? theme
                                                .colorScheme
                                                .onPrimaryContainer
                                          : theme
                                                .colorScheme
                                                .onErrorContainer,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Score: ${result.score.toStringAsFixed(2)} / ${result.questions.length}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  Text(
                    'Pass mark: ${exam.passPercent.toStringAsFixed(0)}% • '
                    'Negative: -${exam.negativeMarking} × ${result.wrong} wrong '
                    '= -${(result.wrong * exam.negativeMarking).toStringAsFixed(2)}',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      Chip(
                        label: Text('Correct ${result.correct}'),
                        backgroundColor: theme.colorScheme.primaryContainer,
                      ),
                      Chip(
                        label: Text('Wrong ${result.wrong}'),
                        backgroundColor: theme.colorScheme.errorContainer,
                      ),
                      Chip(label: Text('Skipped ${result.skipped}')),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Time: ${minutes}m ${seconds}s • '
                    'Avg ${result.secondsPerQuestion.toStringAsFixed(1)}s per question',
                  ),
                ],
              ),
            ),
          ),
          ),
          const SizedBox(height: 16),
          // ---- Full score breakdown (exam mode: −0.25 per wrong) ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Score breakdown',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  _BreakdownRow(
                    label: 'Correct',
                    detail: '${result.correct} × +1',
                    value: '+${result.correct.toDouble().toStringAsFixed(2)}',
                  ),
                  _BreakdownRow(
                    label: 'Wrong',
                    detail:
                        '${result.wrong} × −${exam.negativeMarking}',
                    value:
                        '−${result.negativeDeduction(exam.negativeMarking).toStringAsFixed(2)}',
                  ),
                  _BreakdownRow(
                    label: 'Skipped',
                    detail: '${result.skipped} × 0',
                    value: '0.00',
                  ),
                  const Divider(),
                  _BreakdownRow(
                    label: 'Raw score',
                    detail: 'correct answers only',
                    value: result.rawScore.toStringAsFixed(2),
                    bold: true,
                  ),
                  _BreakdownRow(
                    label: 'Final score',
                    detail: 'raw − deduction',
                    value:
                        '${result.score.toStringAsFixed(2)} / ${result.questions.length}',
                    bold: true,
                  ),
                  _BreakdownRow(
                    label: 'Percentage',
                    detail:
                        'pass mark ${exam.passPercent.toStringAsFixed(0)}%',
                    value: '${result.percent.toStringAsFixed(1)}%',
                    bold: true,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Subject-wise breakdown',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          ...result.perSubject.entries.map((e) {
            final total = e.value['total']!;
            final correct = e.value['correct']!;
            final rate = total == 0 ? 0.0 : correct / total;
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // v1.2: long subject names flex instead of
                        // squeezing the "x / y" out.
                        Expanded(
                          child: Text(
                            e.key,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text('$correct / $total'),
                      ],
                    ),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: rate,
                      color: rate >= 0.6
                          ? Colors.green
                          : rate >= 0.4
                              ? Colors.amber
                              : Colors.red,
                    ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 16),
          Text(
            'Weak topics — revise these',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          ...result.weakSubjects
              .where((e) {
                final total = e.value['total']!;
                final correct = e.value['correct']!;
                return total > 0 && correct / total < 0.6;
              })
              .take(3)
              .map(
                (e) => ListTile(
                  leading: const Icon(Icons.trending_down, color: Colors.red),
                  title: Text(e.key),
                  subtitle: Text(
                    '${e.value['correct']} / ${e.value['total']} correct — '
                    'dobara tayyar karein.',
                  ),
                ),
              ),
          if (result.weakSubjects.every((e) {
            final total = e.value['total']!;
            return total == 0 || e.value['correct']! / total >= 0.6;
          }))
            const ListTile(
              leading: Icon(Icons.check_circle, color: Colors.green),
              title: Text('No weak subject — sab mein 60%+!'),
            ),
          const SizedBox(height: 16),
          // v1.3 fix: "Download PDF" now REALLY downloads — it writes
          // the PDF into the phone's Downloads folder (MediaStore).
          // "Share PDF" opens the share sheet (WhatsApp / Drive).
          // "Share as image" shares a PNG of the card. All offline.
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _downloadPdf(context),
                  icon: const Icon(Icons.download),
                  label: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 10),
                    child: Text('Download PDF'),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _sharePdf(context),
                  icon: const Icon(Icons.share),
                  label: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 10),
                    child: Text('Share PDF'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _sharePng(context),
                  icon: const Icon(Icons.image),
                  label: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 10),
                    child: Text('Share as image'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ReviewScreen(result: result),
                ),
              );
            },
            icon: const Icon(Icons.rate_review),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Review Answers — Har sawal dekhein'),
            ),
          ),
          const SizedBox(height: 8),
          if (result.wrongQuestions.isNotEmpty)
            OutlinedButton.icon(
              onPressed: () {
                final wrong = result.wrongQuestions;
                // AUDIT C4: retries are FREE and are NOT saved as a new
                // History attempt (see TestScreen.isRetry) — the retry
                // button can no longer bypass the 3/month paywall.
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TestScreen(
                      questions: wrong,
                      exam: exam,
                      durationMinutes: exam
                          .minutesFor(wrong.length)
                          .clamp(10, 200),
                      isRetry: true,
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.replay),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Retry Wrong Only'),
              ),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                  builder: (_) => SetupScreen(exam: exam),
                ),
              );
            },
            icon: const Icon(Icons.add),
            label: const Text('New Test'),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () {
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const HomeScreen()),
                (route) => false,
              );
            },
            icon: const Icon(Icons.home),
            label: const Text('Back to Home'),
          ),
          // v1.2: developer credit — last item of the scroll view.
          const DeveloperCreditFooter(),
        ],
      ),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({
    required this.label,
    required this.detail,
    required this.value,
    this.bold = false,
  });

  final String label;
  final String detail;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = bold
        ? const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)
        : const TextStyle(fontSize: 15);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(label, style: style),
          ),
          Expanded(
            child: Text(
              detail,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
          Text(value, style: style),
        ],
      ),
    );
  }
}
