import 'package:flutter/material.dart';

import '../models/exam.dart';
import '../models/question.dart';
import '../services/book_selection.dart';
import '../services/book_structure.dart';
import '../services/storage_service.dart';
import '../services/subscription_service.dart';
import '../services/test_generator.dart';
import '../widgets/developer_credit_footer.dart';
import '../widgets/upgrade_button.dart';
import 'book_selection_screen.dart';
import 'test_screen.dart';
import 'upgrade_screen.dart';

/// Test setup — exam pattern, size, and "aaj kya tayyar kiya" checklist.
/// The test is generated ONLY from the ticked sources.
///
/// FREEMIUM: free users get 3 tests per calendar month. Generating a
/// test consumes one. When the limit is reached, the Generate button
/// opens the Upgrade screen.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.exam});

  final ExamPattern exam;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  List<BookSource> _sources = [];
  final Set<String> _selected = {};

  /// Per-source part/range selection (v1.2): "Is book ke kis hisse
  /// se test banayein?" — the test pool is ONLY the selection.
  final Map<String, BookSelection> _selections = {};
  int _count = 50;
  int _available = 0;
  bool _loading = true;
  bool _isPremium = false;
  int _testsRemaining = SubscriptionService.freeTestLimit;
  bool _generating = false;
  bool _firstLoad = true;

  List<int> get _sizeOptions {
    if (widget.exam.id == 'css_mpt') return [25, 50, 100, 200];
    return [25, 50, 100];
  }

  bool get _canGenerate => _isPremium || _testsRemaining > 0;

  @override
  void initState() {
    super.initState();
    _count = widget.exam.id == 'css_mpt' ? 100 : 50;
    _load();
  }

  Future<void> _load() async {
    final sources = await StorageService.instance.getSources();
    final sub = SubscriptionService.instance;
    final premium = await sub.isPremium();
    final remaining = await sub.testsRemaining();
    if (!mounted) return;
    setState(() {
      _sources = sources;
      // AUDIT m3: pre-select all sources ONLY on first load — coming
      // back from a test used to re-tick everything the user unticked.
      if (_firstLoad) {
        _selected.addAll(sources.map((s) => s.id));
        _firstLoad = false;
      }
      _isPremium = premium;
      _testsRemaining = remaining;
      _loading = false;
    });
    await _refreshAvailable();
  }

  Future<void> _refreshAvailable() async {
    final count = await StorageService.instance.questionCountForSources(
      _selected,
    );
    if (!mounted) return;
    setState(() => _available = count);
  }

  void _openUpgrade() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const UpgradeScreen()),
    ).then((_) => _load());
  }

  /// Opens the selection screen for one saved book (v1.2): parts
  /// come from the stored questions' `part` field, the page range
  /// from the highest stored page. A book with no parts and one page
  /// has nothing to select — the user is told so honestly.
  Future<void> _pickPartsForSource(BookSource source) async {
    final parts = await StorageService.instance.getPartsForSource(
      source.id,
    );
    final maxPage = await StorageService.instance.maxPageForSource(
      source.id,
    );
    if (!mounted) return;
    if (parts.isEmpty && maxPage <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Is book mein koi hisse nahi mile — poori book se test banega.',
          ),
        ),
      );
      return;
    }
    final selection = await Navigator.push<BookSelection>(
      context,
      MaterialPageRoute(
        builder: (_) => BookSelectionScreen(
          parts: parts
              .map(
                (p) => BookPart(
                  title: p.title,
                  startPage: p.startPage,
                  endPage: p.endPage,
                  questionCount: p.count,
                ),
              )
              .toList(),
          totalPages: maxPage,
          initial: _selections[source.id],
        ),
      ),
    );
    if (selection == null) return;
    setState(() {
      if (selection.isWholeBook) {
        _selections.remove(source.id);
      } else {
        _selections[source.id] = selection;
      }
    });
  }

  Future<void> _generate() async {
    // AUDIT F5: no _busy guard meant two rapid taps recorded 2 tests
    // and pushed 2 TestScreens.
    if (_generating) return;
    if (!_canGenerate) {
      _openUpgrade();
      return;
    }
    if (_selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tick at least one paper / book first.'),
        ),
      );
      return;
    }
    if (_available == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No MCQs in the selected sources. Upload a book first.',
          ),
        ),
      );
      return;
    }
    setState(() => _generating = true);
    try {
      final bank = await StorageService.instance.getQuestionsBySources(
        _selected,
      );
      // Apply per-source part/range selections (v1.2): the pool is
      // ONLY the selected parts/pages of each book.
      final pool = bank.where((q) {
        final selection = _selections[q.sourceId];
        if (selection == null || selection.isWholeBook) return true;
        return selection.apply([q]).isNotEmpty;
      }).toList();
      final take = _count > pool.length ? pool.length : _count;
      if (take == 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Selection mein koi MCQ nahi — hissa badlein ya poori book lein.',
              ),
            ),
          );
        }
        return;
      }
      final questions = generateTest(
        bank: pool,
        sourceIds: _selected,
        count: take,
      );
      if (questions.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'No MCQs could be picked from the selected sources.',
              ),
            ),
          );
        }
        return;
      }
      final minutes = widget.exam.minutesFor(take);
      // AUDIT F5: the free-test credit is consumed only AFTER a test
      // was actually generated (a failure above used to burn a test
      // with no test delivered). Premium users never consume the
      // counter (enforced inside recordTestGenerated).
      await SubscriptionService.instance.recordTestGenerated();
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => TestScreen(
            questions: questions,
            exam: widget.exam,
            durationMinutes: minutes,
          ),
        ),
      ).then((_) => _load());
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // AUDIT F11: the UI used to show minutes for the REQUESTED size
    // while the test ran minutes for the EFFECTIVE size (e.g. "23 min"
    // shown, 10 min run when only 10 MCQs exist). Show the real one.
    final take = _count > _available ? _available : _count;
    final minutes = widget.exam.minutesFor(take);
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.exam.shortName} — New Test'),
        // v1.2 (user): RED UPGRADE button, top corner.
        actions: [UpgradeAppBarButton(onReturn: _load)],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.schedule),
                    title: Text(widget.exam.patternLabel),
                    subtitle: Text(
                      'Pass: ${widget.exam.passPercent.toStringAsFixed(0)}% • '
                      'Negative: -${widget.exam.negativeMarking} per wrong answer',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  color: _canGenerate
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.errorContainer,
                  child: ListTile(
                    leading: Icon(
                      _isPremium ? Icons.workspace_premium : Icons.lock_open,
                    ),
                    title: Text(
                      _isPremium
                          ? 'Premium — unlimited tests'
                          : 'Free tests left: $_testsRemaining / ${SubscriptionService.freeTestLimit}',
                    ),
                    subtitle: _canGenerate
                        ? const Text(
                            'Generating this test uses 1 free test.',
                          )
                        : const Text(
                            'You have used this month\'s 3 free tests. '
                            'Upgrade to Premium for unlimited tests.',
                          ),
                    trailing: _isPremium
                        ? null
                        : TextButton(
                            onPressed: _openUpgrade,
                            child: const Text('Upgrade'),
                          ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'How many questions?',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: _sizeOptions.map((n) {
                    return ChoiceChip(
                      label: Text('$n MCQs'),
                      selected: _count == n,
                      onSelected: (_) => setState(() => _count = n),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 8),
                Text(
                  'Time: $minutes minutes (auto-set from the ${widget.exam.shortName} '
                  'pattern for $take questions). Time khatam hote hi test auto-submit ho jayega.',
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // v1.2: title flexes — the old fixed Row clipped
                    // at 360px / large text.
                    Expanded(
                      child: Text(
                        'Aaj kya tayyar kiya? (tick karein)',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        setState(() {
                          if (_selected.length == _sources.length) {
                            _selected.clear();
                          } else {
                            _selected.addAll(_sources.map((s) => s.id));
                          }
                        });
                        await _refreshAvailable();
                      },
                      child: Text(
                        _selected.length == _sources.length
                            ? 'Clear all'
                            : 'Select all',
                      ),
                    ),
                  ],
                ),
                Text(
                  'Test sirf tick kiye hue sources mein se banega — '
                  'jaise aaj aap ne 5 past papers tayyar kiye hon.',
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                ..._sources.map(
                  (s) => CheckboxListTile(
                    value: _selected.contains(s.id),
                    onChanged: (v) async {
                      setState(() {
                        if (v == true) {
                          _selected.add(s.id);
                        } else {
                          _selected.remove(s.id);
                        }
                      });
                      await _refreshAvailable();
                    },
                    title: Text(s.title),
                    subtitle: Text(
                      '${s.kindLabel} • ${s.questionCount} MCQs'
                      '${_selections[s.id] != null && !_selections[s.id]!.isWholeBook ? ' • ${_selections[s.id]!.describe()}' : ''}',
                    ),
                    secondary: IconButton(
                      icon: const Icon(Icons.tune),
                      tooltip: 'Hissa chunein — is book ke kis hisse se test banayein?',
                      onPressed: () => _pickPartsForSource(s),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  color: _available >= _count
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.errorContainer,
                  child: ListTile(
                    leading: const Icon(Icons.quiz),
                    title: Text(
                      _available >= _count
                          ? 'Ready: $_count questions from $_available available MCQs'
                          : 'Only $_available MCQs available in ticked sources — '
                              'test will use all $_available. Upload more to reach $_count.',
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _generating ? null : _generate,
                  icon: Icon(_canGenerate ? Icons.play_arrow : Icons.lock),
                  label: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      _canGenerate
                          ? 'Generate Test — Test banao'
                          : 'Free limit reached — Upgrade to Premium',
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                ),
                // v1.2: developer credit — last item of the scroll view.
                const DeveloperCreditFooter(),
              ],
            ),
    );
  }
}
