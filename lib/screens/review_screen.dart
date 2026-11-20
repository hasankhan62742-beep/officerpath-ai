import 'package:flutter/material.dart';

import '../services/test_generator.dart';
import '../theme/app_theme.dart';
import '../widgets/developer_credit_footer.dart';

/// Full review: every question with the user's answer vs the correct one
/// plus the explanation.
class ReviewScreen extends StatelessWidget {
  const ReviewScreen({super.key, required this.result});

  final AttemptResult result;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Review Answers')),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: result.questions.length + 1,
        itemBuilder: (context, i) {
          // v1.2: developer credit — last item of the list.
          if (i == result.questions.length) {
            return const DeveloperCreditFooter();
          }
          final q = result.questions[i];
          final chosen = result.answers[i];
          // No-answers mode (20 Nov 2026): a question with no attached
          // answer was never judged — it is neither correct nor wrong,
          // and no "correct answer" exists to reveal.
          final hasAnswer = q.hasAnswer;
          final wasCorrect = hasAnswer && chosen == q.correctIndex;
          final wasSkipped = chosen == null;
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // v1.2: Wrap, not a fixed Row — "Q 1 • subject" +
                  // status + Marked + −0.25 clipped at 360px.
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      Chip(
                        label: Text('Q ${i + 1} • ${q.subject.label}'),
                      ),
                      Chip(
                        label: Text(
                          !hasAnswer
                              ? 'No answer'
                              : wasSkipped
                                  ? 'Skipped'
                                  : wasCorrect
                                      ? 'Correct'
                                      : 'Wrong',
                        ),
                        backgroundColor: !hasAnswer
                            ? Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest
                            : wasSkipped
                                ? Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest
                                : wasCorrect
                                    ? Theme.of(context)
                                        .colorScheme
                                        .primaryContainer
                                    : Theme.of(context)
                                        .colorScheme
                                        .errorContainer,
                      ),
                      if (result.markedForReview.contains(i))
                        const Chip(label: Text('Marked')),
                      // Exam mode: every wrong answer costs −0.25.
                      // Answerless questions are never scored, so no
                      // deduction chip for them.
                      if (hasAnswer && !wasSkipped && !wasCorrect)
                        const Chip(
                          label: Text('−0.25'),
                          backgroundColor: Colors.red,
                          labelStyle: TextStyle(color: Colors.white),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    q.text,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...List.generate(4, (opt) {
                    final isCorrect = hasAnswer && opt == q.correctIndex;
                    final isChosen = opt == chosen;
                    return ListTile(
                      dense: true,
                      leading: CircleAvatar(
                        radius: 14,
                        backgroundColor: isCorrect
                            ? Colors.green
                            : (hasAnswer && isChosen)
                                ? Colors.red
                                : Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                        foregroundColor: isCorrect || (hasAnswer && isChosen)
                            ? Colors.white
                            : Theme.of(context).colorScheme.onSurface,
                        child: Text(
                          String.fromCharCode(65 + opt),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      title: Text(q.options[opt]),
                      trailing: isCorrect
                          ? const Icon(Icons.check, color: Colors.green)
                          : (hasAnswer && isChosen)
                              ? const Icon(Icons.close, color: Colors.red)
                              : null,
                    );
                  }),
                  if (!hasAnswer)
                    const Text(
                      'Is question ka jawab nahi hai — score nahi hua.',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    )
                  else if (wasSkipped || !wasCorrect)
                    Text(
                      'Correct answer: ${q.correctLetter} — ${q.options[q.correctIndex]}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  if (q.explanation.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        // v1.2: goldTint, not amber.shade50 — the pale
                        // amber + white (dark-mode) text was unreadable.
                        color: AppTheme.goldTint(context),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('Explanation: ${q.explanation}'),
                    ),
                  ],
                  Text(
                    'Source: ${q.sourceLabel}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
