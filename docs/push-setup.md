# OfficerPath AI v2.0.0 — Push Notifications Setup (FCM)

Push notifications (Firebase Cloud Messaging) let the admin announce a
new version — or send a short announcement — to users who have the app
installed. Push is **only the announcement**: tapping an update
notification opens the About screen, whose "Check for updates" runs
the in-app updater (GitHub release → APK download → system installer).
Push never installs anything itself.

**Delivery status: UNVERIFIED.** Everything below is built and
unit-tested, but no notification has ever been delivered to a real
phone. Do not claim push works until the manual phone test in
§ 8 passes.

**Cost:** Firebase Cloud Messaging is free on the Firebase Spark
(no-cost) plan — no card, no billing needed for sending.

**No credentials in this repo.** The only Firebase secret is the
service-account JSON key, and it lives ONLY as a Supabase Edge
Function secret (set in the Dashboard, § 4). It is never committed,
never pasted into the app, the admin panel, or any file.

## Files involved

| File | What it is |
| --- | --- |
| `lib/services/push_service.dart` | App side: Firebase init (guarded), token registration + refresh, permission (asked once, after first Home open), foreground SnackBar, tap routing, opt-out. Pure helpers: `buildUpdatePayload`, `buildAnnouncementPayload`, `shouldSendToUser`, `parseNotificationTap`, `buildTokenUpdate`. |
| `supabase/migrations/004_push_notifications.sql` | `profiles.fcm_token`, `fcm_token_updated_at`, `notifications_enabled` + the `sent_notifications` log table (admins only). |
| `supabase/functions/send-notification/index.ts` | Admin-only Edge Function: reads opted-in recipients, sends one FCM HTTP v1 message per token, logs the send. |
| `admin/index.html` + `admin/app.js` | "Send notification" section + sent history. |
| `android/app/src/main/AndroidManifest.xml` | `POST_NOTIFICATIONS` permission (Android 13+) + default notification icon/channel metadata. |
| `android/app/google-services.json` | **PLACEHOLDER — replace with the real file (§ 2).** Every value is `REPLACE-ME`. The app treats a placeholder/missing config as "push disabled", never a crash. |
| `test/push_service_test.dart`, `test/push_admin_test.dart` | Unit + static tests (mocked FCM, no network). |

---

## 1. Create the Firebase project

1. Open https://console.firebase.google.com and sign in with the
   Google account that owns OfficerPath (the same account used for
   the Google sign-in / Play work if any).
2. **Add project** → name it `OfficerPath AI` → Continue.
3. **Google Analytics: OFF** (pick: not needed — push does not need
   Analytics, and keeping it off avoids the extra consent/data
   surface). Click **Create project**, wait, then **Continue**.

## 2. Register the Android app + download google-services.json

1. In the Firebase project, click the **Android** icon
   ("Add app" → Android).
2. **Android package name:** `com.qadeerautomations.officerpath`
   (exactly — this is the `applicationId` in
   `android/app/build.gradle.kts`).
3. **App nickname:** `OfficerPath AI` (optional, any name).
4. **Debug signing certificate SHA-1:** leave blank for now. (SHA-1
   is needed only for Google Sign-In / Dynamic Links, not for FCM.
   The app's Google sign-in already works without it in this setup;
   add the release SHA-1 later if Google sign-in ever requires it.)
5. Click **Register app**.
6. **Download `google-services.json`** and replace the placeholder at
   `android/app/google-services.json` in the repo with the real file.
   Delete every `REPLACE-ME` value — none of them may survive.
7. Click **Next** through the SDK steps — the SDK is already in the
   app (`firebase_core` + `firebase_messaging` in `pubspec.yaml`).

### CI note (release builds)

The release workflow (`.github/workflows/build-apk.yml`, owned by
another coordinator — do NOT edit it) needs the real
`google-services.json` at build time. Two options, pick one:

- **Option A — commit the real file (simplest).** `google-services.json`
  contains only public client identifiers (project id, API key for
  the Android app). It is NOT a secret credential — Firebase's own
  docs treat it as safe to include in a client app — but it must be
  the REAL file, not the placeholder. Replace
  `android/app/google-services.json` and commit it.
