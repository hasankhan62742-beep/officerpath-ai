-- ============================================================
-- OfficerPath AI v2.0.0 — Supabase migration 014_realtime_payments.sql
-- RUN ORDER: 14 — run AFTER 001..013.
-- HOW TO APPLY: Supabase Dashboard -> SQL Editor -> New query ->
-- paste this file -> Run.
-- No secrets or keys in this file. Safe to commit.
--
-- LIVE PAYMENT ALERTS (2026-11-20): the admin panel subscribes to
-- Realtime postgres_changes on public.payments INSERT so a new
-- pending payment pops up with a sound + banner while the panel is
-- open. Realtime only streams tables that are members of the
-- supabase_realtime publication — this file adds payments to it.
--
-- Idempotent: the DO block checks pg_publication_tables first, so
-- re-running this file is a no-op instead of an error.
--
-- NOTE on migration numbering: 013 is the receipt-screenshot
-- migration (013_payment_screenshot.sql). There is no gap — 013
-- exists; 014 follows it.
-- ============================================================

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'payments'
  ) then
    alter publication supabase_realtime add table public.payments;
  end if;
end $$;
