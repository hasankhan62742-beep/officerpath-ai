import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_config.dart';

/// Fetches one `profiles` row for [userId]: `{'plan': 'free'|'premium',
/// 'premium_until': [ISO string or null]}`. Injected in tests so
/// [SubscriptionService.refreshPlanFromServer] needs no network.
typedef ServerProfileFetcher =
    Future<Map<String, dynamic>?> Function(String userId);

/// Counts the user's `test_results` rows created since [monthStart]
/// (the first day of the current calendar month). Injected in tests;
/// production counts rows in Supabase. Returns null on error.
typedef ServerMonthlyTestCountFetcher =
    Future<int?> Function(String userId, DateTime monthStart);

/// Inserts one finished-test row into `test_results`. Injected in
/// tests; production inserts via Supabase. Returns true when the row
/// was stored.
typedef ServerTestResultInserter =
    Future<bool> Function({
      required String userId,
      required String examName,
      required int score,
      required int total,
      String? bookTitle,
    });

/// Freemium model — CONFIRMED 18 Nov 2026 (monthly plan confirmed same day).
///
/// FREE (v2.0.0, user decision 19 Nov 2026 — "Teen best rahenge"):
/// 3 tests PER CALENDAR MONTH. The count resets when the month rolls
/// over; unused tests do NOT carry over. This REPLACES v1's 5-tests-
/// total-once. The live v1.2.0 app keeps 5 total — do not backport.
/// PREMIUM: unlimited tests + unlimited books.
///   * 1 month  = Rs 600 PKR   (starter / trial plan, Rs 600/mo)
///   * 2 months = Rs 1,000 PKR (Rs 500/mo)
///   * 1 year   = Rs 5,000 PKR (Rs 417/mo — BEST VALUE, ~17% cheaper per
///     month than the 2-month plan; vs Pak Imtehan Rs 5,900/yr and
///     MockCSS Rs 2,000/mo, these prices undercut both competitors.)
///
/// PAYMENT in v1 is MANUAL (JazzCash / Easypaisa / bank transfer + owner
/// activation code) — see manual_activation.dart. Google Play Billing is
/// NOT wired in v1; it is a stub for the later Play Store phase
/// (billing_service.dart). No money moves through this service directly.
///
/// v2.0 — SERVER SOURCE OF TRUTH: the plan now lives in the server
/// `profiles` row (`plan` + `premium_until`) and is fetched by
/// [refreshPlanFromServer] whenever the app is online. The
/// SharedPreferences cache below is only the OFFLINE fallback, so
/// `isPremium` / `testsRemaining` keep working with no connection.
/// After a successful code redemption the caller applies the grant
/// with [applyServerPremium] (which writes the same cache). The old
/// offline-code path ([ManualActivationService.activateWithCode]) is
/// v1-only and deprecated — it still writes this cache, but the
/// Upgrade screen no longer calls it.
///
/// NOTE on Play fees (for the owner, not shown as a promise to users):
/// Google Play takes a ~15% service fee on subscriptions under the
/// small-business tier (Rs 5,000 → Rs 4,250 net; Rs 1,000 → Rs 850 net).
/// Manual JazzCash/Easypaisa in v1 keeps 100%.
class PremiumPlan {
  const PremiumPlan({
    required this.id,
    required this.name,
    required this.pricePkr,
    required this.durationDays,
    required this.playStoreProductId,
    required this.tagline,
  });

  final String id;
  final String name;

  /// Price in Pakistani Rupees, as charged in Google Play.
  final int pricePkr;
  final int durationDays;

  /// Subscription product id to create in Play Console at publish time.
  final String playStoreProductId;
  final String tagline;

  String get priceLabel => 'Rs ${pricePkr.toString()}';

  String get perMonthLabel {
    // AUDIT m1: durationDays < 30 made months == 0 and divided by zero.
    final months = max(1, durationDays ~/ 30);
    return 'Rs ${(pricePkr / months).round()} / month';
  }

