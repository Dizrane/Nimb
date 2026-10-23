// Nimb report relay: takes a report from the app, keeps it for 90 days (KV `REPORTS`) and passes it to the developer's Telegram
// as a text file. A report that the program sends by itself (`auto: true`, the switch «Помогать тестированию») is only kept: it does not go
// to Telegram, so that the chat is not filled; it is taken with the export. `GET /export?key=EXPORT_KEY` gives all the kept reports as one text file (`&clear=1` removes them after).
// The bot token, the chat and the export key live in the secrets of this Worker; nothing secret is in the app.

const MAX_BODY = 100_000;
const PLATFORMS = ["macos", "windows"];
const KEEP_SECONDS = 90 * 24 * 3600;
const EXPORT_LIMIT = 200;

const reply = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/export") return exportReports(url, env);
    if (request.method === "GET" && url.pathname === "/chat") return findChat(url, env);
    if (request.method !== "POST") return new Response("Nimb report relay", { status: 200 });

    if (Number(request.headers.get("content-length") || 0) > MAX_BODY) return reply({ ok: false, error: "too large" }, 413);
    const raw = await request.text();
    if (raw.length > MAX_BODY) return reply({ ok: false, error: "too large" }, 413);

    let data;
    try {
      data = JSON.parse(raw);
    } catch {
      return reply({ ok: false, error: "bad json" }, 400);
    }
    const valid =
      data && data.v === 1 &&
      typeof data.id === "string" && /^[A-Z0-9]{4,12}$/.test(data.id) &&
      typeof data.app === "string" && /^[0-9A-Za-z.\-]{1,20}$/.test(data.app) &&
      PLATFORMS.includes(data.platform) &&
      typeof data.text === "string" && data.text.length > 0;
    if (!valid) return reply({ ok: false, error: "bad report" }, 400);
    // What an automatic report says about itself: the cause and the random number of the installation, both in a plain form.
    const auto = data.auto === true;
    data.trigger = auto && typeof data.trigger === "string" && /^[A-Za-z0-9:\-]{1,40}$/.test(data.trigger) ? data.trigger : "";
    data.install = auto && typeof data.install === "string" && /^[A-Z0-9]{4,16}$/.test(data.install) ? data.install : "";

    if (env.LIMITER) {
      const key = request.headers.get("CF-Connecting-IP") || "unknown";
      const { success } = await env.LIMITER.limit({ key });
      if (!success) return reply({ ok: false, error: "too many" }, 429);
    }
    // The first lines of what the person wrote go to the caption, so that the message says what it is about.
    const written = (data.text.match(/Что случилось:\n([\s\S]*?)(?:\n\n|$)/) || [, ""])[1].trim().slice(0, 300);
    const caption = `Nimb ${data.app} · ${data.platform} · № ${data.id}` + (written ? `\n${written}` : "");

    // Telegram can be slow from some places (20 seconds from Moscow, measured): when the report is already kept, the person is not made
    // to wait for it, and the sending goes on after the answer.
    const stored = await save(env, { ...data, auto });
    if (auto) return stored ? reply({ ok: true }) : reply({ ok: false, error: "nowhere to put it" }, env.REPORTS ? 502 : 500);
    if (stored && ctx && ctx.waitUntil) {
      ctx.waitUntil(forward(env, data, caption));
      return reply({ ok: true });
    }
    const sent = await forward(env, data, caption);
    if (!stored && !sent) return reply({ ok: false, error: "nowhere to put it" }, env.BOT_TOKEN ? 502 : 500);
    return reply({ ok: true });
  },
};

// The report goes to KV under a key that sorts by time. A failure here must not lose the report: Telegram may still have it.
async function save(env, data) {
  if (!env.REPORTS) return false;
  try {
    const key = `r:${String(Date.now()).padStart(13, "0")}:${data.id}`;
    await env.REPORTS.put(key, JSON.stringify({ id: data.id, app: data.app, platform: data.platform, text: data.text, ...(data.auto ? { auto: true, trigger: data.trigger, install: data.install } : {}) }), { expirationTtl: KEEP_SECONDS });
    return true;
  } catch {
    return false;
  }
}

