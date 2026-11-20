import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Push-notification admin checks (no network, no backend).
///
/// Reads admin/index.html + admin/app.js and asserts the
/// Send-notification UI exists and is wired to the send-notification
/// Edge Function, and that no FCM server key / legacy key material
/// is anywhere in the repo's push files.
/// `node --check` runs when node is available; otherwise the static
/// checks still run and the syntax check is skipped with a note.

/// Every id the push section of admin/app.js looks up.
const _pushIds = [
  'push-section',
  'push-form',
  'push-title',
  'push-message',
  'push-audience',
  'push-type',
  'push-version-wrap',
  'push-version',
  'push-send-btn',
  'push-error',
  'push-result',
  'push-history-table',
  'push-history-tbody',
  'push-history-empty',
];

String _read(String path) => File(path).readAsStringSync();

void main() {
  late String html;
  late String js;
  late String readme;
  late String pushService;
  late String migration;
  late String edgeFunction;
  late String docs;

  setUpAll(() {
    html = _read('admin/index.html');
    js = _read('admin/app.js');
    readme = _read('admin/README.md');
    pushService = _read('lib/services/push_service.dart');
    migration = _read('supabase/migrations/004_push_notifications.sql');
    edgeFunction = _read('supabase/functions/send-notification/index.ts');
    docs = _read('docs/push-setup.md');
  });

  group('admin panel — Send notification UI', () {
    test('every push element id app.js needs exists in index.html', () {
      for (final id in _pushIds) {
        expect(
          html,
          contains('id="$id"'),
          reason: 'admin/index.html must define id="$id"',
        );
      }
    });

    test('audience picker has all / premium / free', () {
      expect(html, contains('value="all"'));
      expect(html, contains('value="premium"'));
      expect(html, contains('value="free"'));
      expect(html, contains('All users'));
      expect(html, contains('Premium only'));
      expect(html, contains('Free users'));
    });

    test('type picker has update_available / announcement', () {
      expect(html, contains('value="update_available"'));
      expect(html, contains('value="announcement"'));
      expect(html, contains('New version available'));
    });

    test('app.js sends via the send-notification Edge Function', () {
      expect(js, contains("invoke('send-notification'"));
      expect(js, contains('push-form'));
      expect(js, contains('push-send-btn'));
      expect(js, contains('loadPushHistory'));
      expect(js, contains('sent_notifications'));
    });

    test('app.js confirms before sending and shows the recipient count',
        () {
      expect(js, contains('window.confirm'));
      expect(js, contains('recipient_count'));
    });

    test('version field is required for update sends, hidden otherwise',
        () {
      expect(js, contains('update_available'));
      expect(js, contains('push-version-wrap'));
    });

    test('README documents the Send notification section', () {
      expect(readme, contains('Send notification'));
      expect(readme, contains('send-notification'));
    });
  });

  group('migration 004 — push columns + log table', () {
    test('adds the three profiles columns', () {
      expect(migration, contains('fcm_token text'));
      expect(migration, contains('fcm_token_updated_at timestamptz'));
      expect(
        migration,
        contains('notifications_enabled boolean not null default true'),
      );
    });

    test('creates sent_notifications with audience + type checks', () {
      expect(migration, contains('sent_notifications'));
      expect(migration, contains("check (audience in ('all', 'premium', 'free'))"));
      expect(
        migration,
        contains(
          "check (notification_type in ('update_available', 'announcement'))",
        ),
      );
      expect(migration, contains('recipient_count int'));
    });

    test('sent_notifications is admin-read only from the client', () {
      expect(migration, contains('enable row level security'));
      expect(migration, contains('Admins can view sent notifications'));
    });
  });

  group('Edge Function — send-notification', () {
    test('verifies the caller is_admin and validates the request', () {
      expect(edgeFunction, contains('is_admin'));
      expect(edgeFunction, contains('forbidden_not_admin'));
      expect(edgeFunction, contains('invalid_request'));
    });

    test('filters recipients by the opt-out flag server-side', () {
      expect(edgeFunction, contains('notifications_enabled'));
      expect(edgeFunction, contains('fcm_token'));
    });

    test('uses FCM HTTP v1 with an OAuth2 access token, no legacy key',
        () {
      expect(edgeFunction, contains('fcm.googleapis.com/v1/projects/'));
      expect(edgeFunction, contains('oauth2.googleapis.com/token'));
      expect(edgeFunction, contains('FIREBASE_SERVICE_ACCOUNT'));
      expect(edgeFunction, contains('messages:send'));
    });

    test('logs the send in sent_notifications', () {
      expect(edgeFunction, contains("from(\"sent_notifications\")"));
      expect(edgeFunction, contains('recipient_count'));
    });
  });

  group('push docs', () {
    test('push-setup.md covers the full handover', () {
      for (final section in [
        'Firebase project',
        'google-services.json',
        'Cloud Messaging API',
        'service account',
        'FIREBASE_SERVICE_ACCOUNT',
        'send-notification',
        '004_push_notifications',
        'Manual verification',
        'UNVERIFIED',
      ]) {
        expect(docs, contains(section), reason: 'docs must cover $section');
      }
    });

    test('docs state the google-services plugin lines for the build', () {
      expect(docs, contains('com.google.gms.google-services'));
    });
  });

  group('no server keys anywhere in the push surface', () {
    test('no legacy FCM server-key pattern (AAAA…) in push files', () {
      // A legacy FCM server key starts with AAAA followed by a long
      // base64-ish token. Any such string is a credential leak.
      final legacyKey = RegExp(r'AAAA[A-Za-z0-9_\-]{20,}');
      for (final entry in {
        'lib/services/push_service.dart': pushService,
        'supabase/functions/send-notification/index.ts': edgeFunction,
        'admin/app.js': js,
        'admin/index.html': html,
        'docs/push-setup.md': docs,
      }.entries) {
        expect(
          legacyKey.hasMatch(entry.value),
          isFalse,
          reason: '${entry.key} must not contain a legacy FCM server key',
        );
      }
    });

    test('no service_role / server-key strings in admin/', () {
      for (final path in ['admin/index.html', 'admin/app.js']) {
        expect(
          _read(path),
          isNot(contains('service_role')),
          reason: '$path must never mention the service_role key',
        );
      }
    });

    test('placeholder google-services.json has no real values', () {
      final placeholder = _read('android/app/google-services.json');
      expect(placeholder, contains('REPLACE-ME'));
      expect(
        placeholder,
        isNot(contains(RegExp(r'"project_id":\s*"[a-z0-9\-]+"'))),
        reason: 'placeholder must not carry a real project id',
      );
    });

    test('AndroidManifest has POST_NOTIFICATIONS, keeps the deep link',
        () {
      final manifest = _read(
        'android/app/src/main/AndroidManifest.xml',
      );
      expect(manifest, contains('POST_NOTIFICATIONS'));
      expect(manifest, contains('REQUEST_INSTALL_PACKAGES'));
      expect(manifest, contains('officerpath'));
      expect(manifest, contains('reset-password'));
    });
  });

  group('admin panel — JS syntax (node --check when available)', () {
    test('app.js parses as JavaScript', () async {
      try {
        final result = await Process.run('node', [
          '--check',
          'admin/app.js',
        ]).timeout(const Duration(seconds: 30));
        expect(
          result.exitCode,
          0,
          reason: 'node --check admin/app.js failed:\n${result.stderr}',
        );
      } on ProcessException {
        // ignore: avoid_print
        print(
          'node is not available in this test env — JS syntax check '
          'skipped; run `node --check admin/app.js` manually.',
        );
      }
    });
  });
}
