/// Supabase configuration for OfficerPath AI v2.0.0.
///
/// The URL and anon key come ONLY from `--dart-define` at build time:
///
///   flutter build apk --dart-define=SUPABASE_URL=https://YOUR-REF.supabase.co \
///                     --dart-define=SUPABASE_ANON_KEY=YOUR-ANON-KEY
///
/// No real URL or key is ever committed to this repo. When both are
/// empty the app runs in its offline v1 mode ([isConfigured] is false)
/// and the v2 login / sync screens must stay hidden.
///
/// The ANON key is safe to ship in the app binary: it is a public,
/// publishable key, and Row Level Security (supabase/migrations/)
/// is what actually protects user data. The SERVICE_ROLE key must
/// NEVER appear here — it lives only in Edge Function secrets.
class SupabaseConfig {
  SupabaseConfig._();

  /// e.g. https://abcdefghijklm.supabase.co — empty when not configured.
  static const String url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: '',
  );

  /// Publishable anon key — empty when not configured.
  static const String anonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: '',
  );

  /// True only when both values were supplied at build time.
  static bool get isConfigured =>
      url.isNotEmpty && anonKey.isNotEmpty;

  /// Project ref parsed from the URL host (`<ref>.supabase.co` -> `<ref>`).
  /// Empty when the URL is missing or not a supabase.co host. Used for
  /// docs / deep links, never for auth.
  static String get projectRef {
    if (url.isEmpty) return '';
    final host = Uri.tryParse(url)?.host ?? '';
    const suffix = '.supabase.co';
    if (!host.endsWith(suffix)) return '';
    return host.substring(0, host.length - suffix.length);
  }
}
