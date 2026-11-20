// ============================================================
// OfficerPath AI v2.0.0 — Edge Function: delete-account
// POST {}  (Authorization: Bearer <user JWT>)
// Returns { ok: true }.
//
// FEASIBILITY: YES — this is feasible in an Edge Function. Supabase's
// Admin API (auth.admin.deleteUser) runs with the privileged server
// key, which only Edge Functions (never the app) hold. The auth user
// is deleted; the profiles row is removed by the ON DELETE CASCADE
// foreign key in 001_schema.sql.
//
// ORDER MATTERS: payments / test_results reference auth.users WITHOUT
// ON DELETE CASCADE, so the caller's rows there are deleted first
// (and activation_codes rows are unlinked) — otherwise deleting the
// auth user would fail on the foreign-key constraint. Payment history
// for a deleted account is gone by design: deleting an account is
// permanent, and the user is told so in the app before confirming.
//
// REQUIRED SECRETS (Supabase Dashboard -> Edge Functions -> Secrets):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
//   (auto-injected by Supabase for hosted functions)
// NO secret is ever sent to, or stored in, the app.
//
// NOTE: an admin variant is deliberately NOT included — an admin
// deletes another user from the Supabase Dashboard (Authentication ->
// Users -> Delete), where the action is audited. This function deletes
// ONLY the caller (the JWT owner).
//
// ERROR STRINGS: unauthorized | server_error
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

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

  // Verify the caller. Only the JWT owner can be deleted here.
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

  // 1. Delete the caller's own rows that block the auth-user delete.
  await admin.from("test_results").delete().eq("user_id", user.id);
  await admin.from("payments").delete().eq("user_id", user.id);
  // Unlink (do not delete) codes issued to / used by this user, so the
  // admin's sales record keeps its rows.
  await admin.from("activation_codes").update({ user_id: null }).eq(
    "user_id",
    user.id,
  );
  await admin.from("activation_codes").update({ used_by: null }).eq(
    "used_by",
    user.id,
  );

  // 2. Delete the auth user. profiles row follows via ON DELETE CASCADE.
  const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);
  if (deleteError) {
    return json({ ok: false, error: "server_error" }, 500);
  }

  return json({ ok: true });
});
