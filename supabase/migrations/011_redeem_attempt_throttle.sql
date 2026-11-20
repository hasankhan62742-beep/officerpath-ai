-- 011_redeem_attempt_throttle.sql
-- OfficerPath AI v2.0.0 — L2 fix (security audit 2026-11-20):
-- per-user attempt log backing the redeem-code rate limit
-- (10 attempts/hour per caller, HTTP 429 after the cap).
--
-- Why a new table: no existing table can hold this. activation_codes
-- is one row per issued code, profiles/payments/test_results are user
-- data that must not be polluted with attempt bookkeeping, and an
-- in-memory counter inside the Edge Function would not be shared
-- across Deno isolates, so it could not enforce a real limit.
-- The function logs one row per redeem attempt (service-role only)
-- and counts rows in the last hour; the check is fail-open, so if
-- this table is ever missing the redeem still works.
--
-- RLS: enabled with ZERO policies, exactly like activation_codes —
-- no client of any kind can read or write attempt rows; only the
-- service-role key (Edge Functions) touches this table.
-- Old rows are harmless (the window query ignores rows older than
-- one hour); delete them opportunistically, e.g.:
--   delete from public.redeem_attempts
--   where attempted_at < now() - interval '7 days';

create table if not exists public.redeem_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  attempted_at timestamptz not null default now()
);

alter table public.redeem_attempts enable row level security;

create index if not exists redeem_attempts_user_time_idx
  on public.redeem_attempts (user_id, attempted_at desc);
