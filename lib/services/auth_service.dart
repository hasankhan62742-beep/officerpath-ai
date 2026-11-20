import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_config.dart';

/// Auth for OfficerPath AI v2.0.0 — a thin, testable wrapper around
/// Supabase Auth (email/password + Google) and the `profiles` table.
///
/// Testability: [AuthService] never touches `Supabase.instance` in its
/// own methods. It talks to an [AuthBackend]; production passes a
/// [SupabaseAuthBackend] (built from the real client), tests pass a
/// fake. The default constructor builds the real backend lazily and
/// falls back to [UnconfiguredAuthBackend] when Supabase was never
/// initialised (offline / no dart-define values) — so the app still
/// starts and the auth screen can show its "server abhi connect nahi
/// hua" state instead of crashing.
///
/// Local data is never touched here: login does NOT wipe the sqflite
/// books/history in StorageService. Session persistence comes free
/// with supabase_flutter.

/// Outcome of an auth call, with a plain-language message for the UI.
enum AuthStatus {
  success,
  needsEmailVerification,
  cancelled,
  unavailable,
  error,
}

class AuthResult {
  const AuthResult(this.status, [this.message]);
  const AuthResult.success() : this(AuthStatus.success);
  const AuthResult.needsEmailVerification()
    : this(AuthStatus.needsEmailVerification);
  const AuthResult.cancelled() : this(AuthStatus.cancelled);
  const AuthResult.unavailable([String? message])
    : this(AuthStatus.unavailable, message);
  const AuthResult.error(String message) : this(AuthStatus.error, message);

  final AuthStatus status;

  /// Plain-language message for the user (Roman Urdu), null on success.
  final String? message;

  /// True for success and for "check your inbox" (signup accepted).
  bool get ok =>
      status == AuthStatus.success ||
      status == AuthStatus.needsEmailVerification;
}

/// One row of the `profiles` table (created by a DB trigger on signup).
class UserProfile {
  const UserProfile({
    required this.id,
    required this.username,
    required this.email,
    this.plan = 'free',
    this.premiumUntil,
    this.isAdmin = false,
    this.createdAt,
  });

  factory UserProfile.fromMap(Map<String, dynamic> map) {
    DateTime? parseDate(Object? raw) {
      if (raw is String) return DateTime.tryParse(raw);
      return null;
    }

    return UserProfile(
      id: (map['id'] as Object?)?.toString() ?? '',
      username: (map['username'] as Object?)?.toString() ?? '',
      email: (map['email'] as Object?)?.toString() ?? '',
      plan: (map['plan'] as Object?)?.toString() ?? 'free',
      premiumUntil: parseDate(map['premium_until']),
      isAdmin: map['is_admin'] == true,
      createdAt: parseDate(map['created_at']),
    );
  }

  final String id;
  final String username;
  final String email;

  /// 'free' or 'premium'.
  final String plan;
  final DateTime? premiumUntil;
  final bool isAdmin;
  final DateTime? createdAt;

  bool get isPremium => plan == 'premium';
  String get planLabel => isPremium ? 'Premium' : 'Free';
}

/// Result of a successful sign-up: the user id (when known) and
/// whether a session already exists (false when email verification
/// is required first).
class SignUpOutcome {
  const SignUpOutcome({this.userId, required this.hasSession});

  final String? userId;
  final bool hasSession;
}

/// Result of the server-side account deletion.
enum DeleteAccountOutcome { deleted, unavailable }

/// The narrow slice of Supabase that [AuthService] needs, as an
/// interface so tests can fake it without a network or a real client.
abstract class AuthBackend {
  bool get isConfigured;
  String? get currentUserId;
  String? get currentUserEmail;
  bool get isSignedIn;

  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String username,
  });
  Future<void> signIn({required String email, required String password});
  Future<void> signInWithIdToken(String idToken);
  Future<void> signOut();
  Future<void> sendPasswordResetEmail(String email, String redirectTo);
  Future<void> resendSignupEmail(String email);
  Future<void> updatePassword(String newPassword);
  Future<bool> isUsernameTaken(String username);
  Future<void> upsertProfile({
    required String userId,
    required String username,
    required String email,
  });
  Future<Map<String, dynamic>?> fetchProfile(String userId);
  Future<void> updateProfileUsername(String userId, String username);
  Future<DeleteAccountOutcome> deleteAccount();
}

