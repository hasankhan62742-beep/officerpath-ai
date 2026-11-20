import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The user's own Gemini API key — stored ONLY in platform secure
/// storage (Android Keystore via flutter_secure_storage).
///
/// NEVER in SharedPreferences, NEVER in sqflite, NEVER in a log, and
/// NEVER sent anywhere except directly to Google's Gemini API
/// (see [GeminiClient]). There is no key in the source code and no
/// default key: [readKey] returns null until the user enters one in
/// Settings.
///
/// [SecureStore] is the seam tests use: the real app passes the
/// platform store, tests pass an in-memory fake — so a test can prove
/// the key never touches SharedPreferences without a device.
abstract class SecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class PlatformSecureStore implements SecureStore {
  PlatformSecureStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// In-memory fake secure store — tests only. It behaves like secure
/// storage (read/write/delete) without touching the platform.
class InMemorySecureStore implements SecureStore {
  final _map = <String, String>{};

  @override
  Future<String?> read(String key) async => _map[key];

  @override
  Future<void> write(String key, String value) async {
    _map[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _map.remove(key);
  }
}

/// The Gemini key, behind secure storage only.
class GeminiKeyStore {
  GeminiKeyStore([SecureStore? store])
    : _store = store ?? PlatformSecureStore();

  static const String _keyName = 'gemini_api_key_v1';

  final SecureStore _store;

  Future<bool> hasKey() async {
    final key = await _store.read(_keyName);
    return key != null && key.trim().isNotEmpty;
  }

  /// Returns the stored key, or null when none is configured.
  /// Callers must never log the return value.
  Future<String?> readKey() async {
    final key = await _store.read(_keyName);
    if (key == null || key.trim().isEmpty) return null;
    return key.trim();
  }

  Future<void> saveKey(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await _store.delete(_keyName);
      return;
    }
    await _store.write(_keyName, trimmed);
  }

  Future<void> deleteKey() => _store.delete(_keyName);
}
