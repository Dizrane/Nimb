import { Animator, makeCanvas, begin, now } from './anim.js';
import { drawRingStack } from './halo.js';
import { IconView, playIcon, preloadIcons } from './icons.js';
import { preload } from './art.js';
import { api, logPage, SV, ORDER, esc } from './common.js';
import { HomePage, AIPage, TelegramPage, MediaPage, SettingsPage, ReportPage, showSites } from './pages.js';
import { Onboarding } from './onboarding.js';

// The page of Nimb. All it knows comes from Go (window.go.main.App.*): GetState() every two seconds and the actions below.
let S = null;                 // the state from Go
let page = 'home';            // home, ai, telegram, media, settings, report
let current = null;           // the object of the page that is shown
let onb = null;               // the first setup, while it is shown
let rep = null;               // the report about a problem
let testSent = false;         // the test notification was just sent: the button says so for 3 seconds
let autostart = false;        // whether Nimb starts with Windows (read when the settings open)
let prevOn = null;            // what worked at the last look, to play an icon when a service goes on
const icons = {};             // the animated icons of the sidebar
let rings = null;             // the three small rings of the home row

const isOn = (k) => !!S[k].on;
const effective = () => ORDER.filter((k) => S[k].on || S[k].busy).length;

// ---------------------------------------------------------------------------------------------------------------- the shell

function buildShell() {
  const rows = ORDER.map((k) => `<div class="row-item" id="row-${k}">
      <div class="face"><button class="icon" data-a="play" data-v="${k}" tabindex="-1" aria-hidden="true"></button>
      <button class="rl" data-a="nav" data-v="${k}" data-f="nav-${k}" id="nav-${k}" aria-label="${SV[k].title}">${SV[k].title}</button></div>
      <span id="slot-${k}"></span></div>`).join('');
  document.getElementById('app').innerHTML = `
    <nav class="side" aria-label="Разделы">
      <div class="row-item" id="row-home"><div class="face"><div class="icon" id="home-icon" style="width:26px"></div>
        <button class="rl" data-a="nav" data-v="home" data-f="nav-home" id="nav-home">Главная</button></div></div>
      <div class="sec">Сервисы</div>${rows}<div class="spacer"></div>
      <div class="row-item" id="row-settings"><div class="face"><button class="icon" data-a="play" data-v="settings" tabindex="-1" aria-hidden="true"></button>
        <button class="rl" data-a="nav" data-v="settings" data-f="nav-settings" id="nav-settings">Настройки</button></div></div>
    </nav>
    <main class="main"><div id="banner"></div><div id="content" style="flex:1;min-height:0;display:flex;flex-direction:column"></div>
      <div class="foot"><span id="version"></span><span id="upd"></span><button data-a="channel" data-f="channel" id="channel">Канал в Telegram ↗</button></div></main>`;

  for (const k of ORDER) {
    icons[k] = new IconView(SV[k].icon, 32, () => !S || !S[k].on);
    document.querySelector(`#row-${k} .icon`).appendChild(icons[k].canvas);
  }
  icons.settings = new IconView('gear', 32, () => false);
  document.querySelector('#row-settings .icon').appendChild(icons.settings.canvas);

  const [c, ctx, dpr] = makeCanvas(28, 22);
  c.style.cssText += ';position:absolute;left:-1px;top:1px';
  document.getElementById('home-icon').style.cssText += ';position:relative;height:24px';
  document.getElementById('home-icon').appendChild(c);
  rings = new Animator(() => { begin(ctx, dpr, 28, 22); drawRingStack(ctx, 14, 11, S ? effective() : 0, page === 'home'); }, { fps: 10, wants: () => false });
}

function updateShell() {
  document.getElementById('version').textContent = `Версия ${S.version}`;
  const banner = document.getElementById('banner');
  const text = S.serviceOk ? (S.update.error || '') : S.serviceError;
  if (banner.dataset.text !== text) { banner.dataset.text = text; banner.innerHTML = text ? `<div class="banner" role="alert">${esc(text)}</div>` : ''; }
  // A newer version: the button at the bottom of the window, as on the Mac. While it is being installed it says what goes on.
  const u = S.update, upd = document.getElementById('upd');
  const key = u.installing ? `i|${u.installing}` : u.available ? `a|${u.version}` : '';
  if (upd.dataset.key !== key) {
    upd.dataset.key = key;
    upd.innerHTML = u.installing ? `<span class="upd busy"><span class="spin"></span>${esc(u.installing)}</span>`
      : u.available ? `<button class="upd" data-a="update" data-f="update" id="update">Обновить до ${esc(u.version)}</button>` : '';
  }
  const sel = page === 'report' ? 'settings' : page;
  for (const id of ['home', ...ORDER, 'settings']) document.getElementById(`row-${id}`).classList.toggle('sel', id === sel);
  for (const k of ORDER) {
    const slot = document.getElementById(`slot-${k}`);
    const busy = S[k].busy, on = isOn(k), disabled = busy || !(k === 'telegram' || S.serviceOk) || (k === 'ai' && S.probe.running);
    const key = `${busy}|${on}|${disabled}`;
    if (slot.dataset.key !== key) {
      slot.dataset.key = key;
      slot.innerHTML = busy ? '<span class="pending"><span class="spin"></span></span>'
        : `<button class="pill ${on ? 'on' : ''}" role="switch" aria-checked="${on}" aria-label="${SV[k].title}" data-a="sw" data-v="${k}" data-f="sw-${k}" id="sw-${k}" ${disabled ? 'disabled' : ''}></button>`;
    }
    icons[k].invalidate();
  }
  rings.invalidate();
}

