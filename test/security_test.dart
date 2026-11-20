import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// v1.2 security regression tests (source-level — they fail the build
/// if a hardening ever regresses):
/// * the Gemini key lives in flutter_secure_storage only (never
///   SharedPreferences / logs);
/// * no cleartext `http://` URL in lib/ (the network security config
///   blocks cleartext, and the Dawn feed is HTTPS-only now);
/// * the retired `gemini-2.5-flash-lite` model id is nowhere in lib/
///   (it 404s for new users — the primary is `gemini-3.5-flash-lite`);
/// * no hardcoded API key / default activation secret in lib/;
/// * network security config + backup rules exist in the manifest.
void main() {
  String read(String path) => File(path).readAsStringSync();

  List<File> libDartFiles() {
    final lib = Directory('lib');
    return lib
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
  }

  /// Strips `//` line comments so doc comments that NAME a forbidden
  /// thing (to say "never do this") do not trip the check — only real
  /// code counts.
  String codeOnly(String src) => src
      .split('\n')
      .where((line) => !line.trim().startsWith('///') && !line.trim().startsWith('//'))
      .join('\n');

  test('no http:// URLs in lib/ (cleartext is blocked)', () {
    final offenders = <String>[];
    for (final f in libDartFiles()) {
      final content = codeOnly(read(f.path));
      // Namespace URIs (schemas.android.com etc.) are not URLs the
      // app fetches — lib/ has none, but keep the rule precise: any
      // 'http://' followed by a host is an offender.
      for (final m in RegExp(r"http://[a-zA-Z0-9]").allMatches(content)) {
        offenders.add('${f.path}:${m.group(0)}');
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('no retired gemini-2.5-flash-lite model id in lib/', () {
    final offenders = <String>[];
    for (final f in libDartFiles()) {
      if (codeOnly(read(f.path)).contains('gemini-2.5-flash-lite')) {
        offenders.add(f.path);
      }
    }
    expect(offenders, isEmpty);
  });

  test('no hardcoded Gemini key or default activation secret in lib/',
      () {
    final offenders = <String>[];
    for (final f in libDartFiles()) {
      final content = read(f.path);
      if (RegExp(r'AIza[0-9A-Za-z_\-]{10,}').hasMatch(content)) {
        offenders.add('${f.path}: looks like a hardcoded API key');
      }
      // The activation secret default must never be a real value in
      // source — the mint tool refuses a default (see
      // manual_activation.dart).
      if (content.contains('DEFAULT_ACTIVATION_SECRET')) {
        offenders.add('${f.path}: default activation secret present');
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('Gemini key goes through secure storage, never SharedPreferences',
      () {
    final keyStore = codeOnly(read('lib/services/secure_key_store.dart'));
    expect(keyStore, contains('FlutterSecureStorage'));
    expect(keyStore, contains('gemini_api_key_v1'));
    expect(keyStore, isNot(contains('SharedPreferences')));
    // The upload/settings code never writes the key anywhere else.
    final upload = codeOnly(read('lib/screens/upload_screen.dart'));
    expect(upload, isNot(contains('SharedPreferences')));
    final settings = codeOnly(read('lib/screens/ai_settings_screen.dart'));
    expect(settings, contains('GeminiKeyStore'));
    expect(settings, isNot(contains('SharedPreferences')));
    expect(
      read('pubspec.yaml'),
      contains('flutter_secure_storage'),
    );
  });

  test('network security config blocks cleartext; backups are off', () {
    final config = read(
      'android/app/src/main/res/xml/network_security_config.xml',
    );
    expect(config, contains('cleartextTrafficPermitted="false"'));
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    expect(
      manifest,
      contains('android:networkSecurityConfig="@xml/network_security_config"'),
    );
    // allowBackup=false: secure-storage / entitlement data is never
    // backed up to (or restored from) another device.
    expect(manifest, contains('android:allowBackup="false"'));
  });

  test('release build enables R8 obfuscation', () {
    final gradle = read('android/app/build.gradle.kts');
    expect(gradle, contains('isMinifyEnabled = true'));
    expect(gradle, contains('isShrinkResources = true'));
  });

  // v1.3: REQUEST_INSTALL_PACKAGES is the only extra permission, and
  // only for the GitHub-sideload updater (install the downloaded APK).
  // Android still asks the user once to allow "Install unknown apps"
  // for OfficerPath; no silent install is possible for a regular app.
  // A future Play build must drop this permission (Play forbids
  // self-updates) — see AppUpdateService.selfUpdateEnabled.
  // v1.3 fix: WRITE_EXTERNAL_STORAGE, capped at SDK 28, for saving a
  // result PDF to Downloads on Android 9 and below (MediaStore on
  // Android 10+ needs no permission).
  // v2.0.0 push: POST_NOTIFICATIONS, the Android 13+ runtime
  // permission for FCM notifications — asked once, after first login
  // (see PushService). No other permissions may be added without
  // updating this list and saying why.
  test('only the expected permissions are declared', () {
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    final permissions = RegExp(
      r'android:name="android\.permission\.([A-Z_]+)"',
    ).allMatches(manifest).map((m) => m.group(1)).toList();
    expect(permissions, [
      'INTERNET',
      'REQUEST_INSTALL_PACKAGES',
      'WRITE_EXTERNAL_STORAGE',
      'POST_NOTIFICATIONS',
    ]);
  });
}
