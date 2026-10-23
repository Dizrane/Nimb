// Runs the relay against a pretend Telegram: node test.mjs
import assert from "node:assert/strict";
import worker from "./index.js";

const sent = [];
globalThis.fetch = async (url, init) => {
  sent.push({ url: String(url), form: init.body });
  return new Response(JSON.stringify({ ok: true }), { status: 200 });
};
const env = { BOT_TOKEN: "123:abc", CHAT_ID: "42" };
const good = { v: 1, id: "AB12CD", app: "0.9.3", platform: "macos", text: "Отчёт № AB12CD\n\nЧто случилось:\nНе включается туннель\n\n— Программа —\nNimb 0.9.3" };
const pending = [];
const ctx = { waitUntil: (promise) => void pending.push(promise) };
const post = async (body, e = env, headers = {}) => {
  const response = await worker.fetch(new Request("https://relay.test/", { method: "POST", body: typeof body === "string" ? body : JSON.stringify(body), headers }), e, ctx);
  await Promise.all(pending.splice(0));
  return response;
};

let r = await post(good);
assert.equal(r.status, 200);
assert.equal(sent.length, 1);
assert.match(sent[0].url, /\/bot123:abc\/sendDocument$/);
assert.equal(sent[0].form.get("chat_id"), "42");
assert.match(sent[0].form.get("caption"), /№ AB12CD\nНе включается туннель/);
assert.equal(sent[0].form.get("document").name, "nimb-report-AB12CD.txt");

assert.equal((await worker.fetch(new Request("https://relay.test/"), env)).status, 200); // a browser sees a line of text
assert.equal((await post("not json")).status, 400);
assert.equal((await post({ ...good, platform: "linux" })).status, 400);
assert.equal((await post({ ...good, id: "<script>" })).status, 400);
assert.equal((await post({ ...good, text: "" })).status, 400);
assert.equal((await post({ ...good, text: "x".repeat(100_001) })).status, 413);
assert.equal((await post(good, {})).status, 500);
assert.equal((await post(good, { ...env, LIMITER: { limit: async () => ({ success: false }) } })).status, 429);

globalThis.fetch = async () => new Response("{}", { status: 400 });
assert.equal((await post(good)).status, 502);
globalThis.fetch = async () => { throw new Error("offline"); };
assert.equal((await post(good)).status, 502);

// Kept reports and the export: a pretend KV.
const kv = new Map();
const REPORTS = {
  put: async (key, value) => void kv.set(key, value),
  get: async (key) => kv.get(key) ?? null,
  delete: async (key) => void kv.delete(key),
  list: async () => ({ keys: [...kv.keys()].sort().map((name) => ({ name })), list_complete: true }),
};
globalThis.fetch = async () => new Response("{}", { status: 200 });
const kept = { ...env, REPORTS, EXPORT_KEY: "secret-export-key" };
assert.equal((await post(good, kept)).status, 200);
await new Promise((resolve) => setTimeout(resolve, 5));
assert.equal((await post({ ...good, id: "ZZ99YY", text: "Отчёт № ZZ99YY\n\nЧто случилось:\nВторой человек\n\n— Программа —" }, kept)).status, 200);
assert.equal(kv.size, 2);

// Telegram down but the report is kept: still a success for the person.
globalThis.fetch = async () => new Response("{}", { status: 500 });
assert.equal((await post({ ...good, id: "KEPT01" }, kept)).status, 200);
assert.equal(kv.size, 3);
// The person does not wait for Telegram when the report is kept: the answer comes before the sending ends.
let release;
globalThis.fetch = () => new Promise((resolve) => { release = () => resolve(new Response("{}", { status: 200 })); });
const early = await worker.fetch(new Request("https://relay.test/", { method: "POST", body: JSON.stringify({ ...good, id: "SLOW01" }) }), kept, ctx);
assert.equal(early.status, 200);
assert.equal(kv.size, 4);
release();
await Promise.all(pending.splice(0));
kv.delete([...kv.keys()].find((k) => k.endsWith(":SLOW01")));
globalThis.fetch = async () => { throw new Error("offline"); };

const get = (query, e = kept) => worker.fetch(new Request(`https://relay.test/export${query}`), e);
assert.equal((await get("")).status, 401);
assert.equal((await get("?key=wrong")).status, 401);
assert.equal((await get("?key=secret-export-key", { ...kept, EXPORT_KEY: "short" })).status, 401);
r = await get("?key=secret-export-key");
assert.equal(r.status, 200);
assert.match(r.headers.get("content-disposition"), /nimb-reports-\d{4}-\d{2}-\d{2}\.txt/);
const body = await r.text();
assert.match(body, /^Nimb: отчётов 3/);
assert.match(body, /№ AB12CD · 0\.9\.3 · macos · .* · Не включается туннель/);
assert.match(body, /№ ZZ99YY .* Второй человек/);
assert.ok(body.indexOf("AB12CD") < body.indexOf("ZZ99YY"), "oldest first");
assert.equal(kv.size, 3, "export alone does not delete");
await get("?key=secret-export-key&clear=1");
assert.equal(kv.size, 0, "clear=1 deletes what was given");

