# OfficerPath AI — Admin Panel

Static HTML/CSS/JS admin panel for OfficerPath AI v2. No build step, no
server of your own — it talks straight to Supabase with the anon key.
Free hosting: **Cloudflare Pages (manual drag-and-drop)** — see
[Deploy](#deploy-cloudflare-pages-drag-and-drop) below.

## What it does

- **Admin login** — Supabase Auth email/password. After sign-in the
  panel checks `profiles.is_admin`; non-admins see "Access denied" and
  no data is loaded. (Real enforcement is Row Level Security on the
  server — this is a second, client-side gate.)
- **Dashboard cards** — total users, Premium users, pending payment
  approvals, codes issued, codes used, tests taken.
- **Signups chart** — per-day signups for the last 30 days (plain
  HTML/CSS bars, no chart library).
- **Users table** — search by email/username; columns username, email,
  plan, premium until, tests taken, member since. Click a user for
  their payments, codes and test results.
- **Pending payments queue** — Approve / Reject per payment.
  - **Approve** calls the `issue-code` Edge Function with
    `{user_id, email, plan}`. The generated code is shown **once** in a
    popup with a Copy button, the ready email text, and a mailto link.
    The payment is marked `approved` and linked to the code row.
  - **Reject** sets the payment to `rejected`. You can type an
    optional reason — the v2 `payments` table has no column for it, so
    the reason is **not stored**; it is shown to you so you can paste
    it into your message to the buyer.
- **Codes table** — hash prefix only (never the plain code after
  issue), plan, buyer email, issued/expires dates, status
  (unused / used / expired).
- **Revoke Premium** — on a user detail view, sets `plan = 'free'` and
  `premium_until = null` (with a confirm dialog).
- **Send notification** — push notification to installed users via
  the `send-notification` Edge Function: title + message, audience
  (All / Premium only / Free), type (New version available /
  Announcement, with a version field for updates), confirm dialog,
  and a sent-history list from `sent_notifications`. Only opted-in
  users with a device token receive it — the function re-checks the
  opt-out flag server-side. Needs migration
  `004_push_notifications.sql` run and the function deployed with
  its `FIREBASE_SERVICE_ACCOUNT` secret (see
  `docs/push-setup.md`).

## Files

| File | What it is |
| --- | --- |
| `index.html` | The panel page (loads Supabase JS from CDN, then `config.js`, then `app.js`). |
| `app.js` | All panel logic. No credentials in here — only the config values from `config.js`. |
| `styles.css` | Navy + gold styling, same as the app. |
| `config.example.js` | Placeholders ONLY. Copy it to `config.js` and fill in the real values. |
| `config.js` | **You create this at deploy time. Never commit it.** (Listed in `.gitignore`.) |
| `.gitignore` | Keeps `config.js` out of git. |

## Deploy — Cloudflare Pages (drag-and-drop)

No account charges, no build, free HTTPS. You need a free Cloudflare
account (sign up at dash.cloudflare.com with your email).

1. **Make `config.js`.** In this `admin/` folder, copy
   `config.example.js` to `config.js` and open it. Replace the two
   placeholders with the real values from your Supabase Dashboard →
   **Settings → API**:
   - `SUPABASE_URL` → **Project URL** (looks like
     `https://abcdefgh.supabase.co`)
   - `SUPABASE_ANON_KEY` → **anon public** key (the long `eyJ…` key
     labelled "anon public" — **never** the `service_role` secret key)
   Save the file. Double-check you did NOT paste the service_role key.
2. **Open Cloudflare Pages.** Go to https://dash.cloudflare.com →
   **Workers & Pages** (left sidebar) → **Create** → tab **Pages** →
   **Upload assets** (the "direct upload" option — *not* "Connect to
   Git").
3. **Name the project.** Project name: `officerpath-admin` → **Create
   project**.
4. **Upload the folder.** Drag the whole `admin/` folder — with your
   new `config.js` inside it — onto the upload box (or click
   **Select from computer** and pick the folder). Wait for the upload
   to finish, then click **Deploy site**.
5. **Open the site.** Cloudflare gives you a URL like
   `https://officerpath-admin.pages.dev`. Open it — you should see the
   admin sign-in form. Bookmark it.
6. **Sign in.** Use the admin email + password you created in
   Supabase Auth (the account whose `profiles.is_admin` is `true`).
   If you see "Access denied", that account is not flagged admin —
   set `is_admin = true` for it in Supabase → Table Editor →
   `profiles`, then sign in again.

### Updating the panel later

Change the files in `admin/`, then in Cloudflare Pages open the
`officerpath-admin` project → **Create deployment** → drag the folder
again. The URL stays the same.

### If config.js is missing or wrong

The panel shows a "Setup needed" box instead of the sign-in form.
That means `config.js` was not uploaded, or it still has the
`YOUR-PROJECT` / `YOUR-ANON-KEY` placeholders. Re-do step 1 and
re-deploy.

## Send notification (push, v2.0.0)

The **Send notification** section announces a new version or sends an
announcement to users who have the app installed and notifications
turned on.

1. Fill in **Title** and **Message**.
2. Pick the **Audience**: All users / Premium only / Free users.
3. Pick the **Type**: *New version available* (the **Version** field
   appears — e.g. `2.0.0`; tapping the notification opens the
   in-app updater) or *Announcement* (tapping opens Home).
4. Click **Send notification** and confirm. The panel shows how many
   users it was sent to; every send is listed under **Sent history**
   (title, audience, type, date, recipient count).

How it works: the panel calls the `send-notification` Edge Function
with your admin JWT. The function verifies you are an admin, reads
recipients from `profiles` (`notifications_enabled = true` AND
`fcm_token` present, filtered by audience/plan), sends one FCM HTTP
v1 message per token, and logs the send in `sent_notifications`.
Users who turned notifications off in the app's Account settings are
never sent to — the check runs server-side, and the app also deletes
its local token on opt-out.

If sending fails, the panel shows the error. Common causes:
- **server_misconfigured** — the `FIREBASE_SERVICE_ACCOUNT` secret
  is not set on the function (see `docs/push-setup.md` § 4).
- **fcm_auth_failed** — the service-account key is wrong or the
  Firebase project does not match `google-services.json`.
- **forbidden_not_admin** — the signed-in account is not flagged
  `is_admin` in `profiles`.
- The function is not deployed yet — deploy it first
  (`supabase functions deploy send-notification`).

## Security notes

- The panel uses the **anon key only**. It can only do what Row Level
  Security allows for the signed-in admin.
- The `service_role` key must never appear in any file in this folder,
  in git, or in the deployed site. It lives only in Supabase
  Dashboard → Settings → API and in Edge Function secrets.
- The plain activation code exists in exactly one place at exactly
  one moment: the approval popup. After the popup closes it cannot be
  retrieved again — if the buyer loses it, approve a new payment /
  issue a new code.
- If you ever suspect the anon key leaked, rotate it in Supabase →
  Settings → API → **Rotate keys**, then update `config.js` and
  re-deploy.
