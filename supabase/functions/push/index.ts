// Gesta · funzione "push": riceve gli avvisi del database e manda le notifiche sul telefono.
// Segreti richiesti (Edge Functions → Secrets): VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT, HOOK_SECRET.
// SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY li mette Supabase da solo.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
webpush.setVapidDetails(Deno.env.get("VAPID_SUBJECT") || "mailto:gesta@example.com", Deno.env.get("VAPID_PUBLIC_KEY")!, Deno.env.get("VAPID_PRIVATE_KEY")!);

const SPORT: Record<string, string> = { gym: "Palestra", cal: "Calisthenics", cfx: "Crossfit", box: "Boxe", run: "Corsa", swm: "Nuoto", bik: "Bici", row: "Canottaggio", trk: "Trekking", bch: "Beach", soc: "Calcio", vol: "Pallavolo", bsk: "Basket", rug: "Rugby", pad: "Padel", ten: "Tennis", sqs: "Squash", pkb: "Pickleball", yog: "Yoga", pil: "Pilates", dnc: "Danza", wsf: "Windsurf", ski: "Sci", bld: "Boulder", glf: "Golf", bon: "Jolly" };
const GIORNI = ["domenica", "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato"];
const sp = (k: string) => SPORT[k] || k;
const oggi = () => new Date().toLocaleDateString("sv-SE", { timeZone: "Europe/Rome" });
const cap = (q: string) => (q || "").charAt(0).toUpperCase() + (q || "").slice(1);
const giorno = (d: string) => { const x = new Date(d + "T12:00:00"); return d === oggi() ? "di oggi" : "di " + GIORNI[x.getDay()]; };
const quando = (d: string) => { if (!d || d <= oggi()) return ""; const x = new Date(d + "T12:00:00"); return " · per " + GIORNI[x.getDay()] + " " + x.getDate(); };

async function nome(id: string) { const { data } = await sb.from("profiles").select("name").eq("id", id).maybeSingle(); return (data && data.name) || "Un amico"; }

type Msg = { to: string; kind: string; title: string; body: string; go: string; tag: string };

async function messaggi(p: any): Promise<Msg[]> {
  const r = p.record || {}, o = p.old_record || {}, out: Msg[] = [];
  if (p.table === "challenges") {
    if (p.type === "INSERT" && r.to_id) {
      out.push({ to: r.to_id, kind: "glove", title: (await nome(r.from_id)) + " ti ha lanciato un guanto", body: cap(r.quest) + (r.shared ? " · condivisa" : "") + quando(r.day), go: "letters", tag: "g" + r.id });
    } else if (p.type === "INSERT" && r.gang_id) {
      const { data: g } = await sb.from("gangs").select("name").eq("id", r.gang_id).maybeSingle();
      const { data: mem } = await sb.from("gang_members").select("user_id").eq("gang_id", r.gang_id);
      const chi = await nome(r.from_id);
      (mem || []).filter((m: any) => m.user_id !== r.from_id).forEach((m: any) => out.push({ to: m.user_id, kind: "gang", title: "Obiettivo della Gang " + ((g && g.name) || ""), body: chi + " ha fissato: " + cap(r.quest), go: "party", tag: "o" + r.id }));
    } else if (p.type === "UPDATE" && r.to_id) {
      if (!o.to_done && r.to_done) out.push({ to: r.from_id, kind: "won", title: (await nome(r.to_id)) + " ha chiuso la tua sfida", body: cap(r.quest), go: "letters", tag: "w" + r.id });
      if (r.shared && !o.from_done && r.from_done) out.push({ to: r.to_id, kind: "won", title: (await nome(r.from_id)) + " ha chiuso la quest condivisa", body: cap(r.quest), go: "letters", tag: "s" + r.id });
      if (o.status !== "countered" && r.status === "countered" && r.counter) out.push({ to: r.from_id, kind: "glove", title: (await nome(r.to_id)) + " ti propone una modifica", body: cap(r.counter.quest), go: "letters", tag: "c" + r.id });
    }
  } else if (p.table === "friend_requests" && p.type === "INSERT") {
    out.push({ to: r.to_id, kind: "req", title: (await nome(r.from_id)) + " vuole essere tuo amico", body: "Rispondi in Novità", go: "letters", tag: "r" + r.id });
  } else if (p.table === "fives" && p.type === "INSERT") {
    // se l'altro te l'aveva dato da poco (questa settimana o la scorsa), questo lo batte
    const prev = new Date(r.week + "T12:00:00"); prev.setDate(prev.getDate() - 7);
    const { data: backs } = await sb.from("fives").select("from_id").eq("from_id", r.to_id).eq("to_id", r.from_id).in("week", [r.week, prev.toISOString().slice(0, 10)]);
    const back = backs && backs.length;
    const chi = await nome(r.from_id);
    if (back) out.push({ to: r.to_id, kind: "five", title: chi + " ha battuto il tuo cinque", body: "Cinque battuto", go: "letters", tag: "b" + r.from_id + r.week });
    else out.push({ to: r.to_id, kind: "five", title: chi + " ti ha dato il cinque", body: r.day && r.sport ? "Per la sessione di " + sp(r.sport).toLowerCase() + " " + giorno(r.day) : "Per la tua settimana", go: "letters", tag: "f" + r.from_id + r.week });
  }
  return out;
}

const DEF: Record<string, boolean> = { glove: true, won: true, req: true, gang: true, five: false };

Deno.serve(async (req) => {
  if (req.headers.get("x-hook-secret") !== Deno.env.get("HOOK_SECRET")) return new Response("non autorizzato", { status: 401 });
  let p: any; try { p = await req.json(); } catch { return new Response("vuoto", { status: 400 }); }
  const list = await messaggi(p); let sent = 0;
  for (const m of list) {
    const { data: subs } = await sb.from("push_subscriptions").select("endpoint,p256dh,auth,prefs").eq("user_id", m.to);
    for (const s of subs || []) {
      const pr = s.prefs || {}; if (pr[m.kind] === false || (pr[m.kind] === undefined && !DEF[m.kind])) continue;
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, JSON.stringify({ title: m.title, body: m.body, go: m.go, tag: m.tag }), { TTL: 86400, urgency: "high" });
        sent++;
      } catch (e: any) {
        if (e && (e.statusCode === 404 || e.statusCode === 410)) await sb.from("push_subscriptions").delete().eq("endpoint", s.endpoint);
        else console.log("push non riuscita", e && e.statusCode, e && e.body);
      }
    }
  }
  return new Response(JSON.stringify({ ok: true, sent }), { headers: { "content-type": "application/json" } });
});
