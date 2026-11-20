// ============================================================
// OfficerPath AI v2.0.0 — Edge Function: redeem-code
// POST { "code": "OP1-ABCDEF" }  (Authorization: Bearer <user JWT>)
// Returns { ok: true, plan: "premium", premium_until: "<ISO>" }
// or { ok: false, error: "<code>" } with a 4xx status.
//
// REQUIRED SECRETS (Supabase Dashboard -> Edge Functions -> Secrets):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
//   These three are auto-injected by Supabase for hosted functions;
//   set them explicitly only if you self-host.
// NO secret is ever sent to, or stored in, the app.
//
// HOW IT WORKS:
// 1. The caller's JWT is verified with the anon client (auth.getUser).
// 2. The submitted code is SHA-256 hashed; only the hash is looked up.
//    The plain code is never stored in the database.
// 3. On success the code is marked used (single-use), bound to the
//    caller if it was unbound, and profiles.plan becomes 'premium'
//    with premium_until extended from the existing date when the user
//    is already Premium (never shortened).
//
// ERROR STRINGS (the app maps these to Roman Urdu messages):
//   unauthorized | invalid_code | code_not_found | code_already_used
//   code_expired | code_not_yours | rate_limited
//
// RATE LIMIT (L2): at most REDEEM_ATTEMPTS_PER_HOUR redeem attempts
// per caller per hour, logged in public.redeem_attempts (migration
// 011). Exceeding it returns 429 rate_limited. The throttle is
// FAIL-OPEN: if logging/counting errors (e.g. the table is not
// applied yet), the error is logged and the redeem proceeds — a
// throttle failure must never block a legitimate redeem.
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const CODE_RE = /^OP([123])-([A-Z2-9]{6})$/;
const MONTHS: Record<string, number> = { "1": 1, "2": 2, "3": 12 };
const REDEEM_ATTEMPTS_PER_HOUR = 10;
const REDEEM_ATTEMPT_WINDOW_MS = 60 * 60 * 1000;

async function sha256Hex(input: string): Promise<string> {
  const data = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(input),
  );
  return [...new Uint8Array(data)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ ok: false, error: "method_not_allowed" }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !anonKey || !serviceKey) {
    return json({ ok: false, error: "server_misconfigured" }, 500);
  }

  // 1. Verify the caller's JWT. The anon client forwards the
  // Authorization header, so getUser() authenticates the caller.
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: authError } = await userClient.auth
    .getUser();
  if (authError || !user) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }

  // 1b. Per-user attempt throttle (L2): at most
  // REDEEM_ATTEMPTS_PER_HOUR attempts per rolling hour. Every
  // attempt is logged first, then counted — so brute-force guessing
  // of codes is capped at 10/hour per account. FAIL-OPEN: any error
  // in the throttle itself is logged and the redeem proceeds, so a
  // throttle failure (e.g. migration 011 not applied yet) can never
  // block a legitimate redeem.
  const admin = createClient(supabaseUrl, serviceKey);
  try {
    const windowStart = new Date(Date.now() - REDEEM_ATTEMPT_WINDOW_MS)
      .toISOString();
    const { error: logError } = await admin
      .from("redeem_attempts")
      .insert({ user_id: user.id });
    if (logError) throw logError;
    const { count, error: countError } = await admin
      .from("redeem_attempts")
      .select("id", { count: "exact", head: true })
      .eq("user_id", user.id)
      .gte("attempted_at", windowStart);
    if (countError) throw countError;
    if ((count ?? 0) > REDEEM_ATTEMPTS_PER_HOUR) {
      return json({ ok: false, error: "rate_limited" }, 429);
    }
  } catch (e) {
    console.error("redeem-code throttle check failed (fail-open):", e);
  }

  // 2. Validate + hash the code.
  let body: { code?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "invalid_code" }, 400);
  }
  const rawCode = typeof body.code === "string"
    ? body.code.trim().toUpperCase().replaceAll(" ", "")
    : "";
  const match = CODE_RE.exec(rawCode);
  if (!match) {
    return json({ ok: false, error: "invalid_code" }, 400);
  }
  const months = MONTHS[match[1]];
  const codeHash = await sha256Hex(rawCode);

  // 3. Look the code up by hash. The service-role client (created
  // above, step 1b) bypasses RLS; activation_codes has NO client
  // policies, so this is the only way in.
  const { data: codeRow, error: lookupError } = await admin
    .from("activation_codes")
    .select("id, plan, months, user_id, expires_at, used_at")
    .eq("code_hash", codeHash)
    .maybeSingle();
  if (lookupError) {
    return json({ ok: false, error: "server_error" }, 500);
  }
  if (!codeRow) {
    return json({ ok: false, error: "code_not_found" }, 404);
  }
  if (codeRow.used_at) {
    return json({ ok: false, error: "code_already_used" }, 409);
  }
  if (new Date(codeRow.expires_at).getTime() < Date.now()) {
    return json({ ok: false, error: "code_expired" }, 410);
  }
  if (codeRow.user_id && codeRow.user_id !== user.id) {
    return json({ ok: false, error: "code_not_yours" }, 403);
  }

  // 4. Extend Premium from the existing premium_until when the user is
  // already Premium and it lies in the future; otherwise start now.
  const { data: profile } = await admin
    .from("profiles")
    .select("premium_until")
    .eq("id", user.id)
    .maybeSingle();
  const existingUntil = profile?.premium_until
    ? new Date(profile.premium_until).getTime()
    : 0;
  const base = Math.max(existingUntil, Date.now());
  const premiumUntil = new Date(base);
  premiumUntil.setMonth(premiumUntil.getMonth() + (codeRow.months ?? months));

  // 5. Mark the code used (single-use) and grant Premium.
  // M1 fix: the claim must affect exactly one row. A PostgREST
  // UPDATE matching zero rows returns success with an empty array
  // and NO error, so checking only the error let two simultaneous
  // redeems of one code both succeed. Appending .select() and
  // requiring exactly one returned row makes the loser fail with
  // code_already_used: the .is("used_at", null) predicate means only
  // the first claim matches a row.
  const { data: claimed, error: useError } = await admin
    .from("activation_codes")
    .update({
      user_id: user.id,
      used_at: new Date().toISOString(),
      used_by: user.id,
    })
    .eq("id", codeRow.id)
    .is("used_at", null)
    .select("id");
  if (useError || !claimed || claimed.length !== 1) {
    // Either the update errored, or another request redeemed it a
    // moment ago (zero rows matched) — either way the code is gone.
    return json({ ok: false, error: "code_already_used" }, 409);
  }
  const { error: profileError } = await admin
    .from("profiles")
    .update({
      plan: "premium",
      premium_until: premiumUntil.toISOString(),
    })
    .eq("id", user.id);
  if (profileError) {
    return json({ ok: false, error: "server_error" }, 500);
  }

  return json({
    ok: true,
    plan: "premium",
    premium_until: premiumUntil.toISOString(),
  });
});
