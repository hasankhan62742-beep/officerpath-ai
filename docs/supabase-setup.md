# OfficerPath AI v2.0.0 — Supabase setup (handover checklist)

No credentials in this file. Every secret is created in a dashboard and
pasted where the step says — never into the repo, never into chat.

## Verified limits that shape this setup (checked 19 Nov 2026)

- **Auth emails, built-in sender: 2 emails per hour, per PROJECT**
  (not per user). Source: Supabase docs, "Rate limits"
  (`supabase.com/docs/guides/auth/rate-limits`):
  > "Emails sent by Supabase Auth … 2 emails per hour with the built-in
  > email provider."
  And "Send emails with custom SMTP"
  (`supabase.com/docs/guides/auth/auth-smtp`):
  > "Currently this value is set to 2 messages per hour."
- **Worse than the cap: the built-in sender only delivers to the
  project's TEAM addresses.** Same SMTP doc:
  > "Unless you configure a custom SMTP server … Supabase Auth will
  > refuse to deliver messages to addresses that are not part of the
  > project's team … All other addresses will fail with the error
  > message *Email address not authorized*."
- **Verdict: custom SMTP is REQUIRED from day one, not optional.**
  With the built-in sender, the 3rd signup / password reset in any hour
  gets no email at all, and a real buyer (not a team member) gets no
  email ever. Verification emails, forgot-password emails AND the
  activation-code emails (sent by the `issue-code` function via Resend)
  do NOT fit in the built-in cap at any real launch scale — even 3
  signups in one hour breaks it.
- With custom SMTP the default limit is **30 messages/hour**
  (adjustable under Authentication → Rate Limits). That fits launch
  scale (tens of users/day); raise it if signups ever bunch up.
- Free project pauses after **1 week of inactivity** — see
  [keep-alive.md](keep-alive.md). Free plan: 50,000 MAU, 500 MB DB,
  500k Edge Function invocations/month — all ample for this app.

## 1. Create the Supabase project

1. Go to supabase.com → New project.
2. Name: `officerpath-ai`. Organisation: your own.
3. Region: **Singapore (ap-southeast-1)** — closest to Pakistan.
4. Plan: **Free**. Set a strong database password and store it in a
   password manager (it is needed only for direct DB access, not daily use).

## 2. Run the 3 SQL migrations (in order)

Supabase Dashboard → SQL Editor → New query, paste, Run — one file at a time:

1. `supabase/migrations/001_schema.sql` — tables + RLS enabled.
2. `supabase/migrations/002_rls.sql` — policies + `is_admin()` helper.
3. `supabase/migrations/003_triggers.sql` — auto-create profile on signup.

Verify: Table Editor shows `profiles`, `activation_codes`, `payments`,
`test_results`. Authentication → Users is still empty until first signup.

## 3. Deploy the 3 Edge Functions

On a machine with the Supabase CLI (one-time install:
`npm install -g supabase` — or `brew install supabase/tap/supabase`):

```bash
supabase login
supabase link --project-ref <project-ref>   # from Project Settings → General
supabase functions deploy redeem-code
supabase functions deploy issue-code
supabase functions deploy delete-account
```

What each does: `redeem-code` — user redeems a Premium code (single-use,
hash-checked, expiry-checked). `issue-code` — admin-only, mints a code
and emails it to the buyer. `delete-account` — user deletes their own
account via the Admin API. Full details are in the header comment of
each `supabase/functions/<name>/index.ts`.

## 4. Set Edge Function secrets

Supabase Dashboard → Edge Functions → Secrets (or CLI:
`supabase secrets set NAME=value`). Secrets needed:

| Secret | Value | Notes |
|---|---|---|
| `SUPABASE_URL` | `https://<ref>.supabase.co` | Auto-injected by Supabase; set only if self-hosting |
| `SUPABASE_ANON_KEY` | anon / publishable key | Project Settings → API; auto-injected |
| `SUPABASE_SERVICE_ROLE_KEY` | service_role key | Project Settings → API; auto-injected; **never in the app** |
| `RESEND_API_KEY` | `re_...` from Resend | See step 5; used ONLY by `issue-code` |
| `RESEND_FROM` | `OfficerPath AI <hello@abdulqadeerml.com>` | Optional; this is the default |

## 5. Email provider — Resend (one account, two jobs)

**Pick: Resend free tier (100 emails/day, 3,000/month).** Chosen over
Gmail SMTP for code emails because it is one API key instead of a Google
app password tied to a personal Gmail account, and it is a plain HTTPS
call — no SMTP library. The same account also supplies the SMTP settings
for Supabase Auth below, so the owner manages ONE email provider.

