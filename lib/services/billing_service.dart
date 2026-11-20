import 'subscription_service.dart';

/// Google Play Billing — STUB in v1, for the later Play Store phase only.
///
/// v1 distribution is a DIRECT APK (sideload) with NO Play account, and
/// v1 payment is MANUAL (JazzCash / Easypaisa / bank transfer + owner
/// activation code — server-issued single-use code, see issue-code). This service ships NO
/// billing dependency and takes NO money. It always reports "not wired
/// yet" and never grants Premium, so a v1 build can never accidentally
/// sell something.
///
/// HOW TO WIRE IN THE PLAY STORE PHASE (do not do this in v1):
/// 1. Play Console → Monetization → Subscriptions: create three
///    subscription products with EXACTLY these ids
///    (see PremiumPlan.playStoreProductId):
///      * officerpath_premium_1month   — Rs 600 / 1 month
///      * officerpath_premium_2months  — Rs 1,000 / 2 months
///      * officerpath_premium_1year    — Rs 5,000 / 1 year
///    Set them as subscriptions (not one-time products), PKR pricing.
/// 2. Add the `in_app_purchase` package to pubspec.yaml.
/// 3. Implement [PlayBillingService] with InAppPurchase: query product
///    details, launch the subscription purchase flow, listen to the
///    purchase stream, verify the purchase (server-side verification via
///    Google Play Developer API / RTDN is the production-grade route),
///    and ONLY then grant Premium through the server-verified path
///    (`SubscriptionService.instance.applyServerPremium(plan, until)`).
/// 4. Handle restores (user reinstalls / new phone) by re-querying owned
///    purchases on app start and re-granting while the subscription is active.
/// 5. Test with Play Console license testers on the Internal Testing track
///    before promoting to production.
class BillingResult {
  const BillingResult({required this.success, required this.message});

  final bool success;
  final String message;
}

abstract class PlayBillingService {
  Future<List<PremiumPlan>> getPlans();
  Future<BillingResult> purchase(PremiumPlan plan);
  Future<BillingResult> restorePurchases();
}

/// v1 stub: billing is not connected. Every purchase attempt is refused
/// with an honest message instead of silently failing or granting access.
class StubPlayBillingService implements PlayBillingService {
  @override
  Future<List<PremiumPlan>> getPlans() async => PremiumPlan.plans;

  @override
  Future<BillingResult> purchase(PremiumPlan plan) async {
    return BillingResult(
      success: false,
      message:
          'Payments are not connected yet in this version. Google Play '
          'Billing will be wired before the public launch — your free '
          '${SubscriptionService.freeTestLimit} tests still work.',
    );
  }

  @override
  Future<BillingResult> restorePurchases() async {
    return const BillingResult(
      success: false,
      message:
          'Restore is not available yet — Google Play Billing will be '
          'wired before the public launch.',
    );
  }
}
