// ============================================================
// OfficerPath AI v2.0.0 — Edge Function: send-notification (ADMIN ONLY)
// POST { "title": "...", "body": "...",
//        "audience": "all" | "premium" | "free",
//        "type": "update_available" | "announcement",
//        "version": "2.0.0" }        // required when type = update_available
// Authorization: Bearer <ADMIN's JWT> — the caller must have
// profiles.is_admin = true.
// Returns { ok: true, recipient_count: <tokens attempted>,
//           sent: <delivered>, failed: <failed> }
//
// SENDING — FCM HTTP v1 API (no legacy server key anywhere):
//   1. A Google OAuth2 access token is minted from the service-account
//      credentials with a hand-rolled JWT RS256 flow (WebCrypto —
//      Deno Edge Functions have no google-auth-library, and the npm
//      package pulls Node crypto APIs the Edge runtime does not
//      reliably provide, so the explicit flow below is the approach
//      that genuinely works here).
//   2. One POST per token to
//      https://fcm.googleapis.com/v1/projects/{project_id}/messages:send
//      with { notification: {title, body}, data: {type, version?} }.
//      No topic spam: only tokens of users who opted in.
//   3. The send is logged in sent_notifications (recipient_count =
//      tokens attempted). Failed tokens are counted, not retried:
//      the admin can re-send; a token that FCM reports UNREGISTERED
//      is cleared from profiles so it is never tried again.
//
// OPT-OUT IS MANDATORY: recipients are read with
// notifications_enabled = true AND fcm_token IS NOT NULL, filtered
// by audience/plan. A user who opted out is never sent to, even if
// the admin asks for audience "all".
//
// REQUIRED SECRETS (Supabase Dashboard -> Edge Functions -> Secrets):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
//     (auto-injected by Supabase for hosted functions)
//   FIREBASE_SERVICE_ACCOUNT — the service-account JSON key, as raw
//     JSON or base64-encoded JSON. Create it in the Firebase console:
//     Project settings -> Service accounts -> Generate new private
//     key. NEVER commit it anywhere.
//   FIREBASE_PROJECT_ID — optional override; when unset, project_id
//     is read from the service-account JSON.
// ERROR STRINGS: unauthorized | forbidden_not_admin | invalid_request
//   | server_misconfigured | fcm_auth_failed
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// ---------- base64 helpers (Deno has atob/btoa, no Buffer) ----------

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

function base64DecodeToBytes(input: string): Uint8Array {
  const clean = input.replace(/\s+/g, "");
  const binary = atob(clean);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

// ---------- service-account parsing ----------

interface ServiceAccount {
  client_email: string;
  private_key: string;
  project_id: string;
}

function parseServiceAccount(raw: string): ServiceAccount | null {
  let text = raw.trim();
  // Accept base64-encoded JSON as well as raw JSON.
  if (!text.startsWith("{")) {
    try {
      text = new TextDecoder().decode(base64DecodeToBytes(text));
    } catch {
      return null;
    }
  }
  try {
    const parsed = JSON.parse(text) as Record<string, unknown>;
    const clientEmail = parsed.client_email;
    const privateKey = parsed.private_key;
    const projectId = parsed.project_id;
    if (
      typeof clientEmail !== "string" || !clientEmail ||
      typeof privateKey !== "string" || !privateKey ||
      typeof projectId !== "string" || !projectId
    ) {
      return null;
    }
    return {
      client_email: clientEmail,
      private_key: privateKey,
      project_id: projectId,
    };
  } catch {
    return null;
  }
}

// ---------- Google OAuth2 access token (JWT RS256, WebCrypto) ----------

async function mintAccessToken(sa: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const claims = {
    iss: sa.client_email,
    sub: sa.client_email,
    aud: "https://oauth2.googleapis.com/token",
    scope: FCM_SCOPE,
    iat: now,
    exp: now + 3600,
  };
  const enc = new TextEncoder();
  const unsigned = base64UrlEncode(enc.encode(JSON.stringify(header))) +
    "." + base64UrlEncode(enc.encode(JSON.stringify(claims)));

  // The private_key is a PEM PKCS#8 block — strip the armor and
  // import the DER bytes as an RSASSA-PKCS1-v1_5 SHA-256 key.
  const pemBody = sa.private_key
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "");
  const der = base64DecodeToBytes(pemBody);
  const key = await crypto.subtle.importKey(
    "pkcs8",
    der.buffer as ArrayBuffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    enc.encode(unsigned),
  );
  const jwt = unsigned + "." + base64UrlEncode(new Uint8Array(signature));

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }).toString(),
  });
  if (!res.ok) {
    const detail = await res.text();
    throw new Error(`token exchange HTTP ${res.status}: ${detail}`);
  }
  const data = await res.json() as { access_token?: unknown };
  if (typeof data.access_token !== "string" || !data.access_token) {
    throw new Error("token exchange returned no access_token");
  }
  return data.access_token;
}

