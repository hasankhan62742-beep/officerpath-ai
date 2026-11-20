import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:officerpath_ai/services/subscription_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sub = SubscriptionService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await sub.resetForTest();
    // Tests pass no --dart-define, so SupabaseConfig.isConfigured is
    // false; the override seam lets the fake server answer anyway.
    sub.isConfiguredOverride = () => true;
    sub.currentUserIdOverride = () => 'user-1';
  });

  tearDown(() async {
    await sub.resetForTest();
  });

  group('planIdForServerPlan (pure mapping)', () {
    test('plan ids pass through, free maps to null', () {
      expect(
        SubscriptionService.planIdForServerPlan('premium_1month', null),
        'premium_1month',
      );
      expect(
        SubscriptionService.planIdForServerPlan('premium_1year', null),
        'premium_1year',
      );
      expect(
        SubscriptionService.planIdForServerPlan('free', null),
        isNull,
      );
      expect(
        SubscriptionService.planIdForServerPlan('weird', null),
        isNull,
      );
    });

    test('literal premium resolves from months', () {
      expect(
        SubscriptionService.planIdForServerPlan(
          'premium',
          null,
          months: 1,
        ),
        'premium_1month',
      );
      expect(
        SubscriptionService.planIdForServerPlan(
          'premium',
          null,
          months: 2,
        ),
        'premium_2months',
      );
      expect(
        SubscriptionService.planIdForServerPlan(
          'premium',
          null,
          months: 12,
        ),
        'premium_1year',
      );
    });

    test('literal premium resolves from the expiry length', () {
      final now = DateTime(2026, 11, 19);
      expect(
        SubscriptionService.planIdForServerPlan(
          'premium',
          now.add(const Duration(days: 30)),
          now: now,
        ),
        'premium_1month',
      );
      expect(
        SubscriptionService.planIdForServerPlan(
          'premium',
          now.add(const Duration(days: 60)),
          now: now,
        ),
        'premium_2months',
      );
      expect(
        SubscriptionService.planIdForServerPlan(
          'premium',
          now.add(const Duration(days: 365)),
          now: now,
        ),
        'premium_1year',
      );
    });
  });

  group('isServerPremium (pure)', () {
    test('premium needs a future expiry', () {
      final now = DateTime(2026, 11, 19);
      expect(
        SubscriptionService.isServerPremium(
          'premium',
          now.add(const Duration(days: 1)),
          now: now,
        ),
        isTrue,
      );
      expect(
        SubscriptionService.isServerPremium(
          'premium',
          now.subtract(const Duration(days: 1)),
          now: now,
        ),
        isFalse,
      );
      expect(
        SubscriptionService.isServerPremium('premium', null, now: now),
        isFalse,
      );
      expect(
        SubscriptionService.isServerPremium(
          'free',
          now.add(const Duration(days: 30)),
          now: now,
        ),
        isFalse,
      );
    });
  });

  group('applyServerPremium', () {
    test('premium grant caches plan id + expiry, unlocks tests', () async {
      final until = DateTime.now().add(const Duration(days: 60));
      await sub.applyServerPremium('premium_2months', until);
      expect(await sub.isPremium(), isTrue);
      expect(await sub.currentPlanId(), 'premium_2months');
      expect(await sub.testsRemaining(), -1); // unlimited
      expect(await sub.currentPlan(), 'premium');
      final stored = await sub.premiumUntil();
      expect(stored, isNotNull);
      expect(stored!.difference(until).inSeconds.abs(), lessThan(2));
    });

    test('literal premium + months resolves the plan id', () async {
      await sub.applyServerPremium(
        'premium',
        DateTime.now().add(const Duration(days: 365)),
        months: 12,
      );
      expect(await sub.isPremium(), isTrue);
      expect(await sub.currentPlanId(), 'premium_1year');
    });

    test('free / expired grants clear the cache', () async {
      await sub.applyServerPremium(
        'premium_1month',
        DateTime.now().add(const Duration(days: 30)),
      );
      expect(await sub.isPremium(), isTrue);
      await sub.applyServerPremium('free', null);
      expect(await sub.isPremium(), isFalse);
      expect(await sub.currentPlan(), 'free');
      expect(await sub.testsRemaining(), 3);
      await sub.applyServerPremium(
        'premium_1month',
        DateTime.now().subtract(const Duration(days: 1)),
      );
      expect(await sub.isPremium(), isFalse);
    });
  });

  group('refreshPlanFromServer', () {
    test('server premium maps into the cache', () async {
      sub.serverProfileFetcher =
          (_) async => {
            'plan': 'premium',
            'premium_until':
                DateTime.now()
                    .add(const Duration(days: 30))
                    .toIso8601String(),
          };
      expect(await sub.refreshPlanFromServer(), isTrue);
      expect(await sub.isPremium(), isTrue);
      expect(await sub.currentPlanId(), 'premium_1month');
    });

    test('server free plan downgrades a cached premium', () async {
      await sub.applyServerPremium(
        'premium_1month',
        DateTime.now().add(const Duration(days: 30)),
      );
      expect(await sub.isPremium(), isTrue);
      sub.serverProfileFetcher =
          (_) async => {'plan': 'free', 'premium_until': null};
      expect(await sub.refreshPlanFromServer(), isTrue);
      expect(await sub.isPremium(), isFalse);
      expect(await sub.testsRemaining(), 3);
    });

    test('offline fallback: fetcher error keeps the cache untouched', () async {
      await sub.recordTestGenerated();
      await sub.recordTestGenerated();
      expect(await sub.testsUsed(), 2);
      sub.serverProfileFetcher = (_) async => throw Exception('no network');
      expect(await sub.refreshPlanFromServer(), isFalse);
      expect(await sub.testsUsed(), 2);
      expect(await sub.isPremium(), isFalse);
      expect(await sub.testsRemaining(), 1);
    });

    test('offline fallback: null row keeps the cache untouched', () async {
      await sub.applyServerPremium(
        'premium_1year',
        DateTime.now().add(const Duration(days: 365)),
      );
      sub.serverProfileFetcher = (_) async => null;
      expect(await sub.refreshPlanFromServer(), isFalse);
      expect(await sub.isPremium(), isTrue);
    });

    test('unconfigured backend returns false without calling the fetcher',
        () async {
      sub.isConfiguredOverride = () => false;
      var called = false;
      sub.serverProfileFetcher =
          (_) async {
            called = true;
            return {'plan': 'premium', 'premium_until': null};
          };
      expect(await sub.refreshPlanFromServer(), isFalse);
      expect(called, isFalse);
      expect(await sub.isPremium(), isFalse);
    });

    test('signed-out user returns false without calling the fetcher',
        () async {
      sub.currentUserIdOverride = () => null;
      var called = false;
      sub.serverProfileFetcher =
          (_) async {
            called = true;
            return {'plan': 'premium', 'premium_until': null};
          };
      expect(await sub.refreshPlanFromServer(), isFalse);
      expect(called, isFalse);
    });
  });
}
