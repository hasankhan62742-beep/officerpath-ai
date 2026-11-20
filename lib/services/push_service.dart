import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';
import 'supabase_config.dart';

/// Push notifications (Firebase Cloud Messaging) for OfficerPath AI v2.0.0.
///
/// Push is ONLY the announcement that a new version exists (or a short
/// admin announcement). The in-app updater ([AppUpdateService]) stays
/// the update mechanism: tapping an update notification opens the
/// About screen, whose "Check for updates" runs the real update flow.
///
/// SAFETY / HONESTY:
/// * Firebase is optional. When `google-services.json` is missing or
///   still the placeholder, [initialize] returns false, push is
///   DISABLED and the app works normally — never a crash.
/// * No Firebase server key / service-account material anywhere in
///   this file or the app. Sending happens server-side only, in the
///   `send-notification` Edge Function (see docs/push-setup.md).
/// * Opt-out is enforced twice: the app deletes its local FCM token
///   ([setNotificationsEnabled]) AND the Edge Function re-checks
///   `profiles.notifications_enabled` before sending.
///
/// Testability: [PushService] never touches `FirebaseMessaging.instance`
/// or `Supabase.instance` directly. It talks to small ports
/// ([MessagingPort], [FirebaseInitPort], [PushProfileStore],
/// [PushAuthPort]) — production passes the real ones, tests pass fakes.
/// The payload builders and [shouldSendToUser] / [parseNotificationTap]
/// are pure static helpers with no network and no platform channels.

/// Where a tapped notification should take the user.
enum PushDestination {
  /// Open the About screen ("Check for updates" runs the updater).
  update,

  /// Open Home (default for announcements / unknown payloads).
  home,
}

/// The narrow slice of Firebase Messaging [PushService] needs, as an
/// interface so tests can fake it without platform channels.
abstract class MessagingPort {
  Future<String?> getToken();
  Future<void> deleteToken();

  /// True when the user granted (or provisionally granted)
  /// notification permission.
  Future<bool> requestPermission();

  Stream<String> get onTokenRefresh;
  Stream<RemoteMessage> get onMessage;
  Stream<RemoteMessage> get onMessageOpenedApp;
  Future<RemoteMessage?> getInitialMessage();
}

/// Real [MessagingPort] backed by `FirebaseMessaging.instance`.
/// Lazy: `FirebaseMessaging.instance` throws `[core/no-app]` when no
/// Firebase app was initialised (e.g. widget tests, offline builds),
/// so the instance is only touched when a method actually runs —
/// never in the constructor. That keeps `PushService.instance`
/// constructible in tests and offline builds; real use happens only
/// after a successful [PushService.initialize].
class RealMessagingPort implements MessagingPort {
  RealMessagingPort([FirebaseMessaging? messaging])
    : _messagingOverride = messaging;

  final FirebaseMessaging? _messagingOverride;

  FirebaseMessaging get _messaging =>
      _messagingOverride ?? FirebaseMessaging.instance;

  @override
  Future<String?> getToken() => _messaging.getToken();

  @override
  Future<void> deleteToken() => _messaging.deleteToken();

  @override
  Future<bool> requestPermission() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    return settings.authorizationStatus ==
            AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }

  @override
  Stream<String> get onTokenRefresh => _messaging.onTokenRefresh;

  @override
  Stream<RemoteMessage> get onMessage => FirebaseMessaging.onMessage;

  @override
  Stream<RemoteMessage> get onMessageOpenedApp =>
      FirebaseMessaging.onMessageOpenedApp;

  @override
  Future<RemoteMessage?> getInitialMessage() =>
      _messaging.getInitialMessage();
}

/// The narrow slice of Firebase initialisation [PushService] needs.
abstract class FirebaseInitPort {
  /// True when Firebase initialised (or was already initialised).
  /// False when there is no usable config — never throws.
  Future<bool> initialize();
}

