import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:officerpath_ai/services/subscription_service.dart';

/// Free tests, v2.0.0 — 3 PER CALENDAR MONTH (user decision 19 Nov 2026),
/// replacing v1's 5-total-once. Covers the month boundary, the offline
/// fallback, and the server reconciliation (reinstall = server count
/// wins). The mechanism that shipped: local month-keyed counter in
/// SharedPreferences + best-effort server count from `test_results`
/// (each finished test syncs one row on completion; see
/// TestScreen._submit). No profiles counter was needed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SubscriptionService.instance.resetForTest();
  });

  test('monthKeyFor / monthStartFor', () {
    expect(SubscriptionService.monthKeyFor(DateTime(2026, 11, 19)), '2026-11');
    expect(SubscriptionService.monthKeyFor(DateTime(2026, 1, 5)), '2026-01');
    expect(
      SubscriptionService.monthStartFor(DateTime(2026, 11, 19, 15, 30)),
      DateTime(2026, 11, 1),
    );
  });

  test('month rollover resets the count (no carry-over)', () async {
    final sub = SubscriptionService.instance;
    final nov = DateTime(2026, 11, 30, 23, 0);
    final dec = DateTime(2026, 12, 1, 0, 30);
    await sub.recordTestGenerated(now: nov);
    await sub.recordTestGenerated(now: nov);
    await sub.recordTestGenerated(now: nov);
    expect(await sub.testsUsed(now: nov), 3);
    expect(await sub.canGenerateTest(now: nov), isFalse);
    // The rollover: the same counter reads 0 in December, and the
    // first December test starts a fresh count of 1.
    expect(await sub.testsUsed(now: dec), 0);
    expect(await sub.testsRemaining(now: dec), 3);
    expect(await sub.canGenerateTest(now: dec), isTrue);
    await sub.recordTestGenerated(now: dec);
    expect(await sub.testsUsed(now: dec), 1);
  });

  test('December 31 -> January 1 is a rollover too', () async {
    final sub = SubscriptionService.instance;
    await sub.recordTestGenerated(now: DateTime(2026, 12, 31));
    expect(await sub.testsUsed(now: DateTime(2026, 12, 31)), 1);
    expect(await sub.testsUsed(now: DateTime(2027, 1, 1)), 0);
  });

  test('unused tests do not carry over', () async {
    final sub = SubscriptionService.instance;
    await sub.recordTestGenerated(now: DateTime(2026, 11, 10));
    expect(await sub.testsUsed(now: DateTime(2026, 12, 10)), 0);
    expect(await sub.testsRemaining(now: DateTime(2026, 12, 10)), 3);
  });

  test('premium never consumes the monthly counter', () async {
    final sub = SubscriptionService.instance;
    await sub.grantPremium(PremiumPlan.plans[0]);
    await sub.recordTestGenerated(now: DateTime(2026, 11, 10));
    expect(await sub.testsUsed(now: DateTime(2026, 11, 10)), 0);
  });

  test('offline fallback: server error leaves the local count alone',
      () async {
    final sub = SubscriptionService.instance;
    sub.isConfiguredOverride = () => true;
    sub.currentUserIdOverride = () => 'user-1';
    sub.serverMonthlyTestCountFetcher =
        (_, _) async => throw Exception('no network');
    await sub.recordTestGenerated(now: DateTime(2026, 11, 10));
    await sub.recordTestGenerated(now: DateTime(2026, 11, 10));
    expect(
      await sub.refreshFreeCountFromServer(now: DateTime(2026, 11, 10)),
      isFalse,
    );
    expect(await sub.testsUsed(now: DateTime(2026, 11, 10)), 2);
  });

  test('offline fallback: unconfigured / signed out returns false',
      () async {
    final sub = SubscriptionService.instance;
    // Unconfigured: no dart-define in tests.
    expect(await sub.refreshFreeCountFromServer(), isFalse);
    expect(await sub.syncTestResultToServer(
      examName: 'PPSC',
      score: 40,
      total: 50,
    ), isFalse);
    // Configured but signed out.
    sub.isConfiguredOverride = () => true;
    sub.currentUserIdOverride = () => null;
    expect(await sub.refreshFreeCountFromServer(), isFalse);
    expect(await sub.syncTestResultToServer(
      examName: 'PPSC',
      score: 40,
      total: 50,
    ), isFalse);
  });

  test('reinstall: server count wins when it is higher', () async {
    final sub = SubscriptionService.instance;
    sub.isConfiguredOverride = () => true;
    sub.currentUserIdOverride = () => 'user-1';
    // Fresh install: local counter is empty (0 used this month).
    // Server says 2 finished tests already happened this month.
    sub.serverMonthlyTestCountFetcher = (_, _) async => 2;
    expect(
      await sub.refreshFreeCountFromServer(now: DateTime(2026, 11, 10)),
      isTrue,
    );
    expect(await sub.testsUsed(now: DateTime(2026, 11, 10)), 2);
    expect(await sub.testsRemaining(now: DateTime(2026, 11, 10)), 1);
  });

  test('offline tests are not forgotten when the server says fewer',
      () async {
    final sub = SubscriptionService.instance;
    sub.isConfiguredOverride = () => true;
    sub.currentUserIdOverride = () => 'user-1';
    // 2 tests generated offline (not synced yet); server has 0 rows.
    await sub.recordTestGenerated(now: DateTime(2026, 11, 10));
    await sub.recordTestGenerated(now: DateTime(2026, 11, 10));
    sub.serverMonthlyTestCountFetcher = (_, _) async => 0;
    expect(
      await sub.refreshFreeCountFromServer(now: DateTime(2026, 11, 10)),
      isTrue,
    );
    expect(await sub.testsUsed(now: DateTime(2026, 11, 10)), 2);
  });

  test('syncTestResultToServer inserts via the seam and never throws',
      () async {
    final sub = SubscriptionService.instance;
    sub.isConfiguredOverride = () => true;
    sub.currentUserIdOverride = () => 'user-1';
    Map<String, dynamic>? seen;
    sub.serverTestResultInserter = ({
      required userId,
      required examName,
      required score,
      required total,
      bookTitle,
    }) async {
      seen = {
        'userId': userId,
        'examName': examName,
        'score': score,
        'total': total,
        'bookTitle': bookTitle,
      };
      return true;
    };
    expect(
      await sub.syncTestResultToServer(
        examName: 'PPSC',
        score: 40,
        total: 50,
        bookTitle: 'Past Papers',
      ),
      isTrue,
    );
    expect(seen?['userId'], 'user-1');
    expect(seen?['examName'], 'PPSC');
    expect(seen?['score'], 40);
    expect(seen?['total'], 50);
    expect(seen?['bookTitle'], 'Past Papers');
    // A failing insert reports false, never throws.
    sub.serverTestResultInserter = ({
      required userId,
      required examName,
      required score,
      required total,
      bookTitle,
    }) async => throw Exception('db down');
    expect(
      await sub.syncTestResultToServer(
        examName: 'PPSC',
        score: 40,
        total: 50,
      ),
      isFalse,
    );
  });
}
