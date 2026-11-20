import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/screens/account_settings_screen.dart';
import 'package:officerpath_ai/services/push_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Push service tests — mocked FCM, no network, no platform channels.
///
/// The pure helpers (payloads, audience filter, tap parsing, token
/// patch) are tested directly. The service itself is tested through
/// the same ports production uses, with fakes below.

class FakeMessagingPort implements MessagingPort {
  String? tokenToReturn = 'fake-fcm-token-123';
  bool deleteTokenCalled = false;
  bool requestPermissionCalled = false;
  bool permissionGranted = true;
  RemoteMessage? initialMessage;

  final _tokenRefresh = StreamController<String>.broadcast();
  final _onMessage = StreamController<RemoteMessage>.broadcast();
  final _onMessageOpenedApp = StreamController<RemoteMessage>.broadcast();

  @override
  Future<String?> getToken() async => tokenToReturn;

  @override
  Future<void> deleteToken() async {
    deleteTokenCalled = true;
  }

  @override
  Future<bool> requestPermission() async {
    requestPermissionCalled = true;
    return permissionGranted;
  }

  @override
  Stream<String> get onTokenRefresh => _tokenRefresh.stream;

  @override
  Stream<RemoteMessage> get onMessage => _onMessage.stream;

  @override
  Stream<RemoteMessage> get onMessageOpenedApp => _onMessageOpenedApp.stream;

  @override
  Future<RemoteMessage?> getInitialMessage() async => initialMessage;

  void dispose() {
    _tokenRefresh.close();
    _onMessage.close();
    _onMessageOpenedApp.close();
  }
}

class FakeFirebaseInitPort implements FirebaseInitPort {
  FakeFirebaseInitPort({this.available = true});

  bool available;

  @override
  Future<bool> initialize() async => available;
}

class FakePushAuthPort implements PushAuthPort {
  FakePushAuthPort({
    this.isConfigured = true,
    this.isSignedIn = true,
    this.currentUserId = 'user-1',
  });

  @override
  bool isConfigured;

  @override
  bool isSignedIn;

  @override
  String? currentUserId;
}

class FakePushProfileStore implements PushProfileStore {
  String? lastTokenUserId;
  String? lastToken;
  String? lastEnabledUserId;
  bool? lastEnabled;
  bool? storedEnabled;

  @override
  Future<void> updateToken(String userId, String token) async {
    lastTokenUserId = userId;
    lastToken = token;
  }

  @override
  Future<void> setNotificationsEnabled(String userId, bool enabled) async {
    lastEnabledUserId = userId;
    lastEnabled = enabled;
    storedEnabled = enabled;
  }

  @override
  Future<bool?> fetchNotificationsEnabled(String userId) async =>
      storedEnabled;
}

