// ============================================================
// OfficerPath AI v2.0.0 — Edge Function: issue-code (ADMIN ONLY)
// POST { "user_id": "<uuid>", "email": "buyer@gmail.com",
//        "plan": "premium_1month" | "premium_2months" | "premium_1year"
//              (also accepts "1" | "2" | "3") }
// Authorization: Bearer <ADMIN's JWT> — the caller must have
// profiles.is_admin = true.
// Returns { ok: true, code: "OP1-ABCDEF", email_sent: true }
// The plain code is returned ONLY to the admin caller, once. It is
// never stored — only its SHA-256 hash goes in activation_codes.
//
// REQUIRED SECRETS (Supabase Dashboard -> Edge Functions -> Secrets):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
//     (auto-injected by Supabase for hosted functions)
//   RESEND_API_KEY   — Resend API key (resend.com -> API Keys -> Create).
//   RESEND_FROM      — optional, default "OfficerPath AI
//                      <hello@abdulqadeerml.com>". The domain
//                      abdulqadeerml.com must be verified in Resend
//                      (Domains -> Add Domain -> add the DNS records
//                      Resend shows, at Cloudflare) before real buyers
//                      can receive mail; until then Resend only delivers
//                      to the Resend account owner's own address.
//
// EMAIL PROVIDER PICK — RESEND (free tier: 100 emails/day,
// 3,000/month), chosen over Gmail SMTP because:
//   * ONE secret (an API key), not a Google app password tied to a
//     personal Gmail account with 2FA to enable and keep alive.
//   * Plain HTTPS fetch() — no SMTP library, no SMTP port issues.
//   * The same Resend account also supplies the SMTP settings for
//     Supabase Auth (smtp.resend.com:465, user "resend", password =
//     the same API key), so the owner manages ONE email provider.
//   * Volume fits easily: codes are emailed only when a payment is
//     approved — a handful a day at launch scale.
// FALLBACK: if RESEND_API_KEY is unset or the send fails, the code is
// STILL created and returned to the admin (email_sent: false) so the
// admin can WhatsApp it to the buyer. Email failure never blocks a sale.
//
// ERROR STRINGS: unauthorized | forbidden_not_admin | invalid_request
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"; // no 0/O/1/I/L
const PLAN_MAP: Record<string, { digit: string; months: number }> = {
  "premium_1month": { digit: "1", months: 1 },
  "premium_2months": { digit: "2", months: 2 },
  "premium_1year": { digit: "3", months: 12 },
  "1": { digit: "1", months: 1 },
  "2": { digit: "2", months: 2 },
  "3": { digit: "3", months: 12 },
};

function generateCode(digit: string): string {
  const bytes = new Uint8Array(6);
  crypto.getRandomValues(bytes);
  let suffix = "";
  for (const b of bytes) suffix += ALPHABET[b % ALPHABET.length];
  return `OP${digit}-${suffix}`;
}

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

async function sendCodeEmail(
  apiKey: string,
  from: string,
  to: string,
  code: string,
  planLabel: string,
): Promise<{ sent: boolean; error?: string }> {
  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from,
        to: [to],
        subject: "OfficerPath AI — aapka Premium activation code",
        text:
          `Assalam-o-Alaikum!\n\nAapka OfficerPath AI Premium activation code (${planLabel}):\n\n${code}\n\nApp kholein -> Upgrade -> "Activation code daalein" aur ye code likhein. Code 7 din ke liye valid hai aur sirf ek dafa istemal ho sakta hai.\n\nShukriya!\nQadeer Automations`,
        html:
          `<p>Assalam-o-Alaikum!</p><p>Aapka OfficerPath AI Premium activation code (<strong>${planLabel}</strong>):</p><p style="font-size:22px;letter-spacing:2px"><strong>${code}</strong></p><p>App kholein -&gt; Upgrade -&gt; "Activation code daalein" aur ye code likhein. Code 7 din ke liye valid hai aur sirf ek dafa istemal ho sakta hai.</p><p>Shukriya!<br>Qadeer Automations</p>`,
      }),
    });
    if (!res.ok) {
      const detail = await res.text();
      return { sent: false, error: `Resend HTTP ${res.status}: ${detail}` };
    }
    return { sent: true };
  } catch (e) {
    return { sent: false, error: String(e) };
  }
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

  // 1. Verify the caller is an admin.
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
  let body: { user_id?: unknown; email?: unknown; plan?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "invalid_request" }, 400);
  }
  const planInfo = typeof body.plan === "string"
    ? PLAN_MAP[body.plan]
    : undefined;
  const buyerId = typeof body.user_id === "string" ? body.user_id : "";
  const buyerEmail = typeof body.email === "string" ? body.email.trim() : "";
  if (!planInfo || !buyerId || !buyerEmail.includes("@")) {
    return json({ ok: false, error: "invalid_request" }, 400);
  }
  const planLabel = body.plan === "premium_1year" || body.plan === "3"
    ? "1 Year Premium"
    : body.plan === "premium_2months" || body.plan === "2"
    ? "2 Months Premium"
    : "1 Month Premium";

  // 3. Generate + store the code (hash only). Retry on a hash collision.
  const expiresAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000);
  let code = "";
  let inserted = false;
  for (let attempt = 0; attempt < 3 && !inserted; attempt++) {
    code = generateCode(planInfo.digit);
    const { error } = await admin.from("activation_codes").insert({
      code_hash: await sha256Hex(code),
      plan: body.plan,
      months: planInfo.months,
      user_id: buyerId,
      issued_by: user.id,
      expires_at: expiresAt.toISOString(),
    });
    if (!error) inserted = true;
  }
  if (!inserted) {
    return json({ ok: false, error: "server_error" }, 500);
  }

  // 4. Email the plain code to the buyer. Failure here never blocks
  // the sale: the admin still gets the code back and can WhatsApp it.
  const resendKey = Deno.env.get("RESEND_API_KEY") ?? "";
  const from = Deno.env.get("RESEND_FROM") ??
    "OfficerPath AI <hello@abdulqadeerml.com>";
  let emailSent = false;
  let emailError: string | undefined;
  if (!resendKey) {
    emailError = "RESEND_API_KEY secret is not set — email skipped.";
  } else {
    const result = await sendCodeEmail(
      resendKey,
      from,
      buyerEmail,
      code,
      planLabel,
    );
    emailSent = result.sent;
    emailError = result.error;
  }

  return json({
    ok: true,
    code,
    email_sent: emailSent,
    ...(emailError ? { email_error: emailError } : {}),
  });
});
