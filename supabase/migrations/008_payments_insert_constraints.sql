-- ============================================================
-- OfficerPath AI v2.0.0 — Supabase migration 008_payments_insert_constraints.sql
-- RUN ORDER: 8 — run AFTER 001..007.
-- HOW TO APPLY: Supabase Dashboard -> SQL Editor -> New query ->
-- paste this file -> Run.
-- No secrets or keys in this file. Safe to commit.
--
-- FIXES M2 (security audit 2026-11-20, §1): the payments INSERT
-- policy in 002_rls.sql only checks auth.uid() = user_id, so a
-- signed-in user could insert a row with status = 'approved' (and
-- forged reviewed_by / reviewed_at / code_id). The admin review
-- queue filters status = 'pending', so the forged row never appears
-- for review — yet the user-detail view would display it as a
-- legitimately approved payment, which could induce the admin to
-- issue a code for an unverified payment. payments.plan also had no
-- CHECK constraint, so the plan shown to the admin was free-form
-- user input (e.g. claim a 1-year plan on a Rs 600 payment).
--
-- Three layers, all in this file:
--   (a) the INSERT policy now requires status = 'pending' and
--       reviewed_by / reviewed_at / code_id all NULL;
--   (b) a CHECK constraint limits plan to the three plan ids the app
--       actually sells (verified: PremiumPlan.plans in
--       lib/services/subscription_service.dart, PLAN_MAP in
--       supabase/functions/issue-code/index.ts, and the admin labels
--       in admin/app.js all use exactly these three);
--   (c) a BEFORE INSERT trigger forces status = 'pending' for client
--       inserts (belt-and-braces for clients that omit the field).
--
-- LEGITIMATE FLOWS CHECKED (grep evidence, 2026-11-20):
-- * The ONLY client insert path is PaymentProofService._defaultInsert
--   (lib/services/payment_proof_service.dart:264), fed by
--   buildProofPayload (:157-176), which always sets status 'pending'
--   and never sets reviewed_by / reviewed_at / code_id. The unit test
--   test/payment_proof_test.dart pins that exact payload.
-- * No Edge Function INSERTs into payments (delete-account only
--   DELETEs; issue-code UPDATEs the approved row server-side — the
--   TID guard, migration 012; redeem-code never touches the table).
-- * admin/app.js only SELECTs and UPDATEs payments (review flow);
--   the admin UPDATE policy is untouched by this file.
-- * The CHECK on plan validates EXISTING rows when it is added: if
--   any live payment row holds a plan outside the three ids, this
--   file fails at the ALTER TABLE step — clean those rows first
--   (they can only be forged rows; the app never wrote one).
-- ============================================================

-- (a) Tighten the client INSERT policy: a new payment must be the
-- caller's own, pending, and unreviewed with no code linked yet.
-- Clients that omit status / review fields get the column defaults
-- ('pending' / NULL / NULL / NULL), so the app payload still passes.
drop policy if exists "Users can insert their own payments" on public.payments;

create policy "Users can insert their own payments"
  on public.payments for insert
  with check (
    auth.uid() = user_id
    and status = 'pending'
    and reviewed_by is null
    and reviewed_at is null
    and code_id is null
  );

-- (b) Only the three plans the app sells may appear in payments.plan.
-- Guarded so re-running this file is a no-op instead of an error.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'payments_plan_valid'
      and conrelid = 'public.payments'::regclass
  ) then
    alter table public.payments
      add constraint payments_plan_valid
      check (plan in ('premium_1month', 'premium_2months', 'premium_1year'));
  end if;
end $$;

-- (c) Belt-and-braces BEFORE INSERT trigger: a client insert can
-- never land with a non-pending status. Forged status values are
-- coerced down to 'pending' (the insert succeeds as a normal pending
-- proof); forged reviewed_by / reviewed_at / code_id are NOT coerced
-- here — the tightened policy in (a) still rejects those rows.
-- The server (service_role) and admins bypass the coercion, so a
-- future server-side insert path is not constrained by this trigger.
create or replace function public.force_pending_payment_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.role() = 'service_role' or public.is_admin() then
    return new;
  end if;
  new.status := 'pending';
  return new;
end;
$$;

drop trigger if exists trg_force_pending_payment_status on public.payments;
create trigger trg_force_pending_payment_status
  before insert on public.payments
  for each row execute function public.force_pending_payment_status();
