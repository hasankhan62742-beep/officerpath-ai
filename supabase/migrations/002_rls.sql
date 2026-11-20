-- ============================================================
-- OfficerPath AI v2.0.0 — Supabase migration 002_rls.sql
-- RUN ORDER: 2 of 3 — run AFTER 001_schema.sql.
-- HOW TO APPLY: Supabase Dashboard -> SQL Editor -> New query ->
-- paste this file -> Run. Then run 003_triggers.sql.
-- No secrets or keys in this file. Safe to commit.
--
-- DESIGN:
-- * Users touch ONLY their own rows (profiles / payments / test_results).
-- * activation_codes has NO policy at all: RLS is enabled (001) and no
--   policy grants access, so no client — not even a logged-in user —
--   can SELECT, INSERT or UPDATE it. Only the privileged server key
--   used by Edge Functions bypasses RLS and reaches this table.
-- * Admins are recognised by profiles.is_admin via the is_admin()
--   helper below (SECURITY DEFINER so it can read profiles past RLS).
-- ============================================================

-- Admin check used by every admin policy. SECURITY DEFINER runs it
-- with the function owner's rights, so it can read the caller's own
-- profiles row even though RLS is on. It reads exactly one row:
-- the profile of the currently authenticated user (auth.uid()).
create or replace function public.is_admin()
returns boolean
language sql
security definer
stable
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and is_admin = true
  );
$$;

-- ---------------- profiles ----------------
-- A user sees and edits only their own profile row.
create policy "Users can view their own profile"
  on public.profiles for select
  using (auth.uid() = id);

-- A user can insert their own profile row at signup. (The trigger in
-- 003_triggers.sql normally creates it; this policy covers the case
-- where the app inserts it directly.)
create policy "Users can insert their own profile"
  on public.profiles for insert
  with check (auth.uid() = id);

-- A user can update their own row — but may NOT grant themselves admin:
-- the new row must keep is_admin false unless the caller already is one.
create policy "Users can update their own profile"
  on public.profiles for update
  using (auth.uid() = id)
  with check (auth.uid() = id and (is_admin is not true or public.is_admin()));

-- Admins can read and edit every profile (e.g. grant Premium manually).
create policy "Admins can view all profiles"
  on public.profiles for select
  using (public.is_admin());

create policy "Admins can update all profiles"
  on public.profiles for update
  using (public.is_admin());

-- ---------------- payments ----------------
create policy "Users can view their own payments"
  on public.payments for select
  using (auth.uid() = user_id);

create policy "Users can insert their own payments"
  on public.payments for insert
  with check (auth.uid() = user_id);

-- Admins review every payment (approve / reject, then issue a code).
create policy "Admins can view all payments"
  on public.payments for select
  using (public.is_admin());

create policy "Admins can update payments"
  on public.payments for update
  using (public.is_admin());

-- No DELETE policy on payments: payment records are never deleted
-- from the client. (Admins use the Dashboard if one must go.)

-- ---------------- test_results ----------------
create policy "Users can view their own test results"
  on public.test_results for select
  using (auth.uid() = user_id);

create policy "Users can insert their own test results"
  on public.test_results for insert
  with check (auth.uid() = user_id);

create policy "Admins can view all test results"
  on public.test_results for select
  using (public.is_admin());

-- No UPDATE / DELETE policies on test_results: results are append-only
-- from the client.

-- ---------------- activation_codes ----------------
-- INTENTIONALLY NO POLICIES. RLS is enabled (001_schema.sql) and with
-- no policy, every client-side SELECT / INSERT / UPDATE / DELETE is
-- denied. Codes are read and written ONLY by the Edge Functions
-- (redeem-code, issue-code), which use the privileged server key that
-- bypasses RLS. Never add a client policy to this table.
