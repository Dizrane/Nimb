'use strict';
// The page of Nimb. All it knows comes from Go (window.go.main.App.*): GetState() every two seconds and the actions below.

const SV = {
  ai: { title: 'Нейросети', desc: 'ChatGPT, Claude, Gemini и другие', ico: 'icon-ai/flower', off: 'icon-ai/flower-off', call: 'SetAI' },
  telegram: { title: 'Telegram', desc: 'Прокси для Telegram Desktop', ico: 'icon-telegram/plane', off: 'icon-telegram/plane-off', call: 'SetTelegram' },
  media: { title: 'YouTube и Discord', desc: 'Туннель для YouTube и Discord', ico: 'icon-media/play', off: 'icon-media/play-off', call: 'SetMedia' },
};
const ORDER = ['ai', 'telegram', 'media'];
const art = (p) => `art/${p}.png`;
const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

let S = null;            // the state from Go
let page = 'home';       // home, ai, telegram, media, settings
let lastJSON = '';

const api = () => window.go.main.App;
const isOn = (k) => !!S[k].on;
const nOn = () => ORDER.filter(isOn).length;

// ---- text ------------------------------------------------------------------------------------------------------------

function allTitle() { const n = nOn(); return n === 3 ? 'Всё включено' : n === 0 ? 'Выключено' : 'Включено частично'; }
function allSub() {
  const n = nOn();
  return n === 3 ? 'Нейросети, Telegram, YouTube и Discord работают.'
    : n === 0 ? 'Одна кнопка включает нейросети, Telegram, YouTube и Discord.'
    : 'Включите остальное кнопкой или переключателями.';
}
function providerName(id) { return (S.providers.find((p) => p.id === id) || {}).name || ''; }
function statusLine(k) {
  const s = S[k];
  if (s.busy) return isOn(k) ? 'Выключаем…' : 'Включаем…';
  if (!isOn(k)) return 'Выключено';
  if (k === 'ai') return providerName(S.ai.provider);
  if (k === 'telegram') return `127.0.0.1:${S.telegram.port}`;
  return 'Туннель работает';
}

// ---- pieces ----------------------------------------------------------------------------------------------------------

function sw(k) {
  const busy = S[k].busy;
  return `<button class="sw ${isOn(k) ? 'on' : ''} ${busy ? 'busy' : ''}" role="switch" aria-checked="${isOn(k)}" aria-label="${SV[k].title}"
    data-a="sw" data-v="${k}" data-f="sw-${k}" id="sw-${k}" ${busy || !serviceNeeded(k) ? 'disabled' : ''}></button>`;
}
// DNS and the tunnel need the service; the proxy of Telegram does not.
function serviceNeeded(k) { return k === 'telegram' || S.serviceOk; }

function hero(scale) {
  const n = nOn(), W = 220 * scale, H = 150 * scale;
  let h = '';
  for (let i = 0; i < 3; i++) {
    const s = (0.78 - i * 0.055) * scale, cy = (84 - i * 22 + 8) * scale, o = i < n ? [0.8, 0.92, 1][i] : 0;
    const st = `left:${W / 2 - 168 * s}px;top:${cy - 97 * s}px;width:${336 * s}px;height:${194 * s}px;opacity:${o}`;
    h += `<img class="halo" style="${st}" src="${art('halo/back')}" alt=""><img class="halo" style="z-index:2;${st}" src="${art('halo/front')}" alt="">`;
  }
  const dw = 78 * scale, dh = (dw * 154) / 128;
  return `<div class="hero"><div class="stage" style="width:${W}px;height:${H}px">${h}
    <img style="z-index:1;left:${W / 2 - dw / 2}px;top:${60 * scale}px;width:${dw}px;height:${dh}px" src="${art('hood/' + (n ? 'on' : 'off'))}" alt="">
    </div><h2>${allTitle()}</h2><div class="sub">${allSub()}</div>
    <button class="btn main" data-a="all" data-f="all" id="all">${n === 3 ? 'Выключить всё' : 'Включить всё'}</button></div>`;
}