// ---------- FCM send ----------

async function sendToToken(
  accessToken: string,
  projectId: string,
  token: string,
  title: string,
  body: string,
  type: string,
  version: string | null,
): Promise<{ ok: boolean; unregistered: boolean }> {
  const data: Record<string, string> = { type };
  if (version) data.version = version;
  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
    {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        message: {
          token,
          notification: { title, body },
          data,
          android: { priority: "HIGH" },
        },
      }),
    },
  );
  if (res.ok) return { ok: true, unregistered: false };
  let detail = "";
  try {
    detail = await res.text();
  } catch { /* body unreadable — status is enough */ }
  const unregistered = detail.includes("UNREGISTERED") ||
    detail.includes("INVALID_ARGUMENT");
  return { ok: false, unregistered };
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

  // 1. Verify the caller is an admin (same pattern as issue-code).
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: authError } = await userClient.auth
    .getUser();
  if (authError || !user) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }
  const admin = createClient(supabaseUrl, serviceKey);
  const { data: callerProfile } = await admin
    .from("profiles")
    .select("is_admin")
    .eq("id", user.id)
    .maybeSingle();
  if (!callerProfile?.is_admin) {
    return json({ ok: false, error: "forbidden_not_admin" }, 403);
  }

  // 2. Validate input.
  let body: {
    title?: unknown;
    body?: unknown;
    audience?: unknown;
    type?: unknown;
    version?: unknown;
  };
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "invalid_request" }, 400);
  }
  const title = typeof body.title === "string" ? body.title.trim() : "";
  const messageBody = typeof body.body === "string" ? body.body.trim() : "";
  const audience = body.audience === "premium" || body.audience === "free"
    ? body.audience
    : body.audience === "all"
    ? "all"
    : "";
  const type = body.type === "update_available" ||
      body.type === "announcement"
    ? body.type
    : "";
  const version = typeof body.version === "string"
    ? body.version.trim()
    : "";
  if (!title || !messageBody || !audience || !type) {
    return json({ ok: false, error: "invalid_request" }, 400);
  }
  if (type === "update_available" && !version) {
    return json({ ok: false, error: "invalid_request" }, 400);
  }

  // 3. Firebase credentials (secret only — never in code or the repo).
  const saRaw = Deno.env.get("FIREBASE_SERVICE_ACCOUNT") ?? "";
  const sa = saRaw ? parseServiceAccount(saRaw) : null;
  if (!sa) {
    return json({ ok: false, error: "server_misconfigured" }, 500);
  }
  const projectId = Deno.env.get("FIREBASE_PROJECT_ID") || sa.project_id;

  // 4. Recipients: opted-in users with a token, filtered by audience.
  //    The notifications_enabled check is mandatory — it runs here,
  //    server-side, so an opted-out user is never sent to.
  let query = admin
    .from("profiles")
    .select("id, fcm_token, plan")
    .eq("notifications_enabled", true)
    .not("fcm_token", "is", null);
  if (audience === "premium") query = query.eq("plan", "premium");
  if (audience === "free") query = query.eq("plan", "free");
  const { data: recipients, error: recipientsError } = await query;
  if (recipientsError) {
    return json({ ok: false, error: "server_error" }, 500);
  }
  const tokens = (recipients ?? [])
    .map((r) => (r as { fcm_token?: unknown }).fcm_token)
    .filter((t): t is string => typeof t === "string" && t.length > 0);
  const recipientCount = tokens.length;

  // 5. Mint the OAuth2 access token, then send one message per token.
  let accessToken: string;
  try {
    accessToken = await mintAccessToken(sa);
  } catch (e) {
    return json(
      { ok: false, error: "fcm_auth_failed", detail: String(e) },
      500,
    );
  }
  let sent = 0;
  const deadTokens: string[] = [];
  for (const token of tokens) {
    try {
      const result = await sendToToken(
        accessToken,
        projectId,
        token,
        title,
        messageBody,
        type,
        type === "update_available" ? version : null,
      );
      if (result.ok) {
        sent++;
      } else if (result.unregistered) {
        deadTokens.push(token);
      }
    } catch {
      // One token failing must not abort the rest of the send.
    }
  }
  // Clear dead tokens so they are never tried again.
  for (const token of deadTokens) {
    try {
      await admin.from("profiles").update({
        fcm_token: null,
        fcm_token_updated_at: new Date().toISOString(),
      }).eq("fcm_token", token);
    } catch { /* best-effort cleanup */ }
  }

  // 6. Log the send (recipient_count = tokens attempted).
  await admin.from("sent_notifications").insert({
    title,
    body: messageBody,
    audience,
    notification_type: type,
    version: type === "update_available" ? version : null,
    sent_by: user.id,
    recipient_count: recipientCount,
  });

  return json({
    ok: true,
    recipient_count: recipientCount,
    sent,
    failed: recipientCount - sent,
  });
});