- **Option B — CI secret (cleaner).** In GitHub → the repo →
  **Settings → Secrets and variables → Actions → New repository
  secret**, name `GOOGLE_SERVICES_JSON`, value = the entire contents
  of the real `google-services.json` file. Then the workflow must add
  one step before the Flutter build:
  ```yaml
  - name: Restore google-services.json
    run: echo '${{ secrets.GOOGLE_SERVICES_JSON }}' > android/app/google-services.json
  ```
  (That step is a workflow change for the workflow owner, not part
  of this push work.)

If neither is done, a release build either fails (missing file) or
ships with push disabled (placeholder file) — the app still works,
it just never receives notifications.

### The google-services plugin (Gradle)

The project does **not** currently apply the Google Services Gradle
plugin. A real build needs it. The exact lines (for the workflow /
build owner — the plugin + the real `google-services.json` are both
needed for a real build):

1. In `android/settings.gradle.kts`, inside the `plugins { … }` block,
   add:
   ```kotlin
   id("com.google.gms.google-services") version "4.4.2" apply false
   ```
2. In `android/app/build.gradle.kts`, inside the `plugins { … }` block,
   add:
   ```kotlin
   id("com.google.gms.google-services")
   ```

These lines were deliberately NOT added by the push worker: they
only take effect with the real `google-services.json` in place, and
the file is a placeholder until the browser handover (§ 2) replaces
it. Add the plugin lines at the same time as the real file.

## 3. Enable the Cloud Messaging API

1. In the Firebase console, open the project → left menu →
   **Build → Cloud Messaging** (or Project settings → Cloud
   Messaging tab).
2. If it shows "Cloud Messaging API (Legacy) — Disabled" or asks to
   enable the API, click **Enable** / follow the link to the Google
   Cloud console and enable **Firebase Cloud Messaging API** for
   this project. (FCM HTTP v1 — the API the Edge Function uses —
   needs this API enabled; the legacy server-key API must stay OFF
   and is never used.)
3. No server key is needed anywhere. If the console shows a "Server
   key" under Cloud Messaging (legacy), **ignore it and never copy
   it** — the legacy key is not used by this project, and putting it
   in code would be a credential leak.

## 4. Create the service account + set the Supabase secrets

The Edge Function sends as the Firebase project, using a
service-account key. The key lives ONLY as a Supabase secret.

1. Firebase console → **Project settings** (gear icon) →
   **Service accounts** tab.
2. Click **Generate new private key** → **Generate key**. A JSON file
   downloads. **This file is a credential — never commit it, never
   email it, never paste it into any repo file.**
3. Supabase Dashboard → your project → **Edge Functions** (left menu)
   → **Secrets** (or Settings → Edge Functions → Secrets, depending
   on the Dashboard version) → **Add secret**:
   - Name: `FIREBASE_SERVICE_ACCOUNT`
   - Value: the **entire contents** of the downloaded JSON file
     (raw JSON, or base64-encoded JSON — the function accepts both).
4. Optional second secret (only if the Firebase project id differs
   from the one inside the JSON — normally it does not):
   - Name: `FIREBASE_PROJECT_ID`
   - Value: the Firebase project id (e.g. `officerpath-ai-xxxxx`).
5. `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`
   are auto-injected by Supabase for hosted functions — do not set
   them by hand.

Secret names (exact): `FIREBASE_SERVICE_ACCOUNT`,
`FIREBASE_PROJECT_ID` (optional).

## 5. Deploy the send-notification function

From the repo root, with the Supabase CLI installed and logged in
(`supabase login`, `supabase link --project-ref <ref>` — see
`docs/supabase-setup.md` for the project setup):

```bash
supabase functions deploy send-notification
```

Verify it deployed:

```bash
supabase functions list
```

You should see `send-notification` in the list. If deploy fails
with a Deno/import error, re-run it — the function has no npm
dependencies (the FCM auth flow is hand-rolled WebCrypto, chosen
because `google-auth-library` does not reliably run in the Deno
Edge runtime).

## 6. Run migration 004

Supabase Dashboard → **SQL Editor** → **New query** → paste the
contents of `supabase/migrations/004_push_notifications.sql` →
**Run**. It must run AFTER migrations 001–003.

Check it worked:

```sql
select column_name, data_type
from information_schema.columns
where table_name = 'profiles'
  and column_name in ('fcm_token', 'fcm_token_updated_at',
                      'notifications_enabled');

select count(*) from public.sent_notifications;
```