PushService makeService({
  FakeMessagingPort? messaging,
  FakeFirebaseInitPort? firebaseInit,
  FakePushProfileStore? store,
  FakePushAuthPort? auth,
}) {
  return PushService(
    messaging: messaging ?? FakeMessagingPort(),
    firebaseInit: firebaseInit ?? FakeFirebaseInitPort(),
    profileStore: store ?? FakePushProfileStore(),
    auth: auth ?? FakePushAuthPort(),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('buildUpdatePayload', () {
    test('has notification title/body and data type + version', () {
      final payload = PushService.buildUpdatePayload(version: '2.0.0');
      final notification =
          payload['notification'] as Map<String, dynamic>;
      expect(notification['title'], contains('2.0.0'));
      expect(notification['body'], isNotEmpty);
      final data = payload['data'] as Map<String, dynamic>;
      expect(data['type'], 'update_available');
      expect(data['version'], '2.0.0');
    });
  });

  group('buildAnnouncementPayload', () {
    test('carries the given title/body and announcement type', () {
      final payload = PushService.buildAnnouncementPayload(
        title: 'Hello',
        body: 'World',
      );
      final notification =
          payload['notification'] as Map<String, dynamic>;
      expect(notification['title'], 'Hello');
      expect(notification['body'], 'World');
      final data = payload['data'] as Map<String, dynamic>;
      expect(data['type'], 'announcement');
      expect(data.containsKey('version'), isFalse);
    });
  });

  group('shouldSendToUser', () {
    test('opted-out -> false even with a token and audience all', () {
      expect(
        PushService.shouldSendToUser(
          notificationsEnabled: false,
          fcmToken: 'token-abc',
          audience: 'all',
          plan: 'free',
        ),
        isFalse,
      );
    });

    test('no token -> false', () {
      expect(
        PushService.shouldSendToUser(
          notificationsEnabled: true,
          fcmToken: null,
          audience: 'all',
          plan: 'free',
        ),
        isFalse,
      );
      expect(
        PushService.shouldSendToUser(
          notificationsEnabled: true,
          fcmToken: '',
          audience: 'all',
          plan: 'premium',
        ),
        isFalse,
      );
    });

    test('audience premium + free user -> false', () {
      expect(
        PushService.shouldSendToUser(
          notificationsEnabled: true,
          fcmToken: 'token-abc',
          audience: 'premium',
          plan: 'free',
        ),
        isFalse,
      );
    });

    test('audience premium + premium user -> true', () {
      expect(
        PushService.shouldSendToUser(
          notificationsEnabled: true,
          fcmToken: 'token-abc',
          audience: 'premium',
          plan: 'premium',
        ),
        isTrue,
      );
    });

    test('audience free + premium user -> false, + free user -> true', () {
      expect(
        PushService.shouldSendToUser(
          notificationsEnabled: true,
          fcmToken: 'token-abc',
          audience: 'free',
          plan: 'premium',
        ),
        isFalse,
      );
      expect(
        PushService.shouldSendToUser(
          notificationsEnabled: true,
          fcmToken: 'token-abc',
          audience: 'free',
          plan: 'free',
        ),
        isTrue,
      );
    });

    test('audience all + token + opted-in -> true', () {
      expect(
        PushService.shouldSendToUser(
          notificationsEnabled: true,
          fcmToken: 'token-abc',
          audience: 'all',
          plan: 'free',
        ),
        isTrue,
      );
    });

    test('unknown audience -> false', () {
      expect(
        PushService.shouldSendToUser(
          notificationsEnabled: true,
          fcmToken: 'token-abc',
          audience: 'everyone',
          plan: 'free',
        ),
        isFalse,
      );
    });
  });

  group('parseNotificationTap', () {
    test('update_available -> update', () {
      expect(
        PushService.parseNotificationTap({'type': 'update_available'}),
        PushDestination.update,
      );
    });

    test('announcement -> home', () {
      expect(
        PushService.parseNotificationTap({'type': 'announcement'}),
        PushDestination.home,
      );
    });

    test('missing / unknown type -> home', () {
      expect(PushService.parseNotificationTap(null), PushDestination.home);
      expect(PushService.parseNotificationTap({}), PushDestination.home);
      expect(
        PushService.parseNotificationTap({'type': 'something_else'}),
        PushDestination.home,
      );
    });
  });

  group('buildTokenUpdate', () {
    test('stores the token with an ISO timestamp', () {
      final fixed = DateTime.utc(2026, 11, 19, 12, 0, 0);
      final patch = PushService.buildTokenUpdate(
        token: 'tok-1',
        now: fixed,
      );
      expect(patch['fcm_token'], 'tok-1');
      expect(patch['fcm_token_updated_at'], fixed.toIso8601String());
    });
  });

  group('PushService with fake ports', () {
    late FakeMessagingPort messaging;
    late FakePushProfileStore store;
    late PushService service;

    setUp(() {
      messaging = FakeMessagingPort();
      store = FakePushProfileStore();
      service = makeService(messaging: messaging, store: store);
    });

    tearDown(() => messaging.dispose());

    test('initialize returns false when Firebase is unavailable', () async {
      final unavailable = makeService(
        firebaseInit: FakeFirebaseInitPort(available: false),
      );
      expect(await unavailable.initialize(), isFalse);
      expect(unavailable.isAvailable, isFalse);
      // registerToken is a silent no-op when push is unavailable.
      expect(await unavailable.registerToken(), isFalse);
    });

    test('initialize returns true and registerToken stores the token',
        () async {
      expect(await service.initialize(), isTrue);
      expect(await service.registerToken(), isTrue);
      expect(store.lastTokenUserId, 'user-1');
      expect(store.lastToken, 'fake-fcm-token-123');
    });

    test('registerToken is a no-op when signed out', () async {
      final signedOut = makeService(
        auth: FakePushAuthPort(isSignedIn: false, currentUserId: null),
      );
      await signedOut.initialize();
      expect(await signedOut.registerToken(), isFalse);
    });

    test('registerToken is a no-op when the token is null', () async {
      messaging.tokenToReturn = null;
      await service.initialize();
      expect(await service.registerToken(), isFalse);
      expect(store.lastToken, isNull);
    });

    test('token refresh re-registers the new token', () async {
      await service.initialize();
      messaging.tokenToReturn = 'refreshed-token-9';
      messaging._tokenRefresh.add('refreshed-token-9');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(store.lastToken, 'refreshed-token-9');
    });

    test('permission is asked once and the answer is recorded', () async {
      await service.initialize();
      expect(await service.permissionAsked, isFalse);
      expect(await service.requestPermission(), isTrue);
      expect(messaging.requestPermissionCalled, isTrue);
      expect(await service.permissionAsked, isTrue);
    });

    test('markPermissionAsked records the ask without requesting',
        () async {
      await service.initialize();
      await service.markPermissionAsked();
      expect(await service.permissionAsked, isTrue);
      expect(messaging.requestPermissionCalled, isFalse);
    });

    test('foreground message reaches the onForegroundMessage callback',
        () async {
      await service.initialize();
      RemoteMessage? seen;
      service.onForegroundMessage = (m) => seen = m;
      messaging._onMessage.add(
        const RemoteMessage(data: {'type': 'announcement'}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seen, isNotNull);
      expect(seen!.data['type'], 'announcement');
    });

    test('tapped update notification routes to update, announcement to home',
        () async {
      await service.initialize();
      PushDestination? seen;
      service.onTap = (d) => seen = d;
      messaging._onMessageOpenedApp.add(
        const RemoteMessage(
          data: {'type': 'update_available', 'version': '2.0.0'},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seen, PushDestination.update);
      messaging._onMessageOpenedApp.add(
        const RemoteMessage(data: {'type': 'announcement'}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seen, PushDestination.home);
    });

    test('consumeInitialMessage maps the cold-start message', () async {
      await service.initialize();
      messaging.initialMessage = const RemoteMessage(
        data: {'type': 'update_available', 'version': '2.0.0'},
      );
      expect(
        await service.consumeInitialMessage(),
        PushDestination.update,
      );
      messaging.initialMessage = null;
      expect(await service.consumeInitialMessage(), isNull);
    });

    test('opt-out updates the server flag AND deletes the local token',
        () async {
      await service.initialize();
      expect(await service.setNotificationsEnabled(false), isTrue);
      expect(store.lastEnabled, isFalse);
      expect(messaging.deleteTokenCalled, isTrue);
    });

    test('opt-in updates the flag and re-registers the token', () async {
      await service.initialize();
      expect(await service.setNotificationsEnabled(true), isTrue);
      expect(store.lastEnabled, isTrue);
      expect(store.lastToken, 'fake-fcm-token-123');
    });

    test('isNotificationsEnabled defaults to true when unreadable',
        () async {
      store.storedEnabled = null;
      expect(await service.isNotificationsEnabled(), isTrue);
      store.storedEnabled = false;
      expect(await service.isNotificationsEnabled(), isFalse);
    });
  });

  group('AccountSettingsScreen — notifications toggle (fake push service)',
      () {
    late FakeMessagingPort messaging;
    late FakePushProfileStore store;
    late PushService fakePush;

    setUp(() async {
      messaging = FakeMessagingPort();
      store = FakePushProfileStore();
      store.storedEnabled = true;
      fakePush = makeService(messaging: messaging, store: store);
      await fakePush.initialize();
    });

    tearDown(() => messaging.dispose());

    Future<void> pumpScreen(WidgetTester tester) async {
      // Tall viewport: the toggle sits below the password + username
      // sections in a ListView, and off-screen children are never
      // built. A 3000px-tall surface renders the whole screen.
      await tester.binding.setSurfaceSize(const Size(800, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: AccountSettingsScreen(pushService: fakePush),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('toggling off shows the opted-out state', (tester) async {
      await pumpScreen(tester);
      expect(find.text('Notifications'), findsWidgets);
      final toggle = find.byType(Switch);
      expect(toggle, findsOneWidget);
      expect(tester.widget<Switch>(toggle).value, isTrue);

      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(store.lastEnabled, isFalse);
      expect(messaging.deleteTokenCalled, isTrue);
      expect(tester.widget<Switch>(toggle).value, isFalse);
      expect(find.textContaining('band kar di gayi hain'), findsOneWidget);
    });

    testWidgets('toggling back on re-enables', (tester) async {
      store.storedEnabled = false;
      await pumpScreen(tester);
      final toggle = find.byType(Switch);
      expect(tester.widget<Switch>(toggle).value, isFalse);

      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(store.lastEnabled, isTrue);
      expect(store.lastToken, 'fake-fcm-token-123');
      expect(tester.widget<Switch>(toggle).value, isTrue);
      expect(find.textContaining('on kar di gayi hain'), findsOneWidget);
    });
  });
}
