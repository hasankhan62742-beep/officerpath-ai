import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards Supabase migration 005_waitlist.sql as TEXT: the table,
/// the dedupe constraint, the email CHECK, RLS and the two policies.
/// No database is needed — the file that gets pasted into the
/// Dashboard SQL editor is what is checked.
void main() {
  late String sql;

  setUpAll(() {
    sql = File('supabase/migrations/005_waitlist.sql').readAsStringSync();
  });

  test('migration file exists and is non-empty', () {
    expect(sql.trim(), isNotEmpty);
  });

  test('creates the waitlist table with the required columns', () {
    expect(sql, contains('create table if not exists public.waitlist'));
    expect(sql, contains('id uuid primary key default gen_random_uuid()'));
    expect(sql, contains('email text not null unique'));
    expect(
      sql,
      contains('created_at timestamptz not null default now()'),
    );
    expect(sql, contains("source text not null default 'waitlist-page'"));
  });

  test('UNIQUE on email enforces one row per email (dedupe)', () {
    expect(sql, contains('email text not null unique'));
  });

  test('CHECK constraint enforces a sane email shape', () {
    expect(sql, contains('waitlist_email_format check'));
    expect(
      sql,
      contains(
        r"email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'",
      ),
    );
  });

  test('Row Level Security is enabled on waitlist', () {
    expect(
      sql.toLowerCase(),
      contains('alter table public.waitlist enable row level security'),
    );
  });

  test('anon may INSERT only — no anon SELECT / UPDATE / DELETE', () {
    expect(sql, contains('on public.waitlist for insert'));
    expect(sql, contains('to anon'));
    // Exactly one SELECT policy, and it is the admin one (see below).
    final selectCount =
        'for select'.allMatches(sql.toLowerCase()).length;
    expect(selectCount, 1);
    expect(sql, isNot(contains('on public.waitlist for update')));
    expect(sql, isNot(contains('on public.waitlist for delete')));
  });

  test('admins may SELECT via the existing is_admin() helper', () {
    expect(sql, contains('Admins can view the waitlist'));
    expect(sql, contains('on public.waitlist for select'));
    expect(sql, contains('using (public.is_admin())'));
  });

  test('header documents the run order (after 001-003, and 004)', () {
    expect(sql, contains('005_waitlist.sql'));
    expect(sql, contains('004_push_notifications.sql'));
  });

  test('no privileged key material in the migration', () {
    expect(sql, isNot(contains('service_role')));
    expect(sql.toLowerCase(), isNot(contains('password')));
    expect(sql, isNot(contains('SUPABASE_SERVICE_ROLE_KEY')));
  });
}
