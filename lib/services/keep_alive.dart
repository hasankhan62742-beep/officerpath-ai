/// Supabase Free keep-alive helpers for OfficerPath AI v2.0.0.
///
/// WHY: a Supabase Free project is PAUSED after 1 week of inactivity
/// (no API / database traffic). A paused project cannot sign anyone
/// in until the owner resumes it in the Dashboard. Two mechanisms
/// keep this project alive — see docs/keep-alive.md:
///   1. A daily cron (curl) that pings the REST endpoint below.
///   2. The app itself: on launch, when logged in, it runs a
///      lightweight `profiles` select, which counts as activity.
///
/// This file holds only the pure, unit-tested helpers. No network,
/// no keys — the anon key for the curl call lives in the cron
/// environment, never in the repo.
class KeepAlive {
  KeepAlive._();

  /// The cheapest read that proves the project is alive: one row of
  /// `profiles`, selected through the public REST API. A trailing
  /// slash on the URL is tolerated.
  static String keepAliveUrl(String supabaseUrl) {
    final base = supabaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return '$base/rest/v1/profiles?select=id&limit=1';
  }

  /// True when the ping got a healthy answer: HTTP 200 and a JSON
  /// array body (possibly empty — `[]` is healthy; the table may
  /// simply have no rows visible to the anon key). Anything else —
  /// wrong status, HTML error page, garbage — is unhealthy.
  static bool isHealthyResponse(int statusCode, String body) {
    if (statusCode != 200) return false;
    final trimmed = body.trim();
    return trimmed.startsWith('[') && trimmed.endsWith(']');
  }
}
