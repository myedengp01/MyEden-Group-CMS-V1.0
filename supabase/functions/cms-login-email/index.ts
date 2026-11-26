// MyEden Group CMS V1.0 · PRI-029 Change login email (CLC 26 Nov 2026)
// Deployed to Supabase as "cms-login-email" (verify JWT OFF: the confirmation link is opened by people who are not signed in;
// "start" and "resend" check the caller's sign-in themselves). This file is the copy kept with the CMS.
// POST { action: "start", person_id | tutor_id, email, reason, source? }   (signed in, permission Change login email)
//        login never used -> email changed now, set-password email to the new address
//        login in use     -> one-time confirmation link emailed to the new address (48 h); nothing changes yet
//        existing login   -> (done in the database) notices to the old and new address
// POST { action: "resend", id }                                            (signed in) a new confirmation link
// POST { action: "confirm", token }                                        (anyone holding the link) the change happens; notice to the old address
// Every check runs in the database (cms_login_email_start / _resend as the caller; _by_token / _finish with the service key).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")!;
const CMS = "https://myedengp01.github.io/MyEden-Group-CMS-V1.0/app/";
const CONFIRM = CMS + "confirm-email.html";
const FROM = "MyEden Group <noreply@mail.myeden.group>";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const out = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const friendly = (m: string) => /rate limit|too many|security purposes/i.test(m)
  ? "The sign-in email limit was reached (Supabase allows a number of emails per hour). Try again later." : m;

async function mail(to: string, subject: string, body: string) {
  const html = `<div style="font-family:Arial,Helvetica,sans-serif;font-size:15px;color:#1f2937;max-width:560px">
    <p style="font-size:18px;font-weight:bold;color:#1B2A6B;margin:0 0 12px">MyEden Group CMS</p>${body}
    <p style="color:#6b7280;font-size:12px;margin-top:24px">This email was sent by the MyEden Group CMS. If you did not expect it, please tell HR.</p></div>`;
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, to: [to], subject, html }),
  });
  if (!r.ok) throw new Error(`The email to ${to} could not be sent (${r.status}).`);
}
const btn = (href: string, label: string) =>
  `<p style="margin:20px 0"><a href="${esc(href)}" style="background:#0072bc;color:#fff;padding:11px 20px;border-radius:8px;text-decoration:none;font-weight:bold">${esc(label)}</a></p>`;
const confirmMail = (to: string, name: string, token: string) => mail(to, "Confirm your new MyEden CMS sign-in email",
  `<p>Hello ${esc(name)},</p><p>HR is changing the email you use to sign in to the MyEden Group CMS to <b>${esc(to)}</b>.</p>
   <p>Please confirm that this is your email. Nothing changes until you do.</p>${btn(`${CONFIRM}?t=${encodeURIComponent(token)}`, "Confirm my new email")}
   <p style="color:#6b7280;font-size:13px">The link works once and for 48 hours. After confirming, sign in with <b>${esc(to)}</b> and your usual password.</p>`);
const changedNotice = (to: string, name: string, newEmail: string) => mail(to, "Your MyEden CMS sign-in email was changed",
  `<p>Hello ${esc(name)},</p><p>The email you use to sign in to the MyEden Group CMS is now <b>${esc(newEmail)}</b>. This address (${esc(to)}) no longer signs in.</p>
   <p>If you did not ask for this, please tell HR straight away.</p>`);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return out({ error: "POST only" }, 405);
  let body: { action?: string; person_id?: string; tutor_id?: string; email?: string; reason?: string; source?: string; id?: string; token?: string };
  try { body = await req.json(); } catch { return out({ error: "Bad request" }, 400); }
  const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } });
  const anon = createClient(URL_, ANON, { auth: { persistSession: false } });

  // ---------------------------------------------------------------- confirm (from the link; no sign-in)
  if (body.action === "confirm") {
    const t = await admin.rpc("cms_login_email_by_token", { p_token: String(body.token || "") });
    if (t.error) return out({ error: t.error.message }, 400);
    const C = t.data as { id: string; user_id: string; old_email: string; new_email: string; name: string };
    const u = await admin.auth.admin.updateUserById(C.user_id, { email: C.new_email, email_confirm: true });
    if (u.error) {
      await admin.rpc("cms_login_email_failed", { p_id: C.id, p_error: u.error.message });
      return out({ error: /already|registered|exists/i.test(u.error.message) ? "This email is already used by another login. Please tell HR." : u.error.message }, 400);
    }
    const f = await admin.rpc("cms_login_email_finish", { p_id: C.id });
    if (f.error) return out({ error: f.error.message }, 400);
    try { await changedNotice(C.old_email, C.name, C.new_email); } catch (_) { /* the change stands; the notice is a courtesy */ }
    return out({ ok: true, email: C.new_email, name: C.name });
  }

  // ---------------------------------------------------------------- start / resend (signed in)
  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) return out({ error: "Sign in first." }, 401);
  const asUser = createClient(URL_, ANON, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });

  if (body.action === "resend") {
    const r = await asUser.rpc("cms_login_email_resend", { p_id: body.id });
    if (r.error) return out({ error: r.error.message }, 400);
    const R = r.data as { new_email: string; name: string; token: string };
    try { await confirmMail(R.new_email, R.name, R.token); } catch (e) { return out({ error: (e as Error).message }, 500); }
    return out({ ok: true, mode: "confirm", new_email: R.new_email });
  }

  if (body.action !== "start") return out({ error: "Unknown action." }, 400);
  const s = await asUser.rpc("cms_login_email_start", {
    p_new: body.email || "", p_reason: body.reason || "", p_person: body.person_id || null, p_tutor: body.tutor_id || null, p_source: body.source || "profile",
  });
  if (s.error) return out({ error: s.error.message }, 400);
  const S = s.data as { id: string; mode: string; user_id: string; old_email: string; new_email: string; name: string; token: string | null; records: string[] };

  if (S.mode === "confirm") {
    try { await confirmMail(S.new_email, S.name, S.token!); } catch (e) { return out({ error: (e as Error).message + " The change is waiting: use Resend." }, 500); }
    return out({ ok: true, mode: S.mode, new_email: S.new_email });
  }
  if (S.mode === "existing") {
    try {
      await changedNotice(S.old_email, S.name, S.new_email);
      await mail(S.new_email, "Your MyEden CMS sign-in", `<p>Hello ${esc(S.name)},</p><p>You now sign in to the MyEden Group CMS with <b>${esc(S.new_email)}</b> and the password you already use with it.</p>${btn(CMS, "Open the MyEden CMS")}<p style="color:#6b7280;font-size:13px">Forgot the password? Use <i>Forgot password?</i> on the sign-in page.</p>`);
    } catch (_) { /* the change stands */ }
    return out({ ok: true, mode: S.mode, new_email: S.new_email, records: S.records });
  }
  // direct: the login was never used
  const u = await admin.auth.admin.updateUserById(S.user_id, { email: S.new_email, email_confirm: true });
  if (u.error) {
    await admin.rpc("cms_login_email_failed", { p_id: S.id, p_error: u.error.message });
    return out({ error: u.error.message }, 400);
  }
  const f = await admin.rpc("cms_login_email_finish", { p_id: S.id });
  if (f.error) return out({ error: f.error.message }, 400);
  const pw = await anon.auth.resetPasswordForEmail(S.new_email, { redirectTo: CMS });
  return out({ ok: true, mode: S.mode, new_email: S.new_email, records: (f.data as { records: string[] }).records,
    warning: pw.error ? "The email was changed, but the set-password email could not be sent: " + friendly(pw.error.message) + " Use Invite to send it again." : null });
});
