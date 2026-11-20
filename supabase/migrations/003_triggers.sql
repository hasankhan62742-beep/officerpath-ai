-- ============================================================
-- OfficerPath AI v2.0.0 — Supabase migration 003_triggers.sql
-- RUN ORDER: 3 of 3 — run AFTER 001_schema.sql and 002_rls.sql.
-- HOW TO APPLY: Supabase Dashboard -> SQL Editor -> New query ->
-- paste this file -> Run.
-- No secrets or keys in this file. Safe to commit.
-- ============================================================

-- Auto-create a profiles row whenever a user signs up (email or Google).
-- Username: the name the user CHOSE at sign-up (stored by Supabase Auth
-- in auth.users user_metadata.username) wins when present; otherwise
-- fall back to the part of the email before '@'. Either way it is made
-- unique by appending a number when needed (ali, ali1, ali2, ...).
-- WHY the metadata first: the sign-up form collects a username, Auth
-- stores it in user_metadata, and email verification happens AFTER the
-- trigger runs — taking it only from the email would silently discard
-- the user's chosen name. The user can change it later from their
-- profile screen.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
as $$
declare
  base_username text;
  candidate text;
  suffix int := 0;
begin
  base_username := nullif(
    btrim(coalesce(new.raw_user_meta_data ->> 'username', '')),
    ''
  );
  if base_username is null then
    base_username := split_part(coalesce(new.email, ''), '@', 1);
  end if;
  if base_username = '' then
    base_username := 'user';
  end if;
  candidate := base_username;
  while exists (select 1 from public.profiles where username = candidate) loop
    suffix := suffix + 1;
    candidate := base_username || suffix::text;
  end loop;
  insert into public.profiles (id, username, email)
  values (new.id, candidate, coalesce(new.email, ''))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Keep profiles.updated_at fresh on every edit.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists profiles_updated_at on public.profiles;
create trigger profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();
