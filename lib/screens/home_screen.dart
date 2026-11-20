import 'package:flutter/material.dart';

import '../models/current_affairs.dart';
import '../models/exam.dart';
import '../models/question.dart';
import '../services/ca_cache_service.dart';
import '../services/push_service.dart';
import '../services/storage_service.dart';
import '../services/subscription_service.dart';
import '../services/test_progress_service.dart';
import '../theme/app_theme.dart';
import '../widgets/developer_credit_footer.dart';
import '../widgets/update_prompt.dart';
import '../widgets/upgrade_button.dart';
import 'about_screen.dart';
import 'current_affairs_screen.dart';
import 'history_screen.dart';
import 'profile_screen.dart';
import 'setup_screen.dart';
import 'test_screen.dart';
import 'upgrade_screen.dart';
import 'upload_screen.dart';

/// Home — one screen, no clutter:
/// hero (Apni Book Se Test), progress ring + streak, exam card,
/// today's prepared papers, next-test CTA.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.seedFailed = false});

  /// True when first-run seeding failed (AUDIT C2) — a retry banner
  /// is shown instead of the app dying before start.
  final bool seedFailed;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  ExamPattern _selectedExam = ExamPattern.all.first;
  int _testsTaken = 0;
  double _avgPercent = 0;
  double _bestPercent = 0;
  int _bankSize = 0;
  int _streakDays = 0;
  List<BookSource> _sources = [];
  List<CaItem> _caTop = [];
  DateTime? _caUpdated;
  int _testsRemaining = SubscriptionService.freeTestLimit;
  bool _isPremium = false;
  bool _loading = true;
  TestProgress? _resumeProgress;
  bool _seedBannerDismissed = false;

  @override
  void initState() {
    super.initState();
    _load();
    // In-app update check (v1.3): once per launch, delayed so it never
    // blocks the first paint. Silent unless a newer release exists.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) maybePromptForUpdate(context);
      });
    });
    // Push notifications (v2.0.0): register the token, ask permission
    // once (with an explanation first), and handle notification taps.
    // Runs after the first frame so it never blocks startup.
    WidgetsBinding.instance.addPostFrameCallback((_) => _setupPush());
  }

  /// Push setup for this Home open: foreground banner, tap handling,
  /// token registration, and the one-time permission question.
  /// Every step is best-effort — push is unavailable (or disabled)
  /// in offline builds, and nothing here may crash Home.
  Future<void> _setupPush() async {
    final push = PushService.instance;
    push.onForegroundMessage = (message) {
      if (!mounted) return;
      final destination = PushService.parseNotificationTap(message.data);
      final title = message.notification?.title ?? 'OfficerPath AI';
      final body = message.notification?.body ?? '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(body.isEmpty ? title : '$title\n$body'),
          duration: const Duration(seconds: 6),
          action: destination == PushDestination.update
              ? SnackBarAction(
                  label: 'Update dekhein',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AboutScreen(),
                      ),
                    );
                  },
                )
              : null,
        ),
      );
    };
    push.onTap = (destination) {
      if (!mounted) return;
      if (destination == PushDestination.update) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const AboutScreen()),
        );
      }
    };
    await push.initialize();
    await push.registerToken();
    if (!push.isAvailable) return;
    // Permission: ask at most once per install, AFTER first Home open,
    // with a short explanation first — never on the auth screen, never
    // blocking onboarding.
    if (!await push.permissionAsked && mounted) {
      final allow = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Notifications on karein?'),
          content: const Text(
            'Nayi version aaye ya koi zaroori announcement ho to aap ko '
            'notification mil jayegi. Aap ise Account settings se kabhi '
            'bhi band kar sakte hain.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abhi nahi'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Allow karein'),
            ),
          ],
        ),
      );
      if (allow == true) {
        await push.requestPermission();
      } else {
        // Record the ask even on "Abhi nahi" so it is not nagged again.
        // requestPermission() is only for the allow path; the flag is
        // also set by it — here we ask the service to remember the ask.
        await push.markPermissionAsked();
      }
    }
    // Cold start from a tapped notification.
    final initial = await push.consumeInitialMessage();
    if (initial == PushDestination.update && mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const AboutScreen()),
      );
    }
  }

  Future<void> _load() async {
    final storage = StorageService.instance;
    final lastExamId = await storage.getLastExamId();
    if (lastExamId != null) _selectedExam = ExamPattern.byId(lastExamId);
    final attempts = await storage.getAttempts();
    final sources = await storage.getSources();
    final sub = SubscriptionService.instance;
    final premium = await sub.isPremium();
    final remaining = await sub.testsRemaining();
    final resume = await TestProgressService.instance.load();
    var bank = 0;
    for (final s in sources) {
      bank += s.questionCount;
    }
    if (!mounted) return;
    setState(() {
      _testsTaken = attempts.length;
      _sources = sources;
      _isPremium = premium;
      _testsRemaining = remaining;
      _avgPercent = attempts.isEmpty
          ? 0
          : attempts
                    .map((a) => a.percent.clamp(0.0, 100.0).toDouble())
                    .reduce((a, b) => a + b) /
                attempts.length;
      _bestPercent = attempts.isEmpty
          ? 0
          : attempts
                .map((a) => a.percent.clamp(0.0, 100.0).toDouble())
                .reduce((a, b) => a > b ? a : b);
      _bankSize = bank;
      _streakDays = _computeStreak(
        attempts.map((a) => a.attemptedAtIso).toList(),
      );
      _resumeProgress = resume;
      _loading = false;
    });
    // Current Affairs: refresh in the background (cached headlines show
    // instantly; fresh fetch replaces them when it lands).
    _refreshCa();
  }

  Future<void> _refreshCa() async {
    final cache = CaCacheService.instance;
    await cache.loadFromCache();
    if (mounted) {
      setState(() {
        _caTop = cache.items
            .where((i) => i.category == 'Pakistan')
            .take(3)
            .toList();
        _caUpdated = cache.fetchedAt;
      });
    }
    try {
      await cache.refreshIfStale();
    } catch (_) {
      // Offline — cached headlines stay.
    }
    if (mounted) {
      setState(() {
        _caTop = cache.items
            .where((i) => i.category == 'Pakistan')
            .take(3)
            .toList();
        _caUpdated = cache.fetchedAt;
      });
    }
  }

  /// Consecutive days with at least one attempt, ending today or yesterday.
  static int _computeStreak(List<String> attemptIsoDates) {
    if (attemptIsoDates.isEmpty) return 0;
    final days = attemptIsoDates
        .map((iso) {
          final d = DateTime.tryParse(iso);
          return d == null
              ? null
              : DateTime(d.year, d.month, d.day);
        })
        .whereType<DateTime>()
        .toSet();
    var cursor = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );
    if (!days.contains(cursor)) {
      cursor = cursor.subtract(const Duration(days: 1));
      if (!days.contains(cursor)) return 0;
    }
    var streak = 0;
    while (days.contains(cursor)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  void _openSetup() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SetupScreen(exam: _selectedExam),
      ),
    ).then((_) => _load());
  }

  /// AUDIT C3: resume an interrupted test from saved progress.
  Future<void> _resumeTest() async {
    final progress = _resumeProgress;
    if (progress == null) return;
    final exam = ExamPattern.byId(progress.examId);
    final questions = await StorageService.instance.getQuestionsByIds(
      progress.questionIds,
    );
    if (questions.isEmpty) {
      await TestProgressService.instance.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'That test\'s questions are gone (book deleted). '
              'Generate a new test.',
            ),
          ),
        );
        setState(() => _resumeProgress = null);
      }
      return;
    }
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TestScreen(
          questions: questions,
          exam: exam,
          durationMinutes: progress.durationMinutes,
          resume: progress,
        ),
      ),
    ).then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('OfficerPath AI'),
        actions: [
          // v1.2 (user): RED UPGRADE button, top corner, every main
          // screen — first action so it is never missed.
          UpgradeAppBarButton(onReturn: _load),
          // v2.0.0: profile — account, plan, logout.
          IconButton(
            icon: const Icon(Icons.account_circle_outlined),
            tooltip: 'Profile',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ProfileScreen()),
              ).then((_) => _load());
            },
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'About',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AboutScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'History & progress',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HistoryScreen()),
              ).then((_) => _load());
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // AUDIT C2: first-run seeding failed — let the user
                  // retry instead of silently running with an empty bank.
                  if (widget.seedFailed && !_seedBannerDismissed)
                    Card(
                      color: theme.colorScheme.errorContainer,
                      child: ListTile(
                        leading: const Icon(Icons.warning_amber_outlined),
                        title: const Text(
                          'Sample question bank could not be loaded.',
                        ),
                        subtitle: const Text(
                          'Storage error on first run — tap Retry, or '
                          'upload your own book below.',
                        ),
                        trailing: TextButton(
                          onPressed: () async {
                            // Capture the messenger before the await so
                            // no BuildContext is used across the gap.
                            final messenger = ScaffoldMessenger.of(context);
                            try {
                              await StorageService.instance.ensureSeeded();
                              if (mounted) {
                                setState(
                                  () => _seedBannerDismissed = true,
                                );
                                _load();
                              }
                            } catch (_) {
                              messenger.showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Still failing — check phone storage '
                                    'and try again.',
                                  ),
                                ),
                              );
                            }
                          },
                          child: const Text('Retry'),
                        ),
                      ),
                    ),
                  // AUDIT C3: an interrupted test can be resumed here.
                  if (_resumeProgress != null)
                    Card(
                      color: theme.colorScheme.primaryContainer,
                      child: ListTile(
                        leading: const Icon(Icons.play_circle_outline),
                        title: Text(
                          'Resume test — ${ExamPattern.byId(_resumeProgress!.examId).shortName} '
                          '(${_resumeProgress!.questionIds.length} questions)',
                        ),
                        subtitle: Text(
                          '${_resumeProgress!.answers.length} answered • '
                          'Time left: ${_resumeProgress!.remaining.inMinutes}m '
                          '${_resumeProgress!.remaining.inSeconds % 60}s',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _resumeTest,
                      ),
                    ),
                  // ---- Hero: differentiator #1 — Apni Book Se Test ----
                  Card(
                    color: AppTheme.navy,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.menu_book,
                                color: AppTheme.gold,
                                size: 28,
                              ),
                              const SizedBox(width: 8),
                              // v1.2: title wraps instead of clipping on
                              // narrow phones / large text.
                              Expanded(
                                child: Text(
                                  'APNI BOOK SE TEST',
                                  style: theme.textTheme.titleMedium
                                      ?.copyWith(
                                        color: AppTheme.gold,
                                        letterSpacing: 1.2,
                                      ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Apni book se officer tak ka rasta.',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Dusri apps fixed bank se test banati hain. '
                            'Yahan test banta hai SIRF aap ki book aur aap ke '
                            'tayyar papers se — bilkul commission pattern par.',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              Chip(
                                label: Text(
                                  '$_bankSize MCQs in bank',
                                  style: const TextStyle(
                                    color: AppTheme.navy,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                backgroundColor: Colors.white,
                              ),
                              Chip(
                                label: Text(
                                  _isPremium
                                      ? 'Premium — unlimited tests'
                                      : 'Free tests left: $_testsRemaining / ${SubscriptionService.freeTestLimit}',
                                ),
                                // v1.2: goldTint, not goldSoft — cream +
                                // white (dark-mode) label text was
                                // unreadable in dark mode.
                                backgroundColor: AppTheme.goldTint(context),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: _openSetup,
                                  icon: const Icon(Icons.play_arrow),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: AppTheme.gold,
                                    foregroundColor: AppTheme.navyDark,
                                  ),
                                  label: const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 12),
                                    // v1.2: short label — the old
                                    // "Next Test — Test banao" clipped at
                                    // 360px wide with the icon beside it.
                                    child: Text(
                                      'Next Test',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => const UploadScreen(),
                                      ),
                                    ).then((_) => _load());
                                  },
                                  icon: const Icon(
                                    Icons.upload_file,
                                    color: Colors.white,
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    side: const BorderSide(
                                      color: Colors.white,
                                    ),
                                  ),
                                  label: const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 12),
                                    child: Text(
                                      'Upload Book',
                                      style: TextStyle(fontSize: 16),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // ---- Progress ring + streak + stats ----
                  // AUDIT m11: a fixed Row clipped on small screens /
                  // large text. A Wrap stacks the cards when narrow.
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 72,
                                height: 72,
                                // v1.2: the ring sweeps in on load
                                // (decoration only — the % text below is
                                // the final value from the first frame).
                                // Reduced motion: drawn final at once.
                                child: TweenAnimationBuilder<double>(
                                  tween: Tween<double>(
                                    begin: 0,
                                    end: (_avgPercent.clamp(0, 100)) / 100,
                                  ),
                                  duration:
                                      MediaQuery.of(
                                        context,
                                      ).disableAnimations
                                      ? Duration.zero
                                      : const Duration(milliseconds: 800),
                                  curve: Curves.easeOut,
                                  builder: (context, value, _) {
                                    return Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        SizedBox.expand(
                                          child: CircularProgressIndicator(
                                            value: value,
                                            strokeWidth: 8,
                                            backgroundColor: theme
                                                .colorScheme
                                                .surfaceContainerHighest,
                                          ),
                                        ),
                                        Text(
                                          '${_avgPercent.toStringAsFixed(0)}%',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(width: 12),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Average score',
                                    style: TextStyle(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  Text(
                                    'Best ${_bestPercent.toStringAsFixed(0)}% • '
                                    '$_testsTaken tests',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.local_fire_department,
                                    color: AppTheme.gold,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '$_streakDays day streak',
                                    style: theme.textTheme.titleMedium,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Rozana ek test — consistency hi officer banati hai.',
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // ---- Current Affairs — Rozana (FREE, not a test) ----
                  Card(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const CurrentAffairsScreen(),
                          ),
                        ).then((_) => _load());
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.newspaper,
                                  color: theme.colorScheme.primary,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Current Affairs — Rozana',
                                  style: theme.textTheme.titleMedium,
                                ),
                                const Spacer(),
                                Chip(
                                  label: const Text('FREE'),
                                  // v1.2: goldTint, not goldSoft (dark-mode
                                  // label contrast — see hero chips above).
                                  backgroundColor: AppTheme.goldTint(context),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Daily headlines — Pakistan + World. Free for '
                              'everyone, not counted in your 3 free tests per month.',
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 8),
                            if (_caTop.isEmpty)
                              const Text(
                                'Headlines load here — tap to open. '
                                '(Internet needed for the first fetch.)',
                              )
                            else
                              ..._caTop.map(
                                (item) => Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 3,
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        '•  ',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          item.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            const SizedBox(height: 4),
                            Text(
                              _caUpdated == null
                                  ? 'Tap to load today\'s headlines →'
                                  : 'Tap for all headlines →',
                              style: TextStyle(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // ---- Exam card ----
                  Text(
                    'Choose your exam',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: ExamPattern.all.map((exam) {
                      final selected = exam.id == _selectedExam.id;
                      return ChoiceChip(
                        label: Text(exam.shortName),
                        selected: selected,
                        onSelected: (_) async {
                          setState(() => _selectedExam = exam);
                          await StorageService.instance.setLastExamId(exam.id);
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 8),
                  Card(
                    child: ListTile(
                      leading: const Icon(
                        Icons.schedule,
                        color: AppTheme.gold,
                      ),
                      title: Text(_selectedExam.patternLabel),
                      subtitle: Text(
                        '${_selectedExam.description} '
                        'Pass: ${_selectedExam.passPercent.toStringAsFixed(0)}% • '
                        'Negative −0.25 per wrong answer.',
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // ---- Today's prepared papers ----
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // v1.2: title flexes — the old fixed Row clipped
                      // "Today's prepared papers" + the button at 360px.
                      Expanded(
                        child: Text(
                          "Today's prepared papers",
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      TextButton(
                        onPressed: _openSetup,
                        child: const Text('Tick in test setup'),
                      ),
                    ],
                  ),
                  Text(
                    'Test sirf un papers se banega jo aap ne aaj tayyar kiye — '
                    'setup mein tick karein.',
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_sources.isEmpty)
                    const Card(
                      child: ListTile(
                        leading: Icon(Icons.book_outlined),
                        title: Text('No books yet'),
                        subtitle: Text(
                          'Upload your first book, or use the built-in sample bank.',
                        ),
                      ),
                    )
                  else
                    ..._sources.take(5).map(
                      (s) => Card(
                        child: ListTile(
                          leading: Icon(
                            s.kind == 'past_paper'
                                ? Icons.description
                                : s.kind == 'sample'
                                    ? Icons.school
                                    : Icons.book,
                            color: theme.colorScheme.primary,
                          ),
                          title: Text(s.title),
                          subtitle: Text(
                            '${s.kindLabel} • ${s.questionCount} MCQs',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: _openSetup,
                        ),
                      ),
                    ),
                  if (_sources.length > 5)
                    Text(
                      '+ ${_sources.length - 5} more in test setup',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const SizedBox(height: 16),
                  if (!_isPremium)
                    // v1.2: the old single-line label
                    // ("Go Premium — Rs 600 / month • Rs 1,000 / 2 months
                    // • Rs 5,000 / year") overflowed at 360px. Two-line
                    // label, same prices, no clipping.
                    OutlinedButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const UpgradeScreen(),
                          ),
                        ).then((_) => _load());
                      },
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 10),
                        child: Column(
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.workspace_premium, size: 18),
                                SizedBox(width: 6),
                                Text(
                                  'Go Premium — Unlimited tests',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Rs 600 / month  •  Rs 1,000 / 2 months  •  Rs 5,000 / year',
                              style: TextStyle(fontSize: 12),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Text(
                    'How it works',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const _StepTile(
                    number: '1',
                    title: 'Upload your book',
                    subtitle:
                        'PDF ya TXT file, ya text paste karein. MCQs auto-parse hote hain.',
                  ),
                  const _StepTile(
                    number: '2',
                    title: 'Tick what you prepared today',
                    subtitle:
                        'Aaj jo papers tayyar kiye, sirf wohi tick karein — test unhi se banega.',
                  ),
                  const _StepTile(
                    number: '3',
                    title: 'Attempt with real timer',
                    subtitle:
                        'PPSC: 100 MCQs / 90 min, −0.25 negative. Time khatam hote hi auto-submit.',
                  ),
                  const _StepTile(
                    number: '4',
                    title: 'Result + evaluation',
                    subtitle:
                        'Score, subject-wise breakdown, weak topics, aur ghalat sawalon ki revision.',
                  ),
                  // v1.2: developer credit — last item of the scroll view.
                  const DeveloperCreditFooter(),
                ],
              ),
            ),
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({
    required this.number,
    required this.title,
    required this.subtitle,
  });

  final String number;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: AppTheme.navy,
        foregroundColor: Colors.white,
        child: Text(number),
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      contentPadding: EdgeInsets.zero,
    );
  }
}
