// Runs the relay against a pretend Telegram: node test.mjs
import assert from "node:assert/strict";
import worker from "./index.js";

const sent = [];
globalThis.fetch = async (url, init) => {
  sent.push({ url: String(url), form: init.body });
  return new Response(JSON.stringify({ ok: true }), { status: 200 });
};
const env = { BOT_TOKEN: "123:abc", CHAT_ID: "42", LATEST_MAC: "off" };
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

const get = (query, e = kept, key) =>
  worker.fetch(new Request(`https://relay.test/export${query}`, key === undefined ? {} : { headers: { authorization: `Bearer ${key}` } }), e);
assert.equal((await get("")).status, 401);
assert.equal((await get("", kept, "wrong")).status, 401);
assert.equal((await get("?key=secret-export-key")).status, 401, "the key in the address is not taken any more");
assert.equal((await get("", { ...kept, EXPORT_KEY: "short" }, "short")).status, 401);
r = await get("", kept, "secret-export-key");
assert.equal(r.status, 200);
assert.match(r.headers.get("content-disposition"), /nimb-reports-\d{4}-\d{2}-\d{2}\.txt/);
const body = await r.text();
assert.match(body, /^Nimb: отчётов 3/);
assert.match(body, /№ AB12CD · 0\.9\.3 · macos · .* · Не включается туннель/);
assert.match(body, /№ ZZ99YY .* Второй человек/);
assert.ok(body.indexOf("AB12CD") < body.indexOf("ZZ99YY"), "oldest first");
assert.equal(kv.size, 3, "export alone does not delete");
await get("?clear=1", kept, "secret-export-key");
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
  assert.equal(told[0].form.get("chat_id"), "42", "to the same chat as the others");
  const caption = told[0].form.get("caption");
  assert.match(caption, /^🤖 авто · Nimb 0\.9\.14 · macos · № AU70AA\n/);
  assert.match(caption, /#авто #tunnel_dropped #macos #v0_9_14 #K7M2X9QP$/);
  assert.equal(told[0].form.get("document").name, "nimb-report-AU70AA.txt");
  told.length = 0;
  await post(good, kept2);
  assert.equal(told[0].form.get("chat_id"), "42", "a report that a person wrote goes to the same chat");
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
  const exported = await (await worker.fetch(new Request("https://relay.test/export", { headers: { authorization: "Bearer secret-export-key" } }), kept2)).text();
  assert.match(exported, /№ AU70AA · 0\.9\.14 · macos · .* · авто tunnel-dropped · установка K7M2X9QP · /);
  await worker.fetch(new Request("https://relay.test/export?clear=1", { headers: { authorization: "Bearer secret-export-key" } }), kept2);
  assert.equal(kv.size, 0);
}

// The chat of the person is found by the Worker, with the export key.
globalThis.fetch = async () => new Response(JSON.stringify({ ok: true, result: [{ message: { chat: { id: 7 } } }, { message: { chat: { id: 4242 } } }] }), { status: 200 });
const find = (e = kept, key) =>
  worker.fetch(new Request("https://relay.test/chat", key === undefined ? {} : { headers: { authorization: `Bearer ${key}` } }), e);
assert.equal((await find()).status, 401);
assert.equal((await find(kept, "wrong")).status, 401);
assert.equal((await find({ REPORTS, EXPORT_KEY: "secret-export-key" }, "secret-export-key")).status, 401, "needs the bot token");
assert.deepEqual(await (await find(kept, "secret-export-key")).json(), { ok: true, chat: "4242" });
globalThis.fetch = async () => new Response(JSON.stringify({ ok: true, result: [] }), { status: 200 });
assert.deepEqual(await (await find(kept, "secret-export-key")).json(), { ok: true, chat: null });

