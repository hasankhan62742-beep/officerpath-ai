# Supabase Free keep-alive

## The rule

A Supabase **Free** project is **paused after 1 week of inactivity**
(no API, database or Auth traffic). A paused project refuses sign-ins
until the owner resumes it in the Dashboard (Project → Resume). The
keep-alive below exists so a quiet week never locks users out.

## Mechanism 1 — daily cron (the reliable one)

Ping the cheapest REST read once a day. It needs the **anon key only**
(public key — but still keep it in the cron environment, never in a
shared file or chat message).

```bash
# Daily cron (crontab: 0 9 * * * — 09:00 PKT). SUPABASE_URL and
# SUPABASE_ANON_KEY come from the cron environment, never hard-coded.
curl -s -o /dev/null -w "%{http_code}\n" \
  "$SUPABASE_URL/rest/v1/profiles?select=id&limit=1" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY"
```

Expected output: `200`. Anything else (e.g. `404` = wrong URL,
`401` = wrong key, `000` = no network) means the project may already
be paused or the credentials are wrong — check the Dashboard.

The URL is built by `KeepAlive.keepAliveUrl` in
`lib/services/keep_alive.dart`; health is judged by
`KeepAlive.isHealthyResponse` (HTTP 200 + a JSON-array body — `[]`
counts as healthy, the table may just have no anon-visible rows).

## Mechanism 2 — the app itself (backup, not a replacement)

On launch, when the user is logged in, the app runs a lightweight
`profiles` select (its own profile row). That is real API traffic and
counts as activity — so any week with at least one logged-in user
opening the app keeps the project alive on its own. But it cannot be
relied on before launch, during holidays, or if every user logs out,
which is why the daily cron is the primary mechanism.

## If the project pauses anyway

Dashboard → project → **Resume** (or "Restore"). It takes a few
minutes; no data is lost. Then check why the cron missed (key rotated?
cron host down?) and re-run the curl above to confirm `200`.
