import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:officerpath_ai/screens/upgrade_screen.dart';
import 'package:officerpath_ai/services/activation_service.dart';
import 'package:officerpath_ai/services/payment_proof_service.dart';
import 'package:officerpath_ai/services/subscription_service.dart';
import 'package:officerpath_ai/theme/app_theme.dart';

/// v2.0 — Upgrade screen with the SERVER flow: payment proof submit +
/// server code redemption, with fake services (no network, no Supabase).
///
/// The screen itself is pumpable with injected fakes; the real
/// SubscriptionService cache (SharedPreferences mock) is used, so a
/// successful redemption really flips isPremium.

void _setSmallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// The Upgrade screen's vertical ListView scrollable.
final Finder _listScrollable = find.byWidgetPredicate(
  (widget) =>
      widget is Scrollable && widget.axisDirection == AxisDirection.down,
);

Finder _fieldWithLabel(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byType(TextField),
);

class _FakePayments {
  final List<Map<String, dynamic>> rows = [];

  PaymentProofService get service => PaymentProofService(
    accountProvider: () => (id: 'user-1', email: 'student@example.com'),
    inserter: (row) async {
      final saved = {
        ...row,
        'id': 'pay-${rows.length + 1}',
        'created_at': '2026-11-19T10:00:00.000Z',
      };
      rows.add(saved);
      return saved;
    },
    fetcher: (_) async => List<Map<String, dynamic>>.from(rows),
    isConfigured: () => true,
  );
}

Future<void> _pump(
  WidgetTester tester, {
  ActivationService? activation,
  PaymentProofService? proofs,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: UpgradeScreen(
        activationService: activation,
        paymentProofService: proofs,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SubscriptionService.instance.resetForTest();
  });

  group('UpgradeScreen v2 — code redemption', () {
    testWidgets('redeem success shows Premium unlocked + flips the plan', (
      tester,
    ) async {
      _setSmallPhone(tester);
      final activation = ActivationService(
        invoke:
            (_, _) async => {
              'ok': true,
              'plan': 'premium',
              'premium_until':
                  DateTime.now()
                      .add(const Duration(days: 30))
                      .toIso8601String(),
            },
      );
      final fake = _FakePayments();
      await _pump(tester, activation: activation, proofs: fake.service);
      expect(await SubscriptionService.instance.isPremium(), isFalse);

      await tester.scrollUntilVisible(
        find.text('I have an activation code'),
        500,
        scrollable: _listScrollable,
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        _fieldWithLabel('Activation code (e.g. OP2-XXXXXX)'),
        'OP1-ABCDEF',
      );
      await tester.tap(find.text('Redeem'));
      await tester.pumpAndSettle();

      expect(find.text('Premium unlocked!'), findsOneWidget);
      expect(await SubscriptionService.instance.isPremium(), isTrue);
      expect(
        await SubscriptionService.instance.currentPlanId(),
        'premium_1month',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('redeem failure shows the exact server reason', (
      tester,
    ) async {
      _setSmallPhone(tester);
      final activation = ActivationService(
        invoke: (_, _) async => {'ok': false, 'error': 'code_already_used'},
      );
      final fake = _FakePayments();
      await _pump(tester, activation: activation, proofs: fake.service);

      await tester.scrollUntilVisible(
        find.text('I have an activation code'),
        500,
        scrollable: _listScrollable,
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        _fieldWithLabel('Activation code (e.g. OP2-XXXXXX)'),
        'OP2-K7Q9XA',
      );
      await tester.tap(find.text('Redeem'));
      await tester.pumpAndSettle();

      expect(find.textContaining('istemal ho chuka'), findsOneWidget);
      expect(find.text('Premium unlocked!'), findsNothing);
      expect(await SubscriptionService.instance.isPremium(), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('malformed code shows a format error without calling server', (
      tester,
    ) async {
      _setSmallPhone(tester);
      var called = false;
      final activation = ActivationService(
        invoke: (_, _) async {
          called = true;
          return {'ok': true};
        },
      );
      final fake = _FakePayments();
      await _pump(tester, activation: activation, proofs: fake.service);

      await tester.scrollUntilVisible(
        find.text('I have an activation code'),
        500,
        scrollable: _listScrollable,
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        _fieldWithLabel('Activation code (e.g. OP2-XXXXXX)'),
        'hello',
      );
      await tester.tap(find.text('Redeem'));
      await tester.pumpAndSettle();

      expect(called, isFalse);
      expect(find.textContaining('doesn\'t look right'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('UpgradeScreen v2 — payment proof', () {
    testWidgets('proof submission shows the pending state + proof row', (
      tester,
    ) async {
      _setSmallPhone(tester);
      final fake = _FakePayments();
      await _pump(
        tester,
        activation: ActivationService(invoke: (_, _) async => {'ok': false}),
        proofs: fake.service,
      );

      await tester.scrollUntilVisible(
        find.text('Step 2 — Submit your payment proof'),
        500,
        scrollable: _listScrollable,
      );
      await tester.pumpAndSettle();
      // Registered email is prefilled read-only from the account.
      expect(find.text('student@example.com'), findsOneWidget);
      await tester.enterText(
        _fieldWithLabel('Transaction ID'),
        '1234567890',
      );
      await tester.tap(find.text('Submit proof'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Proof submitted'), findsOneWidget);
      expect(find.textContaining('Pending approval'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Your payment proofs'),
        500,
        scrollable: _listScrollable,
      );
      await tester.pumpAndSettle();
      expect(find.text('Pending'), findsOneWidget);
      expect(
        find.textContaining('Transaction ID: 1234567890'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('short transaction ID shows a validation error', (
      tester,
    ) async {
      _setSmallPhone(tester);
      final fake = _FakePayments();
      await _pump(
        tester,
        activation: ActivationService(invoke: (_, _) async => {'ok': false}),
        proofs: fake.service,
      );

      await tester.scrollUntilVisible(
        find.text('Step 2 — Submit your payment proof'),
        500,
        scrollable: _listScrollable,
      );
      await tester.pumpAndSettle();
      await tester.enterText(_fieldWithLabel('Transaction ID'), '12');
      await tester.tap(find.text('Submit proof'));
      await tester.pumpAndSettle();

      expect(find.textContaining('too short'), findsOneWidget);
      expect(fake.rows, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });
}
