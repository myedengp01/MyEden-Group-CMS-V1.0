// MyEden Group CMS V1.0 · PRI-019 Invite to the CMS (CLC 7 Nov 2026)
// Deployed to Supabase as "cms-invite" (verify JWT on). This file is the copy kept with the CMS.
// POST { person_id, email? } (staff) or { tutor_id } (outside tutor, TEC) from the CMS (signed in). Permission and checks run as the caller in the database:
//   cms_invite_prepare -> who, which email, is there already a login
//   new login            -> Supabase invite email (choose a password), from noreply@mail.myeden.group
//   login never used     -> "set your password" email
//   login in use         -> no email, just linked
//   cms_invite_finish    -> link login to person, Staff role, default self-service parts, record the invite
//   tutors: cms_tutor_invite_prepare / cms_tutor_invite_finish (link login to the tutor record, Tutor role)
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const REDIRECT = "https://myedengp01.github.io/MyEden-Group-CMS-V1.0/";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const out = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const friendly = (m: string) => /rate limit|too many|security purposes/i.test(m)
  ? "The sign-in email limit was reached (Supabase allows a number of emails per hour). Try the rest again later." : m;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return out({ error: "POST only" }, 405);
  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) return out({ error: "Sign in first." }, 401);
  let body: { person_id?: string; tutor_id?: string; email?: string };
  try { body = await req.json(); } catch { return out({ error: "Bad request" }, 400); }
  if (!body.person_id && !body.tutor_id) return out({ error: "No person given." }, 400);
  const tutor = !body.person_id;

  const asUser = createClient(URL_, ANON, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } });
  const anon = createClient(URL_, ANON, { auth: { persistSession: false } });

  const prep = tutor
    ? await asUser.rpc("cms_tutor_invite_prepare", { p_tutor: body.tutor_id })
    : await asUser.rpc("cms_invite_prepare", { p_person: body.person_id, p_email: body.email || null });
  if (prep.error) return out({ error: prep.error.message }, 400);
  const P = prep.data as { email: string; name: string; user_id: string | null; used: boolean };

  let userId = P.user_id; let mode = "linked";
  if (!userId) {
    const r = await admin.auth.admin.inviteUserByEmail(P.email, { redirectTo: REDIRECT, data: { full_name: P.name } });
    if (r.error) return out({ error: friendly(r.error.message) }, /rate/i.test(r.error.message) ? 429 : 400);
    userId = r.data.user?.id || null; mode = "invited";
    if (!userId) return out({ error: "The invite was sent but no login came back." }, 500);
  } else if (!P.used) {
    const r = await anon.auth.resetPasswordForEmail(P.email, { redirectTo: REDIRECT });
    if (r.error) return out({ error: friendly(r.error.message) }, /rate/i.test(r.error.message) ? 429 : 400);
    mode = "reset";
  }

  const fin = tutor
    ? await asUser.rpc("cms_tutor_invite_finish", { p_tutor: body.tutor_id, p_user: userId, p_mode: mode })
    : await asUser.rpc("cms_invite_finish", { p_person: body.person_id, p_user: userId, p_mode: mode });
  if (fin.error) return out({ error: fin.error.message, mode, email: P.email }, 400);
  return out({ ok: true, mode, email: P.email, name: P.name, ...(fin.data as object) });
});
