// Owner tool: mint OfficerPath AI Premium activation codes (v1, manual).
//
// Run from the project root with the SAME secret the release APK was
// built with:
//
//   dart tools/generate_activation_code.dart --plan premium_1year --secret "YOUR-STRONG-SECRET"
//
// Plans: premium_1month | premium_2months | premium_1year
// Output: e.g. OP3-K7Q9XA  (OP1 = 1 month, OP2 = 2 months, OP3 = 1 year)
//
// The app validates a code offline with the same algorithm — keep this
// file's checksum logic identical to
// lib/services/manual_activation.dart (change both together).
//
// SECURITY: never commit your real secret, never share this tool's output
// publicly. One code per paying student — track sold codes in a sheet.
// Codes are not single-use in v1 (no server); server validation is v2.
import 'dart:io';

const _alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

const Map<String, String> _planDigits = {
  'premium_1month': '1',
  'premium_2months': '2',
  'premium_1year': '3',
};

String checksumFor(String secret, String planId) {
  final input = '$secret|$planId';
  var hash = 0x811c9dc5;
  for (var i = 0; i < input.length; i++) {
    hash ^= input.codeUnitAt(i);
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  final buf = StringBuffer();
  var value = hash;
  for (var i = 0; i < 6; i++) {
    buf.write(_alphabet[value % _alphabet.length]);
    value ~/= _alphabet.length;
  }
  return buf.toString();
}

void main(List<String> args) {
  var plan = '';
  var secret = '';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--plan' && i + 1 < args.length) plan = args[++i];
    if (args[i] == '--secret' && i + 1 < args.length) secret = args[++i];
  }
  if (!_planDigits.containsKey(plan)) {
    stderr.writeln(
      'Usage: dart tools/generate_activation_code.dart '
      '--plan <premium_1month|premium_2months|premium_1year> '
      '--secret "YOUR-STRONG-SECRET"',
    );
    exit(2);
  }
  if (secret.isEmpty || secret == 'CHANGE_ME_IN_RELEASE_BUILD') {
    stderr.writeln(
      'ERROR: pass a real secret with --secret. Never mint codes with '
      'the default secret — anyone could forge them.',
    );
    exit(2);
  }
  final digit = _planDigits[plan]!;
  final code = 'OP$digit-${checksumFor(secret, plan)}';
  stdout.writeln('Plan: $plan');
  stdout.writeln('Activation code: $code');
  stdout.writeln('Send this code to the student on WhatsApp after payment.');
}
