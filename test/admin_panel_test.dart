import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Admin panel static checks (no network, no backend).
///
/// Reads admin/index.html + admin/app.js from the repo and asserts the
/// wiring the panel depends on: every element id app.js touches exists
/// in the HTML, no service_role key or real credential is anywhere in
/// admin/, and config.example.js holds placeholders only.
/// `node --check` runs when node is available on the machine; when it
/// is not, the static checks below still run and the syntax check is
/// skipped with a note (it is also documented in the test output).

/// Every id that admin/app.js looks up with getElementById.
const _requiredIds = [
  'config-error',
  'config-error-text',
  'login-view',
  'login-form',
  'login-email',
  'login-password',
  'login-error',
  'login-btn',
  'access-denied',
  'access-denied-email',
  'access-denied-back-btn',
  'app-view',
  'admin-info',
  'admin-email',
  'logout-btn',
  'stat-total-users',
  'stat-premium-users',
  'stat-pending-payments',
  'stat-codes-issued',
  'stat-codes-used',
  'stat-tests-taken',
  'signup-chart',
  'dashboard-error',
  'users-search',
  'users-table',
  'users-tbody',
  'users-empty',
  'user-detail',
  'user-detail-title',
  'user-detail-body',
  'user-detail-close',
  'revoke-premium-btn',
  'payments-queue',
  'payments-table',
  'payments-tbody',
  'payments-empty',
  'codes-table',
  'codes-tbody',
  'codes-empty',
  'toast',
  'approve-modal',
  'approve-modal-title',
  'approve-code',
  'approve-copy-btn',
  'approve-email-text',
  'approve-mailto',
  'approve-close-btn',
];

String _read(String path) => File(path).readAsStringSync();

void main() {
  late String html;
  late String js;
  late String exampleConfig;
  late String readme;

  setUpAll(() {
    html = _read('admin/index.html');
    js = _read('admin/app.js');
    exampleConfig = _read('admin/config.example.js');
    readme = _read('admin/README.md');
  });

  group('admin panel — required element ids', () {
    test('every id app.js needs exists in index.html', () {
      for (final id in _requiredIds) {
        expect(
          html,
          contains('id="$id"'),
          reason: 'admin/index.html must define id="$id"',
        );
      }
    });

    test('index.html loads config.js, the Supabase CDN and app.js', () {
      expect(html, contains('src="config.js"'));
      expect(html, contains('supabase-js'));
      expect(html, contains('src="app.js"'));
    });
  });

  group('admin panel — no credentials', () {
    test('no service_role string in shipped code files', () {
      for (final path in [
        'admin/index.html',
        'admin/app.js',
        'admin/styles.css',
      ]) {
        expect(
          _read(path),
          isNot(contains('service_role')),
          reason: '$path must never mention the service_role key',
        );
      }
    });

    test('example config + README only warn about service_role, never use it',
        () {
      // Both files say "NEVER put the service_role key here" in prose.
      // That warning is required — but neither may carry a real key
      // (checked by the eyJ test below).
      expect(exampleConfig, contains('NEVER'));
      expect(exampleConfig, contains('service_role'));
      expect(readme, contains('service_role'));
      expect(readme, contains('never'));
    });

    test('no JWT-looking secret in code or example config', () {
      // A real Supabase anon key starts with eyJ (base64 JWT header).
      for (final content in [html, js, exampleConfig]) {
        expect(content, isNot(contains('eyJ')));
      }
    });

    test('config.example.js contains placeholders only', () {
      expect(exampleConfig, contains('YOUR-PROJECT'));
      expect(exampleConfig, contains('YOUR-ANON-KEY'));
      expect(exampleConfig, contains('config.js'));
      expect(
        exampleConfig,
        isNot(contains(RegExp(r'https://[a-z0-9]+\.supabase\.co'))),
        reason: 'example config must not contain a real project URL',
      );
    });

    test('app.js reads config from window.OFFICERPATH_CONFIG', () {
      expect(js, contains('OFFICERPATH_CONFIG'));
      expect(js, contains('createClient'));
    });
  });

  group('admin panel — features wired', () {
    test('admin gate checks profiles.is_admin', () {
      expect(js, contains('is_admin'));
      expect(js, contains('access-denied'));
    });

    test('approve flow calls issue-code and shows the code once', () {
      expect(js, contains("invoke('issue-code'"));
      expect(js, contains('approve-modal'));
      expect(js, contains('approve-code'));
      expect(js, contains('approve-mailto'));
    });

    test('revoke flow clears plan + premium_until', () {
      expect(js, contains('revoke-premium-btn'));
      expect(js, contains("plan: 'free'"));
      expect(js, contains('premium_until: null'));
    });

    test('codes table shows hash prefix only, never the plain code', () {
      expect(js, contains('code_hash'));
      expect(js, contains('slice(0, 12)'));
    });

    test('signups chart + dashboard stats are wired', () {
      expect(js, contains('signup-chart'));
      expect(js, contains('stat-total-users'));
      expect(js, contains('stat-pending-payments'));
      expect(js, contains('stat-tests-taken'));
    });

    test('README documents the Cloudflare Pages deploy + config.js', () {
      expect(readme, contains('Cloudflare Pages'));
      expect(readme, contains('config.js'));
      expect(readme, contains('officerpath-admin'));
    });
  });

  group('admin panel — JS syntax (node --check when available)', () {
    test('app.js and config.example.js parse as JavaScript', () async {
      var nodeMissing = false;
      for (final file in ['admin/app.js', 'admin/config.example.js']) {
        try {
          final result = await Process.run('node', [
            '--check',
            file,
          ]).timeout(const Duration(seconds: 30));
          expect(
            result.exitCode,
            0,
            reason: 'node --check $file failed:\n${result.stderr}',
          );
        } on ProcessException {
          nodeMissing = true;
        }
      }
      if (nodeMissing) {
        // ignore: avoid_print
        print(
          'node is not available in this test env — JS syntax check '
          'skipped; run `node --check admin/app.js` manually.',
        );
      }
    });
  });
}