/// Backend used when Supabase was never initialised (offline build or
/// missing dart-define values). Every call fails fast with a clear
/// state error; [AuthService] checks [isConfigured] first and turns
/// that into the "server abhi connect nahi hua" message instead.
class UnconfiguredAuthBackend implements AuthBackend {
  const UnconfiguredAuthBackend();

  @override
  bool get isConfigured => false;

  @override
  String? get currentUserId => null;

  @override
  String? get currentUserEmail => null;

  @override
  bool get isSignedIn => false;

  Never _throw() => throw StateError('Supabase is not configured.');

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String username,
  }) => _throw();

  @override
  Future<void> signIn({required String email, required String password}) =>
      _throw();

  @override
  Future<void> signInWithIdToken(String idToken) => _throw();

  @override
  Future<void> signOut() async {}

  @override
  Future<void> sendPasswordResetEmail(String email, String redirectTo) =>
      _throw();

  @override
  Future<void> resendSignupEmail(String email) => _throw();

  @override
  Future<void> updatePassword(String newPassword) => _throw();

  @override
  Future<bool> isUsernameTaken(String username) => _throw();

  @override
  Future<void> upsertProfile({
    required String userId,
    required String username,
    required String email,
  }) => _throw();

  @override
  Future<Map<String, dynamic>?> fetchProfile(String userId) => _throw();

  @override
  Future<void> updateProfileUsername(String userId, String username) =>
      _throw();

  @override
  Future<DeleteAccountOutcome> deleteAccount() => _throw();
}

/// Real [AuthBackend] backed by a [SupabaseClient].
class SupabaseAuthBackend implements AuthBackend {
  SupabaseAuthBackend(this._client);

  /// Builds the backend from the shared initialised client.
  /// Throws when Supabase was never initialised — callers must guard
  /// with [SupabaseConfig.isConfigured] / try-catch (see [AuthService]).
  factory SupabaseAuthBackend.fromInstance() =>
      SupabaseAuthBackend(Supabase.instance.client);

  final SupabaseClient _client;

  /// Deep link the reset-password email points back to.
  static const String resetPasswordRedirect =
      'officerpath://reset-password';

  @override
  bool get isConfigured => SupabaseConfig.isConfigured;

  @override
  String? get currentUserId => _client.auth.currentUser?.id;

  @override
  String? get currentUserEmail => _client.auth.currentUser?.email;

  @override
  bool get isSignedIn => _client.auth.currentSession != null;

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String username,
  }) async {
    final response = await _client.auth.signUp(
      email: email,
      password: password,
      emailRedirectTo: resetPasswordRedirect,
      data: {'username': username},
    );
    return SignUpOutcome(
      userId: response.user?.id,
      hasSession: response.session != null,
    );
  }

  @override
  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    await _client.auth.signInWithPassword(email: email, password: password);
  }

  @override
  Future<void> signInWithIdToken(String idToken) async {
    await _client.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
    );
  }

  @override
  Future<void> signOut() async {
    await _client.auth.signOut();
  }

  @override
  Future<void> sendPasswordResetEmail(String email, String redirectTo) async {
    await _client.auth.resetPasswordForEmail(email, redirectTo: redirectTo);
  }

  @override
  Future<void> resendSignupEmail(String email) async {
    await _client.auth.resend(email: email, type: OtpType.signup);
  }

  @override
  Future<void> updatePassword(String newPassword) async {
    await _client.auth.updateUser(UserAttributes(password: newPassword));
  }

  /// Case-insensitive exact username match. `_` and `%` are LIKE
  /// wildcards, so they are escaped before the query.
  @override
  Future<bool> isUsernameTaken(String username) async {
    final escaped = username
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    final row = await _client
        .from('profiles')
        .select('id')
        .ilike('username', escaped)
        .maybeSingle();
    return row != null;
  }

  @override
  Future<void> upsertProfile({
    required String userId,
    required String username,
    required String email,
  }) async {
    await _client.from('profiles').upsert({
      'id': userId,
      'username': username,
      'email': email,
    });
  }

  @override
  Future<Map<String, dynamic>?> fetchProfile(String userId) async {
    final row = await _client
        .from('profiles')
        .select()
        .eq('id', userId)
        .maybeSingle();
    if (row == null) return null;
    return Map<String, dynamic>.from(row as Map);
  }

  @override
  Future<void> updateProfileUsername(String userId, String username) async {
    await _client
        .from('profiles')
        .update({'username': username})
        .eq('id', userId);
  }

  @override
  Future<DeleteAccountOutcome> deleteAccount() async {
    try {
      final response = await _client.functions.invoke('delete-account');
      if (response.status == 200 || response.status == 204) {
        return DeleteAccountOutcome.deleted;
      }
      return DeleteAccountOutcome.unavailable;
    } on FunctionException catch (e) {
      // 404 = the Edge Function is not deployed yet — an honest
      // "unavailable", not a crash and not a false success.
      if (e.status == 404) return DeleteAccountOutcome.unavailable;
      rethrow;
    }
  }
}

