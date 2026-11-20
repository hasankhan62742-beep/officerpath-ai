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

    test('implicit-flow tokens in the fragment', () {
      final link = parseResetPasswordUri(
        Uri.parse(
          'officerpath://reset-password'
          '#access_token=AT123&refresh_token=RT456&type=recovery',
        ),
      );
      expect(link.isResetLink, isTrue);
      expect(link.accessToken, 'AT123');
      expect(link.refreshToken, 'RT456');
      expect(link.type, 'recovery');
      expect(link.hasRecoveryToken, isTrue);
    });

    test('tokens may also arrive as query parameters', () {
      final link = parseResetPasswordUri(
        Uri.parse(
          'officerpath://reset-password'
          '?access_token=AT&refresh_token=RT&type=recovery',
        ),
      );
      expect(link.isResetLink, isTrue);
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