// ---------------------------------------------------------------------------------------------------------------- pages

function showPage(name) {
  if (current) current.destroy();
  page = name;
  const content = document.getElementById('content');
  content.replaceChildren();
  const make = { home: HomePage, ai: AIPage, telegram: TelegramPage, media: MediaPage, settings: SettingsPage }[name];
  current = name === 'report' ? new ReportPage(actions, rep) : new make(actions);
  current.mount(content);
  if (name === 'settings') readAutostart();
  render();
}

function render() {
  if (!S) return;
  updateShell();
  current.update(S, { autostart, testSent });
  if (onb) onb.update(S, { autostart });
}

async function readAutostart() {
  try { const v = await api().GetAutostart(); if (v !== autostart) { autostart = v; render(); } } catch (e) { /* keep */ }
}

// -------------------------------------------------------------------------------------------------------------------- state

async function refresh() {
  let next;
  try { next = await api().GetState(); } catch (e) { return; }
  if (prevOn) for (const k of ORDER) if (next[k].on && !prevOn[k]) playIcon(SV[k].icon);
  prevOn = { ai: next.ai.on, telegram: next.telegram.on, media: next.media.on };
  S = next;
  if (page === 'settings' || onb) readAutostart();
  render();
}

/** While the providers are being checked the state is read often, so that the progress moves. */
let watching = false;
async function watchProbe() {
  if (watching) return;
  watching = true;
  try { do { await new Promise((r) => setTimeout(r, 400)); await refresh(); } while (S && S.probe.running); } finally { watching = false; }
}
async function startProbe(enable) {
  S.probe.running = true; S.probe.done = 0; S.probe.total = 0; S.probe.phase = 'addresses'; if (enable) S.probe.reports = []; render();
  try { await api()[enable ? 'EnableBest' : 'ProbeStart'](); } catch (e) { /* the state tells */ }
  await refresh();
  watchProbe();
}

const actions = {
  async toggle(k) {
    if (S[k].busy) return;
    S[k].busy = true; render();
    try { await api()[SV[k].call](!isOn(k)); } catch (e) { /* the error text comes back with the state */ }
    await refresh();
  },
  async toggleAll() {
    const on = !ORDER.every(isOn);
    ORDER.forEach((k) => { S[k].busy = true; }); render();
    try { await api().SetAll(on); } catch (e) { /* see the state */ }
    await refresh();
  },
};

function note(text) { const n = document.getElementById('note'); if (n) { n.textContent = text; setTimeout(() => { if (n.textContent === text) n.textContent = ''; }, 2500); } }

// -------------------------------------------------------------------------------------------------------------------- report

async function openReport() {
  rep = { id: '', loading: true, description: '', contact: '', stage: 'form', message: '', details: false, preview: '', asked: false };
  showPage('report');
  try { const p = await api().ReportPrepare(); rep.id = p.id; } catch (e) { /* the form still works, the facts are empty */ }
  rep.loading = false;
  if (page === 'report') { await refreshPreview(); current.render(); }
}
async function refreshPreview() {
  if (!rep || !rep.details || rep.loading) return;
  try { rep.preview = await api().ReportPreview(rep.description, rep.contact); } catch (e) { /* keep */ }
}
let previewTimer = null;
document.addEventListener('input', (e) => {
  const t = e.target;
  if (!rep || !t.dataset || !t.dataset.input) return;
  rep[t.dataset.input] = t.value;
  clearTimeout(previewTimer);
  previewTimer = setTimeout(async () => { await refreshPreview(); const pre = document.querySelector('.preview'); if (pre) pre.textContent = rep.preview; }, 300);
});

// -------------------------------------------------------------------------------------------------------------------- events

window.addEventListener('error', (e) => logPage(`error: ${e.message} at ${e.lineno}`));
window.addEventListener('unhandledrejection', (e) => logPage(`rejected: ${e.reason}`));

async function finishOnboarding() {
  try { await api().FinishOnboarding(); } catch (e) { /* ask again next time */ }
  if (onb) { onb.destroy(); onb = null; }
  showPage('home');
}

