import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/app_update_service.dart';

void main() {
  group('parseVersion', () {
    test('parses v-prefixed and plain versions', () {
      expect(AppUpdateService.parseVersion('v1.3.0'), [1, 3, 0]);
      expect(AppUpdateService.parseVersion('1.2.0'), [1, 2, 0]);
      expect(AppUpdateService.parseVersion('1.3'), [1, 3, 0]);
      expect(AppUpdateService.parseVersion('1.3.0+4004'), [1, 3, 0]);
      expect(AppUpdateService.parseVersion('  v2.0.1  '), [2, 0, 1]);
    });

    test('rejects non-versions', () {
      expect(AppUpdateService.parseVersion(''), isNull);
      expect(AppUpdateService.parseVersion('latest'), isNull);
      expect(AppUpdateService.parseVersion('v1.3.0-beta'), isNull);
      expect(AppUpdateService.parseVersion('1.2.3.4'), isNull);
      expect(AppUpdateService.parseVersion('v1.x.0'), isNull);
    });
  });

  group('compareVersions / isNewer', () {
    test('orders versions numerically, not lexicographically', () {
      expect(AppUpdateService.compareVersions('1.10.0', '1.9.0'), 1);
      expect(AppUpdateService.compareVersions('1.2.0', '1.10.0'), -1);
      expect(AppUpdateService.compareVersions('1.3.0', '1.3.0'), 0);
      expect(AppUpdateService.compareVersions('v1.3.0', '1.2.1'), 1);
      expect(AppUpdateService.compareVersions('2.0.0', '1.99.99'), 1);
    });

    test('isNewer is true only for a strictly newer release', () {
      expect(AppUpdateService.isNewer('1.3.0', '1.2.0'), isTrue);
      expect(AppUpdateService.isNewer('1.2.0', '1.2.0'), isFalse);
      expect(AppUpdateService.isNewer('1.2.0', '1.3.0'), isFalse);
      expect(AppUpdateService.isNewer('latest', '1.2.0'), isFalse);
    });
  });

  group('pickApkAsset', () {
    test('prefers the arm64 APK over other APKs', () {
      final assets = [
        {
          'name': 'officerpath-ai-v1.3.0.apk',
          'browser_download_url': 'https://example.com/universal.apk',
        },
        {
          'name': 'officerpath-ai-v1.3.0-arm64.apk',
          'browser_download_url': 'https://example.com/arm64.apk',
        },
      ];
      final picked = AppUpdateService.pickApkAsset(assets);
      expect(picked?['name'], 'officerpath-ai-v1.3.0-arm64.apk');
    });

    test('falls back to any APK when there is no arm64 build', () {
      final assets = [
        {
          'name': 'officerpath-ai-v1.3.0.apk',
          'browser_download_url': 'https://example.com/app.apk',
        },
      ];
      expect(
        AppUpdateService.pickApkAsset(assets)?['name'],
        'officerpath-ai-v1.3.0.apk',
      );
    });

    test('ignores non-APK assets and returns null when there is no APK', () {
      expect(
        AppUpdateService.pickApkAsset([
          {'name': 'source.zip', 'browser_download_url': 'https://x/z.zip'},
        ]),
        isNull,
      );
      expect(AppUpdateService.pickApkAsset([]), isNull);
    });
  });

  group('parseLatestRelease', () {
    Map<String, dynamic> release({
      String tag = 'v1.3.0',
      List<Map<String, dynamic>>? assets,
    }) {
      return {
        'tag_name': tag,
        'assets':
            assets ??
            [
              {
                'name': 'officerpath-ai-v1.3.0-arm64.apk',
                'browser_download_url':
                    'https://github.com/x/y/releases/download/v1.3.0/officerpath-ai-v1.3.0-arm64.apk',
                'size': 119172927,
              },
            ],
      };
    }

    test('returns update info for a newer release', () {
      final info = AppUpdateService.parseLatestRelease(release(), '1.2.0');
      expect(info, isNotNull);
      expect(info!.latestVersion, '1.3.0');
      expect(info.tag, 'v1.3.0');
      expect(info.fileName, 'officerpath-ai-v1.3.0-arm64.apk');
      expect(info.assetSize, 119172927);
      expect(info.downloadUrl, contains('releases/download/v1.3.0/'));
    });

    test('returns null when already on the latest version', () {
      expect(
        AppUpdateService.parseLatestRelease(release(), '1.3.0'),
        isNull,
      );
      expect(
        AppUpdateService.parseLatestRelease(release(), '1.4.0'),
        isNull,
      );
    });

    test('returns null when the tag is not a version', () {
      expect(
        AppUpdateService.parseLatestRelease(release(tag: 'latest'), '1.2.0'),
        isNull,
      );
    });

    test('returns null when the release has no APK asset', () {
      expect(
        AppUpdateService.parseLatestRelease(
          release(assets: [
            {
              'name': 'source.zip',
              'browser_download_url': 'https://x/z.zip',
            },
          ]),
          '1.2.0',
        ),
        isNull,
      );
      expect(
        AppUpdateService.parseLatestRelease(release(assets: []), '1.2.0'),
        isNull,
      );
    });

    test('returns null when the asset has no download URL', () {
      expect(
        AppUpdateService.parseLatestRelease(
          release(assets: [
            {'name': 'officerpath-ai-v1.3.0-arm64.apk'},
          ]),
          '1.2.0',
        ),
        isNull,
      );
    });
  });

  group('updateChecksAllowed — Play gating (v2.0.0)', () {
    test('GitHub build checks for updates; Play build never does', () {
      expect(
        AppUpdateService.updateChecksAllowed(playBuild: false),
        isTrue,
      );
      expect(
        AppUpdateService.updateChecksAllowed(playBuild: true),
        isFalse,
      );
    });

    test('selfUpdateEnabled defaults to true (GitHub build)', () {
      // No --dart-define=PLAY_BUILD is passed to `flutter test`, so
      // the default build is the GitHub one: self-update ON. A Play
      // build passes PLAY_BUILD=true and this flips to false — see
      // docs/release-signing.md §3.
      expect(AppUpdateService.selfUpdateEnabled, isTrue);
    });
  });
}