/// Google Sign-In as a small port so tests can fake it.
/// Returns the Google ID token, or null when the user cancels.
abstract class GoogleSignInPort {
  Future<String?> authenticateIdToken();
  Future<void> signOut();
}

class RealGoogleSignInPort implements GoogleSignInPort {
  bool _initialized = false;

  @override
  Future<String?> authenticateIdToken() async {
    try {
      if (!_initialized) {
        await GoogleSignIn.instance.initialize();
        _initialized = true;
      }
      final account = await GoogleSignIn.instance.authenticate();
      return account.authentication.idToken;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      rethrow;
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {
      // Never initialised / already signed out — nothing to do.
    }
  }
}

class AuthService {
  AuthService({AuthBackend? backend, GoogleSignInPort? googleSignIn})
    : _backend = backend ?? _defaultBackend(),
      _google = googleSignIn ?? RealGoogleSignInPort();

  /// Production entry point: real Supabase backend when initialised,
  /// unconfigured backend otherwise (offline build).
  factory AuthService.supabase() =>
      AuthService(backend: SupabaseAuthBackend.fromInstance());

  static AuthBackend _defaultBackend() {
    if (!SupabaseConfig.isConfigured) {
      return const UnconfiguredAuthBackend();
    }
    try {
      return SupabaseAuthBackend.fromInstance();
    } catch (_) {
      return const UnconfiguredAuthBackend();
    }
  }

  final AuthBackend _backend;
  final GoogleSignInPort _google;

  static const String notConfiguredMessage =
      'Server abhi connect nahi hua — login baad mein hoga. '
      'App offline chal rahi hai.';

  static const String deleteUnavailableMessage =
      'Account delete karne wala server feature abhi tayyar nahi hai. '
      'Support se rabta karein — WhatsApp +92 342 7717288.';

  bool get isConfigured => _backend.isConfigured;
  bool get isSignedIn => _backend.isSignedIn;
  String? get currentUserId => _backend.currentUserId;
  String? get currentUserEmail => _backend.currentUserEmail;

  // ---------- Pure validators (no network) ----------

  /// Null when valid, otherwise a plain-language error.
  /// Rules: 3-20 chars, letters/digits/underscore/dot only, must not
  /// start with a digit.
  static String? validateUsername(String username) {
    final value = username.trim();
    if (value.length < 3) {
      return 'Username kam az kam 3 harf ka ho.';
    }
    if (value.length > 20) {
      return 'Username zyada se zyada 20 harf ka ho.';
    }
    if (RegExp(r'^[0-9]').hasMatch(value)) {
      return 'Username digit se shuru nahi ho sakta.';
    }
    if (!RegExp(r'^[A-Za-z0-9_.]+$').hasMatch(value)) {
      return 'Sirf harf, digit, underscore (_) aur dot (.) use karein.';
    }
    return null;
  }

  /// Null when valid, otherwise a plain-language error.
  /// Rules: min 8 chars, at least one letter and one digit.
  static String? validatePassword(String password) {
    if (password.length < 8) {
      return 'Password kam az kam 8 harf ka ho.';
    }
    if (!RegExp(r'[A-Za-z]').hasMatch(password)) {
      return 'Password mein kam az kam ek harf ho.';
    }
    if (!RegExp(r'[0-9]').hasMatch(password)) {
      return 'Password mein kam az kam ek digit ho.';
    }
    return null;
  }

  static bool isValidEmail(String email) {
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email.trim());
  }

