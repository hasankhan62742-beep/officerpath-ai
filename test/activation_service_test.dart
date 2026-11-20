import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/activation_service.dart';

void main() {
  group('isValidCodeFormat', () {
    test('accepts a well-formed code for each plan digit', () {
      expect(ActivationService.isValidCodeFormat('OP1-ABCDEF'), isTrue);
      expect(ActivationService.isValidCodeFormat('OP2-K7Q9XA'), isTrue);
      expect(ActivationService.isValidCodeFormat('OP3-6J79XC'), isTrue);
    });

    test('accepts lowercase and surrounding spaces (normalised)', () {
      expect(ActivationService.isValidCodeFormat('op1-abcdef'), isTrue);
      expect(ActivationService.isValidCodeFormat('  OP2-K7Q9XA  '), isTrue);
    });

    test('rejects wrong prefix, wrong digit, lowercase-only check', () {
      expect(ActivationService.isValidCodeFormat('XP1-ABCDEF'), isFalse);
      expect(ActivationService.isValidCodeFormat('OP9-ABCDEF'), isFalse);
      expect(ActivationService.isValidCodeFormat('OP0-ABCDEF'), isFalse);
      expect(ActivationService.isValidCodeFormat('OP4-ABCDEF'), isFalse);
    });

    test('rejects ambiguous chars 0/O/1/I/L in the suffix', () {
      expect(ActivationService.isValidCodeFormat('OP1-ABCDE0'), isFalse);
      expect(ActivationService.isValidCodeFormat('OP1-ABCDEO'), isFalse);
      expect(ActivationService.isValidCodeFormat('OP1-ABCDE1'), isFalse);
      expect(ActivationService.isValidCodeFormat('OP1-ABCDEI'), isFalse);
      expect(ActivationService.isValidCodeFormat('OP1-ABCDEL'), isFalse);
    });

    test('rejects short, long, missing-dash and empty codes', () {
      expect(ActivationService.isValidCodeFormat('OP1-ABCDE'), isFalse);
      expect(ActivationService.isValidCodeFormat('OP1-ABCDEFG'), isFalse);
      expect(ActivationService.isValidCodeFormat('OP1ABCDEF'), isFalse);
      expect(ActivationService.isValidCodeFormat('OP1-'), isFalse);
      expect(ActivationService.isValidCodeFormat(''), isFalse);
      expect(ActivationService.isValidCodeFormat('hello'), isFalse);
    });
  });

  group('planMonthsForCode', () {
    test('digit maps to months: 1 -> 1, 2 -> 2, 3 -> 12', () {
      expect(ActivationService.planMonthsForCode('OP1-ABCDEF'), 1);
      expect(ActivationService.planMonthsForCode('OP2-ABCDEF'), 2);
      expect(ActivationService.planMonthsForCode('OP3-ABCDEF'), 12);
    });

    test('returns null for malformed codes', () {
      expect(ActivationService.planMonthsForCode('OP9-ABCDEF'), isNull);
      expect(ActivationService.planMonthsForCode('OP1-ABCDE'), isNull);
      expect(ActivationService.planMonthsForCode(''), isNull);
    });
  });

  group('parseRedeemResponse', () {
    test('success carries the premium_until date', () {
      final result = ActivationService.parseRedeemResponse({
        'ok': true,
        'plan': 'premium',
        'premium_until': '2026-12-19T14:00:00.000Z',
      });
      expect(result.success, isTrue);
      expect(result.message, isNull);
      expect(
        result.premiumUntil,
        DateTime.parse('2026-12-19T14:00:00.000Z'),
      );
    });

    test('each server error maps to its Roman Urdu message', () {
      final cases = {
        'code_not_found': 'code nahi mila',
        'invalid_code': 'code nahi mila',
        'code_already_used': 'istemal ho chuka',
        'code_expired': 'muddat khatam',
        'code_not_yours': 'aap ka nahi',
        'unauthorized': 'login karein',
      };
      for (final entry in cases.entries) {
        final result = ActivationService.parseRedeemResponse(
          {'ok': false, 'error': entry.key},
        );
        expect(result.success, isFalse);
        expect(result.message, contains(entry.value));
      }
    });

    test('unknown error and garbage bodies fail safe, never crash', () {
      expect(
        ActivationService.parseRedeemResponse(
          {'ok': false, 'error': 'weird_new_error'},
        ).success,
        isFalse,
      );
      expect(
        ActivationService.parseRedeemResponse({'ok': false}).message,
        isNotNull,
      );
      expect(ActivationService.parseRedeemResponse(null).success, isFalse);
      expect(ActivationService.parseRedeemResponse('nope').success, isFalse);
      expect(ActivationService.parseRedeemResponse(42).success, isFalse);
    });
  });

  group('redeemCode with a fake Edge Function (no network)', () {
    test('well-formed code reaches the function and returns success', () async {
      final service = ActivationService(
        invoke: (name, body) async {
          expect(name, 'redeem-code');
          expect(body['code'], 'OP1-ABCDEF');
          return {
            'ok': true,
            'plan': 'premium',
            'premium_until': '2026-12-19T14:00:00.000Z',
          };
        },
      );
      final result = await service.redeemCode('op1-abcdef');
      expect(result.success, isTrue);
      expect(result.premiumUntil, isNotNull);
    });

    test('server error surfaces as a plain-language failure', () async {
      final service = ActivationService(
        invoke: (_, _) async => {'ok': false, 'error': 'code_already_used'},
      );
      final result = await service.redeemCode('OP2-K7Q9XA');
      expect(result.success, isFalse);
      expect(result.message, contains('istemal ho chuka'));
    });

    test('malformed code never calls the function', () async {
      var called = false;
      final service = ActivationService(
        invoke: (_, _) async {
          called = true;
          return {'ok': true};
        },
      );
      final result = await service.redeemCode('not-a-code');
      expect(result.success, isFalse);
      expect(called, isFalse);
    });
  });
}