/// Real [FirebaseInitPort]: `Firebase.initializeApp()` in try/catch.
/// A missing or placeholder `google-services.json` throws here, and
/// that is the "push disabled" signal — not a crash.
class RealFirebaseInitPort implements FirebaseInitPort {
  @override
  Future<bool> initialize() async {
    try {
      if (Firebase.apps.isNotEmpty) return true;
      await Firebase.initializeApp();
      return true;
    } catch (e) {
      debugPrint('PushService: Firebase unavailable — push disabled: $e');
      return false;
    }
  }
}

/// The narrow slice of auth [PushService] needs: is anyone signed in,
/// and is Supabase configured at all.
abstract class PushAuthPort {
  bool get isConfigured;
  bool get isSignedIn;
  String? get currentUserId;
}

/// Production [PushAuthPort] backed by [AuthService].
class AuthServicePushAuthPort implements PushAuthPort {
  AuthServicePushAuthPort([AuthService? auth]) : _auth = auth ?? AuthService();

  final AuthService _auth;

  @override
  bool get isConfigured => _auth.isConfigured;

  @override
  bool get isSignedIn => _auth.isSignedIn;

  @override
  String? get currentUserId => _auth.currentUserId;
}

/// The narrow slice of the `profiles` table [PushService] needs.
abstract class PushProfileStore {
  Future<void> updateToken(String userId, String token);
  Future<void> setNotificationsEnabled(String userId, bool enabled);

  /// Null when the row / column could not be read — callers treat
  /// null as "enabled" (the DB default is true).
  Future<bool?> fetchNotificationsEnabled(String userId);
}

/// [PushProfileStore] used when Supabase was never configured.
/// Every call fails fast; [PushService] guards with [isConfigured]
/// first and turns that into a silent no-op.
class UnconfiguredPushProfileStore implements PushProfileStore {
  const UnconfiguredPushProfileStore();

  Never _throw() => throw StateError('Supabase is not configured.');

  @override
  Future<void> updateToken(String userId, String token) => _throw();

  @override
  Future<void> setNotificationsEnabled(String userId, bool enabled) =>
      _throw();

  @override
  Future<bool?> fetchNotificationsEnabled(String userId) => _throw();
}

/// Real [PushProfileStore] backed by a [SupabaseClient].
///
/// The "Users can update their own profile" policy in
/// supabase/migrations/002_rls.sql covers `fcm_token` and
/// `notifications_enabled` (it allows any own-row update that does not
/// grant admin) — no extra policy was needed; see migration 004.
class SupabasePushProfileStore implements PushProfileStore {
  SupabasePushProfileStore(this._client);

  /// Builds the store from the shared initialised client.
  /// Throws when Supabase was never initialised — callers must guard
  /// with [SupabaseConfig.isConfigured] / try-catch.
  factory SupabasePushProfileStore.fromInstance() =>
      SupabasePushProfileStore(Supabase.instance.client);

  final SupabaseClient _client;

  @override
  Future<void> updateToken(String userId, String token) async {
    await _client
        .from('profiles')
        .update(PushService.buildTokenUpdate(token: token))
        .eq('id', userId);
  }

  @override
  Future<void> setNotificationsEnabled(String userId, bool enabled) async {
    await _client
        .from('profiles')
        .update({'notifications_enabled': enabled})
        .eq('id', userId);
  }

  @override
  Future<bool?> fetchNotificationsEnabled(String userId) async {
    final row = await _client
        .from('profiles')
        .select('notifications_enabled')
        .eq('id', userId)
        .maybeSingle();
    if (row == null) return null;
    final value = (row as Map)['notifications_enabled'];
    return value is bool ? value : null;
  }
}

class PushService {
  PushService({
    MessagingPort? messaging,
    FirebaseInitPort? firebaseInit,
    PushProfileStore? profileStore,
    PushAuthPort? auth,
  }) : _messaging = messaging ?? RealMessagingPort(),
       _firebaseInit = firebaseInit ?? RealFirebaseInitPort(),
       _profileStore = profileStore ?? _defaultStore(),
       _auth = auth ?? AuthServicePushAuthPort();