  /// Turns a raw auth error into plain Roman Urdu for the UI.
  static String friendlyError(Object error) {
    final raw = error.toString();
    debugPrint('AuthService error: $raw');
    if (raw.contains('Invalid login credentials')) {
      return 'Email ya password ghalat hai.';
    }
    if (raw.contains('User already registered')) {
      return 'Is email se account pehle se bana hua hai — login karein.';
    }
    if (raw.contains('Email not confirmed')) {
      return 'Email abhi verify nahi hui — inbox mein bheja gaya link kholein.';
    }
    if (raw.contains('Password should be at least')) {
      return 'Password kam az kam 8 harf ka ho.';
    }
    if (raw.contains('Failed host lookup') ||
        raw.contains('SocketException') ||
        raw.contains('Network is unreachable') ||
        raw.contains('Connection refused')) {
      return 'Internet nahi mil raha — connection check karke dobara koshish karein.';
    }
    if (raw.contains('404') || raw.contains('not found')) {
      return 'Server par ye feature abhi maujood nahi hai.';
    }
    if (raw.contains('too many requests') ||
        raw.contains('rate limit') ||
        raw.contains('429')) {
      return 'Bohat zyada koshishein ho gayin — thori der baad dobara koshish karein.';
    }
    return 'Kuch ghalat ho gaya — dobara koshish karein.';
  }

  // ---------- Flows ----------

  Future<AuthResult> signUpWithEmail({
    required String email,
    required String password,
    required String username,
  }) async {
    final usernameError = validateUsername(username);
    if (usernameError != null) return AuthResult.error(usernameError);
    if (!isValidEmail(email)) {
      return const AuthResult.error('Sahi email likhein.');
    }
    final passwordError = validatePassword(password);
    if (passwordError != null) return AuthResult.error(passwordError);
    if (!isConfigured) return const AuthResult.error(notConfiguredMessage);
    try {
      if (await _backend.isUsernameTaken(username.trim())) {
        return const AuthResult.error(
          'Ye username pehle se liya gaya hai — koi aur chunein.',
        );
      }
      final outcome = await _backend.signUp(
        email: email.trim(),
        password: password,
        username: username.trim(),
      );
      final userId = outcome.userId;
      if (userId != null) {
        // Best-effort: with email confirmation ON there is no session
        // yet, so this upsert may fail — the DB trigger creates the
        // profiles row and the username is set on first login.
        try {
          await _backend.upsertProfile(
            userId: userId,
            username: username.trim(),
            email: email.trim(),
          );
        } catch (_) {}
      }
      if (outcome.hasSession) return const AuthResult.success();
      return const AuthResult.needsEmailVerification();
    } catch (e) {
      return AuthResult.error(friendlyError(e));
    }
  }

  Future<AuthResult> signInWithEmail({
    required String email,
    required String password,
  }) async {
    if (!isValidEmail(email)) {
      return const AuthResult.error('Sahi email likhein.');
    }
    if (password.isEmpty) {
      return const AuthResult.error('Password likhein.');
    }
    if (!isConfigured) return const AuthResult.error(notConfiguredMessage);
    try {
      await _backend.signIn(email: email.trim(), password: password);
      return const AuthResult.success();
    } catch (e) {
      return AuthResult.error(friendlyError(e));
    }
  }

