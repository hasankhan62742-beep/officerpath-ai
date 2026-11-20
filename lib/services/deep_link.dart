/// Deep-link parsing for OfficerPath AI v2.0.0.
///
/// The password-reset email links to `officerpath://reset-password`.
/// Supabase puts the recovery token in one of two places, depending on
/// the email template / PKCE flow:
///   * PKCE flow: a `code` query parameter, e.g.
///     `officerpath://reset-password?code=abc123`
///   * Implicit flow: tokens in the URL fragment, e.g.
///     `officerpath://reset-password#access_token=...&refresh_token=...&type=recovery`
///
/// This file is pure Dart (no platform channels) so it is unit-tested
/// directly — see test/deep_link_test.dart.
class ResetPasswordLink {
  const ResetPasswordLink({
    required this.isResetLink,
    this.code,
    this.accessToken,
    this.refreshToken,
    this.type,
  });

  /// True only for the officerpath reset-password deep link.
  final bool isResetLink;

  /// PKCE authorisation code (query parameter).
  final String? code;

  /// Access token from the URL fragment (implicit flow).
  final String? accessToken;

  /// Refresh token from the URL fragment (implicit flow).
  final String? refreshToken;

  /// Link type, e.g. `recovery` when present.
  final String? type;

  /// True when the link carries enough to establish a recovery session.
  bool get hasRecoveryToken =>
      code != null || (accessToken != null && refreshToken != null);
}

/// Parses [uri] as a possible password-reset deep link.
///
/// Anything that is not the officerpath reset-password link returns
/// [ResetPasswordLink.isResetLink] == false with no token fields set.
ResetPasswordLink parseResetPasswordUri(Uri uri) {
  final isReset =
      uri.scheme == 'officerpath' && uri.host == 'reset-password';
  if (!isReset) return const ResetPasswordLink(isResetLink: false);
  // The fragment (`#access_token=...`) is not part of queryParameters,
  // so parse it separately. Both sources are checked for every field.
  final fragmentParams = uri.fragment.isEmpty
      ? <String, String>{}
      : Uri.splitQueryString(uri.fragment);
  return ResetPasswordLink(
    isResetLink: true,
    code: uri.queryParameters['code'] ?? fragmentParams['code'],
    accessToken:
        uri.queryParameters['access_token'] ??
        fragmentParams['access_token'],
    refreshToken:
        uri.queryParameters['refresh_token'] ??
        fragmentParams['refresh_token'],
    type: uri.queryParameters['type'] ?? fragmentParams['type'],
  );
}
