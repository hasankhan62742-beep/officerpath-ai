import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the Supabase SQL migrations as TEXT: the tables, RLS and
/// policies the app depends on must actually be in the files that get
/// pasted into the Dashboard SQL editor. No database is needed.
void main() {
  late String schema;
  late String rls;
  late String triggers;

  setUpAll(() {
    schema = File('supabase/migrations/001_schema.sql').readAsStringSync();
    rls = File('supabase/migrations/002_rls.sql').readAsStringSync();
    triggers = File('supabase/migrations/003_triggers.sql').readAsStringSync();
  });

  test('all three migration files exist and are non-empty', () {
    expect(schema.trim(), isNotEmpty);
    expect(rls.trim(), isNotEmpty);
    expect(triggers.trim(), isNotEmpty);
  });

  test('001 defines all four tables', () {
    for (final table in [
      'profiles',
      'activation_codes',
      'payments',
      'test_results',
    ]) {
      expect(schema, contains('create table if not exists public.$table'));
    }
  });

  test('001 enables Row Level Security on every table', () {
    final count = 'enable row level security'.allMatches(
      schema.toLowerCase(),
    ).length;
    expect(count, 4);
    for (final table in [
      'profiles',
      'activation_codes',
      'payments',
      'test_results',
    ]) {
      expect(
        schema.toLowerCase(),
        contains('alter table public.$table enable row level security'),
      );
    }
  });

  test('002 defines the is_admin helper and policies for the user tables',
      () {
    expect(rls, contains('create or replace function public.is_admin()'));
    expect(rls, contains('security definer'));
    for (final table in ['profiles', 'payments', 'test_results']) {
      expect(rls, contains('create policy'));
      expect(rls, contains('on public.$table for select'));
    }
    // Users may only touch their own rows.
    expect(rls, contains('auth.uid() = id'));
    expect(rls, contains('auth.uid() = user_id'));
    // Admins can read / update through the helper.
    expect(rls, contains('public.is_admin()'));
  });

  test('002 gives activation_codes NO client policy (deny by default)', () {
    expect(rls, isNot(contains('on public.activation_codes for select')));
    expect(rls, isNot(contains('on public.activation_codes for insert')));
    expect(rls, isNot(contains('on public.activation_codes for update')));
  });

  test('003 creates the signup trigger and the updated_at trigger', () {
    expect(triggers, contains('handle_new_user'));
    expect(triggers, contains('after insert on auth.users'));
    expect(triggers, contains('on_auth_user_created'));
    expect(triggers, contains('set_updated_at'));
    expect(triggers, contains('profiles_updated_at'));
    // Username defaults to the part before '@'.
    expect(triggers, contains("split_part("));
  });

  test('003 trigger prefers the username the user chose at sign-up',
      () {
    // signUp() stores the chosen username in auth.users
    // raw_user_meta_data.username (auth_service.dart). The trigger
    // must copy THAT into profiles.username when present, so the name
    // survives email verification — falling back to the email prefix
    // only when no username was chosen.
    expect(
      triggers,
      contains("raw_user_meta_data ->> 'username'"),
    );
    // The metadata read must come BEFORE the email-prefix fallback
    // in the function body.
    final metaAt =
        triggers.indexOf("raw_user_meta_data ->> 'username'");
    final fallbackAt = triggers.indexOf('split_part(');
    expect(metaAt, greaterThan(0));
    expect(fallbackAt, greaterThan(metaAt));
  });

  test('no SQL file contains a privileged key or a password', () {
    for (final sql in [schema, rls, triggers]) {
      expect(sql, isNot(contains('service_role')));
      expect(sql.toLowerCase(), isNot(contains('password')));
      expect(sql, isNot(contains('SUPABASE_SERVICE_ROLE_KEY')));
    }
  });
}