The first query must return 3 rows; the second must return 0 (an
empty log table, no error). If `sent_notifications` does not exist,
the migration did not run — re-paste and re-run it.

## 7. Test send from the admin panel

1. Re-deploy the admin panel (Cloudflare Pages → `officerpath-admin`
   project → **Create deployment** → drag the `admin/` folder again),
   so the new "Send notification" section is live.
2. Sign in to the admin panel as the admin.
3. Scroll to **Send notification**. Fill in a test:
   - Title: `Test notification`
   - Message: `Ye OfficerPath AI ki test notification hai.`
   - Audience: **All users**
   - Type: **Announcement**
4. Click **Send notification**, confirm, and check the result line:
   it must say how many users it was sent to (e.g. `Sent to 1
   user(s) (1 delivered)`). The send must also appear under **Sent
   history**.
5. If it says `0 user(s)`, nobody has a token yet — that is expected
   before any phone has run v2 with notifications on. Run the phone
   test (§ 8) first, then re-send.

## 8. Manual verification on a real phone (REQUIRED — delivery UNVERIFIED until this passes)

Do this on a real Android phone with the v2 APK installed from the
release build (with the real `google-services.json` + the
google-services plugin, § 2):

1. Install v2, log in, open Home. When the "Notifications on
   karein?" dialog appears, tap **Allow karein** and allow the
   system permission.
2. In Supabase → Table Editor → `profiles`, find your own row:
   `fcm_token` must be filled (a long token string) and
   `notifications_enabled` must be `true`. If `fcm_token` is empty,
   push cannot reach this phone — check the real
   `google-services.json` and the plugin lines first.
3. From the admin panel, send an **Announcement** to **All users**.
   The notification must arrive on the phone (tray + banner).
   Tapping it must open the app on Home.
4. From the admin panel, send a **New version available** with
   version `2.0.0` to **All users**. Tapping it must open the About
   screen (which shows "Check for updates").
5. **Opt-out check (mandatory):** on the phone, go to Profile →
   Account settings → turn **Notifications** OFF. In `profiles`,
   `notifications_enabled` must now be `false` and `fcm_token` must
   be empty (the app deletes it). Send another announcement from the
   admin panel — it must NOT arrive on the phone. Turn notifications
   back ON and confirm a new send arrives again.
6. **Foreground check:** with the app open on Home, send an
   announcement — an in-app SnackBar must appear (FCM does not show
   a tray banner for foreground messages; the app shows its own).
7. Only when steps 3–6 all pass, mark delivery VERIFIED (note the
   date + phone model in the release notes). Until then the honest
   status is: **push built and unit-tested, real-device delivery
   UNVERIFIED**.

## Troubleshooting

| Symptom | Likely cause → fix |
| --- | --- |
| App works but no token in `profiles` | Placeholder `google-services.json` still in place, or the google-services plugin lines (§ 2) missing → replace the file + add the plugin, rebuild. |
| Admin send says `server_misconfigured` | `FIREBASE_SERVICE_ACCOUNT` secret missing or not valid JSON → re-set it (§ 4). |
| Admin send says `fcm_auth_failed` | Service-account key is for the wrong project, or the Cloud Messaging API is disabled → re-check § 3 and § 4 (key must be from the SAME Firebase project as `google-services.json`). |
| Admin send says `forbidden_not_admin` | Signed-in panel account is not `is_admin` → set `is_admin = true` for it in `profiles`. |
| Send says `0 user(s)` | No opted-in tokens yet → run the phone test (§ 8 step 2) first. |
| Notification arrives but tap does nothing | App version predates the tap handling, or the payload type was not `update_available` → check the send type in Sent history. |
| Opted-out user still receives | The send used an old build of the function, or the token was not deleted → check `notifications_enabled` in `profiles` and re-deploy the function (§ 5). |

## What push does NOT do

- It never installs an update by itself — the in-app updater does that.
- It never sends to a topic or to "everyone, always" — only to
  stored tokens of opted-in users, one message per token.
- It never uses the legacy FCM server key (`AAAA…`) — that key does
  not exist anywhere in this project, and the tests fail the build
  if such a pattern ever appears in the push files.