  /// Production entry point: real Firebase + Supabase ports.
  static final PushService instance = PushService();

  static PushProfileStore _defaultStore() {
    if (!SupabaseConfig.isConfigured) {
      return const UnconfiguredPushProfileStore();
    }
    try {
      return SupabasePushProfileStore.fromInstance();
    } catch (_) {
      return const UnconfiguredPushProfileStore();
    }
  }

  final MessagingPort _messaging;
  final FirebaseInitPort _firebaseInit;
  final PushProfileStore _profileStore;
  final PushAuthPort _auth;

  /// SharedPreferences key: the permission question was asked once.
  /// The user is never re-asked every launch.
  static const String permissionAskedKey = 'push_permission_asked_v2';

  bool _initialized = false;
  bool _available = false;

  /// True after a successful [initialize] (Firebase usable).
  bool get isAvailable => _available;

  /// Set by HomeScreen: called for every foreground message so the
  /// UI can show an in-app banner / SnackBar.
  void Function(RemoteMessage message)? onForegroundMessage;

  /// Set by HomeScreen: called when the user taps a notification.
  void Function(PushDestination destination)? onTap;

  // ---------- Pure helpers (no network, no platform channels) ----------

  /// Payload the admin panel / Edge Function sends for a new version.
  /// `data` is what the app reads on tap; `notification` is what the
  /// system tray shows.
  static Map<String, dynamic> buildUpdatePayload({
    required String version,
  }) {
    return {
      'notification': {
        'title': 'OfficerPath AI v$version aa gayi hai',
        'body':
            'Nayi version download karein — aap ke tests aur books mehfooz rahein ge.',
      },
      'data': {'type': 'update_available', 'version': version},
    };
  }

  /// Payload for a plain admin announcement.
  static Map<String, dynamic> buildAnnouncementPayload({
    required String title,
    required String body,
  }) {
    return {
      'notification': {'title': title, 'body': body},
      'data': {'type': 'announcement'},
    };
  }

  /// Server-side audience filter, mirrored here so the app and the
  /// Edge Function agree. Returns false when the user opted out, has
  /// no token, or their plan does not match the audience.
  /// [audience] is 'all' | 'premium' | 'free'; [plan] is 'free' |
  /// 'premium' (anything else is treated as 'free').
  static bool shouldSendToUser({
    required bool notificationsEnabled,
    required String? fcmToken,
    required String audience,
    required String plan,
  }) {
    if (!notificationsEnabled) return false;
    if (fcmToken == null || fcmToken.isEmpty) return false;
    switch (audience) {
      case 'all':
        return true;
      case 'premium':
        return plan == 'premium';
      case 'free':
        return plan != 'premium';
      default:
        return false;
    }
  }

  /// Maps a notification's data payload to a destination.
  /// 'update_available' -> [PushDestination.update]; anything else
  /// (announcement, unknown, missing) -> [PushDestination.home].
  static PushDestination parseNotificationTap(Map<String, dynamic>? data) {
    if (data != null && data['type'] == 'update_available') {
      return PushDestination.update;
    }
    return PushDestination.home;
  }

  /// The `profiles` row patch that stores a fresh FCM token.
  /// Pure except for the timestamp (injectable for tests).
  static Map<String, dynamic> buildTokenUpdate({
    required String token,
    DateTime? now,
  }) {
    return {
      'fcm_token': token,
      'fcm_token_updated_at': (now ?? DateTime.now()).toIso8601String(),
    };
  }

  // ---------- Lifecycle ----------

