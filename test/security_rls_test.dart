import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// C1 regression tests (security audit 2026-11-20, verified live 20 Nov):
/// the profiles UPDATE policy in 002_rls.sql guards only is_admin, so
/// any signed-in user could set plan='premium' + a far-future
/// premium_until on their own row and the app trusted it
/// (SubscriptionService.refreshPlanFromServer -> applyServerPremium).
/// The fix is migration 006: BEFORE UPDATE/INSERT triggers on profiles
/// that only the server (service_role) or an admin may bypass.
///
/// These are static tripwire tests (no live DB in CI): they fail loudly
/// if the migration is deleted or gutted. The real proof is the live
/// exploit re-attempt documented in SECURITY_AUDIT_2026-11-20.md
/// (non-admin UPDATE must be rejected; admin + service_role pass).

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('C1: client cannot grant itself Premium', () {
    late String migration006;
    late String rls002;
    late String schema001;

    setUpAll(() {
      migration006 = _read(
        'supabase/migrations/006_block_client_premium_grant.sql',
      );
      rls002 = _read('supabase/migrations/002_rls.sql');
      schema001 = _read('supabase/migrations/001_schema.sql');
    });

    test('migration 006 defines the UPDATE guard trigger on profiles',
        () {
      expect(
        migration006,
        contains('prevent_client_premium_grant'),
      );
      expect(migration006, contains('before update on public.profiles'));
      expect(
        migration006,
        contains('trg_prevent_client_premium_grant'),
      );
    });

    test('UPDATE guard lets the server and admins through', () {
      expect(
        migration006,
        contains("auth.role() = 'service_role'"),
      );
      expect(migration006, contains('public.is_admin()'));
    });

    test('UPDATE guard blocks changes to plan, premium_until, is_admin',
        () {
      expect(
        migration006,
        contains('new.plan is distinct from old.plan'),
      );
      expect(
        migration006,
        contains('new.premium_until is distinct from old.premium_until'),
      );
      expect(
        migration006,
        contains('new.is_admin is distinct from old.is_admin'),
      );
      expect(migration006, contains('raise exception'));
    });

    test('INSERT guard coerces premium columns to safe defaults', () {
      expect(
        migration006,
        contains('coerce_client_profile_insert'),
      );
      expect(migration006, contains('before insert on public.profiles'));
      expect(migration006, contains("new.plan := 'free'"));
      expect(migration006, contains('new.premium_until := null'));
      expect(migration006, contains('new.is_admin := false'));
    });

    test('002 policy still guards is_admin on profile update', () {
      expect(rls002, contains('Users can update their own profile'));
      expect(rls002, contains('is_admin is not true'));
    });

    test('001 schema defaults make the INSERT coercion a no-op', () {
      expect(schema001, contains("plan text not null default 'free'"));
      expect(schema001, contains('is_admin boolean not null default false'));
    });
  });
}