document.addEventListener('click', async (e) => {
  const t = e.target.closest('[data-a]');
  logPage(`click ${t ? t.dataset.a + ' ' + (t.dataset.v || '') : e.target.tagName}${t && t.disabled ? ' (disabled)' : ''}`);
  if (!t || t.disabled) return;
  const v = t.dataset.v;
  switch (t.dataset.a) {
    case 'nav': showPage(v); break;
    case 'play': playIcon(v === 'settings' ? 'gear' : SV[v].icon); break;
    case 'sw': await actions.toggle(v); break;
    case 'probe': await startProbe(false); break;
    case 'det': if (current.toggleDetails) { current.toggleDetails(v); render(); } break;
    case 'onbbest': await startProbe(true); break;
    case 'prov': { S.ai.provider = v; render(); await api().SetProvider(v); await refresh(); break; }
    case 'openTg': { const r = await api().OpenTelegram(); if (!r.ok) note(r.error); break; }
    case 'copy': { const r = await api().CopyLink(); note(r.ok ? 'Ссылка скопирована' : r.error); break; }
    case 'channel': api().OpenChannel(); break;
    case 'notify': { S.update.notify = !S.update.notify; render(); await api().SetNotify(S.update.notify); await refresh(); break; }
    case 'notifytest': { const r = await api().SendTestNotification(); if (r.ok) { testSent = true; render(); setTimeout(() => { testSent = false; render(); }, 3000); } break; }
    case 'update': { S.update.installing = 'Загрузка…'; render(); await api().InstallUpdate(); await refresh(); break; }
    case 'terms': api().OpenTerms(); break;
    case 'sites': showSites(); break;
    case 'quit': api().Quit(); break;
    case 'uninstall': api().Uninstall(); break;
    case 'autostart': { const r = await api().SetAutostart(!autostart); if (r.ok) autostart = !autostart; render(); break; }
    case 'onboard': await api().RestartOnboarding(); onb = new Onboarding(actions); render(); break;
    case 'onbnext': onb.next(); render(); break;
    case 'onbclose': case 'onbfinish': await finishOnboarding(); break;
    case 'report': await openReport(); break;
    case 'repcancel': case 'repclose': showPage('settings'); break;
    case 'repdetails': rep.details = !rep.details; await refreshPreview(); current.render(); break;
    case 'repcopy': { const r = await api().ReportCopy(rep.description, rep.contact); if (!r.ok) { rep.message = r.error; rep.stage = 'failed'; } current.render(); break; }
    case 'repwrite': { const r = await api().ReportWrite(rep.description, rep.contact); rep.asked = r.ok; current.render(); break; }
    case 'repsend': {
      rep.stage = 'sending'; rep.asked = false; current.render();
      const r = await api().ReportSend(rep.description, rep.contact);
      if (r.ok) rep.stage = 'sent'; else { rep.stage = 'failed'; rep.message = r.error; }
      current.render(); break;
    }
  }
});

document.addEventListener('keydown', (e) => {
  if (e.key !== 'Escape' || onb) return;
  if (page === 'report') showPage('settings'); else if (page !== 'home') showPage('home');
});

const CORE_ART = [
  'halo/back.png', 'halo/front.png', ...Array.from({ length: 24 }, (_, i) => `halo/sparkle-${String(i).padStart(2, '0')}.png`),
  'header/ring-back.png', 'header/ring-front.png', 'icon-ai/flower.png', 'icon-ai/flower-off.png', 'icon-telegram/plane.png', 'icon-telegram/plane-off.png',
  'icon-media/play.png', 'icon-media/play-off.png', 'icon-gear/gear.png',
];

window.addEventListener('load', async () => {
  // The first picture is drawn when the halo is here; a slow disk does not hold the window for more than a moment.
  await Promise.race([preload(CORE_ART), new Promise((r) => setTimeout(r, 1500))]);
  let first = 'home';
  try { const p = await api().InitialPage(); if (['home', 'ai', 'telegram', 'media', 'settings'].includes(p)) first = p; } catch (e) { /* the home page */ }
  try { S = await api().GetState(); } catch (e) { S = null; }
  if (!S) return;
  prevOn = { ai: S.ai.on, telegram: S.telegram.on, media: S.media.on };
  // The first setup shows on a computer that has nothing set up yet; one that already has something on was set up by hand.
  // It is decided before the first picture, so that the window opens on the setup and not on the home page.
  let firstSetup = false;
  try {
    if (!(await api().Onboarded())) {
      if (ORDER.some(isOn)) await api().FinishOnboarding();
      else { await readAutostart(); firstSetup = true; }
    }
  } catch (e) { /* no first setup */ }
  buildShell();
  showPage(first);
  if (firstSetup) { onb = new Onboarding(actions); render(); }
  preloadIcons();
  setInterval(() => { if (document.visibilityState === 'visible') refresh(); }, 2000);
  window.addEventListener('focus', refresh);
});
