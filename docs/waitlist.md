# OfficerPath AI v2 — Waitlist

> **CURRENT PLAN (19 Nov ~16:46 PKT) — GOOGLE FORM, no GitHub Pages, no FormSubmit.**
> The waitlist is a Google Form created by the user (title "OfficerPath AI — Version
> 2 Waitlist", one Gmail question with email validation, responses linked to a Google
> Sheet — the Sheet IS the list). The FormSubmit page (`waitlist-index.html`) and the
> Supabase page (`docs/index.html`) are BOTH superseded — do NOT deploy either.
> What stays: the Supabase `waitlist` table (migration 005) + the admin panel waitlist
> view (list + count + CSV export) are the permanent home. At v2, the Sheet emails are
> IMPORTED into the table (steps below). Until the import, the SOURCE is the Google
> Sheet. The rest of this doc's GitHub Pages / FormSubmit sections are historical —
> do not follow them.

## Import — Google Sheet → Supabase `waitlist` table (at v2 / when Supabase exists)

1. Open the responses Google Sheet → **File → Download → Comma-separated values
   (.csv)**. The Sheet has at least a Timestamp column and the Gmail column.
2. Open the CSV, keep ONLY the email column (delete the Timestamp column and any
   other columns). Save it. (The import dedupes anyway — see step 4 — so a few
   duplicate rows are harmless, but one email per row is required.)
3. In Supabase Dashboard → **SQL Editor** → New query. Build the INSERT statements
   from the CSV with a spreadsheet formula in a helper column (assuming emails are in
   column A, row 2 onwards):
   `="INSERT INTO waitlist (email, source) VALUES ('"&A2&"', 'google-form-import') ON CONFLICT (email) DO NOTHING;"`
   Copy the helper column down for every row, then copy the generated statements and
   paste them into the SQL Editor → **Run**. (For a handful of addresses, type the
   statements by hand in the same shape.)
4. Verify: `SELECT count(*) FROM waitlist;` — the count must equal the number of
   UNIQUE emails in the Sheet. Spot-check a few rows. Then open the admin panel →
   Waitlist section: the count and list must match, and **Export CSV** must download
   the same emails.
5. Re-run the import at v2 launch to catch late Form responses (ON CONFLICT skips
   the ones already imported — no duplicates, no rework).
6. After the launch email goes out, the Sheet stays as the original record; the
   Supabase table is the working list from then on.


> **INTERIM — parent-built FormSubmit page (19 Nov ~16:43 PKT).** The live waitlist
> page is `waitlist-index.html` (built by the parent, NOT rebuilt here): single static
> HTML, navy/gold, Roman Urdu, form posts to
> `https://formsubmit.co/hello@abdulqadeerml.com` as the INTERIM backend until
> Supabase exists. Upload it to the repo as `docs/index.html` (GitHub Pages source:
> main + `/docs`) — the local filename is `waitlist-index.html`, the repo path must be
> `docs/index.html`. The `docs/index.html` described below (Supabase version, built by
> Worker 6) is SUPERSEDED as the publish file — keep it as the Supabase-ready version
> for the later switch. **FormSubmit needs a ONE-TIME ACTIVATION click:** after the
> page goes live, submit a test email, open the hello@ inbox, find the FormSubmit
> confirmation email and click its activation link — submissions are NOT delivered
> until that is done. Then re-test. **Migration duty (unchanged):** when Supabase
> exists, the emails collected via FormSubmit (they arrive as emails to hello@) are
> migrated into the Supabase `waitlist` table (migration 005) and shown in the admin
> panel (list + count + CSV export). The FormSubmit backend is temporary — the
> Supabase table is the permanent home. Migration: collect the sender addresses from
> the hello@ inbox (one per FormSubmit email), then in Supabase SQL Editor run
> `INSERT INTO waitlist (email, source) VALUES ('a@gmail.com', 'formsubmit-import'),
> ('b@gmail.com', 'formsubmit-import') ON CONFLICT (email) DO NOTHING;` — dedupe is
> enforced by the UNIQUE constraint. Verify the count in Table Editor + the admin panel.

Why this exists: the v1.2.0 download is being stopped (the APK asset is
being deleted from the GitHub release). The old shared link was a GitHub
release **asset URL** — a file endpoint, not a page — so it can never
become a form. From now on, anyone who arrives must enter their Gmail
on the waitlist page; the emails build the list for the v2 launch.

- **Waitlist page:** `docs/index.html` (single self-contained file:
  inline CSS + JS, Supabase JS via CDN only)
- **Live URL (after setup below):**
  `https://hasankhan62742-beep.github.io/officerpath-ai/`
- **Table:** `waitlist` — see
  `supabase/migrations/005_waitlist.sql` (run order 001 → 002 → 003 →
  004 → 005)
