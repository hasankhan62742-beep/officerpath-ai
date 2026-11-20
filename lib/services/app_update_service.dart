import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
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
/// VERIFICATION (M3, v2.0.0): the release carries a SHA-256 sidecar,
/// `officerpath-ai-<version>-arm64.apk.sha256`, published by CI
/// (see .github/workflows/build-apk.yml). [checkForUpdate] fetches that
/// sidecar over HTTPS from the same release API response, and
/// [downloadAndInstall] FAILS CLOSED without a valid expected hash:
/// it never starts a download, and the installer is never triggered.
/// When a hash is present it is passed to `OtaUpdate.execute()` as
/// `sha256checksum`; the plugin's native code (ota_update 7.1.0,
/// `Sha256ChecksumValidator`) hashes the downloaded file and only
/// triggers the installer when the hash matches — on mismatch it
/// emits [OtaStatus.CHECKSUM_ERROR] and does NOT install. The Dart
/// side never sees the downloaded file (the plugin owns the
/// download -> install handoff), so the hash check on the live path is
/// enforced natively; [verifyApkBytes] is the pure-Dart form of the
/// same rule (size first, then SHA-256) and is what the tests cover.
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
    this.checksumUrl,
    this.sha256,
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

  /// Direct download URL of the `<fileName>.sha256` sidecar asset, or
  /// null when the release carries no checksum asset.
  final String? checksumUrl;

  /// Expected SHA-256 of the APK (lowercase hex), fetched from
  /// [checksumUrl] by [AppUpdateService.checkForUpdate]. Null until
  /// fetched, and null when the release has no usable checksum —
  /// [AppUpdateService.downloadAndInstall] refuses to install then.
  final String? sha256;

  AppUpdateInfo copyWith({String? sha256}) => AppUpdateInfo(
    latestVersion: latestVersion,
    tag: tag,
    downloadUrl: downloadUrl,
    fileName: fileName,
    assetSize: assetSize,
    checksumUrl: checksumUrl,
    sha256: sha256 ?? this.sha256,
  );
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

  /// Picks the arm64 APK from a release's assets. Only an asset whose
  /// name ends with '-arm64.apk' counts — there is deliberately NO
  /// fallback to any other '.apk' asset (M3): installing a wrong-ABI
  /// or wrong-file APK must never happen silently.
  static Map<String, dynamic>? pickApkAsset(List<dynamic> assets) {
    for (final a in assets) {
      if (a is! Map<String, dynamic>) continue;
      final name = (a['name'] as String?) ?? '';
      if (name.toLowerCase().endsWith('-arm64.apk')) return a;
    }
    return null;
  }

  /// Picks the SHA-256 sidecar for [apkName] from a release's assets:
  /// the asset whose name is the APK name plus '.sha256'. Null when
  /// absent.
  static Map<String, dynamic>? pickChecksumAsset(
    List<dynamic> assets,
    String apkName,
  ) {
    if (apkName.isEmpty) return null;
    final wanted = '$apkName.sha256';
    for (final a in assets) {
      if (a is! Map<String, dynamic>) continue;
      if ((a['name'] as String?) == wanted) return a;
    }
    return null;
  }

  /// True when [value] is a 64-character hex string (either case).
  static bool isValidSha256Hex(String? value) {
    if (value == null || value.length != 64) return false;
    return RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value);
  }

  /// Parses a `.sha256` sidecar body and returns the expected hash
  /// (lowercase hex), or null when the content is unusable. Accepts
  /// the `sha256sum` format (`<hash>  <filename>`, the `*` binary
  /// marker tolerated) and a bare `<hash>` line. When a filename is
  /// present it must match [apkFileName] exactly — a checksum for a
  /// different file is rejected rather than trusted.
  static String? parseSha256Content(String content, String apkFileName) {
    for (final rawLine in content.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final parts = line.split(RegExp(r'\s+'));
      final hash = parts.first.toLowerCase();
      if (!isValidSha256Hex(hash)) return null;
      if (parts.length > 1) {
        var name = parts[1];
        if (name.startsWith('*')) name = name.substring(1);
        if (name != apkFileName) return null;
      }
      return hash;
    }
    return null;
  }

  /// SHA-256 hex digest (lowercase) of [bytes].
  static String sha256Hex(List<int> bytes) =>
      crypto.sha256.convert(bytes).toString();

  /// True when [actualBytes] matches [expectedSize]. An expected size
  /// of 0 means "unknown" (GitHub did not report one) and is not a
  /// failure — the hash check below is what enforces integrity then.
  static bool matchesExpectedSize(int actualBytes, int expectedSize) =>
      expectedSize <= 0 || actualBytes == expectedSize;

  /// Verifies downloaded APK bytes against the release metadata:
  /// size first (cheap early-out), then SHA-256. This is the
  /// pure-Dart form of the rule the native updater enforces on the
  /// live path (see the class doc): a size mismatch fails here, and
  /// any byte difference — including a size difference — fails the
  /// hash, so the hash alone subsumes the size check.
  static bool verifyApkBytes(
    List<int> bytes,
    String expectedSha256,
    int expectedSize,
  ) {
    if (!matchesExpectedSize(bytes.length, expectedSize)) return false;
    if (!isValidSha256Hex(expectedSha256)) return false;
    return sha256Hex(bytes).toLowerCase() == expectedSha256.toLowerCase();
  }

  /// Builds the update info from a `releases/latest` JSON body, or null
  /// when there is no newer version or no usable APK asset. The
  /// checksum itself is NOT fetched here (this is a pure sync parse);
  /// [checkForUpdate] fills [AppUpdateInfo.sha256] from
  /// [AppUpdateInfo.checksumUrl] afterwards.
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
    final checksumAsset = pickChecksumAsset(assets, name);
    final checksumUrl =
        (checksumAsset?['browser_download_url'] as String?) ?? '';
    return AppUpdateInfo(
      latestVersion: latestVersion,
      tag: tag,
      downloadUrl: url,
      fileName: name,
      assetSize: (asset['size'] as num?)?.toInt() ?? 0,
      checksumUrl: checksumUrl.isEmpty ? null : checksumUrl,
    );
  }

  /// Checks GitHub for a newer release. Returns null when up to date,
  /// offline, rate-limited, or the check fails for any reason — an
  /// update check must never crash the app or block startup.
  ///
  /// When a newer release is found, its `.sha256` sidecar (if any) is
  /// fetched over HTTPS from the same release response and parsed into
  /// [AppUpdateInfo.sha256]. A missing or unparseable checksum does NOT
  /// hide the update — it is enforced later: [downloadAndInstall]
  /// refuses to install without a valid expected hash.
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
        final parsed = parseLatestRelease(json, info.version);
        if (parsed == null) return null;
        final checksumUrl = parsed.checksumUrl;
        if (checksumUrl == null || checksumUrl.isEmpty) return parsed;
        try {
          final sumRes = await httpClient
              .get(Uri.parse(checksumUrl))
              .timeout(const Duration(seconds: 15));
          if (sumRes.statusCode != 200) return parsed;
          final sha256 = parseSha256Content(sumRes.body, parsed.fileName);
          if (sha256 == null) return parsed;
          return parsed.copyWith(sha256: sha256);
        } catch (_) {
          return parsed;
        }
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
  ///
  /// FAIL CLOSED (M3): when [update.sha256] is missing or not a valid
  /// SHA-256 hex string, no download is started and the installer is
  /// never triggered — the stream emits a single
  /// [OtaStatus.CHECKSUM_ERROR] event instead. When a valid hash is
  /// present it is passed to the updater as `sha256checksum`, and the
  /// plugin verifies the downloaded file's hash BEFORE triggering the
  /// installer (mismatch -> CHECKSUM_ERROR, no install).
  Stream<OtaEvent> downloadAndInstall(AppUpdateInfo update) {
    final expected = update.sha256;
    if (expected == null || !isValidSha256Hex(expected)) {
      return Stream<OtaEvent>.value(
        OtaEvent(
          OtaStatus.CHECKSUM_ERROR,
          'Update ki tasdeeq nahi ho saki (checksum missing) — install '
          'roka gaya.',
        ),
      );
    }
    // Never throw synchronously: OtaUpdate.execute() throws
    // OtaUpdateException for an invalid filename (a '/' in it) —
    // thrown from the download dialog's initState that would break
    // the dialog instead of showing an honest error. Fail closed
    // with a DOWNLOAD_ERROR event, like every other failure.
    try {
      return OtaUpdate().execute(
        update.downloadUrl,
        destinationFilename: update.fileName,
        sha256checksum: expected.toLowerCase(),
      );
    } on OtaUpdateException catch (e) {
      return Stream<OtaEvent>.value(
        OtaEvent(
          OtaStatus.DOWNLOAD_ERROR,
          'Update start nahi ho saka (${e.message}) — GitHub link se '
          'install karein.',
        ),
      );
    }
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
