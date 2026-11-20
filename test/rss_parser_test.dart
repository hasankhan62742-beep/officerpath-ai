import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/models/current_affairs.dart';
import 'package:officerpath_ai/services/rss_service.dart';

const _rssSample = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
<channel>
<title>BBC News - World</title>
<item>
<title>World leaders meet for climate talks</title>
<link>https://www.bbc.com/news/world-123</link>
<description><![CDATA[<p>Leaders gather to discuss <b>climate</b> action &amp; funding.</p>]]></description>
<pubDate>Tue, 18 Nov 2026 06:40:10 GMT</pubDate>
</item>
<item>
<title>Markets rise after rate decision</title>
<link>https://www.bbc.com/news/world-124</link>
<description>Stocks climbed on Tuesday.</description>
<pubDate>Tue, 18 Nov 2026 05:00:00 GMT</pubDate>
</item>
</channel>
</rss>
''';

const _atomSample = '''
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
<title>Dawn - Pakistan</title>
<entry>
<title>Senators raise concern over dam design</title>
<link rel="alternate" type="text/html" href="https://www.dawn.com/news/123"/>
<summary>Senators questioned the project cost.</summary>
<updated>2026-11-18T06:30:00Z</updated>
</entry>
<entry>
<title>Item without a link is skipped</title>
<summary>No link here.</summary>
<updated>2026-11-18T06:00:00Z</updated>
</entry>
</feed>
''';

void main() {
  test('parses RSS 2.0 items: title, link, summary, RFC822 date', () {
    final items = RssService.parseFeedXml(
      _rssSample,
      source: 'BBC',
      category: 'International',
    );
    expect(items.length, 2);
    expect(items[0].title, 'World leaders meet for climate talks');
    expect(items[0].link, 'https://www.bbc.com/news/world-123');
    expect(items[0].source, 'BBC');
    expect(items[0].category, 'International');
    // HTML stripped, entity decoded.
    expect(items[0].summary, contains('climate action & funding'));
    expect(items[0].summary.contains('<'), isFalse);
    // RFC 822 date parsed.
    expect(items[0].publishedAt.year, 2026);
    expect(items[0].publishedAt.month, 11);
    expect(items[0].publishedAt.day, 18);
  });

  test('parses Atom entries (Dawn via FeedBurner) and skips link-less', () {
    final items = RssService.parseFeedXml(
      _atomSample,
      source: 'Dawn',
      category: 'Pakistan',
    );
    expect(items.length, 1);
    expect(items[0].title, 'Senators raise concern over dam design');
    expect(items[0].link, 'https://www.dawn.com/news/123');
    expect(items[0].summary, 'Senators questioned the project cost.');
    expect(items[0].publishedAt.year, 2026);
  });

  test('feed URL order: Dawn has an HTTPS fallback URL', () {
    // Dawn direct failed from the build VM; FeedBurner fallback is wired.
    // v1.2: HTTPS only — the plain-HTTP fallback was removed (cleartext
    // traffic is now blocked by the network security config).
    final dawn = CaFeed.feeds
        .firstWhere((f) => f.source == 'Dawn')
        .urls;
    expect(dawn.length, 2);
    expect(dawn[1], contains('feedburner'));
    expect(dawn.every((u) => u.startsWith('https://')), isTrue);
  });
}
