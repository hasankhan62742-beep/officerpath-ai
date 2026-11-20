/// A Current Affairs headline from a publisher RSS/Atom feed.
///
/// Only the headline + 1-line summary + link are stored/shown, with
/// attribution to the source. Full article text is NEVER copied — tapping
/// an item opens the ORIGINAL article in the phone browser.
class CaItem {
  const CaItem({
    required this.id,
    required this.title,
    required this.link,
    required this.summary,
    required this.source,
    required this.publishedAt,
    required this.category,
  });

  /// Stable id: the article link (unique per story).
  final String id;
  final String title;
  final String link;

  /// 1-line summary from the RSS `<description>` / Atom `<summary>`,
  /// HTML stripped. May be empty for some feeds.
  final String summary;

  /// 'Dawn' | 'BBC' | 'Guardian'.
  final String source;
  final DateTime publishedAt;

  /// 'Pakistan' (national) | 'International' (world).
  final String category;

  bool get isPakistan => category == 'Pakistan';

  Map<String, Object?> toMap() => {
    'id': id,
    'title': title,
    'link': link,
    'summary': summary,
    'source': source,
    'publishedAt': publishedAt.toIso8601String(),
    'category': category,
  };

  factory CaItem.fromMap(Map<String, Object?> map) => CaItem(
    id: map['id'] as String,
    title: map['title'] as String,
    link: map['link'] as String,
    summary: map['summary'] as String? ?? '',
    source: map['source'] as String,
    publishedAt: DateTime.parse(map['publishedAt'] as String),
    category: map['category'] as String,
  );
}

/// One publisher feed (free RSS/Atom, no API key, no cost).
class CaFeed {
  const CaFeed({
    required this.source,
    required this.category,
    required this.urls,
  });

  final String source;
  final String category;

  /// Tried in order until one returns a parseable feed.
  final List<String> urls;

  static const List<CaFeed> feeds = [
    CaFeed(
      source: 'Dawn',
      category: 'Pakistan',
      urls: [
        'https://dawn.com/feeds/home',
        // Fallback: FeedBurner mirror (Atom format). Verified live 18 Nov
        // 2026 — dawn.com direct failed from the build VM (HTTP 000),
        // FeedBurner returned HTTP 200 with Pakistan headlines.
        // v1.2: HTTPS ONLY — the plain-HTTP fallback is removed, because
        // the network security config now blocks cleartext traffic and
        // an HTTP feed can be modified in transit.
        'https://feeds.feedburner.com/dawn-news-pakistan',
      ],
    ),
    CaFeed(
      source: 'BBC',
      category: 'International',
      urls: ['https://feeds.bbci.co.uk/news/world/rss.xml'],
    ),
    CaFeed(
      source: 'Guardian',
      category: 'International',
      urls: ['https://www.theguardian.com/world/rss'],
    ),
  ];
}
