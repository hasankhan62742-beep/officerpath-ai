-- ============================================================
-- OfficerPath AI v2.0.0 — Supabase migration 012_tid_reuse_guard.sql
-- RUN ORDER: 12 — run AFTER 001..011.
-- HOW TO APPLY: Supabase Dashboard -> SQL Editor -> New query ->
-- paste this file -> Run.
-- No secrets or keys in this file. Safe to commit.
--
-- FIXES the transaction-ID reuse hole (reported by the owner
-- 2026-11-20, "can anyone take Premium by pasting someone else's
-- transaction ID?"): payments.transaction_id had NO uniqueness of
-- any kind, so the same Easypaisa/JazzCash TID could be approved
-- for two different buyers. The issue-code Edge Function now
-- checks the TID before issuing (and marks the payment approved
-- itself), and this index is the backstop that makes reuse
-- impossible even if two approvals race: the second UPDATE fails
-- with a unique violation (23505), which the function maps to
-- tid_already_used.
--
-- Partial index on purpose: only APPROVED rows are unique. A TID
-- may be submitted more than once while pending (the app warns the
-- user, the admin rejects the copy), and a rejected row must never
-- block a later legitimate payment that happens to share an ID.
-- Exact-match only: the app trims the TID on submit, and
-- Easypaisa/JazzCash IDs are numeric, so case/whitespace variants
-- are not a real vector here.
--
-- IF THIS FAILS on apply: it means two APPROVED rows already share
-- a transaction_id live. Do NOT force it — report it; those rows
-- are the fraud this guard exists to catch, and an admin must
-- decide which approval was genuine before the index can exist.
-- (At launch there should be no approved rows at all.)
-- ============================================================

create unique index if not exists payments_tid_approved_unique
  on public.payments (transaction_id)
  where status = 'approved';
