// ============================================================
// OfficerPath AI v2.0.0 — Edge Function: payment-alert
// POST from a Supabase Database Webhook on public.payments INSERT.
// NO user JWT (verify_jwt must be FALSE when deploying — webhooks
// carry no JWT). Authentication is a shared secret instead:
//   header  x-webhook-secret: <PAYMENT_ALERT_SECRET>
// The secret is an Edge Function secret (same place as
// RESEND_API_KEY). A request with a missing/wrong secret gets 401
// and nothing is emailed.
//
// WHAT IT DOES: when a buyer submits a payment proof, the admin
// gets an email so a new payment is noticed even when the admin
// panel is closed (the panel's live Realtime alert + sound only
// work while the panel is open). The email lists the buyer, plan,
// method and transaction ID, and links the admin panel. It does
// NOT approve anything and never issues a code — approval still
// happens only in the panel, by the admin, after checking the
// receipt.
//
// REQUIRED SECRETS (Supabase Dashboard -> Edge Functions -> Secrets):
//   PAYMENT_ALERT_SECRET — shared secret for the webhook header.
//   RESEND_API_KEY, RESEND_FROM — already set for issue-code.
//
// WEBHOOK SETUP (parent creates this in the Dashboard):
//   Database -> Webhooks -> Create a new webhook:
//   - Name: payment-alert
//   - Table: public.payments
//   - Events: INSERT only
//   - Type: HTTP Request, Method POST
//   - URL: https://gliebuyyjguxrwdfuakz.supabase.co/functions/v1/payment-alert
//   - HTTP Headers: x-webhook-secret = <PAYMENT_ALERT_SECRET value>
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-webhook-secret",
};

const PANEL_URL = "https://officerpath-admin.pages.dev/";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

/// Constant-time-ish string comparison (avoids early exit on the
/// first differing character). Not a substitute for TLS + a strong
/// random secret — just the cheapest correct check in Deno.
function secretsEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

async function sendAlertEmail(
  apiKey: string,
  from: string,
  to: string[],
  subject: string,
  text: string,
  html: string,
): Promise<{ sent: boolean; error?: string }> {
  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ from, to, subject, text, html }),
    });
    if (!res.ok) {
      return { sent: false, error: `Resend HTTP ${res.status}: ${await res.text()}` };
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
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const webhookSecret = Deno.env.get("PAYMENT_ALERT_SECRET") ?? "";
  const resendKey = Deno.env.get("RESEND_API_KEY") ?? "";
  const from = Deno.env.get("RESEND_FROM") ??
    "OfficerPath AI <hello@abdulqadeerml.com>";
  if (!supabaseUrl || !serviceKey) {
    return json({ ok: false, error: "server_misconfigured" }, 500);
  }

  // 1. Shared-secret auth. No secret configured server-side = refuse
  // everything (fail closed) rather than alerting unauthenticated.
  const given = req.headers.get("x-webhook-secret") ?? "";
  if (!webhookSecret || !secretsEqual(given, webhookSecret)) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }

  // 2. Parse the database-webhook payload. Only INSERT on payments
  // alerts; anything else is acknowledged and ignored.
  let payload: {
    type?: unknown;
    table?: unknown;
    record?: Record<string, unknown>;
  };
  try {
    payload = await req.json();
  } catch {
    return json({ ok: false, error: "invalid_request" }, 400);
  }
  if (payload.type !== "INSERT" || payload.table !== "payments") {
    return json({ ok: true, ignored: true });
  }
  const record = payload.record ?? {};
  const buyerEmail = typeof record.email === "string" ? record.email : "";
  const plan = typeof record.plan === "string" ? record.plan : "";
  const method = typeof record.method === "string" ? record.method : "";
  const tid = typeof record.transaction_id === "string"
    ? record.transaction_id
    : "";
  if (!buyerEmail.includes("@")) {
    return json({ ok: false, error: "invalid_request" }, 400);
  }

  // 3. Admin recipients: every profile with is_admin = true.
  const admin = createClient(supabaseUrl, serviceKey);
  const { data: admins, error: adminError } = await admin
    .from("profiles")
    .select("email")
    .eq("is_admin", true);
  if (adminError) {
    return json({ ok: false, error: "server_error" }, 500);
  }
  const recipients = (admins ?? [])
    .map((a) => a.email as string | null)
    .filter((e): e is string => !!e && e.includes("@"));
  if (recipients.length === 0) {
    return json({ ok: false, error: "no_admin_recipients" }, 500);
  }

  // 4. Email the alert. A send failure is reported, not hidden —
  // the panel's live alert still covers the open-panel case.
  if (!resendKey) {
    return json({ ok: false, error: "RESEND_API_KEY secret is not set" }, 500);
  }
  const planLabel = plan === "premium_1year"
    ? "1 Year Premium"
    : plan === "premium_2months"
    ? "2 Months Premium"
    : "1 Month Premium";
  const subject = `New OfficerPath payment — ${buyerEmail} — ${planLabel}`;
  const text =
    `A new payment proof was submitted on OfficerPath AI.\n\n` +
    `Buyer: ${buyerEmail}\n` +
    `Plan: ${planLabel}\n` +
    `Method: ${method}\n` +
    `Transaction ID: ${tid}\n\n` +
    `Check the receipt (in-app upload and/or WhatsApp) and approve or ` +
    `reject it in the admin panel:\n${PANEL_URL}`;
  const html =
    `<p>A new payment proof was submitted on OfficerPath AI.</p>` +
    `<p><strong>Buyer:</strong> ${buyerEmail}<br>` +
    `<strong>Plan:</strong> ${planLabel}<br>` +
    `<strong>Method:</strong> ${method}<br>` +
    `<strong>Transaction ID:</strong> ${tid}</p>` +
    `<p>Check the receipt (in-app upload and/or WhatsApp) and approve or ` +
    `reject it in the <a href="${PANEL_URL}">admin panel</a>.</p>`;
  const result = await sendAlertEmail(
    resendKey,
    from,
    recipients,
    subject,
    text,
    html,
  );
  if (!result.sent) {
    return json({ ok: false, error: result.error ?? "email_failed" }, 500);
  }
  return json({ ok: true, emailed: recipients.length });
});
