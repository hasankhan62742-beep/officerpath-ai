import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/keep_alive.dart';

void main() {
  group('keepAliveUrl', () {
    test('builds the profiles REST read URL', () {
      expect(
        KeepAlive.keepAliveUrl('https://abcdefghijklm.supabase.co'),
        'https://abcdefghijklm.supabase.co/rest/v1/profiles?select=id&limit=1',
      );
    });

    test('tolerates a trailing slash on the base URL', () {
      expect(
        KeepAlive.keepAliveUrl('https://abcdefghijklm.supabase.co/'),
        'https://abcdefghijklm.supabase.co/rest/v1/profiles?select=id&limit=1',
      );
      expect(
        KeepAlive.keepAliveUrl('https://abcdefghijklm.supabase.co///'),
        'https://abcdefghijklm.supabase.co/rest/v1/profiles?select=id&limit=1',
      );
    });
  });

  group('isHealthyResponse', () {
    test('HTTP 200 with an empty JSON array is healthy', () {
      expect(KeepAlive.isHealthyResponse(200, '[]'), isTrue);
      expect(KeepAlive.isHealthyResponse(200, '  []  '), isTrue);
    });

    test('HTTP 200 with rows is healthy', () {
      expect(
        KeepAlive.isHealthyResponse(200, '[{"id":"abc"}]'),
        isTrue,
      );
    });

    test('non-200 statuses are unhealthy even with an array body', () {
      expect(KeepAlive.isHealthyResponse(401, '[]'), isFalse);
      expect(KeepAlive.isHealthyResponse(404, '[]'), isFalse);
      expect(KeepAlive.isHealthyResponse(500, '[]'), isFalse);
      expect(KeepAlive.isHealthyResponse(0, '[]'), isFalse);
    });

    test('HTTP 200 with a non-array body is unhealthy', () {
      expect(KeepAlive.isHealthyResponse(200, ''), isFalse);
      expect(KeepAlive.isHealthyResponse(200, '{"message":"x"}'), isFalse);
      expect(KeepAlive.isHealthyResponse(200, '<html>error</html>'), isFalse);
      expect(KeepAlive.isHealthyResponse(200, 'null'), isFalse);
    });
  });
}
