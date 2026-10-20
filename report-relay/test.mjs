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

// The chat of the person is found by the Worker, with the export key.
globalThis.fetch = async () => new Response(JSON.stringify({ ok: true, result: [{ message: { chat: { id: 7 } } }, { message: { chat: { id: 4242 } } }] }), { status: 200 });
const find = (query, e = kept) => worker.fetch(new Request(`https://relay.test/chat${query}`), e);
assert.equal((await find("")).status, 401);
assert.equal((await find("?key=wrong")).status, 401);
assert.equal((await find("?key=secret-export-key", { REPORTS, EXPORT_KEY: "secret-export-key" })).status, 401, "needs the bot token");
assert.deepEqual(await (await find("?key=secret-export-key")).json(), { ok: true, chat: "4242" });
globalThis.fetch = async () => new Response(JSON.stringify({ ok: true, result: [] }), { status: 200 });
assert.deepEqual(await (await find("?key=secret-export-key")).json(), { ok: true, chat: null });

console.log("relay: all checks passed");
