// DEPRECATED (v1-only): offline codes are replaced by server-side single-use codes in v2.0 — see activation_service.dart. Kept for the v1.2.0 build only; do not use for new activations.
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'subscription_service.dart';

/// Manual Premium activation (v1) — JazzCash / Easypaisa / bank transfer.
///
/// v1 has NO Play account and NO in-app billing. The flow is the same one
/// local competitors (Pak Imtehan, MockCSS) use:
///   1. Student picks a plan in the Upgrade screen.
///   2. Student pays via JazzCash / Easypaisa / bank transfer.
///   3. Student sends the payment proof (screenshot / transaction ID) on
///      WhatsApp to the owner.
///   4. Owner checks the payment and sends back an activation code.
///   5. Student enters the code here → Premium unlocks on this device.
///
/// HOW CODES WORK (offline, no server in v1):
/// A code encodes the plan (`OP1` = 1 month, `OP2` = 2 months,
/// `OP3` = 1 year) plus a 6-character checksum. The checksum is a hash of
/// (secret + plan). The secret is compiled into the app with
/// `--dart-define=ACTIVATION_SECRET=...` and the owner generates codes
/// with `tools/generate_activation_code.dart` using the SAME secret.
/// Anyone with the secret can mint codes — so keep it private, use a
/// strong random value, and never commit it.
///
/// HONEST LIMITS (v1):
/// * A code is NOT single-use and NOT tied to a device — there is no
///   server to check against. A shared code would unlock other phones.
///   The owner must issue one code per paying student and track sold
///   codes (e.g. in a sheet). Server-side validation is a v2 item.
/// * The default secret (`CHANGE_ME_IN_RELEASE_BUILD`) is public in this
///   repo — the release APK MUST be built with a real secret, or codes
///   minted with the default can be forged by anyone reading this file.
class ManualActivationService {
  ManualActivationService._();
  static final ManualActivationService instance = ManualActivationService._();

  /// Owner's WhatsApp (public business number, Qadeer Automations).
  static const String ownerWhatsApp = '923427717288';

  /// Code prefix letter per plan (digit after "OP").
  static const Map<String, String> _planDigits = {
    'premium_1month': '1',
    'premium_2months': '2',
    'premium_1year': '3',
  };

  static const String _alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

  static String get _secret => const String.fromEnvironment(
    'ACTIVATION_SECRET',
    defaultValue: 'CHANGE_ME_IN_RELEASE_BUILD',
  );

  /// The checksum algorithm. Kept identical in
  /// `tools/generate_activation_code.dart` — change both together.
  static String checksumFor(String planId) {
    final input = '$_secret|$planId';
    var hash = 0x811c9dc5; // FNV-1a 32-bit offset basis
    for (var i = 0; i < input.length; i++) {
      hash ^= input.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0xFFFFFFFF; // FNV prime
    }
    final buf = StringBuffer();
    var value = hash;
    for (var i = 0; i < 6; i++) {
      buf.write(_alphabet[value % _alphabet.length]);
      value ~/= _alphabet.length;
    }
    return buf.toString();
  }

  /// Builds the full code for a plan, e.g. `OP2-K7Q9XA`.
  static String buildCode(String planId) {
    final digit = _planDigits[planId];
    if (digit == null) throw ArgumentError('Unknown plan: $planId');
    return 'OP$digit-${checksumFor(planId)}';
  }

  /// Validates a code the student typed. Returns the plan it unlocks,
  /// or null when the code is invalid (wrong format, unknown plan digit,
  /// or checksum mismatch).
  PremiumPlan? validateCode(String rawCode) {
    final code = rawCode.trim().toUpperCase().replaceAll(' ', '');
    final match = RegExp(r'^OP([123])-([A-Z2-9]{6})$').firstMatch(code);
    if (match == null) return null;
    final digit = match.group(1)!;
    final planId = _planDigits.entries
        .firstWhere(
          (e) => e.value == digit,
          orElse: () => const MapEntry('', ''),
        )
        .key;
    if (planId.isEmpty) return null;
    if (match.group(2)! != checksumFor(planId)) return null;
    return PremiumPlan.byId(planId);
  }

  /// Grants Premium for the plan encoded in [rawCode]. Returns the plan
  /// on success, null on an invalid code.
  Future<PremiumPlan?> activateWithCode(String rawCode) async {
    final plan = validateCode(rawCode);
    if (plan == null) return null;
    await SubscriptionService.instance.grantPremium(plan);
    return plan;
  }

  /// Saves the student's pending payment (plan + method + reference) on
  /// the device so the Upgrade screen can show "request sent" state.
  Future<void> savePendingRequest({
    required PremiumPlan plan,
    required String method,
    required String reference,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pending_plan_id', plan.id);
    await prefs.setString('pending_method', method);
    await prefs.setString('pending_reference', reference);
    await prefs.setString(
      'pending_at_iso',
      DateTime.now().toIso8601String(),
    );
  }

  Future<Map<String, String>?> getPendingRequest() async {
    final prefs = await SharedPreferences.getInstance();
    final planId = prefs.getString('pending_plan_id');
    if (planId == null) return null;
    return {
      'planId': planId,
      'method': prefs.getString('pending_method') ?? '',
      'reference': prefs.getString('pending_reference') ?? '',
      'atIso': prefs.getString('pending_at_iso') ?? '',
    };
  }

  /// Opens WhatsApp with a pre-filled payment-proof message for [plan].
  /// Returns false when no app/browser can open the link.
  Future<bool> sendProofOnWhatsApp({
    required PremiumPlan plan,
    required String method,
    required String reference,
  }) async {
    final message =
        'Assalam-o-Alaikum! OfficerPath AI Premium chahiye.\n'
        'Plan: ${plan.name} (${plan.priceLabel})\n'
        'Payment method: $method\n'
        'Transaction / Reference: ${reference.isEmpty ? '(screenshot attached)' : reference}\n'
        'Please send my activation code. Shukriya!';
    final uri = Uri.parse(
      'https://wa.me/$ownerWhatsApp?text=${Uri.encodeComponent(message)}',
    );
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
