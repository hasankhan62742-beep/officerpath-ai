-- ============================================================
-- OfficerPath AI v2.0.0 — Supabase migration 009_waitlist_throttle.sql
-- RUN ORDER: 9 — run AFTER 001..008.
-- HOW TO APPLY: Supabase Dashboard -> SQL Editor -> New query ->
-- paste this file -> Run.
-- No secrets or keys in this file. Safe to commit.
--
-- FIXES M4 (security audit 2026-11-20, §1): the waitlist anon
-- INSERT (005_waitlist.sql, WITH CHECK (true)) is intentionally open
-- but unthrottled — a script could bulk-insert unlimited unique
-- emails, bloating the table and polluting the launch-email list.
-- Postgres cannot see the caller's IP, so a per-IP limit is not
-- possible here; this file adds the DB-side guard that is possible:
--
--   * the UNIQUE constraint on email (already in 005_waitlist.sql:
--     `email text not null unique`) is re-asserted idempotently below
--     — one row per email, ever — so a repeat address can never
--     create a second row;
--   * a BEFORE INSERT trigger caps GLOBAL signups at 30 rows in any
--     trailing 60-second window. Normal human signups are a handful
--     per minute at most; a bulk script hits the cap within seconds
--     and every further insert in the window fails with a clear
--     exception (the public page shows its generic "Kuch masla hua"
--     message for it, same as any other insert error).
--
-- LIMITS OF THIS GUARD (honest note): concurrent transactions each
-- see only committed rows, so two inserts landing in the same instant
-- can both slip under the cap — this is a best-effort DB-side brake,
-- not a hard rate limiter. The real fix remains the audit's Edge
-- Function + CAPTCHA/Turnstile route; this file only makes bulk
-- abuse expensive and visible.
--
-- BYPASS — WHO IS NEVER THROTTLED:
--   * service_role (Edge Functions / server key), and admins
--     (public.is_admin()), same pattern as 006;
--   * auth.role() IS NULL — the Supabase Dashboard SQL Editor runs
--     as postgres with no JWT, so auth.role() is NULL there. The
--     documented Sheet import (docs/waitlist.md) runs exactly that
--     way: generated INSERT statements pasted into the SQL Editor,
--     `ON CONFLICT (email) DO NOTHING`. Without the NULL-role bypass
--     a bulk import of more than 30 addresses would trip the throttle
--     part-way through. The admin panel itself never inserts into
--     waitlist (SELECT only, admin/app.js loadWaitlist), so it is
--     unaffected either way.
--
-- The trigger function is SECURITY DEFINER (with SET search_path =
-- public) on purpose: anon has no SELECT on waitlist, so a plain
-- trigger function running as anon would count zero rows and the
-- throttle would never fire. As SECURITY DEFINER it reads the true
-- count past RLS.
-- ============================================================

-- 005_waitlist.sql already declares `email text not null unique`.
-- Re-assert it idempotently: add a named UNIQUE constraint only if
-- the table somehow has no unique constraint at all (e.g. a live
-- table created before 005 was applied).
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.waitlist'::regclass
      and contype = 'u'
  ) then
    alter table public.waitlist
      add constraint waitlist_email_unique unique (email);
  end if;
end $$;

-- Keep the throttle's window count cheap as the list grows.
create index if not exists waitlist_created_at_idx
  on public.waitlist (created_at);

create or replace function public.throttle_waitlist_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  recent_count int;
begin
  -- Server key, admins, and the Dashboard SQL Editor (no JWT, so
  -- auth.role() is NULL — the documented Sheet-import path) are
  -- never throttled. Only anonymous public signups are capped.
  if auth.role() is null
     or auth.role() = 'service_role'
     or public.is_admin() then
    return new;
  end if;

  select count(*) into recent_count
  from public.waitlist
  where created_at >= now() - interval '1 minute';

  if recent_count >= 30 then
    raise exception 'Waitlist signup rate limit reached — try again in a minute';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_throttle_waitlist_insert on public.waitlist;
create trigger trg_throttle_waitlist_insert
  before insert on public.waitlist
  for each row execute function public.throttle_waitlist_insert();
