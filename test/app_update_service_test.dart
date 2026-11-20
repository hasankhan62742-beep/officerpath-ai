import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/app_update_service.dart';
import 'package:ota_update/ota_update.dart';

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

  group('pickApkAsset — exact -arm64.apk only (M3)', () {
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

    test('returns null when there is only a non-arm64 APK (no fallback)', () {
      final assets = [
        {
          'name': 'officerpath-ai-v1.3.0.apk',
          'browser_download_url': 'https://example.com/app.apk',
        },
      ];
      expect(AppUpdateService.pickApkAsset(assets), isNull);
    });

    test('ignores non-APK assets and returns null when there is no APK', () {
      expect(
        AppUpdateService.pickApkAsset([
          {'name': 'source.zip', 'browser_download_url': 'https://x/z.zip'},
          {
            'name': 'officerpath-ai-v1.3.0-arm64.apk.sha256',
            'browser_download_url': 'https://x/a.sha256',
          },
        ]),
        isNull,
      );
      expect(AppUpdateService.pickApkAsset([]), isNull);
    });

    test('matches the -arm64.apk suffix case-insensitively', () {
      expect(
        AppUpdateService.pickApkAsset([
          {
            'name': 'officerpath-ai-v1.3.0-ARM64.APK',
            'browser_download_url': 'https://example.com/arm64.apk',
          },
        ])?['name'],
        'officerpath-ai-v1.3.0-ARM64.APK',
      );
    });
  });

  group('pickChecksumAsset (M3)', () {
    const apkName = 'officerpath-ai-2.0.1-arm64.apk';
    final assets = [
      {
        'name': apkName,
        'browser_download_url': 'https://example.com/app.apk',
      },
      {
        'name': '$apkName.sha256',
        'browser_download_url': 'https://example.com/app.apk.sha256',
      },
      {
        'name': 'officerpath-ai-2.0.1-arm64.apk.sha256.sig',
        'browser_download_url': 'https://example.com/other',
      },
    ];

    test('picks the exact <apk>.sha256 sidecar', () {
      final picked = AppUpdateService.pickChecksumAsset(assets, apkName);
      expect(picked?['name'], '$apkName.sha256');
      expect(
        picked?['browser_download_url'],
        'https://example.com/app.apk.sha256',
      );
    });

    test('returns null when the sidecar is absent', () {
      expect(
        AppUpdateService.pickChecksumAsset([assets.first], apkName),
        isNull,
      );
      expect(AppUpdateService.pickChecksumAsset([], apkName), isNull);
      expect(AppUpdateService.pickChecksumAsset(assets, ''), isNull);
    });

    test('does not pick a checksum for a different APK name', () {
      expect(
        AppUpdateService.pickChecksumAsset(
          assets,
          'officerpath-ai-2.0.2-arm64.apk',
        ),
        isNull,
      );
    });
  });

  group('parseSha256Content (M3)', () {
    const apkName = 'officerpath-ai-2.0.1-arm64.apk';
    const hash =
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

    test('parses sha256sum format "<hash>  <filename>"', () {
      expect(
        AppUpdateService.parseSha256Content(
          '$hash  $apkName\n',
          apkName,
        ),
        hash,
      );
    });

    test('parses a bare hash line', () {
      expect(AppUpdateService.parseSha256Content('$hash\n', apkName), hash);
    });

    test('lowercases an uppercase hash', () {
      expect(
        AppUpdateService.parseSha256Content(
          '${hash.toUpperCase()}  $apkName\n',
          apkName,
        ),
        hash,
      );
    });

    test('tolerates the binary-mode "*" marker', () {
      expect(
        AppUpdateService.parseSha256Content(
          '$hash *$apkName\n',
          apkName,
        ),
        hash,
      );
    });

    test('rejects a checksum for a different filename', () {
      expect(
        AppUpdateService.parseSha256Content(
          '$hash  officerpath-ai-2.0.2-arm64.apk\n',
          apkName,
        ),
        isNull,
      );
    });

    test('rejects garbage, short hashes and empty content', () {
      expect(
        AppUpdateService.parseSha256Content('not-a-hash\n', apkName),
        isNull,
      );
      expect(
        AppUpdateService.parseSha256Content('abcd  $apkName\n', apkName),
        isNull,
      );
      expect(AppUpdateService.parseSha256Content('', apkName), isNull);
      expect(AppUpdateService.parseSha256Content('\n\n', apkName), isNull);
    });
  });

  group('isValidSha256Hex', () {
    test('accepts 64 hex chars in either case, rejects the rest', () {
      const hash =
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
      expect(AppUpdateService.isValidSha256Hex(hash), isTrue);
      expect(
        AppUpdateService.isValidSha256Hex(hash.toUpperCase()),
        isTrue,
      );
      expect(AppUpdateService.isValidSha256Hex(null), isFalse);
      expect(AppUpdateService.isValidSha256Hex(''), isFalse);
      expect(AppUpdateService.isValidSha256Hex(hash.substring(1)), isFalse);
      expect(AppUpdateService.isValidSha256Hex('$hash aa'), isFalse);
      expect(
        AppUpdateService.isValidSha256Hex('g' * 64),
        isFalse,
      );
    });
  });

  group('sha256Hex / verifyApkBytes / matchesExpectedSize (M3)', () {
    // SHA-256('abc') — the standard test vector.
    const abcHash =
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
    final abc = utf8.encode('abc');

    test('sha256Hex matches the known SHA-256("abc") vector', () {
      expect(AppUpdateService.sha256Hex(abc), abcHash);
      expect(AppUpdateService.sha256Hex([]), startsWith('e3b0c44298fc'));
    });

    test('verifyApkBytes passes for matching bytes, hash and size', () {
      expect(AppUpdateService.verifyApkBytes(abc, abcHash, 3), isTrue);
    });

    test('verifyApkBytes fails on a hash mismatch', () {
      expect(
        AppUpdateService.verifyApkBytes(
          abc,
          '0' * 64,
          3,
        ),
        isFalse,
      );
      expect(
        AppUpdateService.verifyApkBytes(utf8.encode('abd'), abcHash, 3),
        isFalse,
      );
    });

    test('verifyApkBytes fails on a size mismatch', () {
      expect(AppUpdateService.verifyApkBytes(abc, abcHash, 4), isFalse);
      expect(AppUpdateService.verifyApkBytes(abc, abcHash, 2), isFalse);
    });

    test('verifyApkBytes skips the size check when expected size is 0', () {
      expect(AppUpdateService.verifyApkBytes(abc, abcHash, 0), isTrue);
      expect(AppUpdateService.verifyApkBytes(abc, 'not-a-hash', 0), isFalse);
    });

    test('matchesExpectedSize treats 0 as unknown, else exact', () {
      expect(AppUpdateService.matchesExpectedSize(119, 119), isTrue);
      expect(AppUpdateService.matchesExpectedSize(118, 119), isFalse);
      expect(AppUpdateService.matchesExpectedSize(999, 0), isTrue);
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
              {
                'name': 'officerpath-ai-v1.3.0-arm64.apk.sha256',
                'browser_download_url':
                    'https://github.com/x/y/releases/download/v1.3.0/officerpath-ai-v1.3.0-arm64.apk.sha256',
                'size': 105,
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

    test('exposes the checksum sidecar URL and leaves sha256 unfetched', () {
      final info = AppUpdateService.parseLatestRelease(release(), '1.2.0');
      expect(info, isNotNull);
      expect(
        info!.checksumUrl,
        'https://github.com/x/y/releases/download/v1.3.0/officerpath-ai-v1.3.0-arm64.apk.sha256',
      );
      // The pure parser never fetches: the hash is filled in by
      // checkForUpdate() from checksumUrl.
      expect(info.sha256, isNull);
    });

    test('checksumUrl is null when the release has no sidecar', () {
      final info = AppUpdateService.parseLatestRelease(
        release(
          assets: [
            {
              'name': 'officerpath-ai-v1.3.0-arm64.apk',
              'browser_download_url': 'https://example.com/app.apk',
              'size': 100,
            },
          ],
        ),
        '1.2.0',
      );
      expect(info, isNotNull);
      expect(info!.checksumUrl, isNull);
      expect(info.sha256, isNull);
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

    test('returns null when the release has no arm64 APK asset', () {
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
      // A universal APK alone is NOT enough any more (no fallback).
      expect(
        AppUpdateService.parseLatestRelease(
          release(assets: [
            {
              'name': 'officerpath-ai-v1.3.0.apk',
              'browser_download_url': 'https://example.com/app.apk',
              'size': 100,
            },
          ]),
          '1.2.0',
        ),
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

  group('downloadAndInstall — fail closed without a checksum (M3)', () {
    const noChecksum = AppUpdateInfo(
      latestVersion: '2.0.1',
      tag: 'v2.0.1',
      downloadUrl: 'https://example.com/officerpath-ai-2.0.1-arm64.apk',
      fileName: 'officerpath-ai-2.0.1-arm64.apk',
      assetSize: 123,
    );

    test('emits a single CHECKSUM_ERROR and never starts a download', () async {
      final events = await AppUpdateService.instance
          .downloadAndInstall(noChecksum)
          .toList();
      expect(events, hasLength(1));
      expect(events.first.status, OtaStatus.CHECKSUM_ERROR);
      expect(events.first.value, contains('checksum'));
    });

    test('refuses an invalid (non-hex / short) checksum the same way', () async {
      for (final bad in ['not-a-hash', 'abcd', 'g' * 64, '']) {
        final events = await AppUpdateService.instance
            .downloadAndInstall(noChecksum.copyWith(sha256: bad))
            .toList();
        expect(events, hasLength(1));
        expect(events.first.status, OtaStatus.CHECKSUM_ERROR);
      }
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