  /// Initialises Firebase (guarded) and subscribes to token refresh,
  /// foreground messages and notification taps. Returns true when
  /// push is usable. Safe to call when Firebase is not configured —
  /// returns false and the app carries on normally. Idempotent.
  Future<bool> initialize() async {
    if (_initialized) return _available;
    _initialized = true;
    try {
      _available = await _firebaseInit.initialize();
    } catch (_) {
      _available = false;
    }
    if (!_available) return false;
    try {
      _messaging.onTokenRefresh.listen(
        (_) => registerToken(),
        onError: (_) {},
      );
      _messaging.onMessage.listen(
        (message) => onForegroundMessage?.call(message),
        onError: (_) {},
      );
      _messaging.onMessageOpenedApp.listen(
        (message) => onTap?.call(parseNotificationTap(message.data)),
        onError: (_) {},
      );
    } catch (_) {
      // A listener that cannot subscribe must not kill startup.
      _available = false;
    }
    return _available;
  }

  /// True when the permission question has already been asked on this
  /// install (so Home never re-asks every launch).
  Future<bool> get permissionAsked async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(permissionAskedKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Records that the permission question was asked, WITHOUT asking
  /// the system for permission. Used when the user taps "Abhi nahi"
  /// on HomeScreen's explanation dialog — the question was still
  /// asked, so it must not be nagged again next launch.
  Future<void> markPermissionAsked() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(permissionAskedKey, true);
    } catch (_) {}
  }

  /// Asks Android 13+ for the POST_NOTIFICATIONS runtime permission
  /// (via FirebaseMessaging.requestPermission). Records that the
  /// question was asked — whatever the answer — so it is asked at
  /// most once per install. Returns true when granted. The in-app
  /// explanation dialog lives in HomeScreen and runs BEFORE this.
  Future<bool> requestPermission() async {
    if (!_available) return false;
    var granted = false;
    try {
      granted = await _messaging.requestPermission();
    } catch (_) {
      granted = false;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(permissionAskedKey, true);
    } catch (_) {}
    return granted;
  }

  /// Stores the current FCM token in `profiles` for the signed-in
  /// user. Call on login and on app launch (when a session exists).
  /// Returns true when a token was stored. Silent no-op (false) when
  /// push is unavailable, Supabase is unconfigured, or nobody is
  /// signed in — never throws.
  Future<bool> registerToken() async {
    if (!_available) return false;
    if (!_auth.isConfigured || !_auth.isSignedIn) return false;
    final userId = _auth.currentUserId;
    if (userId == null) return false;
    try {
      final token = await _messaging.getToken();
      if (token == null || token.isEmpty) return false;
      await _profileStore.updateToken(userId, token);
      return true;
    } catch (e) {
      debugPrint('PushService: registerToken failed: $e');
      return false;
    }
  }

  /// The user's current opt-out state. Defaults to true (enabled)
  /// when the row cannot be read — the DB default is also true.
  Future<bool> isNotificationsEnabled() async {
    final userId = _auth.currentUserId;
    if (userId == null || !_auth.isConfigured) return true;
    try {
      return await _profileStore.fetchNotificationsEnabled(userId) ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Opt-out / opt-in. When disabling, the local FCM token is also
  /// deleted so nothing can be delivered to this device; the server
  /// re-checks `notifications_enabled` before every send as well.
  /// When enabling, the token is re-registered. Returns true when
  /// the server state was updated.
  Future<bool> setNotificationsEnabled(bool enabled) async {
    final userId = _auth.currentUserId;
    if (userId == null || !_auth.isConfigured) return false;
    try {
      await _profileStore.setNotificationsEnabled(userId, enabled);
      if (!enabled) {
        try {
          await _messaging.deleteToken();
        } catch (_) {
          // Token already gone / Firebase down — the server flag
          // is what actually stops delivery.
        }
      } else {
        await registerToken();
      }
      return true;
    } catch (e) {
      debugPrint('PushService: setNotificationsEnabled failed: $e');
      return false;
    }
  }

  /// The notification that launched a cold app (if any), mapped to
  /// its destination. Null when the app was not opened from a
  /// notification. HomeScreen calls this once on first open.
  Future<PushDestination?> consumeInitialMessage() async {
    if (!_available) return null;
    try {
      final message = await _messaging.getInitialMessage();
      if (message == null) return null;
      return parseNotificationTap(message.data);
    } catch (_) {
      return null;
    }
  }
}
