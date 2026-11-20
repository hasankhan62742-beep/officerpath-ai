-- ============================================================
-- OfficerPath AI v2.0.0 — Supabase migration 013_payment_screenshot.sql
-- RUN ORDER: 13 — run AFTER 001..012.
-- HOW TO APPLY: Supabase Dashboard -> SQL Editor -> New query ->
-- paste this file -> Run.
-- No secrets or keys in this file. Safe to commit.
--
-- RECEIPT SCREENSHOT (in-app upload, 2026-11-20): a Premium buyer
-- must attach the Easypaisa/JazzCash receipt screenshot when
-- submitting a payment proof. The app uploads it to a PRIVATE
-- storage bucket BEFORE inserting the payments row, and stores the
-- storage path in payments.screenshot_path. The admin opens it from
-- the panel (signed URL) and matches receiver number + amount + TID
-- before approving. The same receipt is ALSO sent on WhatsApp — the
-- admin can check either channel.
--
-- NOTE on migration numbering: there is no 012b — 013 is this file.
--
-- VERIFY LIVE BEFORE APPLYING (flagged honestly): the storage
-- policies below use the Supabase-provided storage.foldername()
-- helper and the standard storage.objects columns (bucket_id,
-- name). That is the documented Supabase pattern, but this repo has
-- no way to check the live storage schema from files alone — after
-- applying, confirm in the Dashboard (Storage -> payment-proofs ->
-- Policies) that the three policies exist, and test one real upload
-- from the app before telling buyers to use it.
-- ============================================================

-- (a) The payments row records where its receipt lives.
alter table public.payments
  add column if not exists screenshot_path text;

-- (b) Private bucket for receipt screenshots. 5 MB cap, images only.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('payment-proofs', 'payment-proofs', false, 5242880, array['image/jpeg', 'image/png'])
  on conflict (id) do nothing;

-- (c) Storage policies on storage.objects for this bucket.
-- Authenticated users may INSERT only under their own uid folder
-- (<uid>/...); nobody may upload into someone else's folder.
create policy "Users can upload their own receipt"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'payment-proofs'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Admins may read every receipt in the bucket.
create policy "Admins can view all receipts"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'payment-proofs'
    and public.is_admin()
  );

-- Owners may read their own receipts.
create policy "Users can view their own receipts"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'payment-proofs'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- No UPDATE / DELETE policy on purpose: receipts are immutable once
-- uploaded. (Admins use the Dashboard if one must go.)
