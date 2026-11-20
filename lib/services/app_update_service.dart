import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:ota_update/ota_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-app updates for the GitHub-sideloaded app (v1.3).
///
/// Play's In-App Updates API does NOT work for sideloaded apps, so this
/// service does the proven sideload flow instead:
///   1. Ask the GitHub Releases API for the latest release.
///   2. Compare its tag (v1.3.0) with the installed version.
///   3. If newer, download the arm64 APK and hand it to the Android
///      system installer (ota_update). Android asks the user once to
///      allow "Install unknown apps" for OfficerPath.
///
/// HONEST LIMITS:
/// * The user still taps "Install" on the system prompt — Android never
///   lets a regular app install silently.
/// * An update installs OVER the old app only when both APKs share the
///   same signing key. A release-key build cannot update over the
///   debug-signed v1.2.0 — those users must uninstall first (one-time).
/// * Play forbids self-updating apps. A Play build passes
///   `--dart-define=PLAY_BUILD=true`, which flips
///   [AppUpdateService.selfUpdateEnabled] to false (see
///   docs/release-signing.md §3) and lets Play deliver updates.
/// * GitHub's unauthenticated API allows 60 requests/hour per IP — one
///   check per launch is far inside that.
class AppUpdateInfo {
  const AppUpdateInfo({
    required this.latestVersion,
    required this.tag,
    required this.downloadUrl,
    required this.fileName,
    required this.assetSize,
  });

  /// Version without the leading 'v', e.g. '1.3.0'.
  final String latestVersion;

  /// Release tag as published, e.g. 'v1.3.0'.
  final String tag;

  /// Direct download URL of the APK asset (browser_download_url).
  final String downloadUrl;

  /// Asset file name, e.g. 'officerpath-ai-v1.3-arm64.apk'.
  final String fileName;

  /// Asset size in bytes (0 when GitHub does not report it).
  final int assetSize;
}

class AppUpdateService {
  AppUpdateService._();
  static final AppUpdateService instance = AppUpdateService._();

  static const String owner = 'hasankhan62742-beep';
  static const String repo = 'officerpath-ai';
  static const String latestReleaseUrl =
      'https://api.github.com/repos/$owner/$repo/releases/latest';

  /// False for a Play build (Play forbids self-updates). Driven by the
  /// `--dart-define=PLAY_BUILD=true` build flag — the GitHub CI build
  /// does not pass it, so GitHub builds keep self-update ON by default
  /// and nobody has to remember to flip anything for the normal
  /// release path. See docs/release-signing.md §3 for the full
  /// mechanism (including stripping REQUEST_INSTALL_PACKAGES).
  static bool get selfUpdateEnabled => updateChecksAllowed(
    playBuild: const bool.fromEnvironment('PLAY_BUILD'),
  );

  /// Pure gating logic, so it is unit-testable: a Play build never
  /// checks for updates; any other build does.
  static bool updateChecksAllowed({required bool playBuild}) =>
      !playBuild;

  static const String _dismissedTagKey = 'update_dismissed_tag';

  /// Parses 'v1.3.0' / '1.3' / '1.3.0+4004' into [major, minor, patch].
  /// Returns null when the tag is not a version at all.
  static List<int>? parseVersion(String tag) {
    var s = tag.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    s = s.split('+').first;
    final parts = s.split('.');
    if (parts.isEmpty || parts.length > 3) return null;
    final nums = <int>[];
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null || n < 0) return null;
      nums.add(n);
    }
    while (nums.length < 3) {
      nums.add(0);
    }
    return nums;
  }

  /// -1 when [a] < [b], 0 when equal, 1 when [a] > [b]. Unparseable
  /// versions compare as equal (never offer an update we cannot read).
  static int compareVersions(String a, String b) {
    final av = parseVersion(a);
    final bv = parseVersion(b);
    if (av == null || bv == null) return 0;
    for (var i = 0; i < 3; i++) {
      if (av[i] != bv[i]) return av[i] < bv[i] ? -1 : 1;
    }
    return 0;
  }

  static bool isNewer(String latest, String current) =>
      compareVersions(latest, current) > 0;

  /// Picks the arm64 APK from a release's assets. Prefers an asset whose
  /// name ends with '-arm64.apk'; falls back to any '.apk' asset.
  static Map<String, dynamic>? pickApkAsset(List<dynamic> assets) {
    Map<String, dynamic>? fallback;
    for (final a in assets) {
      if (a is! Map<String, dynamic>) continue;
      final name = (a['name'] as String?) ?? '';
      if (!name.toLowerCase().endsWith('.apk')) continue;
      fallback ??= a;
      if (name.toLowerCase().endsWith('-arm64.apk')) return a;
    }
    return fallback;
  }

  /// Builds the update info from a `releases/latest` JSON body, or null
  /// when there is no newer version or no usable APK asset.
  static AppUpdateInfo? parseLatestRelease(
    Map<String, dynamic> json,
    String currentVersion,
  ) {
    final tag = (json['tag_name'] as String?) ?? '';
    final latest = parseVersion(tag);
    if (latest == null) return null;
    final latestVersion = latest.join('.');
    if (!isNewer(latestVersion, currentVersion)) return null;
    final assets = json['assets'];
    if (assets is! List) return null;
    final asset = pickApkAsset(assets);
    if (asset == null) return null;
    final url = (asset['browser_download_url'] as String?) ?? '';
    final name = (asset['name'] as String?) ?? '';
    if (url.isEmpty || name.isEmpty) return null;
    return AppUpdateInfo(
      latestVersion: latestVersion,
      tag: tag,
      downloadUrl: url,
      fileName: name,
      assetSize: (asset['size'] as num?)?.toInt() ?? 0,
    );
  }

  /// Checks GitHub for a newer release. Returns null when up to date,
  /// offline, rate-limited, or the check fails for any reason — an
  /// update check must never crash the app or block startup.
  Future<AppUpdateInfo?> checkForUpdate({http.Client? client}) async {
    if (!selfUpdateEnabled) return null;
    try {
      final info = await PackageInfo.fromPlatform();
      final httpClient = client ?? http.Client();
      try {
        final res = await httpClient
            .get(
              Uri.parse(latestReleaseUrl),
              headers: {'Accept': 'application/vnd.github+json'},
            )
            .timeout(const Duration(seconds: 15));
        if (res.statusCode != 200) return null;
        final json = jsonDecode(res.body);
        if (json is! Map<String, dynamic>) return null;
        return parseLatestRelease(json, info.version);
      } finally {
        if (client == null) httpClient.close();
      }
    } catch (_) {
      return null;
    }
  }

  /// Downloads the APK and triggers the system installer. The returned
  /// stream reports progress (OtaEvent). The caller shows progress and
  /// handles errors; Android shows the install prompt itself.
  Stream<OtaEvent> downloadAndInstall(AppUpdateInfo update) {
    return OtaUpdate().execute(
      update.downloadUrl,
      destinationFilename: update.fileName,
    );
  }

  /// The user dismissed the prompt for [tag] — don't nag again for the
  /// same release. A newer release still prompts.
  Future<bool> isDismissed(String tag) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_dismissedTagKey) == tag;
  }

  Future<void> dismiss(String tag) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dismissedTagKey, tag);
  }

  /// Installed version string, e.g. '1.2.0'. Empty when unreadable.
  Future<String> currentVersion() async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return '';
    }
  }
}