// The signature of a Mac report: checked before the limit, the keeping and Telegram.
{
  const told = [];
  globalThis.fetch = async (url, init) => { told.push(String(url)); return new Response("{}", { status: 200 }); };
  const crypto = await import("node:crypto");
  // The program signs with the key of its own version, which comes from the master key (scripts/report_key.py makes it for the build).
  const versionKey = (master, version) => crypto.createHmac("sha256", master).update(`nimb-key|${version}`).digest("hex");
  const signWith = (data, key) => {
    const hash = crypto.createHash("sha256").update(data.text, "utf8").digest("hex");
    const message = ["nimb1", data.id, data.app, data.platform, data.install ?? "", hash].join("|");
    return crypto.createHmac("sha256", key).update(message).digest("hex");
  };
  const sign = (data, master = "test-key") => signWith(data, versionKey(master, data.app));
  let asked = 0;
  const strict = { ...env, REPORTS, REPORT_KEY: "test-key", LIMITER: { limit: async () => { asked++; return { success: true }; } } };
  const fresh = { ...good, id: "SG01AA", app: "0.9.23", text: "текст" };

  // The same line and key as the test of the program (Tests/NimbTests/ReportTests.swift): the two sides must give the same letters.
  assert.equal(signWith({ id: "AB12CD", app: "0.9.23", platform: "macos", install: "ABCD2345", text: "текст" }, "test-key"), "8d7d8304a9c38885b81822903a8d789248e7b4333623ae5aafadc6d7ceb580e1");
  // The key of a version, the same as the build script makes (scripts/test.sh runs the script against this value).
  assert.equal(versionKey("test-master", "0.9.23"), "9297899018b3ede3fff74dc1a582516c01c52cb17aaa53aa593f5cdcd87c10b0");

  kv.clear();
  assert.equal((await post({ ...fresh, sig: sign(fresh) }, strict)).status, 200, "a signed report of a new version is taken");
  assert.equal(told.length, 1);
  assert.equal(kv.size, 1);
  const auto = { ...fresh, id: "SG02BB", auto: true, trigger: "daily", install: "K7M2X9QP" };
  assert.equal((await post({ ...auto, sig: sign(auto) }, strict)).status, 200, "so is an automatic one, with the number of the installation in the line");

  told.length = 0; kv.clear(); asked = 0;
  assert.equal((await post(fresh, strict)).status, 403, "no signature");
  assert.equal((await post({ ...fresh, sig: "0".repeat(64) }, strict)).status, 403, "a wrong one");
  assert.equal((await post({ ...fresh, sig: "zz" }, strict)).status, 403, "not letters of a signature");
  assert.equal((await post({ ...fresh, text: "другой текст", sig: sign(fresh) }, strict)).status, 403, "the text was changed after it was signed");
  assert.equal((await post({ ...fresh, app: "0.9.24", sig: sign(fresh) }, strict)).status, 403, "so was the version");
  assert.equal((await post({ ...auto, install: "OTHER123", sig: sign(auto) }, strict)).status, 403, "and the installation");
  assert.equal((await post({ ...fresh, sig: sign(fresh, "other-key") }, strict)).status, 403, "a key that is not ours");
  assert.equal((await post({ ...fresh, app: "0.9.24", sig: signWith({ ...fresh, app: "0.9.24" }, versionKey("test-key", "0.9.23")) }, strict)).status, 403, "the key of one version signs no other version");
  assert.equal((await post({ ...fresh, sig: signWith(fresh, "test-key") }, strict)).status, 403, "the master key itself is no key of a version");
  assert.equal((await post({ ...fresh, app: "setup", sig: undefined }, strict)).status, 403, "a version that is no version needs a signature too");
  assert.equal((await post({ ...fresh, sig: sign(fresh) }, { ...strict, REPORT_KEY: undefined })).status, 403, "no key in the secrets: nothing signed is taken");
  assert.equal(told.length, 0, "nothing turned away reaches Telegram");
  assert.equal(kv.size, 0, "nor the storage");
  assert.equal(asked, 0, "nor the count of the address");

  const changing = { ...strict, REPORT_KEY: "new-key", REPORT_KEY_PREV: "test-key" };
  assert.equal((await post({ ...fresh, sig: sign(fresh) }, changing)).status, 200, "the key before it still works while the key is being changed");
  assert.equal((await post({ ...fresh, id: "SG03CC", sig: sign({ ...fresh, id: "SG03CC" }, "new-key") }, changing)).status, 200, "and the new one");
  const next = { ...fresh, id: "SG04DD", app: "0.9.24" };
  assert.equal((await post({ ...next, sig: sign(next) }, strict)).status, 200, "the next version has a key of its own, and the relay finds it by the version in the report");

  const old = { ...good, id: "OLD001", app: "0.9.22" };
  assert.equal((await post(old, strict)).status, 200, "a version from before the signature, as before");
  assert.equal((await post({ ...old, app: "0.8.30" }, strict)).status, 200);
  assert.equal((await post({ ...old, app: "0.9.23" }, strict)).status, 403);
  assert.equal((await post(old, { ...strict, UNSIGNED_UP_TO: "0.0.0" })).status, 403, "closed when the testers have moved on");
  assert.equal((await post({ ...good, id: "WIN001", platform: "windows", app: "0.2.3" }, strict)).status, 200, "the Windows build signs nothing yet");
  kv.clear();
}

