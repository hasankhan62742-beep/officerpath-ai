import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:officerpath_ai/services/billing_service.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';
import 'package:officerpath_ai/services/secure_key_store.dart';
import 'package:officerpath_ai/services/subscription_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The premium cache lives in secure storage (audit L8, fixed
  // 2026-11-20); tests inject the in-memory fake so no platform
  // channel is needed.
  late InMemorySecureStore secureStore;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SubscriptionService.instance.resetForTest();
    secureStore = InMemorySecureStore();
    SubscriptionService.instance.secureStoreOverride = secureStore;
  });

  test('freemium numbers are exactly as confirmed', () {
    expect(SubscriptionService.freeTestLimit, 3);
    expect(SubscriptionService.freeBookLimit, 5);
    expect(SubscriptionService.maxBookFileBytes, 100 * 1024 * 1024);
    final plans = PremiumPlan.plans;
    expect(plans.length, 3);
    expect(plans[0].id, 'premium_1month');
    expect(plans[0].pricePkr, 600);
    expect(plans[0].durationDays, 30);
    expect(plans[0].playStoreProductId, 'officerpath_premium_1month');
    expect(plans[1].pricePkr, 1000);
    expect(plans[1].durationDays, 60);
    expect(plans[1].playStoreProductId, 'officerpath_premium_2months');
    expect(plans[2].pricePkr, 5000);
    expect(plans[2].durationDays, 365);
    expect(plans[2].playStoreProductId, 'officerpath_premium_1year');
    // Per-month math shown on the Upgrade screen.
    expect(plans[0].perMonthLabel, 'Rs 600 / month');
    expect(plans[1].perMonthLabel, 'Rs 500 / month');
    expect(plans[2].perMonthLabel, 'Rs 417 / month');
  });

  test('free user is locked out after 3 generated tests in a month', () async {
    final sub = SubscriptionService.instance;
    expect(await sub.canGenerateTest(), isTrue);
    expect(await sub.testsRemaining(), 3);
    for (var i = 0; i < 3; i++) {
      await sub.recordTestGenerated();
    }
    expect(await sub.testsUsed(), 3);
    expect(await sub.testsRemaining(), 0);
    expect(await sub.canGenerateTest(), isFalse);
  });

  test('premium removes the test limit and the book limit', () async {
    final sub = SubscriptionService.instance;
    expect(await sub.canAddBook(5), isFalse);
    expect(await sub.canAddBook(4), isTrue);
    await sub.applyServerPremium(
      'premium_1year',
      DateTime.now().add(const Duration(days: 365)),
    );
    expect(await sub.isPremium(), isTrue);
    expect(await sub.canGenerateTest(), isTrue);
    expect(await sub.testsRemaining(), -1); // -1 = unlimited
    expect(await sub.canAddBook(99), isTrue);
  });

  test('premium cache lives in secure storage, never SharedPreferences',
      () async {
    final sub = SubscriptionService.instance;
    final until = DateTime.now().add(const Duration(days: 60));
    await sub.applyServerPremium('premium_2months', until);
    expect(await sub.isPremium(), isTrue);
    expect(await sub.currentPlanId(), 'premium_2months');
    // No premium state in SharedPreferences — neither the new keys
    // (which must never be written there) nor the legacy v1 keys.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('is_premium_v1'), isNull);
    expect(prefs.getString('premium_plan_id_v1'), isNull);
    expect(prefs.getString('premium_until_iso_v1'), isNull);
    // ...and it IS in the secure store (key names mirror the private
    // constants in SubscriptionService).
    expect(await secureStore.read('premium_is_active_v2'), 'true');
    expect(await secureStore.read('premium_plan_id_v2'), 'premium_2months');
    expect(await secureStore.read('premium_until_iso_v2'), isNotNull);
  });

  test('billing stub never grants premium and never charges', () async {
    final billing = StubPlayBillingService();
    final result = await billing.purchase(PremiumPlan.plans[0]);
    expect(result.success, isFalse);
    expect(result.message, contains('not connected'));
    expect(
      await SubscriptionService.instance.isPremium(),
      isFalse,
    );
  });

  test('text parsing runs in a background isolate (no UI-thread work)',
      () async {
    // ParseQueue is gone: heavy parsing now runs in compute(), so the UI
    // thread can never block on a big book (the ANR fix).
    const text = 'Q1. What is the capital of Pakistan?\n'
        'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\nAnswer: C\n';
    final maps = await compute(parseTextInBackground, {
      'text': text,
      'sourceId': 'test-src',
      'sourceLabel': 'Test',
    });
    expect(maps['parsed'], 1);
    expect((maps['questions'] as List).length, 1);
  });
}