  static const List<PremiumPlan> plans = [
    PremiumPlan(
      id: 'premium_1month',
      name: 'Premium — 1 Month',
      pricePkr: 600,
      durationDays: 30,
      playStoreProductId: 'officerpath_premium_1month',
      tagline: 'Starter / trial plan',
    ),
    PremiumPlan(
      id: 'premium_2months',
      name: 'Premium — 2 Months',
      pricePkr: 1000,
      durationDays: 60,
      playStoreProductId: 'officerpath_premium_2months',
      tagline: 'Rs 500 / month',
    ),
    PremiumPlan(
      id: 'premium_1year',
      name: 'Premium — 1 Year',
      pricePkr: 5000,
      durationDays: 365,
      playStoreProductId: 'officerpath_premium_1year',
      tagline: 'Best value — save Rs 1,000 vs 6 × 2-month plans',
    ),
  ];

  static PremiumPlan byId(String id) {
    // AUDIT m2: a stale/unknown stored id used to silently become the
    // 1-month plan. Log it so a wrong plan name on Upgrade is traceable.
    final found = plans.where((p) => p.id == id).firstOrNull;
    if (found == null) {
      debugPrint('SubscriptionService: unknown plan id "$id", using 1-month.');
    }
    return found ?? plans.first;
  }
}

class SubscriptionService {
  SubscriptionService._();
  static final SubscriptionService instance = SubscriptionService._();

  /// Free users may generate this many tests PER CALENDAR MONTH
  /// (v2.0.0 — was 5 tests total-once in v1). The count resets on the
  /// 1st of each month; unused tests do not carry over.
  static const int freeTestLimit = 3;

  /// `'yyyy-MM'` of the month the cached free-test count belongs to.
  /// A different stored month means the count is stale (rollover) and
  /// reads as 0 until the next test is generated.
  static String monthKeyFor(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}';

  /// First instant of the calendar month [dt] is in (local time).
  /// The server count query uses this as the `created_at` lower bound.
  static DateTime monthStartFor(DateTime dt) => DateTime(dt.year, dt.month);

  /// Free users may store this many of their own books. Premium: unlimited.
  static const int freeBookLimit = 5;

  /// Largest single book file accepted (PDF/TXT). See BUILD_REPORT.md
  /// for why the whole file is never uploaded anywhere.
  static const int maxBookFileBytes = 100 * 1024 * 1024; // 100 MB

  static const _kTestsUsed = 'tests_used_v1';
  // v2 monthly counter (supersedes _kTestsUsed, which counted 5-total
  // in v1 and is left untouched so a v1 cache can never leak into v2:
  // a user upgrading to v2 starts the new month at 0).
  static const _kTestsUsedMonth = 'free_tests_month_v2';
  static const _kTestsUsedMonthCount = 'free_tests_used_month_v2';
  static const _kIsPremium = 'is_premium_v1';
  static const _kPlanId = 'premium_plan_id_v1';
  static const _kPremiumUntil = 'premium_until_iso_v1';

  /// Test seam: when set, [refreshPlanFromServer] calls this instead
  /// of the Supabase `profiles` table. Production leaves it null.
  /// Cleared by [resetForTest].
  ServerProfileFetcher? serverProfileFetcher;

  /// Test seam: when set, this supplies the signed-in user id instead
  /// of Supabase Auth. Production leaves it null. Cleared by
  /// [resetForTest].
  String? Function()? currentUserIdOverride;

  /// Test seam: when set, this answers "is the server configured?"
  /// instead of [SupabaseConfig.isConfigured] (which is false in
  /// tests, where no --dart-define is passed). Production leaves it
  /// null. Cleared by [resetForTest].
  bool Function()? isConfiguredOverride;

  /// Test seam: when set, [refreshFreeCountFromServer] calls this
  /// instead of counting `test_results` in Supabase. Production
  /// leaves it null. Cleared by [resetForTest].
  ServerMonthlyTestCountFetcher? serverMonthlyTestCountFetcher;

