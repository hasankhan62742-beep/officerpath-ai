import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../models/current_affairs.dart';

/// Fetches free publisher RSS/Atom feeds directly with `http`.
///
/// Native Flutter has NO CORS problem (that is a browser-only issue).
/// No API key, no cost, no NewsAPI (free plan: 100 req/day, 24h delayed,
/// paid $449/mo — deliberately not used).
///
/// LIVE VERIFICATION — 18 Nov 2026 ~11:40 PKT, from the build VM:
///   * Dawn direct  https://dawn.com/feeds/home — FAILED (HTTP 000,
///     connection failed). Fallback FeedBurner
///     https://feeds.feedburner.com/dawn-news-pakistan — HTTP 200,
///     296 KB, Atom format, Pakistan headlines present.
///   * BBC World https://feeds.bbci.co.uk/news/world/rss.xml — HTTP 200,
///     ~22 KB, 28 items (RSS 2.0).
///   * Guardian World https://www.theguardian.com/world/rss — HTTP 200,
///     ~147 KB, 45 items (RSS 2.0).
/// The parser handles BOTH RSS 2.0 (`<item>`) and Atom (`<entry>`),
/// and each feed is tried in URL order until one parses.
class RssService {
  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 13) OfficerPathAI/1.0';

  /// Fetches all feeds. A feed that fails (network / parse) is skipped
  /// and reported in [FeedFetchResult.failedSources] — one dead feed
  /// never blocks the others.
  Future<FeedFetchResult> fetchAll() async {
    final items = <CaItem>[];
    final failed = <String>[];
    for (final feed in CaFeed.feeds) {
      try {
        items.addAll(await _fetchFeed(feed));
      } catch (_) {
        failed.add(feed.source);
      }
    }
    items.sort((a, b) => b.publishedAt.compareTo(a.publishedAt));
    return FeedFetchResult(items: items, failedSources: failed);
  }

  Future<List<CaItem>> _fetchFeed(CaFeed feed) async {
    Exception? lastError;
    for (final url in feed.urls) {
      try {
        final res = await http
            .get(
              Uri.parse(url),
              headers: {'User-Agent': _userAgent},
            )
            .timeout(const Duration(seconds: 20));
        if (res.statusCode != 200) {
          throw Exception('HTTP ${res.statusCode}');
        }
        final parsed = parseFeedXml(
          res.body,
          source: feed.source,
          category: feed.category,
        );
        if (parsed.isEmpty) throw Exception('No items parsed');
        return parsed;
      } catch (e) {
        lastError = e is Exception ? e : Exception('$e');
      }
    }
    throw lastError ?? Exception('Feed failed: ${feed.source}');
  }

  /// Parses an RSS 2.0 or Atom document into items. Pure function —
  /// unit-tested with embedded samples (no network needed).
  static List<CaItem> parseFeedXml(
    String xmlText, {
    required String source,
    required String category,
  }) {
    final doc = XmlDocument.parse(xmlText);
    final items = <CaItem>[];

    // RSS 2.0: <rss><channel><item>…
    for (final item in doc.findAllElements('item')) {
      final title = _textOf(item, 'title');
      final link = _textOf(item, 'link');
      if (title.isEmpty || link.isEmpty) continue;
      items.add(
        CaItem(
          id: link,
          title: _cleanText(title),
          link: link,
          summary: _summaryOf(
            _textOf(item, 'description'),
          ),
          source: source,
          publishedAt: _parseDate(
            _textOf(item, 'pubDate'),
          ),
          category: category,
        ),
      );
    }

    // Atom: <feed><entry>… (Dawn via FeedBurner serves Atom).
    for (final entry in doc.findAllElements('entry')) {
      final title = _textOf(entry, 'title');
      final link = _linkHref(entry);
      if (title.isEmpty || link.isEmpty) continue;
      items.add(
        CaItem(
          id: link,
          title: _cleanText(title),
          link: link,
          summary: _summaryOf(
            _textOf(entry, 'summary').isNotEmpty
                ? _textOf(entry, 'summary')
                : _textOf(entry, 'content'),
          ),
          source: source,
          publishedAt: _parseDate(
            _textOf(entry, 'updated').isNotEmpty
                ? _textOf(entry, 'updated')
                : _textOf(entry, 'published'),
          ),
          category: category,
        ),
      );
    }
    return items;
  }

  static String _textOf(XmlElement parent, String tag) {
    final el = parent.findElements(tag).firstOrNull;
    return el?.innerText.trim() ?? '';
  }

  /// Atom `<link href="..." rel="alternate">` (or the first link).
  static String _linkHref(XmlElement entry) {
    for (final link in entry.findElements('link')) {
      final rel = link.getAttribute('rel');
      final href = link.getAttribute('href') ?? '';
      if (href.isEmpty) continue;
      if (rel == null || rel == 'alternate') return href;
    }
    return '';
  }

  /// Strips HTML tags + entities, collapses whitespace, caps length.
  static String _summaryOf(String raw) {
    var text = raw.replaceAll(RegExp(r'<[^>]*>'), ' ');
    text = text
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length > 220) text = '${text.substring(0, 220).trim()}…';
    return text;
  }

  static String _cleanText(String raw) =>
      raw.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Parses RFC 822 (`Tue, 18 Nov 2026 06:40:10 GMT`) and ISO 8601 dates.
  ///
  /// AUDIT F12: the old code built a naive local DateTime from a GMT
  /// timestamp, so BBC/Guardian times landed ~5 h late in PKT and broke
  /// sort order + Today/Yesterday filters. GMT/UTC and numeric offsets
  /// are now honoured (converted to local). An unparseable or missing
  /// date returns the epoch sentinel — never `now()` — so undated items
  /// sort to the bottom instead of faking "newest" and passing the
  /// Today filter (they are also pruned by the 7-day archive rule).
  static DateTime _parseDate(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return DateTime.fromMillisecondsSinceEpoch(0);
    final iso = DateTime.tryParse(text);
    if (iso != null) return iso.toLocal();
    final rfc = RegExp(
      r'^(?:\w{3},\s*)?(\d{1,2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2})(?::(\d{2}))?\s*([A-Za-z]+|[+-]\d{4})?',
    ).firstMatch(text);
    if (rfc != null) {
      const months = {
        'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
        'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
      };
      final month = months[rfc.group(2)!] ?? 1;
      final utc = DateTime.utc(
        int.parse(rfc.group(3)!),
        month,
        int.parse(rfc.group(1)!),
        int.parse(rfc.group(4)!),
        int.parse(rfc.group(5)!),
        int.parse(rfc.group(6) ?? '0'),
      );
      final tz = rfc.group(7);
      if (tz != null && tz.startsWith(RegExp(r'[+-]'))) {
        // Numeric offset, e.g. +0500: the wall time is AHEAD of UTC,
        // so UTC = wall time MINUS the offset.
        final sign = tz.startsWith('-') ? -1 : 1;
        final hours = int.parse(tz.substring(1, 3));
        final minutes = int.parse(tz.substring(3, 5));
        return utc
            .add(Duration(minutes: -sign * (hours * 60 + minutes)))
            .toLocal();
      }
      // GMT/UTC/UT/Z or an unknown zone name: treat as UTC.
      return utc.toLocal();
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
}

class FeedFetchResult {
  const FeedFetchResult({required this.items, required this.failedSources});

  final List<CaItem> items;

  /// Sources that failed this round (shown as "unavailable — retry").
  final List<String> failedSources;
}
