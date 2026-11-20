import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/supabase_config.dart';

void main() {
  test('isConfigured is false with empty dart-define defaults', () {
    // No --dart-define was passed to this test run, so both values
    // must be empty and the app must treat Supabase as unconfigured
    // (offline v1 mode). A test run must never need real credentials.
    expect(SupabaseConfig.url, isEmpty);
    expect(SupabaseConfig.anonKey, isEmpty);
    expect(SupabaseConfig.isConfigured, isFalse);
  });

  test('projectRef is empty when the URL is empty', () {
    expect(SupabaseConfig.projectRef, isEmpty);
  });

  test('projectRef parsing logic: host <ref>.supabase.co -> <ref>', () {
    // Same parsing as SupabaseConfig.projectRef, exercised on inputs
    // the getter cannot see (its URL comes from dart-define).
    String refOf(String url) {
      final host = Uri.tryParse(url)?.host ?? '';
      const suffix = '.supabase.co';
      if (!host.endsWith(suffix)) return '';
      return host.substring(0, host.length - suffix.length);
    }

    expect(refOf('https://abcdefghijklm.supabase.co'), 'abcdefghijklm');
    expect(refOf('https://abcdefghijklm.supabase.co/'), 'abcdefghijklm');
    expect(refOf(''), isEmpty);
    expect(refOf('https://example.com'), isEmpty);
    expect(refOf('not a url'), isEmpty);
  });
}