  /// Test seam: when set, [syncTestResultToServer] calls this instead
  /// of inserting into Supabase. Production leaves it null. Cleared
  /// by [resetForTest].
  ServerTestResultInserter? serverTestResultInserter;

  bool _isConfigured() =>
      isConfiguredOverride?.call() ?? SupabaseConfig.isConfigured;

  /// Pure mapping: which plan id does a server plan value describe?
  ///
  /// [serverPlan] is a plan id (`premium_1month` …) or the literal
  /// `premium`. For the literal, [months] (from the redeemed code) or
  /// the length of [premiumUntil] decides: 1 → 1 month, 2 → 2 months,
  /// 12 (or ~365 days) → 1 year. Returns null for `free` / unknown.
  static String? planIdForServerPlan(
    String serverPlan,
    DateTime? premiumUntil, {
    int? months,
    DateTime? now,
  }) {
    if (serverPlan == 'free') return null;
    if (PremiumPlan.plans.any((p) => p.id == serverPlan)) return serverPlan;
    if (serverPlan != 'premium') return null;
    if (months != null) {
      return switch (months) {
        1 => 'premium_1month',
        2 => 'premium_2months',
        12 => 'premium_1year',
        _ => 'premium_1month',
      };
    }
    if (premiumUntil != null) {
      final days = premiumUntil
          .difference(now ?? DateTime.now())
          .inDays;
      if (days >= 300) return 'premium_1year';
      if (days >= 45) return 'premium_2months';
      return 'premium_1month';
    }
    return 'premium_1month';
  }

  /// Pure check: is the server plan active right now? Premium needs a
  /// future [premiumUntil]; anything else is Free. Pure — no I/O.
  static bool isServerPremium(
    String serverPlan,
    DateTime? premiumUntil, {
    DateTime? now,
  }) {
    if (serverPlan == 'free') return false;
    if (premiumUntil == null) return false;
    return premiumUntil.isAfter(now ?? DateTime.now());
  }