// Only the latest version of the Mac program reports: an older one is turned away (and told which one is the latest), before it is counted,
// kept or sent anywhere.
{
  const told = [];
  const github = (answer) => async (url, init) => {
    told.push(String(url));
    if (String(url).startsWith("https://api.github.com/")) return typeof answer === "function" ? answer() : new Response(JSON.stringify(answer), { status: 200 });
    return new Response("{}", { status: 200 });
  };
  let asked = 0;
  const open = { ...env, LATEST_MAC: undefined, UNSIGNED_UP_TO: "99.0.0", REPORTS, LIMITER: { limit: async () => { asked++; return { success: true }; } } };
  const report = { ...good, id: "FR01AA", app: "0.9.22" };
  kv.clear();

  globalThis.fetch = github({ tag_name: "v0.9.23" });
  let answer = await post(report, open);
  assert.equal(answer.status, 403, "an older version is not taken");
  assert.deepEqual(await answer.json(), { ok: false, error: "outdated", latest: "0.9.23" });
  assert.equal(told.filter((url) => !url.startsWith("https://api.github.com/")).length, 0, "nothing reached Telegram");
  assert.equal(kv.size, 0, "nor the storage");
  assert.equal(asked, 0, "nor the count of the address");
  assert.match(told[0], /^https:\/\/api\.github\.com\/repos\/Dizrane\/Nimb\/releases\/latest$/);

  assert.equal((await post({ ...report, app: "0.9.23" }, open)).status, 200, "the latest one is taken");
  assert.equal((await post({ ...report, id: "FR02BB", app: "0.9.24" }, open)).status, 200, "and one that is ahead of the latest (a build before its release)");
  assert.equal((await post({ ...report, id: "FR03CC", platform: "windows", app: "0.1.0" }, open)).status, 200, "the Windows build has its own versions");
  assert.equal((await post({ ...report, app: "0.9.9" }, open)).status, 403, "ten is more than nine: 0.9.9 is older than 0.9.23");

  for (const [name, fetcher] of [
    ["no answer", () => { throw new Error("offline"); }],
    ["an error of GitHub", github(() => new Response("{}", { status: 403 }))],
    ["something that is not json", github(() => new Response("<html>", { status: 200 }))],
    ["a release of the Windows version made the latest", github({ tag_name: "windows-v0.2.3" })],
    ["no tag", github({})],
  ]) {
    globalThis.fetch = fetcher;
    assert.equal((await post({ ...report, id: "FR04DD" }, open)).status, 200, `${name}: no minimum, the report is taken`);
  }

  globalThis.fetch = github({ tag_name: "v9.9.9" });
  assert.equal((await post(report, { ...open, LATEST_MAC: "off" })).status, 200, "the check can be turned off");
  assert.equal((await post(report, { ...open, LATEST_MAC: "0.9.23" })).status, 403, "or set by hand, and GitHub is not asked then");
  assert.equal((await post(report, { ...open, LATEST_MAC: "0.9.22" })).status, 200);
  assert.equal((await post({ ...report, app: "0.9.21" }, { ...open, LATEST_MAC: "0.9.22" })).status, 403);
  kv.clear();
}

console.log("relay: all checks passed");
