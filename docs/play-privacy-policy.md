# OfficerPath AI v2.0.0 — Privacy Policy (Play Store)

> This is the text to publish as the app's public privacy policy (Play
> Console requires a URL — host this content as a public web page and
> paste that URL in Play Console → App content → Privacy policy).
> Last updated: 19 Nov 2026. Contact: the developer, Muhammad Abdul
> Qadeer (see the app's About screen).

## What the app is

OfficerPath AI turns the user's OWN MCQ books / past papers (PDF, DOCX,
TXT, or a phone-camera photo) into timed practice tests in the PPSC /
PMS / CSS / FPSC / KPPSC / BPSC / SPSC pattern. The books never leave
the phone: parsing and test generation happen on-device.

## What the app collects

| Data | When / why | Where it goes |
|---|---|---|
| Email address + username | When the user creates an account (email sign-up or Google sign-in). Needed to log in, to know who a Premium code belongs to, and to send the password-reset email. | Supabase Auth (the app's backend database). Never sold, never shared with advertisers. |
| Test results (exam name, book title, score, total, date) | Only when the user is SIGNED IN: each finished test is also saved to the server as a cloud backup, so results survive a reinstall. The on-device history is the source of truth and works fully offline. Signed-out users: results stay on the phone only. | Supabase `test_results` table. Only the user (and the admin, for support) can see them. |
| Payment proof (plan, payment method, transaction id, email) | Only when the user chooses manual payment (JazzCash / Easypaisa) and submits a proof for review. | Supabase `payments` table. Only the user and the admin can see it. |
| FCM token (push-notification device token) | Only when notifications are ON (opt-in after first login). Lets the admin announce a new version. | Supabase `profiles` table (the token) + Firebase Cloud Messaging (delivery). Turning notifications off in Account settings deletes the token. |
| Gemini API key | Only if the user enters their own key in AI Settings (for the optional Gemini OCR tier). | Stored ON-DEVICE ONLY (Flutter secure storage). It is never sent to the app's server. It is sent to Google's Gemini API only when the user runs that OCR tier. |
| Books / PDFs / photos the user uploads | Parsed on the phone to build tests. | Nowhere — they never leave the device. |

## What the app does NOT collect

- No location, no contacts, no call/SMS data, no advertising ID.
- No third-party tracking SDKs and no ads — nothing in the app reports
  usage to an analytics or advertising company.
- No photos of the user, no microphone, no camera roll access beyond
  the single photo/PDF the user picks for a book.
- The app does not read any other app's data.

## Data sharing

The app shares data with exactly two processors, only for the jobs
above: Supabase (account, Premium codes, test-result backup, payment
proofs) and Google Firebase Cloud Messaging (push delivery) / Google
Gemini (only when the user runs the Gemini OCR tier with their own
key). No data is sold. No data is shared with advertisers or data
brokers. The admin panel (used only by the developer) reads the same
Supabase tables to issue Premium codes, review payment proofs, and
send version announcements.

## Security

All traffic to Supabase and Firebase is over HTTPS (encryption in
transit). Supabase Row Level Security means a signed-in user can only
read/write their own rows; activation codes have NO client access at
all (server Edge Functions only). The Gemini key is kept in the
phone's secure storage, not in the app's database.

## Account deletion (how to delete your account and data)

In the app: **Profile → Account settings → Delete account**. That
calls the server `delete-account` function, which deletes the Auth
user and (by database cascade) the profile, payments, test results
and FCM token. Books and test history stored ON the phone are deleted
when the app is uninstalled. If the in-app delete ever fails, email
the developer (address on the About screen) from the account's email
address and ask for deletion — it is done manually from the Supabase
dashboard.

## Children

The app is a test-preparation tool for adults (CSS / PMS / PPSC
aspirants). It is not directed at children under 13 and does not
knowingly collect data from them.

## Changes

If this policy changes, the new version is published at the same URL
and the app's About screen notes the version it was written for.

---

## Play data-safety form — EXACT answers (copy verbatim)

Fill Play Console → App content → Data safety with these answers.
They must match this policy and the code (`AndroidManifest.xml`,
`lib/services/*`).

- **Does the app collect or share any of the required user data
  types?** YES.
- **Is all of the user data collected by the app encrypted in
  transit?** YES (HTTPS to Supabase / Firebase / Gemini; no plain-HTTP
  endpoints — the only HTTP feed is a last-resort RSS fallback for
  public news headlines, which carries no user data).
- **Can users request that their data be deleted?** YES — in-app
  (Profile → Account settings → Delete account) + by email to the
  developer.
- **Data types collected:**
  - **Personal info — Email address:** Collected. Purpose: account
    management (login, password reset, Premium codes). Optional? NO
    (an account needs an email). Shared? NO (Supabase is the
    processor, not a third-party share — declare as "shared with a
    service provider" if Play's form asks; never with advertisers).
  - **Personal info — User IDs (username):** Collected. Purpose:
    account management (display name / unique username). Shared? NO.
  - **App activity — App interactions (test results: exam, score,
    date):** Collected, only when signed in. Purpose: app
    functionality (cloud backup of results). Shared? NO.
  - **Financial info — Purchase history (manual payment proof:
    method + transaction id):** Collected, only when the user submits
    a payment proof. Purpose: payment processing (manual review by
    the developer). Shared? NO.
  - **Device or other IDs (FCM token):** Collected, only when
    notifications are on. Purpose: notifications (version
    announcements). Shared? YES — with Firebase Cloud Messaging, the
    delivery provider only.
- **Data types NOT collected:** Precise / approximate location,
  contacts, photos and videos (beyond the book the user picks),
  audio, call logs, SMS, health, calendar, advertising ID.
- **Account deletion:** "Users can delete their account and data
  from inside the app (Profile → Account settings → Delete
  account)."

> Note on the Gemini key: it is stored on-device only and is NOT a
> server-collected data type — do not list it as collected data.
> The user's books/PDFs never leave the device — do not list them
> as collected data either.