  /// Fetches the server plan for the signed-in user and writes it to
  /// the offline cache. Returns true when the server answered, false
  /// when offline / unconfigured / signed out / error — in which case
  /// the cache is left untouched and the app keeps working offline.
  /// Never throws.
  Future<bool> refreshPlanFromServer() async {
    if (!_isConfigured()) return false;
    final userId = _currentUserId();
    if (userId == null) return false;
    try {
      final row = await (serverProfileFetcher ?? _fetchServerProfile)(
        userId,
      );
      if (row == null) return false;
      final plan = (row['plan'] as String?) ?? 'free';
      final untilRaw = row['premium_until'] as String?;
      final until =
          untilRaw == null ? null : DateTime.tryParse(untilRaw);
      await applyServerPremium(plan, until);
      // Best-effort monthly reconciliation (free users only, and only
      // when signed in): the server count wins over the local cache
      // when it is higher — e.g. after a reinstall, where the local
      // counter is gone but the server still has this month's rows.
      // A failure here never changes the plan result above.
      await refreshFreeCountFromServer();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Reconciles the local monthly free-test count with the server.
  ///
  /// Counts the user's `test_results` rows created in the current
  /// calendar month and takes the HIGHER of (server count, local
  /// count) as this month's used count. That is the safe direction
  /// both ways: a reinstall (local 0, server 2) does not reset the
  /// limit, and offline tests (local 2, server 0 — not synced yet)
  /// are not forgotten either. Returns true when the server answered,
  /// false when offline / unconfigured / signed out / error — in
  /// which case the local cache is left untouched. Never throws.
  Future<bool> refreshFreeCountFromServer({DateTime? now}) async {
    if (!_isConfigured()) return false;
    final userId = _currentUserId();
    if (userId == null) return false;
    final at = now ?? DateTime.now();
    try {
      final serverCount =
          await (serverMonthlyTestCountFetcher ?? _fetchServerMonthlyCount)(
            userId,
            monthStartFor(at),
          );
      if (serverCount == null) return false;
      final local = await testsUsed(now: at);
      final merged = serverCount > local ? serverCount : local;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kTestsUsedMonth, monthKeyFor(at));
      await prefs.setInt(_kTestsUsedMonthCount, merged);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Syncs ONE finished test to the server `test_results` table
  /// (the cloud backup AND the server-side monthly count). Best
  /// effort, never blocking: returns false (never throws) when
  /// offline, unconfigured, signed out, or the insert fails — the
  /// local history is the source of truth and is unaffected. The
  /// caller must NOT await this on the result path.
  Future<bool> syncTestResultToServer({
    required String examName,
    required int score,
    required int total,
    String? bookTitle,
  }) async {
    if (!_isConfigured()) return false;
    final userId = _currentUserId();
    if (userId == null) return false;
    try {
      return await (serverTestResultInserter ?? _insertServerTestResult)(
        userId: userId,
        examName: examName,
        score: score,
        total: total,
        bookTitle: bookTitle,
      );
    } catch (_) {
      return false;
    }
  }

  /// Applies a server-side grant (called after a successful code
  /// redemption, and by [refreshPlanFromServer]). [plan] is a plan id
  /// or the literal `premium` / `free`; [premiumUntil] is the server
  /// expiry (null for Free). [months] (from the redeemed code, when
  /// known) disambiguates the literal `premium`. Writes the offline
  /// cache so the app works without a connection afterwards.
  Future<void> applyServerPremium(
    String plan,
    DateTime? premiumUntil, {
    int? months,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (!isServerPremium(plan, premiumUntil)) {
      await prefs.setBool(_kIsPremium, false);
      await prefs.remove(_kPlanId);
      await prefs.remove(_kPremiumUntil);
      return;
    }
    final planId =
        planIdForServerPlan(plan, premiumUntil, months: months) ??
        'premium_1month';
    await prefs.setBool(_kIsPremium, true);
    await prefs.setString(_kPlanId, planId);
    await prefs.setString(_kPremiumUntil, premiumUntil!.toIso8601String());
  }

  /// Cached premium expiry (null when Free / never granted). The
  /// stored value may be past — [isPremium] is the authority on
  /// whether Premium is active.
  Future<DateTime?> premiumUntil() async {
    final prefs = await SharedPreferences.getInstance();
    final until = prefs.getString(_kPremiumUntil);
    return until == null ? null : DateTime.tryParse(until);
  }

  /// `'premium'` when Premium is active, `'free'` otherwise (cached).
  Future<String> currentPlan() async =>
      await isPremium() ? 'premium' : 'free';

  String? _currentUserId() {
    if (currentUserIdOverride != null) return currentUserIdOverride!();
    if (!_isConfigured()) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _fetchServerProfile(
    String userId,
  ) async {
    final row = await Supabase.instance.client
        .from('profiles')
        .select('plan, premium_until')
        .eq('id', userId)
        .maybeSingle();
    if (row == null) return null;
    return Map<String, dynamic>.from(row as Map);
  }

  /// Counts the user's `test_results` rows with
  /// `created_at >= monthStart`. RLS ("Users can view their own test
  /// results") lets a user count only their own rows. A count query
  /// would be cheaper, but the Supabase Dart client returns rows for
  /// `.select('id')` — the table holds at most a few rows per user
  /// per month, so this stays tiny.
  static Future<int?> _fetchServerMonthlyCount(
    String userId,
    DateTime monthStart,
  ) async {
    final rows = await Supabase.instance.client
        .from('test_results')
        .select('id')
        .eq('user_id', userId)
        .gte('created_at', monthStart.toIso8601String());
    return (rows as List).length;
  }

  /// Inserts one finished-test row. RLS ("Users can insert their own
  /// test results") requires `user_id` to be the caller's own id.
  static Future<bool> _insertServerTestResult({
    required String userId,
    required String examName,
    required int score,
    required int total,
    String? bookTitle,
  }) async {
    await Supabase.instance.client.from('test_results').insert({
      'user_id': userId,
      'exam': examName,
      'score': score,
      'total': total,
      'book_title': bookTitle ?? '',
    });
    return true;
  }

  /// Tests used in the CURRENT calendar month (local cache). A stored
  /// count from a previous month reads as 0 — the reset is the month
  /// rollover, no timer or job needed. Offline-first: this never
  /// touches the network; [refreshFreeCountFromServer] reconciles it
  /// with the server when online.
  Future<int> testsUsed({DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    final month = monthKeyFor(now ?? DateTime.now());
    if (prefs.getString(_kTestsUsedMonth) != month) return 0;
    return prefs.getInt(_kTestsUsedMonthCount) ?? 0;
  }

  Future<int> testsRemaining({DateTime? now}) async {
    if (await isPremium()) return -1; // -1 = unlimited
    final used = await testsUsed(now: now);
    final remaining = freeTestLimit - used;
    return remaining < 0 ? 0 : remaining;
  }

  /// True when the user may generate another test right now.
  Future<bool> canGenerateTest({DateTime? now}) async {
    if (await isPremium()) return true;
    return (await testsUsed(now: now)) < freeTestLimit;
  }

  /// Call when a test is generated (not when it is finished — abandoning
  /// a generated test still counts, otherwise the limit is trivially
  /// bypassed by force-closing the app).
  ///
  /// AUDIT F5: Premium users used to consume free-test credits too,
  /// so after expiry they showed "12 / 3 tests used" and got 0 free
  /// tests left. Premium never consumes the free counter.
  ///
  /// v2 monthly: the counter lives under the current `'yyyy-MM'` key.
  /// Generating the first test of a new month resets the count to 1
  /// (the rollover IS the reset — no timer, no server call here).
  Future<void> recordTestGenerated({DateTime? now}) async {
    if (await isPremium()) return;
    final prefs = await SharedPreferences.getInstance();
    final month = monthKeyFor(now ?? DateTime.now());
    if (prefs.getString(_kTestsUsedMonth) != month) {
      await prefs.setString(_kTestsUsedMonth, month);
      await prefs.setInt(_kTestsUsedMonthCount, 1);
      return;
    }
    final used = prefs.getInt(_kTestsUsedMonthCount) ?? 0;
    await prefs.setInt(_kTestsUsedMonthCount, used + 1);
  }

  /// Premium is time-bound. An expired plan falls back to Free.
  Future<bool> isPremium() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kIsPremium) != true) return false;
    final until = prefs.getString(_kPremiumUntil);
    if (until == null) return false;
    final expiry = DateTime.tryParse(until);
    if (expiry == null || DateTime.now().isAfter(expiry)) {
      await prefs.setBool(_kIsPremium, false);
      return false;
    }
    return true;
  }

  Future<String?> currentPlanId() async {
    if (!await isPremium()) return null;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kPlanId);
  }

  /// True when the user may add another of their own books.
  /// [customBookCount] = number of non-built-in sources already stored.
  Future<bool> canAddBook(int customBookCount) async {
    if (await isPremium()) return true;
    return customBookCount < freeBookLimit;
  }

  /// Called ONLY by the billing layer after a verified Play purchase.
  /// Never call this from UI code directly.
  Future<void> grantPremium(PremiumPlan plan) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kIsPremium, true);
    await prefs.setString(_kPlanId, plan.id);
    await prefs.setString(
      _kPremiumUntil,
      DateTime.now()
          .add(Duration(days: plan.durationDays))
          .toIso8601String(),
    );
  }

  /// Test/dev helper: clears the entitlement (used by unit tests only).
  Future<void> resetForTest() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kTestsUsed);
    await prefs.remove(_kTestsUsedMonth);
    await prefs.remove(_kTestsUsedMonthCount);
    await prefs.remove(_kIsPremium);
    await prefs.remove(_kPlanId);
    await prefs.remove(_kPremiumUntil);
    serverProfileFetcher = null;
    serverMonthlyTestCountFetcher = null;
    serverTestResultInserter = null;
    currentUserIdOverride = null;
    isConfiguredOverride = null;
  }
}
