// MyEden Group CMS V1.0 · Purchasing (new PRFAF) · pr-notify (CLC 8 Nov 2026)
// Deployed to Supabase as "pr-notify" (verify JWT on). This file is the copy kept with the CMS.
// POST { event, request_id } from the CMS (signed in) after an action. Only sends when the request really is in the matching state.
//   submitted -> Finance            forwarded / second -> the Directors who still have to approve
//   approved  -> purchaser (+ Finance when money has to be released)      released -> purchaser
//   returned / disapproved -> purchaser
//   settled (purchase recorded) -> Finance · queried -> purchaser · closed -> purchaser · overdue (reminder from Reports) -> purchaser
// From MyEden Group <noreply@mail.myeden.group>, replies to claims@myeden.group.
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
const STATE: Record<string, string[]> = {
  submitted: ["finance"], forwarded: ["directors"], second: ["directors"], approved: ["approved", "purchasing"],
  released: ["released", "purchasing"], returned: ["returned"], disapproved: ["disapproved"],
  settled: ["settlement"], queried: ["purchasing"], closed: ["closed"], overdue: ["released", "purchasing"],
};

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
    const { event, request_id } = await req.json();
    if (!STATE[event] || !request_id) return out({ error: "Missing or unknown event" }, 400);
    const { data: q, error } = await admin.rpc("cms_pr_notify_info", { p_id: request_id, p_event: event });
    if (error || !q) return out({ error: "Request not found" }, 404);
    if (!STATE[event].includes(q.status)) return out({ warning: `Request is ${q.status}` });
    const head = `<p style="color:#555">Purchase request <b>${esc(q.pr_no)}</b> · ${esc(q.company)} · ${esc(q.requester)}<br>${esc(q.purpose)} · <b>${rm(q.approved_amount ?? q.est_total)}</b></p>`;
    const foot = `<p>Open <b>Purchasing › Purchase Requests</b> in the MyEden Group CMS.</p><p style="color:#888;font-size:12px">MyEden Group CMS · <a href="${CMS}">${CMS}</a></p>`;
    const sent: string[] = [];
    const go = async (to: string[], subject: string, body: string, tag: string) => {
      const list = [...new Set(to.filter(Boolean))];
      if (!list.length) return;
      await send(list, subject, `${body}${head}${foot}`);
      sent.push(`${tag}:${list.length}`);
    };
    const me = q.requester_email ? [q.requester_email] : [];
    if (event === "submitted") await go(q.finance || [], `Purchase request to review: ${q.pr_no}`, `<p>A purchase request is waiting for Finance review.</p>`, "finance");
    else if (event === "forwarded" || event === "second") await go(q.directors || [], `Purchase request to approve: ${q.pr_no}`, `<p>A purchase request needs your approval${q.level === "both" ? " (both Directors)" : ""}.</p>`, "directors");
    else if (event === "approved") {
      await go(me, `Purchase request approved: ${q.pr_no}`, `<p>Your purchase request has been approved for <b>${rm(q.approved_amount)}</b>.${Number(q.release_amount) > 0 ? ` Finance will release <b>${rm(q.release_amount)}</b>.` : " Your petty-cash balance covers it: you can go ahead with the purchase."}</p>`, "purchaser");
      if (q.status === "approved") await go(q.finance || [], `Funds to release: ${q.pr_no}`, `<p>An approved purchase request is waiting for the funds to be released (<b>${rm(q.release_amount)}</b>).</p>`, "finance");
    } else if (event === "released") await go(me, `Funds released: ${q.pr_no}`, `<p><b>${rm(q.released_amount)}</b> has been released for your purchase request. Please confirm in the CMS when you have received it.</p>`, "purchaser");
    else if (event === "returned") await go(me, `Purchase request returned: ${q.pr_no}`, `<p>Your purchase request was returned for changes:</p><blockquote>${esc(q.reason)}</blockquote>`, "purchaser");
    else if (event === "settled") await go(q.finance || [], `Purchase to verify: ${q.pr_no}`, `<p>${esc(q.requester)} has recorded the purchase (<b>${rm(q.actual_total)}</b>) with receipts.${q.excess ? " It is over the tolerance: the overspend needs approval." : ""}</p>`, "finance");
    else if (event === "queried") await go(me, `Questions on your purchase: ${q.pr_no}`, `<p>Finance has questions about the receipts you recorded:</p><blockquote>${esc(q.reason)}</blockquote><p>Please fix them and send it again.</p>`, "purchaser");
    else if (event === "closed") await go(me, `Purchase closed: ${q.pr_no}`, `<p>Finance has checked your receipts (<b>${rm(q.actual_total)}</b>) and closed the request. Any money left stays as your petty cash for the next request.</p>`, "purchaser");
    else if (event === "overdue") await go(me, `Reminder: record your purchase ${q.pr_no}`, `<p>Please record what you bought, with the receipts, for this request. It was due on <b>${esc(q.settle_due)}</b>.</p>`, "purchaser");
    else if (event === "disapproved") await go(me, `Purchase request not approved: ${q.pr_no}`, `<p>Your purchase request was not approved:</p><blockquote>${esc(q.reason)}</blockquote>`, "purchaser");
    return out({ ok: true, sent });
  } catch (e) {
    return out({ error: String((e as Error).message || e) }, 500);
  }
});
