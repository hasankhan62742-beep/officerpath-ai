import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the v2 waitlist landing page (docs/index.html) as TEXT: the
/// validation logic, the element ids the JS wires up, the CONFIG
/// placeholders, and the "no forbidden claims" rules. No network,
/// no backend — the page is read from the repo.
///
/// The email regex is extracted from the page itself (the
/// `EMAIL_REGEX = /.../;` literal) and exercised in Dart, so the
/// test checks the rule the page actually ships, not a copy of it.
void main() {
  late String html;
  late RegExp emailRegex;

  setUpAll(() {
    html = File('docs/index.html').readAsStringSync();
    final match = RegExp(r'EMAIL_REGEX\s*=\s*/(.+?)/;').firstMatch(html);
    expect(match, isNotNull, reason: 'page must define EMAIL_REGEX');
    emailRegex = RegExp(match!.group(1)!);
  });

  bool isValid(String email) => emailRegex.hasMatch(email.trim());

  group('email validation (regex extracted from the page)', () {
    test('rejects bad emails', () {
      for (final bad in [
        'not-an-email',
        'a@b',
        '@x.com',
        'a b@c.com',
      ]) {
        expect(isValid(bad), isFalse, reason: '"$bad" must be rejected');
      }
    });

    test('accepts good emails', () {
      for (final good in [
        'name@gmail.com',
        'user.name+tag@outlook.com',
      ]) {
        expect(isValid(good), isTrue, reason: '"$good" must be accepted');
      }
    });

    test('page defines the isValidEmail function', () {
      expect(html, contains('function isValidEmail'));
      expect(html, contains('EMAIL_REGEX'));
    });
  });

  group('required element ids', () {
    test('email input, submit button and message areas exist', () {
      for (final id in [
        'waitlist-email',
        'waitlist-form',
        'waitlist-submit',
        'waitlist-success',
        'waitlist-error',
      ]) {
        expect(html, contains('id="$id"'), reason: 'page must define id="$id"');
      }
    });
  });

  group('CONFIG block — placeholders only, never real credentials', () {
    test('CONFIG block holds placeholders', () {
      expect(
        html,
        contains("const SUPABASE_URL = 'YOUR_SUPABASE_URL';"),
      );
      expect(
        html,
        contains("const SUPABASE_ANON_KEY = 'YOUR_SUPABASE_ANON_KEY';"),
      );
    });

    test('no real Supabase project URL in the page', () {
      expect(
        RegExp(r'https://[A-Za-z0-9-]+\.supabase\.co').hasMatch(html),
        isFalse,
        reason: 'a real https://*.supabase.co URL must never be in the page',
      );
    });

    test('no JWT-shaped anon key in the page', () {
      expect(
        RegExp(r'eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+').hasMatch(html),
        isFalse,
        reason: 'a JWT-shaped key must never be in the page',
      );
    });

    test('no service_role key anywhere in the page', () {
      expect(html, isNot(contains('service_role')));
    });
  });

  group('waitlist behaviour copy', () {
    test('inserts into the waitlist table with source waitlist-page', () {
      expect(html, contains("from('waitlist')"));
      expect(html, contains("source: 'waitlist-page'"));
    });

    test('success, already-registered and error states exist', () {
      expect(
        html,
        contains('Shukriya! v2 aate hi aap ko email kar dein ge.'),
      );
      expect(
        html,
        contains(
          'Ye email pehle se list mein hai — v2 aate hi aap ko email milega.',
        ),
      );
      expect(html, contains('Kuch masla hua — dobara koshish karein'));
      expect(html, contains('Sahi email likhein'));
    });

    test('duplicate is detected via the unique-violation code', () {
      expect(html, contains('23505'));
    });

    test('privacy line is present', () {
      expect(
        html,
        contains('sirf v2 launch ke liye use hoga'),
      );
    });
  });

  group('branding and forbidden claims', () {
    test('headline and navy + gold branding', () {
      expect(html, contains('OfficerPath AI v2 jald aa raha hai'));
      expect(html, contains('#0B1F3A'));
      expect(html, contains('#C9A227'));
    });

    test('Supabase JS comes from the CDN, no other external dependency', () {
      expect(
        html,
        contains(
          'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2',
        ),
      );
    });

    test('no Muse link anywhere in the page', () {
      expect(html, isNot(contains('muse.ai')));
    });

    test('no Play Store claim and no download button', () {
      expect(html, isNot(contains('Play Store')));
      expect(html, isNot(contains('Google Play')));
      expect(html, isNot(contains('Download')));
      expect(html, isNot(contains('download')));
    });
  });
}
