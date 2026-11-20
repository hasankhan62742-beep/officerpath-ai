import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/current_affairs.dart';
import '../services/ca_cache_service.dart';
import '../theme/app_theme.dart';
import '../widgets/developer_credit_footer.dart';
import '../widgets/upgrade_button.dart';

/// Current Affairs — Rozana. Two tabs: Pakistan | International.
///
/// FREE for all users — headlines are never counted in the Free 3/month
/// test limit. Auto-updates on open + pull-to-refresh + every 30 min while
/// this screen is open. Last fetch is cached locally, so the screen works
/// offline and never shows empty after the first fetch.
///
/// Each item shows headline + source + time + 1-line summary only.
/// Tapping opens the ORIGINAL article in the phone browser — full article
/// text is never copied into the app.
class CurrentAffairsScreen extends StatefulWidget {
  const CurrentAffairsScreen({super.key});

  @override
  State<CurrentAffairsScreen> createState() => _CurrentAffairsScreenState();
}

class _CurrentAffairsScreenState extends State<CurrentAffairsScreen> {
  final _cache = CaCacheService.instance;
  final _searchController = TextEditingController();
  Timer? _timer;
  bool _refreshing = false;
  bool _initialLoad = true;
  String _query = '';
  String _dateFilter = 'all'; // all | today | yesterday
  bool _savedOnly = false;