function serviceHero(k) {
  const s = S[k], on = isOn(k);
  const img = k === 'ai'
    ? `<img class="planet ${on ? '' : 'off'}" src="${art('icon-ai/planet')}" alt="">`
    : `<img class="bigicon ${on ? '' : 'off'}" src="${art(on ? SV[k].ico : SV[k].off)}" alt="">`;
  return `<div class="hero left">${img}
    <h2>${s.busy ? (on ? 'Выключаем…' : 'Включаем…') : on ? 'Включено' : 'Выключено'}</h2>
    <div class="status"><span class="dot ${on ? 'on' : ''}"></span><span>${esc(statusLine(k))}</span></div>
    <button class="btn main" data-a="sw" data-v="${k}" data-f="power" id="power" ${s.busy || !serviceNeeded(k) ? 'disabled' : ''}>${on ? 'Выключить' : 'Включить'}</button>
    ${s.error ? `<div class="err">${esc(s.error)}</div>` : ''}</div>`;
}

// ---- pages -----------------------------------------------------------------------------------------------------------

function pageHome() { return `<div class="center">${hero(1.25)}</div>`; }

function pageAI() {
  const cards = S.providers.map((p) => {
    const sel = p.id === S.ai.provider;
    return `<button class="prov ${sel ? 'sel' : ''}" role="radio" aria-checked="${sel}" data-a="prov" data-v="${p.id}" data-f="prov-${p.id}" id="prov-${p.id}">
      <span class="nm grow">${esc(p.name)}${sel && S.ai.on ? ' <span class="on">· активен</span>' : ''}</span>
      <span class="radio">${sel ? '<i></i>' : ''}</span></button>`;
  }).join('');
  return `<div class="cols">${serviceHero('ai')}<div class="right"><div class="label" style="margin:0 0 9px">DNS-провайдеры</div>
    <div role="radiogroup" aria-label="DNS-провайдеры">${cards}</div></div></div>`;
}

function pageTelegram() {
  const on = isOn('telegram'), st = S.telegram.stats || {};
  const stats = on ? `Соединений: ${st.Total} (сейчас ${st.Active})   ↑ ${bytes(st.BytesUp)}   ↓ ${bytes(st.BytesDown)}` : '';
  return `<div class="cols">${serviceHero('telegram')}<div class="right">
    <div class="card"><div class="nm">Подключить Telegram</div>
      <div class="sm" style="margin:3px 0 10px">Кнопка откроет Telegram Desktop с окном «Добавить прокси»: подтвердите его.</div>
      <div class="row" style="flex-wrap:wrap;gap:8px">
        <button class="btn" data-a="copy" data-f="copy" id="copy" ${on ? '' : 'disabled'}>Скопировать ссылку</button>
        <button class="btn main" data-a="openTg" data-f="open" id="open" ${on ? '' : 'disabled'}>Открыть в Telegram</button></div>
      <div id="note" class="sm" style="margin-top:8px;min-height:18px"></div></div>
    <div class="mono" style="margin:10px 4px">${esc(stats)}</div></div></div>`;
}

function pageMedia() {
  return `<div class="cols">${serviceHero('media')}<div class="right">
    <div class="card"><div class="nm">Как это работает</div>
      <div class="sm" style="margin-top:3px">У вас личная анонимная учётная запись Cloudflare WARP, созданная при первом включении. Весь трафик идёт через неё, поэтому открываются и другие закрытые сайты.</div></div>
    ${S.serviceOk ? '' : ''}</div></div>`;
}

function pageSettings() {
  return `<div class="card row"><div class="grow"><div class="nm">Версия</div><div class="sm">Nimb для Windows ${esc(S.version)}</div></div></div>
    <div class="card row"><div class="grow"><div class="nm">Работа в фоне</div><div class="sm">Закрытие окна не выключает Nimb: он остаётся у часов. Выйти можно из меню значка.</div></div>
      <button class="btn" data-a="quit" data-f="quit" id="quit">Выйти из Nimb</button></div>`;
}

const PAGES = { home: pageHome, ai: pageAI, telegram: pageTelegram, media: pageMedia, settings: pageSettings };
const TITLES = { home: '', ai: 'Нейросети', telegram: 'Telegram', media: 'YouTube и Discord', settings: 'Настройки' };

function bytes(n) {
  n = n || 0;
  if (n < 1024) return `${n} Б`;
  if (n < 1048576) return `${(n / 1024).toFixed(0)} КБ`;
  return `${(n / 1048576).toFixed(1).replace('.', ',')} МБ`;
}

// ---- the window ------------------------------------------------------------------------------------------------------

function stackMini() {
  return [0, 1, 2].map((i) => {
    const o = isOn(ORDER[2 - i]) ? 1 : 0.2;
    return `<img src="${art('header/ring-back')}" style="top:${-0.5 + i * 5}px;opacity:${o}" alt=""><img src="${art('header/ring-front')}" style="top:${-0.5 + i * 5}px;opacity:${o}" alt="">`;
  }).join('');
}

