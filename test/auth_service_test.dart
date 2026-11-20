import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/auth_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Fake backend for [AuthService] tests — no network, no real client.
class FakeAuthBackend implements AuthBackend {
  bool configured = true;
  bool signedIn = false;
  String? userId = 'user-1';
  String? userEmail = 'ali@example.com';
  Set<String> takenUsernames = {'taken.user'};
  bool signUpHasSession = true;
  Object? signInError;
  Object? signUpError;
  Map<String, dynamic>? profileRow;
  DeleteAccountOutcome deleteOutcome = DeleteAccountOutcome.deleted;

  String? upsertedUsername;
  String? updatedUsername;
  String? resetEmailSentTo;
  String? idTokenReceived;
  String? passwordUpdatedTo;
  String? resendEmailTo;

  @override
  bool get isConfigured => configured;

  @override
  String? get currentUserId => signedIn ? userId : userId;

  @override
  String? get currentUserEmail => userEmail;

  @override
  bool get isSignedIn => signedIn;

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String username,
  }) async {
    if (signUpError != null) throw signUpError!;
    signedIn = signUpHasSession;
    return SignUpOutcome(userId: userId, hasSession: signUpHasSession);
  }

  @override
  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    if (signInError != null) throw signInError!;
    signedIn = true;
  }

  @override
  Future<void> signInWithIdToken(String idToken) async {
    idTokenReceived = idToken;
    signedIn = true;
  }

  @override
  Future<void> signOut() async {
    signedIn = false;
  }

  @override
  Future<void> sendPasswordResetEmail(String email, String redirectTo) async {
    resetEmailSentTo = email;
  }

  @override
  Future<void> resendSignupEmail(String email) async {
    resendEmailTo = email;
  }

  @override
  Future<void> updatePassword(String newPassword) async {
    passwordUpdatedTo = newPassword;
  }

  @override
  Future<bool> isUsernameTaken(String username) async {
    return takenUsernames.contains(username.toLowerCase());
  }

  @override
  Future<void> upsertProfile({
    required String userId,
    required String username,
    required String email,
  }) async {
    upsertedUsername = username;
  }

  @override
  Future<Map<String, dynamic>?> fetchProfile(String userId) async {
    return profileRow;
  }

  @override
  Future<void> updateProfileUsername(
    String userId,
    String username,
  ) async {
    updatedUsername = username;
  }

  @override
  Future<DeleteAccountOutcome> deleteAccount() async => deleteOutcome;
}

class FakeGoogleSignIn implements GoogleSignInPort {
  String? idToken = 'google-id-token';
  bool signOutCalled = false;

  @override
  Future<String?> authenticateIdToken() async => idToken;

  @override
  Future<void> signOut() async {
    signOutCalled = true;
  }
}

