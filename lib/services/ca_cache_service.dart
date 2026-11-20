import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/current_affairs.dart';
import 'rss_service.dart';

/// Offline-first Current Affairs cache (SharedPreferences JSON).
///
/// Behaviour:
/// * Last successful fetch is cached with its timestamp — the CA screen
///   NEVER shows empty when a previous fetch exists, even offline.
/// * Items older than 7 days are pruned on save (7-day archive).
/// * Bookmarks are stored as a set of article links, independent of the
///   cache — a bookmarked headline survives cache refreshes.
/// * A fetch is "stale" after 30 minutes; the UI refreshes on open,
///   on pull-to-refresh, and every 30 min while the CA screen is open.
class CaCacheService {
  CaCacheService._();
  static final CaCacheService instance = CaCacheService._();

  static const _kItems = 'ca_items_v1';
  static const _kFetchedAt = 'ca_fetched_at_iso_v1';
  static const _kBookmarks = 'ca_bookmarks_v1';
  static const _kFailedSources = 'ca_failed_sources_v1';

  static const Duration staleAfter = Duration(minutes: 30);
  static const Duration archiveDays = Duration(days: 7);

  final _rss = RssService();

  List<CaItem> _items = [];
  DateTime? _fetchedAt;
  Set<String> _bookmarks = {};
  List<String> _failedSources = [];
  bool _loaded = false;

  List<CaItem> get items => List.unmodifiable(_items);
  DateTime? get fetchedAt => _fetchedAt;
  List<String> get failedSources => List.unmodifiable(_failedSources);
  bool get hasCache => _items.isNotEmpty;

  bool get isStale {
    if (_fetchedAt == null) return true;
    return DateTime.now().difference(_fetchedAt!) > staleAfter;
  }

  bool isBookmarked(String id) => _bookmarks.contains(id);

  Future<void> loadFromCache() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kItems);
    if (raw != null) {
      try {
        final list = (jsonDecode(raw) as List).cast<Map<String, Object?>>();
        _items = list.map(CaItem.fromMap).toList();
      } catch (_) {
        // AUDIT m8: a corrupt cache used to set _loaded = true and stay
        // empty until the app was restarted. Clear the corrupt entry and
        // stay unloaded so the next refresh() can repair it in-session.
        _items = [];
        _loaded = false;
        await prefs.remove(_kItems);
        await prefs.remove(_kFetchedAt);
        _fetchedAt = null;
        _bookmarks = (prefs.getStringList(_kBookmarks) ?? []).toSet();
        _failedSources = prefs.getStringList(_kFailedSources) ?? [];
        return;
      }
    }
    final fetched = prefs.getString(_kFetchedAt);
    _fetchedAt = fetched == null ? null : DateTime.tryParse(fetched);
    _bookmarks = (prefs.getStringList(_kBookmarks) ?? []).toSet();
    _failedSources = prefs.getStringList(_kFailedSources) ?? [];
    _loaded = true;
  }

  /// Fetches fresh headlines and replaces the cache. On failure the old
  /// cache is kept untouched (offline never wipes the list).
  Future<FeedFetchResult> refresh() async {
    await loadFromCache();
    final result = await _rss.fetchAll();
    final cutoff = DateTime.now().subtract(archiveDays);
    final fresh = result.items
        .where((i) => i.publishedAt.isAfter(cutoff))
        .toList();
    // Merge with cached items that are still in the 7-day window, so a
    // feed that is briefly down does not erase its older headlines.
    // AUDIT m7: bookmarked items are exempt from the 7-day prune — a
    // saved headline must not vanish from the Saved tab.
    final byId = {for (final i in fresh) i.id: i};
    for (final old in _items) {
      if (old.publishedAt.isAfter(cutoff) || _bookmarks.contains(old.id)) {
        byId.putIfAbsent(old.id, () => old);
      }
    }
    _items = byId.values.toList()
      ..sort((a, b) => b.publishedAt.compareTo(a.publishedAt));
    // AUDIT F13: only advance the "Updated …" timestamp when at least
    // one feed actually returned items. A total failure used to stamp
    // "just now" and suppress retries for 30 min.
    if (result.items.isNotEmpty) {
      _fetchedAt = DateTime.now();
    }
    _failedSources = result.failedSources;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kItems,
      jsonEncode(_items.map((i) => i.toMap()).toList()),
    );
    if (_fetchedAt != null) {
      await prefs.setString(_kFetchedAt, _fetchedAt!.toIso8601String());
    }
    await prefs.setStringList(_kFailedSources, _failedSources);
    return result;
  }

  /// Fetches only when the cache is empty or stale. Returns true when a
  /// network refresh happened.
  Future<bool> refreshIfStale() async {
    await loadFromCache();
    if (_items.isEmpty || isStale) {
      try {
        await refresh();
        return true;
      } catch (_) {
        return false; // offline — keep showing the cache
      }
    }
    return false;
  }

  Future<void> toggleBookmark(String id) async {
    await loadFromCache();
    if (_bookmarks.contains(id)) {
      _bookmarks.remove(id);
    } else {
      _bookmarks.add(id);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kBookmarks, _bookmarks.toList());
  }

  List<CaItem> bookmarkedItems() =>
      _items.where((i) => _bookmarks.contains(i.id)).toList();
}