function render() {
  const focused = document.activeElement && document.activeElement.dataset ? document.activeElement.dataset.f : null;
  const items = ORDER.map((k) => `<div class="si ${page === k ? 'sel' : ''}">
      <button class="row grow" style="gap:10px;min-width:0" data-a="nav" data-v="${k}" data-f="nav-${k}" id="nav-${k}" aria-label="${SV[k].title}">
        <img class="ico ${isOn(k) ? '' : 'off'}" src="${art(isOn(k) ? SV[k].ico : SV[k].off)}" alt=""><span class="name">${SV[k].title}</span></button>${sw(k)}</div>`).join('');
  document.getElementById('app').innerHTML = `
    <nav class="side" aria-label="Разделы">
      <button class="si ${page === 'home' ? 'sel' : ''}" data-a="nav" data-v="home" data-f="nav-home" id="nav-home"><span class="rings">${stackMini()}</span><span class="name">Главная</span></button>
      <div class="sec">Сервисы</div>${items}<div class="grow"></div>
      <button class="si ${page === 'settings' ? 'sel' : ''}" data-a="nav" data-v="settings" data-f="nav-settings" id="nav-settings"><img class="ico" src="${art('icon-gear/gear')}" alt=""><span class="name">Настройки</span></button>
    </nav>
    <main class="main">
      ${TITLES[page] ? `<h1>${TITLES[page]}</h1>` : '<div style="height:12px"></div>'}
      ${S.serviceOk ? '' : `<div class="banner" role="alert">${esc(S.serviceError)}</div>`}
      <div class="body">${PAGES[page]()}</div>
    </main>
    <div class="foot"><span>Версия ${esc(S.version)}</span><button data-a="channel" data-f="channel" id="channel">Канал в Telegram ↗</button></div>`;
  if (focused) { const el = document.querySelector(`[data-f="${focused}"]`); if (el) el.focus(); }
}

// ---- actions ---------------------------------------------------------------------------------------------------------

async function refresh() {
  try {
    S = await api().GetState();
  } catch (e) {
    return;
  }
  const json = JSON.stringify(S) + page;
  if (json !== lastJSON) { lastJSON = json; render(); }
}

async function setService(k, on) {
  if (S[k].busy) return;
  S[k].busy = true; render();
  try { await api()[SV[k].call](on); } catch (e) { /* the error text comes back with the state */ }
  await refresh();
}

function note(text) { const n = document.getElementById('note'); if (n) { n.textContent = text; setTimeout(() => { if (n.textContent === text) n.textContent = ''; }, 2500); } }

const report = (what) => { try { api().Log(String(what)); } catch (e) { /* no bridge */ } };
window.addEventListener('error', (e) => report(`error: ${e.message} at ${e.lineno}`));
window.addEventListener('unhandledrejection', (e) => report(`rejected: ${e.reason}`));

document.addEventListener('click', async (e) => {
  const t = e.target.closest('[data-a]');
  report(`click ${t ? t.dataset.a + ' ' + (t.dataset.v || '') : e.target.tagName}${t && t.disabled ? ' (disabled)' : ''}`);
  if (!t || t.disabled) return;
  const v = t.dataset.v;
  switch (t.dataset.a) {
    case 'nav': page = v; lastJSON = ''; render(); break;
    case 'sw': await setService(v, !isOn(v)); break;
    case 'all': {
      const on = nOn() !== 3;
      ORDER.forEach((k) => { S[k].busy = true; }); render();
      try { await api().SetAll(on); } catch (err) { /* see the state */ }
      await refresh(); break;
    }
    case 'prov': {
      S.ai.provider = v; render();
      await api().SetProvider(v); await refresh(); break;
    }
    case 'openTg': { const r = await api().OpenTelegram(); if (!r.ok) note(r.error); break; }
    case 'copy': { const r = await api().CopyLink(); note(r.ok ? 'Ссылка скопирована' : r.error); break; }
    case 'channel': api().OpenChannel(); break;
    case 'quit': api().Quit(); break;
  }
});

document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && page !== 'home') { page = 'home'; lastJSON = ''; render(); } });

window.addEventListener('load', async () => {
  try { const p = await api().InitialPage(); if (TITLES[p] !== undefined) page = p; } catch (e) { /* the home page */ }
  await refresh();
  setInterval(() => { if (document.visibilityState === 'visible') refresh(); }, 2000);
  window.addEventListener('focus', refresh);
});