1. Sign up at resend.com (email + password, no card).
2. Domains → Add Domain → `abdulqadeerml.com`. Resend shows DNS records
   (SPF/DKIM/MX). Add them in Cloudflare (DNS → Add record; TXT records
   must be **DNS-only, not proxied**). Click Verify — usually minutes.
   Until the domain is verified, Resend only delivers to the Resend
   account owner's own address, so do this before launch.
3. API Keys → Create API Key → permission **Sending access** → copy the
   `re_...` key → set as the `RESEND_API_KEY` Edge Function secret (step 4).
4. **Supabase Auth custom SMTP (REQUIRED — see the verdict above).**
   Dashboard → Authentication → Settings → SMTP Settings → enable
   "Custom SMTP":
   - Sender email: `hello@abdulqadeerml.com`
   - Sender name: `OfficerPath AI`
   - Host: `smtp.resend.com`, Port: `465`, encryption: SSL/TLS
     (Resend also offers port 587 STARTTLS; 465 is the documented default)
   - Username: `resend`
   - Password: the same Resend API key (`re_...`)
   - Save, then send a test email from the same page.
   Fallback if Resend SMTP ever fails: Gmail SMTP — host
   `smtp.gmail.com`, port `587`, user = the Gmail address behind
   `hello@`, password = a Google **app password** (Google Account →
   Security → 2-Step Verification ON → App passwords). App passwords
   need 2FA and break when the Google password changes, which is why
   Resend is the primary.

## 6. Auth settings — redirect URLs + Google

Dashboard → Authentication → URL Configuration:

- **Site URL:** `https://officerpath.abdulqadeerml.com`
  (or the app's public page; used as the fallback redirect).
- **Redirect URLs — add:** `officerpath://reset-password`
  (the password-reset deep link the app handles; `app_links` is already
  a dependency). Also add `officerpath://login-callback` if the login
  screen uses it.
- **Email templates** (Authentication → Email Templates): keep the
  defaults for v2, but check the "Reset Password" template links to
  `{{ .SiteURL }}/...` — the deep link above must be in the allowed list
  or the reset email's link will be rejected.

**Google provider** — Dashboard → Authentication → Providers → Google →
Enable. Supabase shows a callback URL
(`https://<ref>.supabase.co/auth/v1/callback`); the parent must collect
from **Google Cloud Console** (a separate browser step, not done here):
1. console.cloud.google.com → create/select project → APIs & Services →
   Credentials → Create Credentials → OAuth client ID → **Web application**.
2. Authorized redirect URI: paste Supabase's callback URL above.
3. Copy the **Client ID** and **Client Secret** into Supabase's Google
   provider fields and Save. (The `google_sign_in` package is already in
   pubspec; the app-side wiring is the auth coordinator's job.)

## 7. Make the owner an admin

After the owner signs up once in the app (or via Dashboard →
Authentication → Users → Add user), run in the SQL Editor:

```sql
update public.profiles
set is_admin = true
where email = 'hello@abdulqadeerml.com';
```

(Replace with the owner's actual login email if different.) Only an
admin can call `issue-code` and review payments. Never set
`is_admin = true` for a buyer.

## 8. GitHub Actions secrets for the build

**Note:** `.github/workflows/build-apk.yml` is owned by another
coordinator — do NOT edit it here. Ask them to add these two lines to
the `flutter build apk` step (values from Project Settings → API,
stored as GitHub repo secrets, never pasted in the workflow file):

```yaml
run: flutter build apk --release --target-platform android-arm64 \
  --dart-define=SUPABASE_URL=${{ secrets.SUPABASE_URL }} \
  --dart-define=SUPABASE_ANON_KEY=${{ secrets.SUPABASE_ANON_KEY }}
```

GitHub repo → Settings → Secrets and variables → Actions → New
repository secret: `SUPABASE_URL` and `SUPABASE_ANON_KEY`.
Without them the build still compiles, but the app runs in offline v1
mode (`SupabaseConfig.isConfigured == false`).

## 9. Launch-day smoke test

1. Sign up in the app with a test Gmail → confirmation email arrives
   (proves custom SMTP works — if it doesn't, nothing else matters).
2. Forgot password → reset email arrives → `officerpath://reset-password`
   opens the app.
3. Admin (owner) issues a code for the test user via `issue-code` →
   buyer gets the email → redeem in the app → Premium until the right date.
4. Redeem the same code again → "code istemal ho chuka" (single-use works).
5. Delete the test account from the app → user gone from
   Authentication → Users.
