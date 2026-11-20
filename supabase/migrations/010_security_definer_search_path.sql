-- ============================================================
-- OfficerPath AI v2.0.0 — Supabase migration 010_security_definer_search_path.sql
-- RUN ORDER: 10 — run AFTER 001..009.
-- HOW TO APPLY: Supabase Dashboard -> SQL Editor -> New query ->
-- paste this file -> Run.
-- No secrets or keys in this file. Safe to commit.
--
-- FIXES L1 (security audit 2026-11-20, §1): a SECURITY DEFINER
-- function without an explicit search_path can be influenced by
-- search-path manipulation (standard Supabase hardening guidance).
-- Practical risk here is low — ordinary users cannot create schemas
-- — but the fix is one line per function.
--
-- EVERY SECURITY DEFINER function in supabase/migrations/*.sql was
-- checked (grep, 2026-11-20):
--   * public.is_admin()            — 002_rls.sql, NO search_path -> fixed here
--   * public.handle_new_user()     — 003_triggers.sql, NO search_path -> fixed here
--   * public.prevent_client_premium_grant()  — 006, already SET search_path = public
--   * public.coerce_client_profile_insert()  — 006, already SET search_path = public
--   * 004_push_notifications.sql, 005_waitlist.sql, 011_redeem_attempt_throttle.sql
--     define NO functions at all.
--   * public.set_updated_at() (003_triggers.sql) is a plain trigger
--     function, NOT security definer, so it is out of scope for L1
--     and is left untouched.
-- After this file, zero SECURITY DEFINER functions without
-- search_path remain in the migrations. (New SECURITY DEFINER
-- functions added by 008/009 already set search_path = public in
-- their own definitions.)
-- ============================================================

alter function public.is_admin()
  set search_path = public;

alter function public.handle_new_user()
  set search_path = public;
