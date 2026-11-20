import 'package:supabase_flutter/supabase_flutter.dart';

/// Server-side Premium activation for OfficerPath AI v2.0.0.
///
/// v1 codes were validated OFFLINE with a compiled-in secret — anyone
/// reading the repo could forge them, and a code could be shared
/// forever. v2 codes live in Supabase (`activation_codes`, hash only)
/// and are redeemed ONCE through the `redeem-code` Edge Function.
///
/// The pure helpers ([isValidCodeFormat], [planMonthsForCode],
/// [parseRedeemResponse]) need no network and are unit-tested.
/// [redeemCode] takes an injectable [invoke] so tests can fake the
/// Edge Function without a network call; production callers omit it
/// and the real Supabase client is used.
class RedeemResult {
  const RedeemResult({
    required this.success,
    this.premiumUntil,
    this.message,
  });

  /// True when the code redeemed and Premium was granted.
  final bool success;

  /// Premium expiry returned by the server (null on failure).
  final DateTime? premiumUntil;

  /// Plain-language failure reason (Roman Urdu), null on success.
  final String? message;
}

/// Signature of the Edge Function call, so tests can inject a fake.
typedef EdgeFunctionInvoker =
    Future<Map<String, dynamic>> Function(
      String functionName,
      Map<String, dynamic> body,
    );

class ActivationService {
  ActivationService({EdgeFunctionInvoker? invoke})
    : _invoke = invoke ?? _defaultInvoke;

  final EdgeFunctionInvoker _invoke;

  static Future<Map<String, dynamic>> _defaultInvoke(
    String functionName,
    Map<String, dynamic> body,
  ) async {
    final response = await Supabase.instance.client.functions.invoke(
      functionName,
      body: body,
    );
    final data = response.data;
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return {'ok': false, 'error': 'server_error', 'status': response.status};
  }

  /// Code format: `OP` + plan digit + `-` + 6 chars.
  /// Digit 1 = 1 month, 2 = 2 months, 3 = 1 year. The 6 chars use the
  /// alphabet ABCDEFGHJKMNPQRSTUVWXYZ23456789 (no 0/O/1/I/L).
  static final RegExp codePattern = RegExp(r'^OP[123]-[A-HJ-KM-NP-Z2-9]{6}$');

  /// Local format check only — a well-formed code can still be unknown,
  /// used or expired; only the server knows that.
  static bool isValidCodeFormat(String rawCode) {
    final code = rawCode.trim().toUpperCase().replaceAll(' ', '');
    return codePattern.hasMatch(code);
  }

  /// Months a code grants, from its plan digit: 1 -> 1, 2 -> 2, 3 -> 12.
  /// Returns null for a malformed code.
  static int? planMonthsForCode(String rawCode) {
    final code = rawCode.trim().toUpperCase().replaceAll(' ', '');
    final match = codePattern.firstMatch(code);
    if (match == null) return null;
    return switch (code[2]) {
      '1' => 1,
      '2' => 2,
      '3' => 12,
      _ => null,
    };
  }

  /// Maps a redeem-code Edge Function response to a [RedeemResult].
  /// [data] is the decoded JSON body. Unknown / missing shapes become a
  /// generic failure — never a crash, never a false success.
  static RedeemResult parseRedeemResponse(dynamic data) {
    if (data is! Map) {
      return const RedeemResult(
        success: false,
        message: 'Server se jawab nahi mila. Dobara koshish karein.',
      );
    }
    final map = data is Map<String, dynamic>
        ? data
        : Map<String, dynamic>.from(data);
    if (map['ok'] == true) {
      DateTime? until;
      final raw = map['premium_until'];
      if (raw is String) until = DateTime.tryParse(raw);
      return RedeemResult(success: true, premiumUntil: until);
    }
    final message = switch (map['error']) {
      'code_not_found' || 'invalid_code' => 'Ye code nahi mila. '
          'Code dobara check karke likhein.',
      'code_already_used' => 'Ye code istemal ho chuka hai.',
      'code_expired' => 'Is code ki muddat khatam ho chuki hai.',
      'code_not_yours' => 'Ye code aap ka nahi hai.',
      'unauthorized' => 'Pehle login karein, phir code redeem karein.',
      _ => 'Code redeem nahi hua. Dobara koshish karein.',
    };
    return RedeemResult(success: false, message: message);
  }

  /// Redeems [rawCode] on the server. Returns success with the Premium
  /// expiry, or a plain-language failure reason. Never throws for a
  /// bad code or a bad server answer — only a transport failure
  /// (no network) propagates as an exception for the caller to catch.
  Future<RedeemResult> redeemCode(String rawCode) async {
    final code = rawCode.trim().toUpperCase().replaceAll(' ', '');
    if (!isValidCodeFormat(code)) {
      return const RedeemResult(
        success: false,
        message: 'Code ka format ghalat hai. Jaise: OP1-ABCDEF',
      );
    }
    final data = await _invoke('redeem-code', {'code': code});
    return parseRedeemResponse(data);
  }
}
