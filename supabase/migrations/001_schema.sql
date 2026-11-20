-- ============================================================
-- OfficerPath AI v2.0.0 — Supabase migration 001_schema.sql
-- RUN ORDER: 1 of 3 — run this file FIRST.
-- HOW TO APPLY: Supabase Dashboard -> SQL Editor -> New query ->
-- paste this file -> Run. Then run 002_rls.sql, then 003_triggers.sql.
-- No secrets or keys in this file. Safe to commit.
-- ============================================================

-- Required for gen_random_uuid().
create extension if not exists "pgcrypto";

-- One row per signed-in user. Created automatically by the
-- handle_new_user() trigger in 003_triggers.sql.
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text unique not null,
  email text not null,
  plan text not null default 'free'
    check (plan in ('free', 'premium')),
  premium_until timestamptz,
  is_admin boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Single-use Premium activation codes. Only the SHA-256 hash is stored;
-- the plain code is emailed to the buyer once (see issue-code function)
-- and is never stored anywhere. No client access: see 002_rls.sql.
create table if not exists public.activation_codes (
  id uuid primary key default gen_random_uuid(),
  code_hash text unique not null,
  plan text not null,
  months int not null check (months in (1, 2, 12)),
  user_id uuid references auth.users (id),
  issued_by uuid references auth.users (id),
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  used_by uuid references auth.users (id)
);

-- Manual-payment proofs (JazzCash / Easypaisa). The admin reviews the
-- transaction id, then issues a code with the issue-code function.
create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id),
  email text not null,
  plan text not null,
  method text not null check (method in ('easypaisa', 'jazzcash')),
  transaction_id text not null,
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected')),
  created_at timestamptz not null default now(),
  reviewed_by uuid references auth.users (id),
  reviewed_at timestamptz,
  code_id uuid references public.activation_codes (id)
);

-- Test history, synced so a user's results survive a reinstall.
-- Local (on-device) history remains the source of truth in v2;
-- this table is the cloud backup.
create table if not exists public.test_results (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id),
  book_title text,
  exam text,
  score int,
  total int,
  created_at timestamptz not null default now()
);

-- Row Level Security is ON for every table. Policies live in 002_rls.sql.
-- With RLS enabled and no policy granting access, a table denies
-- everything by default — that is exactly what activation_codes relies on.
alter table public.profiles enable row level security;
alter table public.activation_codes enable row level security;
alter table public.payments enable row level security;
alter table public.test_results enable row level security;