  Future<AuthResult> signInWithGoogle() async {
    if (!isConfigured) return const AuthResult.error(notConfiguredMessage);
    try {
      final idToken = await _google.authenticateIdToken();
      if (idToken == null) return const AuthResult.cancelled();
      await _backend.signInWithIdToken(idToken);
      await _ensureProfileAfterGoogleSignIn();
      return const AuthResult.success();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        return const AuthResult.cancelled();
      }
      return AuthResult.error(friendlyError(e));
    } catch (e) {
      return AuthResult.error(friendlyError(e));
    }
  }

  /// Google sign-in has no username step: make sure a profiles row
  /// exists, deriving a username from the email when there is none.
  /// Best-effort — a failure here never blocks the login itself.
  Future<void> _ensureProfileAfterGoogleSignIn() async {
    try {
      final userId = _backend.currentUserId;
      final email = _backend.currentUserEmail;
      if (userId == null || email == null) return;
      final existing = await _backend.fetchProfile(userId);
      if (existing != null &&
          (existing['username'] as Object?)?.toString().isNotEmpty == true) {
        return;
      }
      var candidate = _usernameFromEmail(email);
      for (var attempt = 0; attempt < 5; attempt++) {
        final taken = await _backend.isUsernameTaken(candidate);
        if (!taken) break;
        candidate = '${_usernameFromEmail(email)}${attempt + 2}';
      }
      await _backend.upsertProfile(
        userId: userId,
        username: candidate,
        email: email,
      );
    } catch (_) {}
  }

  /// Derives a display username from an email address, e.g.
  /// `ali.ahmed@example.com` -> `ali.ahmed`. Never empty.
  static String _usernameFromEmail(String email) {
    final local = email.split('@').first;
    var clean = local.replaceAll(RegExp(r'[^A-Za-z0-9_.]'), '');
    clean = clean.replaceFirst(RegExp(r'^[0-9]+'), '');
    if (clean.length < 3) clean = 'officer';
    if (clean.length > 20) clean = clean.substring(0, 20);
    return clean;
  }

  Future<void> signOut() async {
    try {
      await _backend.signOut();
    } catch (_) {}
    try {
      await _google.signOut();
    } catch (_) {}
  }

  Future<AuthResult> sendPasswordResetEmail(String email) async {
    if (!isValidEmail(email)) {
      return const AuthResult.error('Sahi email likhein.');
    }
    if (!isConfigured) return const AuthResult.error(notConfiguredMessage);
    try {
      await _backend.sendPasswordResetEmail(
        email.trim(),
        SupabaseAuthBackend.resetPasswordRedirect,
      );
      return const AuthResult.success();
    } catch (e) {
      return AuthResult.error(friendlyError(e));
    }
  }

  Future<AuthResult> resendVerificationEmail(String email) async {
    if (!isValidEmail(email)) {
      return const AuthResult.error('Sahi email likhein.');
    }
    if (!isConfigured) return const AuthResult.error(notConfiguredMessage);
    try {
      await _backend.resendSignupEmail(email.trim());
      return const AuthResult.success();
    } catch (e) {
      return AuthResult.error(friendlyError(e));
    }
  }

  Future<AuthResult> updatePassword(String newPassword) async {
    final passwordError = validatePassword(newPassword);
    if (passwordError != null) return AuthResult.error(passwordError);
    if (!isConfigured) return const AuthResult.error(notConfiguredMessage);
    try {
      await _backend.updatePassword(newPassword);
      return const AuthResult.success();
    } catch (e) {
      return AuthResult.error(friendlyError(e));
    }
  }

  /// Re-authenticates with the current password (used to verify the
  /// "current password" field before a password change — Supabase
  /// updateUser does not check the old password itself).
  Future<bool> reauthenticate(String currentPassword) async {
    final email = _backend.currentUserEmail;
    if (email == null || !isConfigured) return false;
    try {
      await _backend.signIn(email: email, password: currentPassword);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<AuthResult> updateUsername(String newUsername) async {
    final usernameError = validateUsername(newUsername);
    if (usernameError != null) return AuthResult.error(usernameError);
    final userId = _backend.currentUserId;
    if (userId == null) {
      return const AuthResult.error('Pehle login karein.');
    }
    if (!isConfigured) return const AuthResult.error(notConfiguredMessage);
    try {
      if (await _backend.isUsernameTaken(newUsername.trim())) {
        return const AuthResult.error(
          'Ye username pehle se liya gaya hai — koi aur chunein.',
        );
      }
      await _backend.updateProfileUsername(userId, newUsername.trim());
      return const AuthResult.success();
    } catch (e) {
      return AuthResult.error(friendlyError(e));
    }
  }

  /// Null when the username is invalid or the check could not run
  /// (offline) — the UI then shows no availability hint.
  Future<bool?> checkUsernameAvailable(String username) async {
    if (validateUsername(username) != null) return null;
    if (!isConfigured) return null;
    try {
      return !await _backend.isUsernameTaken(username.trim());
    } catch (_) {
      return null;
    }
  }

  /// The signed-in user's profile, or null when signed out / the
  /// row could not be read. When the row is missing (trigger lag),
  /// a profile derived from the auth user is returned so the UI
  /// still has something honest to show.
  Future<UserProfile?> fetchProfile() async {
    final userId = _backend.currentUserId;
    if (userId == null) return null;
    try {
      final row = await _backend.fetchProfile(userId);
      if (row != null) return UserProfile.fromMap(row);
      final email = _backend.currentUserEmail ?? '';
      return UserProfile(
        id: userId,
        username: _usernameFromEmail(email),
        email: email,
      );
    } catch (_) {
      return null;
    }
  }

  Future<AuthResult> deleteAccount() async {
    if (!isConfigured) {
      return const AuthResult.unavailable(deleteUnavailableMessage);
    }
    try {
      final outcome = await _backend.deleteAccount();
      if (outcome == DeleteAccountOutcome.unavailable) {
        return const AuthResult.unavailable(deleteUnavailableMessage);
      }
      await signOut();
      return const AuthResult.success();
    } catch (e) {
      return AuthResult.error(friendlyError(e));
    }
  }
}
