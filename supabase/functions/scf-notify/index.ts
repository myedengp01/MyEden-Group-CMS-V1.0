// MyEden Group CMS V1.0 · PRI-010 F1 · scf-notify (CLC 7 Nov 2026)
// Deployed to Supabase as "scf-notify" (verify JWT on). This file is the copy kept with the CMS.
// POST { event: "submitted" | "paid", submission_id } from the CMS (signed in).
//   submitted -> "claim received" to the claimant, "new SCF claim" to the SCF processors (finance / mark paid / form admin)
//   paid      -> "claim paid" to the claimant
// Only sends when the claim really is in that state. From MyEden Group <noreply@mail.myeden.group>, replies to claims@myeden.group.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")!;
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const CMS = "https://myedengp01.github.io/MyEden-Group-CMS-V1.0/";
const FROM = "MyEden Group <noreply@mail.myeden.group>";
const REPLY_TO = "claims@myeden.group";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const out = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const rm = (n: unknown) => "RM " + Number(n || 0).toLocaleString("en-MY", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

async function send(to: string[], subject: string, html: string) {
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, reply_to: REPLY_TO, to, subject, html }),
  });
  if (!res.ok) throw new Error(`Email not sent (${res.status}): ${await res.text()}`);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  try {
    const { event, submission_id } = await req.json();
    if (!["submitted", "paid"].includes(event) || !submission_id) return out({ error: "Missing or unknown event" }, 400);
    const { data: c, error } = await admin.rpc("cms_scf_notify_info", { p_id: submission_id });
    if (error || !c) return out({ error: "Claim not found" }, 404);
    const head = `<p style="color:#555">Staff Claim (SCF) <b>${esc(c.serial_no)}</b> · ${esc(c.claimed_by)} · ${esc(c.period)} · <b>${rm(c.total)}</b></p>`;
    const foot = `<p style="color:#888;font-size:12px">MyEden Group CMS · <a href="${CMS}">${CMS}</a></p>`;
    const sent: string[] = [];
    if (event === "submitted") {
      if (c.status !== "submitted") return out({ warning: "Claim is not submitted" });
      if (c.claimant_email) {
        await send([c.claimant_email], `Claim received: ${c.serial_no}`, `<p>Hello ${esc(c.claimed_by)},</p><p>Your staff claim has been received and is with Payroll / Accounts for processing.</p>${head}<p>You can follow it in <b>My Claims</b> in the MyEden Group CMS.</p>${foot}`);
        sent.push("claimant");
      }
      const pros = (c.processors || []).filter((e: string) => e && e !== c.claimant_email);
      if (pros.length) {
        await send(pros, `New staff claim: ${c.serial_no} (${c.claimed_by})`, `<p>A new staff claim is ready to process.</p>${head}<p>Open the <b>Action Center</b> in the MyEden Group CMS to check and process it.</p>${foot}`);
        sent.push(`processors:${pros.length}`);
      }
    } else {
      if (!c.paid) return out({ warning: "Claim is not marked as paid" });
      if (c.claimant_email) {
        await send([c.claimant_email], `Claim paid: ${c.serial_no}`, `<p>Hello ${esc(c.claimed_by)},</p><p>Your staff claim has been paid.</p>${head}${foot}`);
        sent.push("claimant");
      }
    }
    return out({ ok: true, sent });
  } catch (e) {
    return out({ error: String((e as Error).message || e) }, 500);
  }
});