async function forward(env, data, caption) {
  if (!env.BOT_TOKEN || !env.CHAT_ID) return false;
  const form = new FormData();
  form.append("chat_id", env.CHAT_ID);
  form.append("caption", caption.slice(0, 1000));
  form.append("document", new Blob([data.text], { type: "text/plain" }), `nimb-report-${data.id}.txt`);
  const api = env.TELEGRAM_API || "https://api.telegram.org";
  const started = Date.now();
  try {
    const response = await fetch(`${api}/bot${env.BOT_TOKEN}/sendDocument`, { method: "POST", body: form, signal: AbortSignal.timeout(28000) });
    console.log(`telegram answered ${response.status} in ${Date.now() - started} ms`);
    return response.ok;
  } catch (error) {
    console.log(`telegram failed after ${Date.now() - started} ms: ${error}`);
    return false;
  }
}

// Used once by deploy.sh: the id of the chat that the person opened with the bot. The Mac of the person may not reach Telegram at all
// (it is slowed down or closed there), Cloudflare does, so the Worker asks.
async function findChat(url, env) {
  if (!sameKey(url.searchParams.get("key"), env.EXPORT_KEY) || !env.BOT_TOKEN) return new Response("no", { status: 401 });
  const api = env.TELEGRAM_API || "https://api.telegram.org";
  try {
    const response = await fetch(`${api}/bot${env.BOT_TOKEN}/getUpdates`);
    const updates = (await response.json()).result || [];
    const chats = updates.map((u) => u.message && u.message.chat && u.message.chat.id).filter((id) => id !== undefined && id !== null);
    return reply({ ok: true, chat: chats.length ? String(chats[chats.length - 1]) : null });
  } catch {
    return reply({ ok: false, chat: null }, 502);
  }
}

function sameKey(given, wanted) {
  if (typeof given !== "string" || typeof wanted !== "string" || wanted.length < 8 || given.length !== wanted.length) return false;
  let diff = 0;
  for (let i = 0; i < wanted.length; i++) diff |= given.charCodeAt(i) ^ wanted.charCodeAt(i);
  return diff === 0;
}

// All the kept reports in one text file, oldest first, with a list of them at the top.
async function exportReports(url, env) {
  if (!env.REPORTS || !sameKey(url.searchParams.get("key"), env.EXPORT_KEY)) return new Response("no", { status: 401 });
  const listed = await env.REPORTS.list({ prefix: "r:", limit: EXPORT_LIMIT });
  const items = [];
  for (const { name } of listed.keys) {
    const raw = await env.REPORTS.get(name);
    if (!raw) continue;
    try {
      items.push({ name, ...JSON.parse(raw) });
    } catch {
      /* a broken record is skipped */
    }
  }
  const when = (name) => new Date(Number(name.split(":")[1])).toISOString().replace("T", " ").slice(0, 16) + " UTC";
  const asked = (text) => (text.match(/Что случилось:\n([\s\S]*?)(?:\n\n|$)/) || [, ""])[1].trim().replace(/\s+/g, " ").slice(0, 100);
  const lines = [`Nimb: отчётов ${items.length}${listed.list_complete ? "" : ` (показаны первые ${EXPORT_LIMIT}, остальные при следующей выгрузке)`}`, ""];
  const tag = (item) => (item.auto ? ` · авто ${item.trigger}${item.install ? ` · установка ${item.install}` : ""}` : "");
  for (const item of items) lines.push(`№ ${item.id} · ${item.app} · ${item.platform} · ${when(item.name)}${tag(item)} · ${asked(item.text)}`);
  for (const item of items) lines.push("", "", `==================== № ${item.id} · ${item.app} · ${item.platform} · ${when(item.name)}${tag(item)} ====================`, "", item.text);
  if (url.searchParams.get("clear") === "1") await Promise.all(items.map((item) => env.REPORTS.delete(item.name)));
  return new Response(lines.join("\n"), {
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "content-disposition": `attachment; filename="nimb-reports-${new Date().toISOString().slice(0, 10)}.txt"`,
      "cache-control": "no-store",
    },
  });
}
