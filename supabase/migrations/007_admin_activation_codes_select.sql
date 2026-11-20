-- ============================================================
-- OfficerPath AI v2.0.0 — Supabase migration 007_admin_activation_codes_select.sql
-- RUN ORDER: 7 — run AFTER 001..006.
-- HOW TO APPLY: Supabase Dashboard -> SQL Editor -> New query ->
-- paste this file -> Run.
-- No secrets or keys in this file. Safe to commit.
--
-- FIXES H2 (security audit 2026-11-20, §6): activation_codes has
-- RLS on but ZERO policies (002_rls.sql), so the admin panel's reads
-- (loadStats, openUser, approvePayment, loadCodes in admin/app.js)
-- all return empty — the dashboard shows "0 codes issued / 0 used",
-- the codes table is always empty, and approvePayment() can never
-- link the issued code to the payment (code_id stays NULL), so there
-- is no audit trail connecting an approved payment to its code.
--
-- This adds ONE admin-only SELECT policy. It is safe: only the
-- SHA-256 hash is stored in activation_codes, never the plain code,
-- so an admin still cannot recover a code from the table.
-- Do NOT add INSERT / UPDATE / DELETE policies for clients: codes
-- are written ONLY by the issue-code / redeem-code Edge Functions
-- with the service_role key, which bypasses RLS.
-- ============================================================

-- Idempotent: re-running this file replaces the policy, never errors.
drop policy if exists "Admins can view activation codes" on public.activation_codes;

create policy "Admins can view activation codes"
  on public.activation_codes for select
  using (public.is_admin());

-- No INSERT / UPDATE / DELETE policy is added here, deliberately.
-- Verify after applying: in the admin panel the codes table must
-- populate, and approving a payment must set its code_id.
