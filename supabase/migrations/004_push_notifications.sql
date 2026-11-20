-- ============================================================
-- OfficerPath AI v2.0.0 — Supabase migration 004_push_notifications.sql
-- RUN ORDER: 4 of 4 — run AFTER 001_schema.sql, 002_rls.sql, 003_triggers.sql.
-- HOW TO APPLY: Supabase Dashboard -> SQL Editor -> New query ->
-- paste this file -> Run. No secrets or keys in this file.
-- Safe to commit.
--
-- WHAT IT ADDS:
-- * profiles.fcm_token / fcm_token_updated_at / notifications_enabled
--   (the device token + the user's opt-out flag).
-- * sent_notifications — an audit log of every push the admin sent.
--
-- POLICY CHECK (verified against 002_rls.sql): the existing
-- "Users can update their own profile" policy covers the new columns
-- WITHOUT any change. It allows an own-row update whose WITH CHECK is
-- (auth.uid() = id AND (is_admin is not true OR public.is_admin())) —
-- updating fcm_token / notifications_enabled leaves is_admin untouched,
-- so the check still passes. The app updates ONLY its own row
-- (eq id = auth user's id), so the USING clause passes too. No new
-- profiles policy is added here, deliberately.
-- ============================================================

alter table public.profiles
  add column if not exists fcm_token text,
  add column if not exists fcm_token_updated_at timestamptz,
  add column if not exists notifications_enabled boolean not null default true;

-- Audit log: one row per admin send (not per device). The Edge
-- Function `send-notification` inserts with the service_role key
-- (which bypasses RLS); the admin panel reads it with the anon key
-- as an admin, so it needs the SELECT policy below.
create table if not exists public.sent_notifications (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text not null,
  audience text not null check (audience in ('all', 'premium', 'free')),
  notification_type text not null
    check (notification_type in ('update_available', 'announcement')),
  version text,
  sent_by uuid references auth.users (id),
  sent_at timestamptz not null default now(),
  recipient_count int not null default 0
);

alter table public.sent_notifications enable row level security;

-- Admins only: read the send history in the admin panel.
create policy "Admins can view sent notifications"
  on public.sent_notifications for select
  using (public.is_admin());

-- Admins may also insert directly (e.g. a manual send from the SQL
-- editor); the Edge Function itself uses service_role and bypasses
-- RLS, so this policy is a fallback, not the send path.
create policy "Admins can insert sent notifications"
  on public.sent_notifications for insert
  with check (public.is_admin());

-- No UPDATE / DELETE policies: the log is append-only. A mistaken
-- entry is corrected by sending a new notification, never by editing
-- history.
