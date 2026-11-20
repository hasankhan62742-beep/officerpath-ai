import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/deep_link.dart';

void main() {
  group('parseResetPasswordUri', () {
    test('PKCE code in the query string', () {
      final link = parseResetPasswordUri(
        Uri.parse('officerpath://reset-password?code=abc123'),
      );
      expect(link.isResetLink, isTrue);
      expect(link.code, 'abc123');
      expect(link.hasRecoveryToken, isTrue);
    });

    test('PKCE code in the fragment is also accepted', () {
      final link = parseResetPasswordUri(
        Uri.parse('officerpath://reset-password#code=abc123&type=recovery'),
      );
      expect(link.isResetLink, isTrue);
      expect(link.code, 'abc123');
      expect(link.type, 'recovery');
      expect(link.hasRecoveryToken, isTrue);
    });

    test('implicit-flow tokens in the fragment are REJECTED (audit L7)', () {
      final link = parseResetPasswordUri(
        Uri.parse(
          'officerpath://reset-password'
          '#access_token=AT123&refresh_token=RT456&type=recovery',
        ),
      );
      expect(link.isResetLink, isTrue);
      // No PKCE code, so no recovery session may be established from
      // this link — bare URL tokens must never reach setSession().
      expect(link.code, isNull);
      expect(link.hasRecoveryToken, isFalse);
    });

    test('tokens as query parameters are REJECTED too', () {
      final link = parseResetPasswordUri(
        Uri.parse(
          'officerpath://reset-password'
          '?access_token=AT&refresh_token=RT&type=recovery',
        ),
      );
      expect(link.isResetLink, isTrue);
      expect(link.code, isNull);
      expect(link.hasRecoveryToken, isFalse);
    });

    test('tokens alongside a code do not override the code', () {
      final link = parseResetPasswordUri(
        Uri.parse(
          'officerpath://reset-password?code=abc123'
          '#access_token=AT&refresh_token=RT',
        ),
      );
      expect(link.code, 'abc123');
      expect(link.hasRecoveryToken, isTrue);
    });

    test('bare reset link has no token', () {
      final link = parseResetPasswordUri(
        Uri.parse('officerpath://reset-password'),
      );
      expect(link.isResetLink, isTrue);
      expect(link.hasRecoveryToken, isFalse);
      expect(link.code, isNull);
    });

    test('other officerpath hosts are not reset links', () {
      final link = parseResetPasswordUri(Uri.parse('officerpath://home'));
      expect(link.isResetLink, isFalse);
      expect(link.hasRecoveryToken, isFalse);
    });

    test('https links are not reset links', () {
      final link = parseResetPasswordUri(
        Uri.parse('https://example.com/reset-password?code=abc'),
      );
      expect(link.isResetLink, isFalse);
      expect(link.code, isNull);
    });
  });
}