// A report that the program sends by itself is marked, tagged, kept with its cause, and goes to the chat of the automatic reports if there is one.
{
  const told = [];
  globalThis.fetch = async (url, init) => { told.push({ url: String(url), form: init && init.body }); return new Response("{}", { status: 200 }); };
  const autoBody = { ...good, id: "AU70AA", app: "0.9.14", text: "Отчёт № AU70AA\n\nЧто случилось:\nавто: туннель остановился сам (установка K7M2X9QP)\n\n— Программа —", auto: true, trigger: "tunnel-dropped", install: "K7M2X9QP" };
  const kept2 = { ...env, REPORTS, EXPORT_KEY: "secret-export-key" };
  r = await post(autoBody, kept2);
  assert.equal(r.status, 200);
  assert.equal(told.length, 1, "an automatic report goes to Telegram as a file, as a manual one does");
  assert.equal(told[0].form.get("chat_id"), "42", "to the same chat when there is no chat of its own");
  const caption = told[0].form.get("caption");
  assert.match(caption, /^🤖 авто · Nimb 0\.9\.14 · macos · № AU70AA\n/);
  assert.match(caption, /#авто #tunnel_dropped #macos #v0_9_14 #K7M2X9QP$/);
  assert.equal(told[0].form.get("document").name, "nimb-report-AU70AA.txt");
  told.length = 0;
  await post(autoBody, { ...kept2, AUTO_CHAT_ID: "-1001234" });
  assert.equal(told[0].form.get("chat_id"), "-1001234", "to the chat of the automatic reports when there is one");
  told.length = 0;
  await post(good, { ...kept2, AUTO_CHAT_ID: "-1001234" });
  assert.equal(told[0].form.get("chat_id"), "42", "a report that a person wrote stays in the main chat");
  assert.match(told[0].form.get("caption"), /^✍️ Nimb 0\.9\.3 · macos · № AB12CD/, "and is marked as written by a person");
  const stored = JSON.parse([...kv.values()][0]);
  assert.equal(stored.auto, true);
  assert.equal(stored.trigger, "tunnel-dropped");
  assert.equal(stored.install, "K7M2X9QP");
  kv.clear();
  assert.equal((await post({ ...autoBody, id: "AU70BB", trigger: "<script>", install: "x" }, kept2)).status, 200);
  const odd = JSON.parse([...kv.values()][0]);
  assert.equal(odd.trigger, "", "a cause with odd signs is dropped");
  assert.equal(odd.install, "", "and so is an odd number of installation");
  kv.clear();
  r = await post(autoBody, kept2);
  const exported = await (await worker.fetch(new Request("https://relay.test/export?key=secret-export-key"), kept2)).text();
  assert.match(exported, /№ AU70AA · 0\.9\.14 · macos · .* · авто tunnel-dropped · установка K7M2X9QP · /);
  await worker.fetch(new Request("https://relay.test/export?key=secret-export-key&clear=1"), kept2);
  assert.equal(kv.size, 0);
}

// The chat of the person is found by the Worker, with the export key.
globalThis.fetch = async () => new Response(JSON.stringify({ ok: true, result: [{ message: { chat: { id: 7 } } }, { message: { chat: { id: 4242 } } }] }), { status: 200 });
const find = (query, e = kept) => worker.fetch(new Request(`https://relay.test/chat${query}`), e);
assert.equal((await find("")).status, 401);
assert.equal((await find("?key=wrong")).status, 401);
assert.equal((await find("?key=secret-export-key", { REPORTS, EXPORT_KEY: "secret-export-key" })).status, 401, "needs the bot token");
assert.deepEqual(await (await find("?key=secret-export-key")).json(), { ok: true, chat: "4242" });
// The channel of the automatic reports: where the bot was made an administrator or a post was made.
globalThis.fetch = async () => new Response(JSON.stringify({ ok: true, result: [{ message: { chat: { id: 4242, type: "private" } } }, { my_chat_member: { chat: { id: -1009, type: "channel" } } }, { channel_post: { chat: { id: -1007, type: "channel" } } }] }), { status: 200 });
assert.deepEqual(await (await find("?key=secret-export-key&kind=channel")).json(), { ok: true, chat: "-1007" });
globalThis.fetch = async () => new Response(JSON.stringify({ ok: true, result: [{ message: { chat: { id: 4242, type: "private" } } }] }), { status: 200 });
assert.deepEqual(await (await find("?key=secret-export-key&kind=channel")).json(), { ok: true, chat: null }, "no channel yet");
globalThis.fetch = async () => new Response(JSON.stringify({ ok: true, result: [{ message: { chat: { id: 7 } } }, { message: { chat: { id: 4242 } } }] }), { status: 200 });
globalThis.fetch = async () => new Response(JSON.stringify({ ok: true, result: [] }), { status: 200 });
assert.deepEqual(await (await find("?key=secret-export-key")).json(), { ok: true, chat: null });

console.log("relay: all checks passed");
