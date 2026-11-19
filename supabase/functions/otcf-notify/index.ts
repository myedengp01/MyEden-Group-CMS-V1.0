// MyEden Group CMS V1.0 · otcf-notify (PRI-025, v2026.11.20) — Overtime Claim (OTCF) emails, sent from the CMS's point of view.
// POST { event: "submitted" | "approved" | "disapproved", submission_id } from the CMS or the old form app.
//   submitted   -> the people whose CMS role may approve OTCF for that company (never the claimant; Directors only when the
//                  claimant is a Super Admin / Admin / Director), with a link that opens the claim in the CMS Action Center
//   approved    -> the claimant, with the signed PDF link and a link to My Claims
//   disapproved -> the claimant, with the reason
// Recipients come from cms_claim_mail_info (CMS roles), not the form app's own permission list.
// From MyEden Group <noreply@mail.myeden.group>, replies to claims@myeden.group.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")!;
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const CMS = "https://myedengp01.github.io/MyEden-Group-CMS-V1.0/app/";
const FORM = "otcf";
const FROM = "MyEden Group <noreply@mail.myeden.group>";
const REPLY_TO = "claims@myeden.group";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const out = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

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
    if (!["submitted", "approved", "disapproved"].includes(event) || !submission_id) return out({ error: "Missing or unknown event" }, 400);
    const { data: s, error } = await admin.from("otcf_submissions").select("*").eq("id", submission_id).single();
    if (error || !s) return out({ error: "Submission not found" }, 404);
    const { data: who, error: werr } = await admin.rpc("cms_claim_mail_info", { p_form: FORM, p_id: submission_id });
    if (werr || !who) return out({ error: "Recipients not found" }, 500);
    const name = s.emp_name || "";
    const head = `<p style="color:#555">Overtime Claim (OTCF) <b>${esc(s.serial_no)}</b> · ${esc(name)} · ${`${["January","February","March","April","May","June","July","August","September","October","November","December"][(Number(s.month) || 1) - 1]} ${esc(s.year)} · <b>${Number(s.total_hours || 0).toFixed(2)} hours</b>`}</p>`;
    const link = (path: string, label: string) => `<p><a href="${CMS}#/${path}" style="display:inline-block;background:#1c3d6e;color:#fff;padding:9px 16px;border-radius:6px;text-decoration:none">${label}</a></p>`;
    const foot = `<p style="color:#888;font-size:12px">MyEden Group CMS · <a href="${CMS}">${CMS}</a></p>`;
    if (event === "submitted") {
      const to = (who.approvers || []).filter((e: string) => e && e !== who.claimant_email);
      if (!to.length) return out({ warning: "No CMS approvers for this form and company — email not sent" });
      await send(to, `Overtime Claim (OTCF) to approve: ${s.serial_no} (${name})`,
        `<p>You have a request from ${esc(name)} to approve their overtime claim.</p>${head}${who.needs_director ? "<p>This claim was made by a Super Admin / Admin / Director, so a Director decides it.</p>" : ""}${link(`approvals?claim=${FORM}:${s.id}`, "Open the claim in the CMS")}${foot}`);
      return out({ ok: true, notified: to.length });
    }
    if (!who.claimant_email) return out({ warning: "Claimant email not found — not sent" });
    if (event === "approved") {
      const pdf = s.pdf_url ? `<p><a href="${s.pdf_url}">📄 Download the signed claim PDF</a> (link valid 30 days)</p>` : "";
      await send([who.claimant_email], `Your overtime claim has been approved: ${s.serial_no}`,
        `<p>Hello ${esc(name)},</p><p>Your overtime claim has been approved by ${esc(s.approved_by_name || "your approver")}.</p>${head}${pdf}${link("me/claims", "See it in My Claims")}${foot}`);
      return out({ ok: true });
    }
    const reason = s.disapproval_reason ? `<p><b>Reason:</b> ${esc(s.disapproval_reason)}</p>` : "";
    await send([who.claimant_email], `Your overtime claim was disapproved: ${s.serial_no}`,
      `<p>Hello ${esc(name)},</p><p>Your overtime claim has been disapproved by ${esc(s.disapproved_by_name || s.approved_by_name || "your approver")}.</p>${reason}${head}${link("me/claims", "Review it in My Claims")}${foot}`);
    return out({ ok: true });
  } catch (e) {
    return out({ error: String((e as Error).message || e) }, 500);
  }
});