- **Admin view:** snippets in `admin/waitlist-section.html` +
  `admin/waitlist-section.js` — paste them in as described in
  § 4 below. They are snippets, not edits: `admin/index.html` and
  `admin/app.js` were **not** changed by this work (another worker
  was editing them at the same time).

## 1. What the page does

- Headline: "OfficerPath AI v2 jald aa raha hai" (Roman Urdu + English
  copy). Navy `#0B1F3A` + gold `#C9A227`.
- One email input + submit button. The subline says, in one short
  line, that v2 brings login, admin panel and tests from books in
  every format — no feature promises beyond what v2 is building.
- Email format is validated in the page; garbage gets a plain
  Roman Urdu message ("Sahi email likhein — jaise name@gmail.com").
- On submit it inserts `{email, source: 'waitlist-page'}` into the
  Supabase `waitlist` table.
  - Success: "Shukriya! v2 aate hi aap ko email kar dein ge."
  - Already registered (Supabase unique violation, code 23505):
    "Ye email pehle se list mein hai — v2 aate hi aap ko email milega."
  - Anything else (network failure, or the CONFIG block not filled
    in yet): "Kuch masla hua — dobara koshish karein". Never a silent
    failure.
- Privacy line on the page: the email is used only for the v2 launch
  and is never shared with anyone.
- No download button, no Play Store claims, no Muse link anywhere.

## 2. GitHub Pages setup — exact steps (browser handover)

Do these in the browser, signed in to the GitHub account that owns
`hasankhan62742-beep/officerpath-ai`. No terminal, no git needed.

### Step 1 — Upload the page file

1. Open the repo on github.com:
   `github.com/hasankhan62742-beep/officerpath-ai`
2. Click **Add file → Create new file**.
3. In the filename box type exactly: `docs/index.html`
4. Paste the entire contents of `docs/index.html` from this repo
   into the editor.
5. Click **Commit changes** (commit directly to the `main` branch).

### Step 2 — Turn on GitHub Pages

1. In the repo, click **Settings** (top bar).
2. Left sidebar → **Pages**.
3. Under **Build and deployment → Source**, choose
   **Deploy from a branch**.
4. **Branch:** `main`, folder: `/docs` → click **Save**.

### Step 3 — Verify

1. Wait about 1 minute.
2. Open `https://hasankhan62742-beep.github.io/officerpath-ai/`
3. You should see the navy + gold page with the headline
   "OfficerPath AI v2 jald aa raha hai" and one email box.
   - If GitHub shows a 404, wait another minute and reload; Pages
     takes a few minutes on first publish. If it still 404s after
     10 minutes, check Step 2 again (branch `main`, folder `/docs`).

### Step 4 — Fill in the CONFIG block (Supabase values)

The page ships with placeholders only — it cannot save any email
until these are filled in. Do this after Step 3 works:

1. Open Supabase Dashboard → your OfficerPath project →
   **Settings → API**.
2. Copy **Project URL** and the **anon / publishable key**
   (never the `service_role` secret key).
3. On GitHub, open the repo → `docs/index.html` → click the pencil
   (**Edit this file**).
4. At the very top of the file, replace the two placeholder lines:
   ```js
   const SUPABASE_URL = 'YOUR_SUPABASE_URL';
   const SUPABASE_ANON_KEY = 'YOUR_SUPABASE_ANON_KEY';
   ```
   with the real values, e.g.
   ```js
   const SUPABASE_URL = 'https://YOUR-PROJECT.supabase.co';
   const SUPABASE_ANON_KEY = 'eyJ…'; // anon key from Settings → API
   ```
5. **Commit changes**.
6. Wait ~1 minute, reload the waitlist page, and test it with your
   own Gmail: you should see "Shukriya! v2 aate hi aap ko email kar
   dein ge." — then check the `waitlist` table in Supabase →
   Table Editor to confirm the row arrived. (Submit the same email
   again to check the already-registered message.)
7. **If the anon key is ever rotated**, repeat this step with the new
   key — the page must be re-edited, it does not pick the new key up
   on its own.

### Fallback — if GitHub Pages is troublesome

Use Cloudflare Pages drag-and-drop (same method as the admin panel
in `admin/README.md`):

1. On your computer, take the repo's `docs/` folder (it contains
   only `index.html` plus these docs).
2. Go to https://dash.cloudflare.com → **Workers & Pages** →
   **Create** → tab **Pages** → **Upload assets** (direct upload).
3. Name the project `officerpath-waitlist` → **Create project**.
4. Drag the `docs/` folder onto the upload box → **Deploy site**.
5. Cloudflare gives a URL like
   `https://officerpath-waitlist.pages.dev` — that becomes the
   waitlist link instead of the GitHub Pages URL. Use that URL in
   the release notes and social posts (replace the GitHub Pages URL
   in `docs/waitlist-release-notes.md` before pasting).