  @override
  void initState() {
    super.initState();
    _load();
    // Background refresh every 30 min while this screen is open.
    _timer = Timer.periodic(
      CaCacheService.staleAfter,
      (_) => _refresh(silent: true),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await _cache.loadFromCache();
    if (mounted) setState(() => _initialLoad = false);
    // AUDIT m10: opening the screen used to re-download all three
    // feeds every time, ignoring the 30-min staleness rule.
    try {
      await _cache.refreshIfStale();
    } catch (_) {
      // Offline — cached headlines stay.
    }
    if (mounted) setState(() {});
  }

  Future<void> _refresh({bool silent = false}) async {
    if (_refreshing) return;
    // AUDIT F19: this setState was unguarded — the 30-min Timer could
    // fire it after the screen was popped.
    if (!mounted) return;
    setState(() => _refreshing = true);
    try {
      await _cache.refresh();
    } catch (_) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Offline — showing saved headlines. Pull to retry.',
            ),
          ),
        );
      }
    }
    if (mounted) setState(() => _refreshing = false);
  }

  List<CaItem> _filtered(String category) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    var list = _cache.items.where((i) => i.category == category).toList();
    if (_savedOnly) {
      list = list.where((i) => _cache.isBookmarked(i.id)).toList();
    }
    if (_dateFilter == 'today') {
      list = list.where((i) {
        final d = i.publishedAt;
        return DateTime(d.year, d.month, d.day) == today;
      }).toList();
    } else if (_dateFilter == 'yesterday') {
      list = list.where((i) {
        final d = i.publishedAt;
        return DateTime(d.year, d.month, d.day) == yesterday;
      }).toList();
    }
    if (_query.trim().isNotEmpty) {
      final q = _query.toLowerCase();
      list = list.where((i) {
        return i.title.toLowerCase().contains(q) ||
            i.summary.toLowerCase().contains(q);
      }).toList();
    }
    return list;
  }

  String _timeAgo(DateTime dt) {
    // AUDIT m9: future-dated items (clock skew, or the old GMT bug)
    // used to show "-5m ago". Clamp at zero.
    final diff = DateTime.now().difference(dt);
    if (diff.isNegative) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return DateFormat('dd MMM').format(dt);
  }

  Future<void> _openArticle(CaItem item) async {
    // AUDIT F21: a malformed/relative link used to fail silently —
    // the user tapped and nothing happened.
    final uri = Uri.tryParse(item.link);
    if (uri == null ||
        !uri.hasScheme ||
        !(uri.isScheme('http') || uri.isScheme('https'))) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't open this article.")),
        );
      }
      return;
    }
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't open this article.")),
      );
    }
  }

  Widget _buildList(String category) {
    final items = _filtered(category);
    if (_initialLoad) {
      return const Center(child: CircularProgressIndicator());
    }
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _cache.items.isEmpty
                ? 'No headlines yet — pull down to fetch.\n(Internet needed for the first fetch.)'
                : 'No headlines match this filter.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    // Group by day for the 7-day archive view, flattened into one
    // indexed row list so the list builds lazily (AUDIT F20: the old
    // ListView(children: [...]) built ~70 cards in a single frame).
    final rows = <_CaRow>[];
    final groups = <String, List<CaItem>>{};
    for (final item in items) {
      final d = item.publishedAt;
      final key = DateFormat('EEEE, dd MMM yyyy').format(d);
      groups.putIfAbsent(key, () => []).add(item);
    }
    for (final entry in groups.entries) {
      rows.add(_CaRow.header(entry.key));
      for (final item in entry.value) {
        rows.add(_CaRow.item(item));
      }
    }
    return RefreshIndicator(
      onRefresh: () => _refresh(),
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: rows.length,
        itemBuilder: (context, index) {
          final row = rows[index];
          if (row.isHeader) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
              child: Text(
                row.label,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            );
          }
          return _buildItemCard(row.item!);
        },
      ),
    );
  }

  Widget _buildItemCard(CaItem item) {
    final bookmarked = _cache.isBookmarked(item.id);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openArticle(item),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (item.summary.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  item.summary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  // v1.2: Flexible + ellipsis — a long source name
                  // used to squeeze the time / buttons out at 360px.
                  Flexible(
                    child: Chip(
                      label: Text(
                        item.source,
                        overflow: TextOverflow.ellipsis,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _timeAgo(item.publishedAt),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      bookmarked ? Icons.bookmark : Icons.bookmark_border,
                      color: bookmarked ? AppTheme.gold : null,
                    ),
                    tooltip: bookmarked ? 'Saved' : 'Save headline',
                    onPressed: () async {
                      await _cache.toggleBookmark(item.id);
                      setState(() {});
                    },
                  ),
                  const Icon(Icons.open_in_new, size: 18),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final updated = _cache.fetchedAt;
    final updatedLabel = updated == null
        ? 'Not updated yet'
        : 'Updated ${DateFormat('hh:mm a, dd MMM yyyy').format(updated)}';
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Current Affairs — Rozana'),
          // v1.2 (user): RED UPGRADE button, top corner.
          actions: const [UpgradeAppBarButton()],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Pakistan'),
              Tab(text: 'International'),
            ],
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Chip(
                    label: const Text('FREE — not counted in 3/month limit'),
                    // v1.2: goldTint, not goldSoft (dark-mode contrast).
                    backgroundColor: AppTheme.goldTint(context),
                  ),
                  const Spacer(),
                  if (_refreshing)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      updatedLabel,
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ),
                  if (_cache.failedSources.isNotEmpty)
                    Flexible(
                      child: Text(
                        '${_cache.failedSources.join(', ')} unavailable — retry',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: TextField(
                controller: _searchController,
                decoration: const InputDecoration(
                  labelText: 'Search headlines',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              // v1.2: Wrap, not a fixed Row — the four filter chips
              // overflowed at 360px.
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ChoiceChip(
                    label: const Text('All (7 days)'),
                    selected: _dateFilter == 'all',
                    onSelected: (_) =>
                        setState(() => _dateFilter = 'all'),
                  ),
                  ChoiceChip(
                    label: const Text('Today'),
                    selected: _dateFilter == 'today',
                    onSelected: (_) =>
                        setState(() => _dateFilter = 'today'),
                  ),
                  ChoiceChip(
                    label: const Text('Yesterday'),
                    selected: _dateFilter == 'yesterday',
                    onSelected: (_) =>
                        setState(() => _dateFilter = 'yesterday'),
                  ),
                  FilterChip(
                    label: const Text('Saved'),
                    selected: _savedOnly,
                    onSelected: (v) => setState(() => _savedOnly = v),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              "Tap a headline to read the full story on the publisher's site.",
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: TabBarView(
                children: [
                  _buildList('Pakistan'),
                  _buildList('International'),
                ],
              ),
            ),
            // v1.2: developer credit — below the tab content, never
            // over the headlines. The list above is Expanded, so this
            // only shrinks it slightly.
            const DeveloperCreditFooter(),
          ],
        ),
      ),
    );
  }
}

/// One row of the flattened CA list (AUDIT F20): a day header or an item.
class _CaRow {
  const _CaRow.header(this.label) : item = null, isHeader = true;
  const _CaRow.item(this.item) : label = '', isHeader = false;

  final String label;
  final CaItem? item;
  final bool isHeader;
}
