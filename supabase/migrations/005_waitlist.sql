-- ============================================================
-- OfficerPath AI v2.0.0 — Supabase migration 005_waitlist.sql
-- RUN ORDER: 5 of 5 — run AFTER 001_schema.sql, 002_rls.sql,
-- 003_triggers.sql, AND after 004_push_notifications.sql (004
-- exists in this repo). Run order: 001 -> 002 -> 003 -> 004 -> 005.
-- HOW TO APPLY: Supabase Dashboard -> SQL Editor -> New query ->
-- paste this file -> Run. No secrets or keys in this file.
-- Safe to commit.
--
-- WHAT IT ADDS:
-- * waitlist — one row per email that joined the v2 waitlist from
--   the landing page (docs/index.html). Dedupe is enforced by the
--   UNIQUE constraint on email: one row per email, ever.
--
-- WHO CAN READ IT: admins ONLY. The anon role may INSERT (that is
-- how the public waitlist page writes), but may NOT SELECT, UPDATE
-- or DELETE — the list of emails is read only by admins, through
-- the existing public.is_admin() helper from 002_rls.sql. There is
-- deliberately no UPDATE or DELETE policy at all.
-- ============================================================

-- Required for gen_random_uuid() (also created by 001_schema.sql;
-- harmless to repeat so this file works on its own).
create extension if not exists "pgcrypto";

create table if not exists public.waitlist (
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  created_at timestamptz not null default now(),
  source text not null default 'waitlist-page',
  constraint waitlist_email_format check (
    email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
  )
);

alter table public.waitlist enable row level security;

-- Anyone (anon) may JOIN the waitlist — INSERT only. No SELECT,
-- UPDATE or DELETE is granted to anon, so the public page can write
-- an email but can never read the list back.
create policy "Anyone can join the waitlist"
  on public.waitlist for insert
  to anon
  with check (true);

-- Admins (profiles.is_admin, via the 002_rls.sql helper) may read
-- the list in the admin panel and export it for the v2 launch email.
create policy "Admins can view the waitlist"
  on public.waitlist for select
  using (public.is_admin());

-- No UPDATE / DELETE policies: waitlist rows are never edited or
-- deleted from the client. (An admin removes an address from the
-- Supabase Dashboard Table Editor if someone asks to be removed.)
