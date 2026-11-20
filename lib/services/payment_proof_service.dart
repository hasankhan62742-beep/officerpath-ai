import 'package:supabase_flutter/supabase_flutter.dart';

import 'subscription_service.dart';
import 'supabase_config.dart';

/// One payment-proof row from the server `payments` table.
class PaymentProof {
  const PaymentProof({
    this.id,
    this.userId,
    required this.plan,
    required this.method,
    required this.transactionId,
    required this.status,
    this.email,
    this.createdAt,
  });

  factory PaymentProof.fromJson(Map<String, dynamic> json) {
    return PaymentProof(
      id: json['id']?.toString(),
      userId: json['user_id']?.toString(),
      plan: (json['plan'] as String?) ?? 'premium_1month',
      method: (json['method'] as String?) ?? '',
      transactionId: (json['transaction_id'] as String?) ?? '',
      status: (json['status'] as String?) ?? 'pending',
      email: json['email'] as String?,
      createdAt: json['created_at'] == null
          ? null
          : DateTime.tryParse(json['created_at'].toString()),
    );
  }

  final String? id;
  final String? userId;

  /// Plan id: `premium_1month` / `premium_2months` / `premium_1year`.
  final String plan;
  final String method;
  final String transactionId;

  /// `pending` / `approved` / `rejected` (server values, lowercase).
  final String status;
  final String? email;
  final DateTime? createdAt;

  /// Display label for the status: Pending / Approved / Rejected.
  String get statusLabel {
    return switch (status.toLowerCase()) {
      'pending' => 'Pending',
      'approved' => 'Approved',
      'rejected' => 'Rejected',
      _ => status,
    };
  }

  bool get isPending => status.toLowerCase() == 'pending';
}

/// Result of submitting a payment proof. [error] is a plain-language
/// sentence the UI can show as-is.
class PaymentProofSubmitResult {
  const PaymentProofSubmitResult({required this.ok, this.proof, this.error});

  factory PaymentProofSubmitResult.success(PaymentProof proof) =>
      PaymentProofSubmitResult(ok: true, proof: proof);

  factory PaymentProofSubmitResult.failure(String error) =>
      PaymentProofSubmitResult(ok: false, error: error);

  final bool ok;
  final PaymentProof? proof;
  final String? error;
}

/// The signed-in account, as the server sees it. `null` when nobody
/// is signed in (or the backend is not configured).
typedef AccountProvider = ({String id, String? email})? Function();

/// Inserts one row into `payments`. Injected for tests.
typedef PaymentRowInserter =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> row);

/// Lists the current user's rows from `payments`. Injected for tests.
typedef PaymentRowsFetcher =
    Future<List<Map<String, dynamic>>> Function(String userId);

/// Payment-proof submission (v2.0) — the student pays manually
/// (Easypaisa / JazzCash) and submits the transaction ID here. The row
/// lands in the server `payments` table with status `pending`; the
/// owner approves it from the admin panel, which issues the activation
/// code. No money ever moves through this service.
///
/// Testability: the account, the insert and the list fetch are all
/// injectable. Unit/widget tests pass fakes; production uses the
/// default Supabase implementations. Nothing here touches
/// `Supabase.instance` unless [SupabaseConfig.isConfigured] is true,
/// so tests (Supabase never initialised) stay offline-safe.
class PaymentProofService {
  PaymentProofService({
    AccountProvider? accountProvider,
    PaymentRowInserter? inserter,
    PaymentRowsFetcher? fetcher,
    bool Function()? isConfigured,
  }) : _accountProvider = accountProvider ?? _defaultAccount,
       _inserter = inserter ?? _defaultInsert,
       _fetcher = fetcher ?? _defaultFetch,
       _isConfigured = isConfigured ?? (() => SupabaseConfig.isConfigured);

  static final PaymentProofService instance = PaymentProofService();

  final AccountProvider _accountProvider;
  final PaymentRowInserter _inserter;
  final PaymentRowsFetcher _fetcher;
  final bool Function() _isConfigured;

  /// The signed-in user's id, or null when signed out / offline.
  String? currentAccountId() => _accountProvider()?.id;

  /// The signed-in user's registered email (shown read-only on the
  /// Upgrade screen), or null when signed out / offline.
  String? currentAccountEmail() => _accountProvider()?.email;

