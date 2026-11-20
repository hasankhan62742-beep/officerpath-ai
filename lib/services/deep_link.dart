/// Deep-link parsing for OfficerPath AI v2.0.0.
///
/// The password-reset email links to `officerpath://reset-password`.
/// Supabase sends a PKCE authorisation `code` as a query parameter,
/// e.g. `officerpath://reset-password?code=abc123`.
///
/// PKCE-ONLY (audit L7): raw `access_token` / `refresh_token` values in
/// the URL are deliberately NOT parsed and NOT accepted. The app never
/// calls `setSession()` with URL-supplied tokens — implicit-flow tokens
/// can linger in OS intent logs, and the reset flow does not need them:
/// the app's Supabase client defaults to the PKCE flow
/// (`gotrue` default `AuthFlowType.pkce`; `resetPasswordForEmail` sends
/// a `code_challenge`, so the server issues a `code`). A link carrying
/// only bare tokens is treated as having no recovery token, and the
/// reset screen shows its expired-link state.
class ResetPasswordLink {
  const ResetPasswordLink({required this.isResetLink, this.code, this.type});

  /// True only for the officerpath reset-password deep link.
  final bool isResetLink;

  /// PKCE authorisation code (query parameter).
  final String? code;

  /// Link type, e.g. `recovery` when present.
  final String? type;

  /// True only when the link carries a PKCE code.
  bool get hasRecoveryToken => code != null;
}

/// Parses [uri] as a possible password-reset deep link.
///
/// Anything that is not the officerpath reset-password link returns
/// [ResetPasswordLink.isResetLink] == false with no token fields set.
/// A reset link without a PKCE `code` — including one carrying bare
/// `access_token`/`refresh_token` values — has
/// [ResetPasswordLink.hasRecoveryToken] == false.
ResetPasswordLink parseResetPasswordUri(Uri uri) {
  final isReset =
      uri.scheme == 'officerpath' && uri.host == 'reset-password';
  if (!isReset) return const ResetPasswordLink(isResetLink: false);
  // The fragment (`#access_token=...`) is not part of queryParameters,
  // so parse it separately — but only to read `code`/`type`. Bare
  // tokens in either place are ignored on purpose (see class doc).
  final fragmentParams = uri.fragment.isEmpty
      ? <String, String>{}
      : Uri.splitQueryString(uri.fragment);
  return ResetPasswordLink(
    isResetLink: true,
    code: uri.queryParameters['code'] ?? fragmentParams['code'],
    type: uri.queryParameters['type'] ?? fragmentParams['type'],
  );
}
