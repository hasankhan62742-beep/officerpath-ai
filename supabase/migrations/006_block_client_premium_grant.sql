-- ============================================================
-- OfficerPath AI v2.0.0 — Supabase migration 006_block_client_premium_grant.sql
-- RUN ORDER: 6 of 6 — run AFTER 001..005.
-- HOW TO APPLY: Supabase Dashboard -> SQL Editor -> New query ->
-- paste this file -> Run.
-- No secrets or keys in this file. Safe to commit.
--
-- FIXES C1 (security audit 2026-11-20, verified from 002_rls.sql):
-- the profiles UPDATE policy guards only is_admin, so any signed-in
-- user could set plan='premium' + a far-future premium_until on
-- their own row with one PostgREST call, and the app trusted it
-- (SubscriptionService.refreshPlanFromServer -> applyServerPremium).
-- A policy WITH CHECK cannot compare new vs old values, so the guard
-- lives here as BEFORE triggers instead.
--
-- ALLOWED to set plan / premium_until / is_admin:
--   * the server (service_role — Edge Functions redeem-code/issue-code)
--   * an admin (public.is_admin(), i.e. the caller is an admin)
-- Everyone else may update only their own ordinary columns
-- (username, email, ...). Changing any of the three guarded columns
-- on UPDATE raises an exception and the whole UPDATE rolls back.
-- On INSERT the guarded columns are coerced to the safe defaults
-- (free / NULL / false) instead of raising, so sign-up can never
-- break: handle_new_user() (003) inserts only (id, username, email)
-- and the app never inserts a profile row itself.
--
-- NOTE: the dashboard SQL editor runs as postgres with no JWT, so
-- auth.role()/auth.uid() are NULL there — a manual plan change
-- pasted into the SQL editor will be BLOCKED by the UPDATE trigger.
-- Grant Premium from the admin panel or via issue-code instead.
-- ============================================================

-- UPDATE guard: block client-side changes to the three guarded columns.
create or replace function public.prevent_client_premium_grant()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Server-side (Edge Functions with the service_role key) and admins
  -- may change plan / premium_until / is_admin.
  if auth.role() = 'service_role' or public.is_admin() then
    return new;
  end if;
  if new.plan is distinct from old.plan
     or new.premium_until is distinct from old.premium_until
     or new.is_admin is distinct from old.is_admin then
    raise exception 'Only the server or an admin may change plan, premium_until or is_admin';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_prevent_client_premium_grant on public.profiles;
create trigger trg_prevent_client_premium_grant
  before update on public.profiles
  for each row execute function public.prevent_client_premium_grant();

-- INSERT guard (defense in depth): a client that somehow inserts a
-- profile row directly can never smuggle Premium in with it. Coercion
-- (not an exception) so sign-up stays unbreakable.
create or replace function public.coerce_client_profile_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.role() = 'service_role' or public.is_admin() then
    return new;
  end if;
  new.plan := 'free';
  new.premium_until := null;
  new.is_admin := false;
  return new;
end;
$$;

drop trigger if exists trg_coerce_client_profile_insert on public.profiles;
create trigger trg_coerce_client_profile_insert
  before insert on public.profiles
  for each row execute function public.coerce_client_profile_insert();