void main() {
  group('validateUsername', () {
    test('valid usernames pass', () {
      expect(AuthService.validateUsername('ali'), isNull);
      expect(AuthService.validateUsername('ali.ahmed_1'), isNull);
      expect(AuthService.validateUsername('Ayesha123'), isNull);
    });

    test('too short', () {
      expect(AuthService.validateUsername('ab'), isNotNull);
      expect(AuthService.validateUsername(''), isNotNull);
    });

    test('too long', () {
      expect(AuthService.validateUsername('a' * 21), isNotNull);
      expect(AuthService.validateUsername('a' * 20), isNull);
    });

    test('bad characters', () {
      expect(AuthService.validateUsername('ali ahmed'), isNotNull);
      expect(AuthService.validateUsername('ali@ahmed'), isNotNull);
      expect(AuthService.validateUsername('ali-ahmed'), isNotNull);
    });

    test('must not start with a digit', () {
      expect(AuthService.validateUsername('1ali'), isNotNull);
      expect(AuthService.validateUsername('9_ali'), isNotNull);
    });
  });

  group('validatePassword', () {
    test('valid password passes', () {
      expect(AuthService.validatePassword('pass1234'), isNull);
    });

    test('too short', () {
      expect(AuthService.validatePassword('ab12'), isNotNull);
    });

    test('needs a letter', () {
      expect(AuthService.validatePassword('12345678'), isNotNull);
    });

    test('needs a digit', () {
      expect(AuthService.validatePassword('password'), isNotNull);
    });
  });

  group('isValidEmail', () {
    test('accepts normal emails', () {
      expect(AuthService.isValidEmail('ali@example.com'), isTrue);
      expect(AuthService.isValidEmail('a.b+1@x.co'), isTrue);
    });

    test('rejects bad emails', () {
      expect(AuthService.isValidEmail('not-an-email'), isFalse);
      expect(AuthService.isValidEmail('ali@'), isFalse);
      expect(AuthService.isValidEmail('@example.com'), isFalse);
      expect(AuthService.isValidEmail('ali @example.com'), isFalse);
    });
  });

  group('friendlyError', () {
    test('maps invalid credentials', () {
      expect(
        AuthService.friendlyError(
          AuthException('Invalid login credentials'),
        ),
        'Email ya password ghalat hai.',
      );
    });

    test('maps already registered', () {
      expect(
        AuthService.friendlyError(
          AuthException('User already registered'),
        ),
        contains('pehle se bana hua hai'),
      );
    });
  });

  group('signUpWithEmail (mocked backend)', () {
    test('taken username is rejected before any network call', () async {
      final backend = FakeAuthBackend();
      final service = AuthService(backend: backend);
      final result = await service.signUpWithEmail(
        email: 'new@example.com',
        password: 'pass1234',
        username: 'taken.user',
      );
      expect(result.status, AuthStatus.error);
      expect(result.message, contains('pehle se liya gaya hai'));
    });

    test('bad username never reaches the backend', () async {
      final backend = FakeAuthBackend();
      final service = AuthService(backend: backend);
      final result = await service.signUpWithEmail(
        email: 'new@example.com',
        password: 'pass1234',
        username: 'ab',
      );
      expect(result.status, AuthStatus.error);
    });

    test('session present means success', () async {
      final backend = FakeAuthBackend()..signUpHasSession = true;
      final service = AuthService(backend: backend);
      final result = await service.signUpWithEmail(
        email: 'new@example.com',
        password: 'pass1234',
        username: 'new.user',
      );
      expect(result.status, AuthStatus.success);
      expect(backend.upsertedUsername, 'new.user');
    });

    test('no session means email verification is needed', () async {
      final backend = FakeAuthBackend()..signUpHasSession = false;
      final service = AuthService(backend: backend);
      final result = await service.signUpWithEmail(
        email: 'new@example.com',
        password: 'pass1234',
        username: 'new.user',
      );
      expect(result.status, AuthStatus.needsEmailVerification);
    });

    test('unconfigured backend gives the offline message', () async {
      final backend = FakeAuthBackend()..configured = false;
      final service = AuthService(backend: backend);
      final result = await service.signUpWithEmail(
        email: 'new@example.com',
        password: 'pass1234',
        username: 'new.user',
      );
      expect(result.status, AuthStatus.error);
      expect(result.message, contains('Server abhi connect nahi hua'));
    });
  });

  group('signInWithEmail (mocked backend)', () {
    test('wrong credentials map to plain language', () async {
      final backend = FakeAuthBackend()
        ..signInError = AuthException('Invalid login credentials');
      final service = AuthService(backend: backend);
      final result = await service.signInWithEmail(
        email: 'ali@example.com',
        password: 'wrongpass1',
      );
      expect(result.status, AuthStatus.error);
      expect(result.message, 'Email ya password ghalat hai.');
    });

    test('valid sign-in succeeds', () async {
      final backend = FakeAuthBackend();
      final service = AuthService(backend: backend);
      final result = await service.signInWithEmail(
        email: 'ali@example.com',
        password: 'pass1234',
      );
      expect(result.status, AuthStatus.success);
      expect(service.isSignedIn, isTrue);
    });
  });

  group('signInWithGoogle (mocked)', () {
    test('user cancelling returns cancelled, not an error', () async {
      final backend = FakeAuthBackend();
      final google = FakeGoogleSignIn()..idToken = null;
      final service = AuthService(backend: backend, googleSignIn: google);
      final result = await service.signInWithGoogle();
      expect(result.status, AuthStatus.cancelled);
      expect(backend.idTokenReceived, isNull);
    });

    test('id token is exchanged and a profile row is ensured', () async {
      final backend = FakeAuthBackend()
        ..profileRow = null
        ..userEmail = 'ali.ahmed@example.com';
      final google = FakeGoogleSignIn();
      final service = AuthService(backend: backend, googleSignIn: google);
      final result = await service.signInWithGoogle();
      expect(result.status, AuthStatus.success);
      expect(backend.idTokenReceived, 'google-id-token');
      expect(backend.upsertedUsername, 'ali.ahmed');
    });
  });

  group('password reset (mocked backend)', () {
    test('invalid email is rejected client-side', () async {
      final backend = FakeAuthBackend();
      final service = AuthService(backend: backend);
      final result = await service.sendPasswordResetEmail('bad-email');
      expect(result.status, AuthStatus.error);
      expect(backend.resetEmailSentTo, isNull);
    });

    test('valid email sends the reset', () async {
      final backend = FakeAuthBackend();
      final service = AuthService(backend: backend);
      final result = await service.sendPasswordResetEmail('ali@example.com');
      expect(result.status, AuthStatus.success);
      expect(backend.resetEmailSentTo, 'ali@example.com');
    });

    test('weak new password is rejected client-side', () async {
      final backend = FakeAuthBackend();
      final service = AuthService(backend: backend);
      final result = await service.updatePassword('short');
      expect(result.status, AuthStatus.error);
      expect(backend.passwordUpdatedTo, isNull);
    });
  });

  group('updateUsername (mocked backend)', () {
    test('taken username is rejected', () async {
      final backend = FakeAuthBackend();
      final service = AuthService(backend: backend);
      final result = await service.updateUsername('taken.user');
      expect(result.status, AuthStatus.error);
      expect(backend.updatedUsername, isNull);
    });

    test('free username updates the profile row', () async {
      final backend = FakeAuthBackend();
      final service = AuthService(backend: backend);
      final result = await service.updateUsername('free.user');
      expect(result.status, AuthStatus.success);
      expect(backend.updatedUsername, 'free.user');
    });
  });

  group('deleteAccount (mocked backend)', () {
    test('missing edge function returns unavailable, honestly', () async {
      final backend = FakeAuthBackend()
        ..deleteOutcome = DeleteAccountOutcome.unavailable;
      final service = AuthService(backend: backend);
      final result = await service.deleteAccount();
      expect(result.status, AuthStatus.unavailable);
      expect(result.message, contains('Support'));
    });

    test('deployed function deletes and signs out', () async {
      final backend = FakeAuthBackend()
        ..signedIn = true
        ..deleteOutcome = DeleteAccountOutcome.deleted;
      final service = AuthService(backend: backend);
      final result = await service.deleteAccount();
      expect(result.status, AuthStatus.success);
      expect(backend.signedIn, isFalse);
    });
  });

  group('checkUsernameAvailable', () {
    test('free username is available, taken is not', () async {
      final backend = FakeAuthBackend();
      final service = AuthService(backend: backend);
      expect(await service.checkUsernameAvailable('free.user'), isTrue);
      expect(await service.checkUsernameAvailable('taken.user'), isFalse);
    });

    test('invalid or offline check returns null', () async {
      final backend = FakeAuthBackend()..configured = false;
      final service = AuthService(backend: backend);
      expect(await service.checkUsernameAvailable('free.user'), isNull);
      expect(await service.checkUsernameAvailable('ab'), isNull);
    });
  });

  group('fetchProfile', () {
    test('maps a profiles row to UserProfile', () async {
      final backend = FakeAuthBackend()
        ..profileRow = {
          'id': 'user-1',
          'username': 'ali.ahmed',
          'email': 'ali@example.com',
          'plan': 'premium',
          'premium_until': '2026-12-19T00:00:00.000Z',
          'is_admin': false,
          'created_at': '2026-11-01T00:00:00.000Z',
        };
      final service = AuthService(backend: backend);
      final profile = await service.fetchProfile();
      expect(profile?.username, 'ali.ahmed');
      expect(profile?.planLabel, 'Premium');
      expect(profile?.premiumUntil?.year, 2026);
    });
  });
}