  /// Validates a transaction / reference ID. Returns a plain-language
  /// error, or null when the value is fine. Pure — no network.
  ///
  /// Rules: non-empty, 6–30 characters, letters / digits / spaces /
  /// dashes only (Easypaisa & JazzCash IDs are 10–13 digits; the
  /// wider range accepts bank references too).
  static String? validateTransactionId(String? value) {
    final id = value?.trim() ?? '';
    if (id.isEmpty) {
      return 'Enter the transaction ID from your payment app.';
    }
    if (id.length < 6) {
      return 'That transaction ID looks too short — check it and try again.';
    }
    if (id.length > 30) {
      return 'That transaction ID looks too long — check it and try again.';
    }
    if (!RegExp(r'^[A-Za-z0-9 \-]+$').hasMatch(id)) {
      return 'Transaction ID can only contain letters, numbers, spaces and dashes.';
    }
    return null;
  }

  /// Display label for a plan id, e.g. `Premium — 1 Month`. Pure.
  static String planLabel(String planId) => PremiumPlan.byId(planId).name;

  /// Price in PKR for a plan id (600 / 1000 / 5000). Pure.
  /// Unknown ids return null — the caller must not submit those.
  static int? planPrice(String planId) {
    final found = PremiumPlan.plans.where((p) => p.id == planId).firstOrNull;
    return found?.pricePkr;
  }

  /// The exact row inserted into `payments`. Pure — unit-tested.
  /// `plan` is the plan id; `status` is always `pending` on submit.
  static Map<String, dynamic> buildProofPayload({
    required String userId,
    required String? email,
    required String planId,
    required String method,
    required String transactionId,
  }) {
    return {
      'user_id': userId,
      'email': email,
      'plan': planId,
      'method': method,
      'transaction_id': transactionId.trim(),
      'status': 'pending',
    };
  }

  /// Submits a payment proof for the signed-in user. Never throws for
  /// a validation / account / server problem — those come back as a
  /// failed [PaymentProofSubmitResult] with a plain-language [error].
  Future<PaymentProofSubmitResult> submitPaymentProof({
    required String plan,
    required String method,
    required String transactionId,
  }) async {
    final txError = validateTransactionId(transactionId);
    if (txError != null) return PaymentProofSubmitResult.failure(txError);
    if (planPrice(plan) == null) {
      return PaymentProofSubmitResult.failure(
        'Please pick a plan first, then submit your payment proof.',
      );
    }
    if (method != 'Easypaisa' && method != 'JazzCash') {
      return PaymentProofSubmitResult.failure(
        'Please pick Easypaisa or JazzCash as the payment method.',
      );
    }
    final account = _accountProvider();
    if (account == null) {
      return PaymentProofSubmitResult.failure(
        'Please sign in first — your payment proof is linked to your account email.',
      );
    }
    if (!_isConfigured()) {
      return PaymentProofSubmitResult.failure(
        'The server is not connected right now. Send your payment proof '
        'on WhatsApp instead and the owner will activate your Premium.',
      );
    }
    try {
      final row = await _inserter(
        buildProofPayload(
          userId: account.id,
          email: account.email,
          planId: plan,
          method: method,
          transactionId: transactionId,
        ),
      );
      return PaymentProofSubmitResult.success(PaymentProof.fromJson(row));
    } catch (_) {
      return PaymentProofSubmitResult.failure(
        'Could not submit your payment proof. Check your connection '
        'and try again.',
      );
    }
  }

  /// Lists the signed-in user's payment proofs, newest first.
  /// Returns an empty list when signed out, offline, or on error —
  /// the Upgrade screen treats "no proofs" and "could not load" the
  /// same way and offers a refresh button.
  Future<List<PaymentProof>> myPayments() async {
    final account = _accountProvider();
    if (account == null || !_isConfigured()) return [];
    try {
      final rows = await _fetcher(account.id);
      return rows.map(PaymentProof.fromJson).toList();
    } catch (_) {
      return [];
    }
  }

  /// True when the user already has a pending proof for [planId] —
  /// the UI uses it to warn against submitting the same payment twice.
  Future<bool> hasPendingProof(String planId) async {
    final proofs = await myPayments();
    return proofs.any((p) => p.isPending && p.plan == planId);
  }

  static ({String id, String? email})? _defaultAccount() {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return null;
      return (id: user.id, email: user.email);
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>> _defaultInsert(
    Map<String, dynamic> row,
  ) async {
    final inserted = await Supabase.instance.client
        .from('payments')
        .insert(row)
        .select()
        .single();
    return Map<String, dynamic>.from(inserted as Map);
  }

  static Future<List<Map<String, dynamic>>> _defaultFetch(
    String userId,
  ) async {
    final rows = await Supabase.instance.client
        .from('payments')
        .select()
        .eq('user_id', userId)
        .order('created_at', ascending: false);
    return (rows as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
  }
}
