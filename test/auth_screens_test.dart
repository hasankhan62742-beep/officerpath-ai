import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/screens/auth_screen.dart';
import 'package:officerpath_ai/screens/forgot_password_screen.dart';
import 'package:officerpath_ai/screens/profile_screen.dart';
import 'package:officerpath_ai/services/auth_service.dart';

/// Small fake backend for the widget tests — no network, no client.
class FakeAuthBackend implements AuthBackend {
  Set<String> takenUsernames = {'taken.user'};
  Map<String, dynamic>? profileRow = {
    'id': 'user-1',
    'username': 'ali.ahmed',
    'email': 'ali@example.com',
    'plan': 'premium',
    'premium_until': '2026-12-19T00:00:00.000Z',
    'is_admin': false,
    'created_at': '2026-11-01T00:00:00.000Z',
  };
  String? resetEmailSentTo;

  @override
  bool get isConfigured => true;

  @override
  String? get currentUserId => 'user-1';

  @override
  String? get currentUserEmail => 'ali@example.com';

  @override
  bool get isSignedIn => true;

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String username,
  }) async => const SignUpOutcome(userId: 'user-1', hasSession: false);

  @override
  Future<void> signIn({
    required String email,
    required String password,
  }) async {}

  @override
  Future<void> signInWithIdToken(String idToken) async {}

  @override
  Future<void> signOut() async {}

  @override
  Future<void> sendPasswordResetEmail(String email, String redirectTo) async {
    resetEmailSentTo = email;
  }

  @override
  Future<void> resendSignupEmail(String email) async {}

  @override
  Future<void> updatePassword(String newPassword) async {}

  @override
  Future<bool> isUsernameTaken(String username) async {
    return takenUsernames.contains(username.toLowerCase());
  }

  @override
  Future<void> upsertProfile({
    required String userId,
    required String username,
    required String email,
  }) async {}

  @override
  Future<Map<String, dynamic>?> fetchProfile(String userId) async {
    return profileRow;
  }

  @override
  Future<void> updateProfileUsername(
    String userId,
    String username,
  ) async {}

  @override
  Future<DeleteAccountOutcome> deleteAccount() async =>
      DeleteAccountOutcome.deleted;
}

class FakeGoogleSignIn implements GoogleSignInPort {
  @override
  Future<String?> authenticateIdToken() async => 'google-id-token';

  @override
  Future<void> signOut() async {}
}

AuthService fakeService({FakeAuthBackend? backend}) {
  final fake = backend ?? FakeAuthBackend();
  return AuthService(backend: fake, googleSignIn: FakeGoogleSignIn());
}

void main() {
  group('AuthScreen', () {
    testWidgets('shows login and signup tabs', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: AuthScreen(authService: fakeService())),
      );
      await tester.pumpAndSettle();
      expect(find.text('Login'), findsWidgets);
      expect(find.text('Signup'), findsWidgets);
      expect(find.text('Forgot password?'), findsOneWidget);
      expect(find.text('Google se login karein'), findsOneWidget);
    });

    testWidgets('signup tab shows the username hint', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: AuthScreen(authService: fakeService())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Signup'));
      await tester.pumpAndSettle();
      expect(find.text('Username'), findsOneWidget);
      expect(find.text('Account banayein'), findsOneWidget);
      // Type a free username and wait out the 500 ms debounce.
      await tester.enterText(
        find.widgetWithText(TextField, 'Username').first,
        'free.user',
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.text('Username available hai.'), findsOneWidget);
    });

    testWidgets('signup shows the verification state', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: AuthScreen(authService: fakeService())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Signup'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Username').first,
        'free.user',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Email').first,
        'new@example.com',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Password').first,
        'pass1234',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Confirm password').first,
        'pass1234',
      );
      await tester.tap(find.text('Account banayein'));
      await tester.pumpAndSettle();
      expect(find.text('Verification email bheji gayi hai'), findsOneWidget);
      expect(find.text('Resend email'), findsOneWidget);
    });
  });

  group('ForgotPasswordScreen', () {
    testWidgets('shows the email field and sends the reset', (tester) async {
      final backend = FakeAuthBackend();
      await tester.pumpWidget(
        MaterialApp(
          home: ForgotPasswordScreen(
            authService: fakeService(backend: backend),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Email'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'ali@example.com');
      await tester.tap(find.text('Reset link bhejein'));
      await tester.pumpAndSettle();
      expect(backend.resetEmailSentTo, 'ali@example.com');
      expect(
        find.text('Reset link email kar diya gaya hai'),
        findsOneWidget,
      );
    });
  });

  group('ProfileScreen', () {
    testWidgets('renders username, email and plan', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: ProfileScreen(authService: fakeService())),
      );
      await tester.pumpAndSettle();
      expect(find.text('ali.ahmed'), findsWidgets);
      expect(find.text('ali@example.com'), findsOneWidget);
      expect(find.text('Plan: Premium'), findsOneWidget);
      expect(find.text('Account settings'), findsOneWidget);
      expect(find.text('Logout'), findsOneWidget);
    });
  });
}