6. The CONFIG block is filled in the same way (edit `index.html`
   before uploading, or re-upload the folder after editing).

## 3. Supabase — run migration 005

In Supabase Dashboard → **SQL Editor** → New query → paste
`supabase/migrations/005_waitlist.sql` → **Run**. Run it **after**
001, 002, 003 and 004 (004 exists in this repo). It creates the
`waitlist` table with a `UNIQUE` email, an email-shape CHECK, and
Row Level Security: anon may INSERT only, admins (via the existing
`is_admin()` helper from 002) may SELECT. No `service_role` key is
involved anywhere — the page uses the anon key only.

Verify: Supabase → Table Editor → `waitlist` shows columns
`id, email, created_at, source`. Submit a test email on the page and
confirm the row appears; submit it again and confirm no second row
is created.

## 4. Admin panel — exact insertion instructions

Do this **after** the other worker's push-notification edits to
`admin/index.html` / `admin/app.js` have landed, so nothing is
overwritten. These snippets add a Waitlist section to the panel
(total count, search, email/date/source table, Export CSV).

### 4a. `admin/index.html` — paste the HTML snippet

Anchor: inside `<div id="app-view">`, right after the Send
notification section closes and **before** the toast paragraph.
The surrounding lines (verbatim from `admin/index.html`) are:

```html
      </section>

      <p id="toast" class="toast hidden" role="status" aria-live="polite"></p>
```

Paste the entire contents of `admin/waitlist-section.html`
between `</section>` and `<p id="toast" …>` — i.e. the new section
is the last section inside `#app-view`, just above the toast line.
No new CSS is needed (it reuses `.card`, `.table-wrap`, `.muted`,
`.hidden`). Do **not** add any `<script>` tag for the JS snippet.

### 4b. `admin/app.js` — wire-up in `boot()`

Anchor: the push-form listener line (verbatim from `admin/app.js`):

```js
    $('push-form').addEventListener('submit', sendPushNotification);
```

Immediately **after** that line, add these two lines:

```js
    $('waitlist-search').addEventListener('input', renderWaitlist);
    $('waitlist-export-btn').addEventListener('click', exportWaitlistCsv);
```

### 4c. `admin/app.js` — load the list in `loadAll()`

Anchor: the `loadAll()` function (verbatim from `admin/app.js`):

```js
  function loadAll() {
    loadStats();
    loadSignups();
    loadUsers();
    loadPayments();
    loadCodes();
    loadPushHistory();
  }
```

Add one line inside it, after `loadPushHistory();`:

```js
    loadPushHistory();
    loadWaitlist();
```

(`loadAll()` is only called after `checkAdmin()` confirms
`profiles.is_admin`, so the waitlist only ever loads for admins —
and RLS enforces the same rule server-side.)

### 4d. `admin/app.js` — paste the functions

Anchor: the codes-table section header (verbatim from
`admin/app.js`):

```js
  /* ---------------- codes table ---------------- */
```

Paste the entire contents of `admin/waitlist-section.js`
**immediately before** that line — i.e. after the end of
`loadPushHistory()` and before the codes-table comment. The
snippet must sit **inside** the file's outer IIFE
(`(function () { … })();`) so it can use the existing `$`, `esc`,
`fmtDate`, `toast`, `client` and `adminUser` helpers. Do not wrap
it in a second IIFE and do not load it as a separate script file.

### 4e. Verify the integration

1. Re-deploy the admin panel (Cloudflare Pages → re-upload the
   `admin/` folder, as in `admin/README.md`).
2. Sign in as admin — a **Waitlist — v2 launch list** section
   appears with the total count.
3. Submit a test email on the waitlist page, reload the panel:
   the email appears in the table.
4. Type part of the email in the search box — the table filters.
5. Click **Export CSV** — a file `officerpath-waitlist.csv`
   downloads with `email,created_at,source` columns.

## 5. v2 launch plan (do NOT send anything now)

At v2 launch — and only then:

1. Open the admin panel → **Waitlist** section → **Export CSV**.
   That file is the launch list.
2. Email everyone on it the v2 download link **from
   `hello@abdulqadeerml.com`** (the standing sales-email identity —
   never from the personal Gmail). One email to the whole list
   (BCC the addresses; do not expose the list to itself).
3. The email text for launch day is written at launch time; the
   release-notes text for *now* (downloads paused) is in
   `docs/waitlist-release-notes.md`.
4. After the launch email goes out, the waitlist has done its job —
   keep the table (do not delete it) as the record of who asked.
