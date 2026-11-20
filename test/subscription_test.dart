import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:officerpath_ai/services/billing_service.dart';
import 'package:officerpath_ai/services/manual_activation.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';
import 'package:officerpath_ai/services/subscription_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SubscriptionService.instance.resetForTest();
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
    await sub.grantPremium(PremiumPlan.plans[2]);
    expect(await sub.isPremium(), isTrue);
    expect(await sub.canGenerateTest(), isTrue);
    expect(await sub.testsRemaining(), -1); // -1 = unlimited
    expect(await sub.canAddBook(99), isTrue);
  });

  test('manual activation codes round-trip for all 3 plans', () async {
    final activation = ManualActivationService.instance;
    for (final plan in PremiumPlan.plans) {
      final code = ManualActivationService.buildCode(plan.id);
      expect(activation.validateCode(code)?.id, plan.id);
      expect(activation.validateCode(code.toLowerCase())?.id, plan.id);
    }
    // Tampered code / wrong format must fail.
    expect(activation.validateCode('OP2-AAAAAA'), isNull);
    expect(activation.validateCode('OP9-AAAAAA'), isNull);
    expect(activation.validateCode('hello'), isNull);
    expect(activation.validateCode(''), isNull);
  });

  test('activation code grants premium for the encoded plan', () async {
    final activation = ManualActivationService.instance;
    final code = ManualActivationService.buildCode('premium_2months');
    final plan = await activation.activateWithCode(code);
    expect(plan?.id, 'premium_2months');
    expect(await SubscriptionService.instance.isPremium(), isTrue);
    expect(
      await SubscriptionService.instance.currentPlanId(),
      'premium_2months',
    );
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
