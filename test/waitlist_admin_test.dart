import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the admin-panel waitlist snippets
/// (admin/waitlist-section.html + admin/waitlist-section.js) as TEXT.
/// They are snippets, not live panel code: admin/index.html and
/// admin/app.js are deliberately NOT read here — another worker owns
/// them right now. The integration anchors are checked against
/// docs/waitlist.md instead (see the last group).
/// `node --check` runs on the JS snippet when node is available.
void main() {
  late String snippetHtml;
  late String snippetJs;
  late String docs;

  setUpAll(() {
    snippetHtml = File('admin/waitlist-section.html').readAsStringSync();
    snippetJs = File('admin/waitlist-section.js').readAsStringSync();
    docs = File('docs/waitlist.md').readAsStringSync();
  });

  group('waitlist-section.html — required element ids', () {
    test('section, count, search, table and export button exist', () {
      for (final id in [
        'waitlist-section',
        'waitlist-count',
        'waitlist-search',
        'waitlist-table',
        'waitlist-tbody',
        'waitlist-empty',
        'waitlist-error',
        'waitlist-export-btn',
      ]) {
        expect(
          snippetHtml,
          contains('id="$id"'),
          reason: 'snippet must define id="$id"',
        );
      }
    });

    test('table has email / date / source columns', () {
      expect(snippetHtml, contains('<th>Email</th>'));
      expect(snippetHtml, contains('<th>Date</th>'));
      expect(snippetHtml, contains('<th>Source</th>'));
    });

    test('Export CSV button is present', () {
      expect(snippetHtml, contains('Export CSV'));
    });
  });

  group('waitlist-section.js — list, search, export', () {
    test('load + render functions exist and read the waitlist table', () {
      expect(snippetJs, contains('function loadWaitlist'));
      expect(snippetJs, contains('function renderWaitlist'));
      expect(snippetJs, contains("from('waitlist')"));
      expect(snippetJs, contains('waitlistCache'));
      expect(snippetJs, contains('waitlist-count'));
      expect(snippetJs, contains('waitlist-tbody'));
    });

    test('search filters by email', () {
      expect(snippetJs, contains('waitlist-search'));
      expect(snippetJs, contains("toLowerCase().indexOf(q)"));
    });

    test('export-CSV function exists and builds a browser download', () {
      expect(snippetJs, contains('function exportWaitlistCsv'));
      expect(snippetJs, contains('officerpath-waitlist.csv'));
      expect(snippetJs, contains('new Blob'));
      expect(snippetJs, contains('email,created_at,source'));
    });

    test('loading is admin-gated (only after the admin check)', () {
      expect(snippetJs, contains('adminUser'));
      expect(snippetJs, contains('if (!adminUser) return;'));
    });

    test('snippet reuses the panel helpers, does not reinvent them', () {
      expect(snippetJs, contains('fmtDate('));
      expect(snippetJs, contains('esc('));
      expect(snippetJs, contains('toast('));
    });
  });

  group('no credentials embedded in the snippets', () {
    test('no service_role, no Supabase URL, no JWT in either file', () {
      for (final entry in {
        'admin/waitlist-section.html': snippetHtml,
        'admin/waitlist-section.js': snippetJs,
      }.entries) {
        expect(entry.value, isNot(contains('service_role')),
            reason: '${entry.key} must never mention service_role');
        expect(
          RegExp(r'https://[A-Za-z0-9-]+\.supabase\.co')
              .hasMatch(entry.value),
          isFalse,
          reason: '${entry.key} must not contain a Supabase URL',
        );
        expect(
          RegExp(r'eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+')
              .hasMatch(entry.value),
          isFalse,
          reason: '${entry.key} must not contain a JWT-shaped key',
        );
      }
    });
  });

  group('docs/waitlist.md — insertion instructions', () {
    test('docs quote the exact admin/index.html anchor', () {
      expect(docs, contains('<p id="toast"'));
    });

    test('docs quote the exact admin/app.js anchors', () {
      expect(
        docs,
        contains(
          "\$('push-form').addEventListener('submit', sendPushNotification);",
        ),
      );
      expect(docs, contains('loadPushHistory();'));
      expect(docs, contains('loadWaitlist();'));
      expect(docs, contains('codes table'));
    });

    test('docs name the snippet files and forbid a separate script tag', () {
      expect(docs, contains('admin/waitlist-section.html'));
      expect(docs, contains('admin/waitlist-section.js'));
      expect(docs, contains('Do not wrap'));
    });

    test('docs cover the GitHub Pages setup and the launch plan', () {
      expect(docs, contains('hasankhan62742-beep.github.io/officerpath-ai'));
      expect(docs, contains('Deploy from a branch'));
      expect(docs, contains('hello@abdulqadeerml.com'));
      expect(docs, contains('Export CSV'));
    });
  });

  group('JS syntax (node --check when available)', () {
    test('waitlist-section.js parses as JavaScript', () async {
      try {
        final result = await Process.run('node', [
          '--check',
          'admin/waitlist-section.js',
        ]).timeout(const Duration(seconds: 30));
        expect(
          result.exitCode,
          0,
          reason: 'node --check admin/waitlist-section.js failed:\n'
              '${result.stderr}',
        );
      } on ProcessException {
        // ignore: avoid_print
        print(
          'node is not available in this test env — JS syntax check '
          'skipped; run `node --check admin/waitlist-section.js` manually.',
        );
      }
    });
  });
}
