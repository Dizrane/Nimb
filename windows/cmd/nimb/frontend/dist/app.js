'use strict';
// Everything lives in one function: a name of this page must never replace a name of the Wails bridge (window.go, window.runtime).
(() => {
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
let page = 'home';       // home, ai, telegram, media, settings, report
let lastJSON = '';
let autostart = false;   // is Nimb started with Windows (read when the settings open)
let onb = { active: false, step: 0 };                    // the first setup
let rep = null;                                          // the report about a problem

const api = () => window.go.main.App;
const isOn = (k) => !!S[k].on;
const nOn = () => ORDER.filter(isOn).length;
const logPage = (what) => { try { api().Log(String(what)); } catch (e) { /* no bridge */ } };

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
function bytes(n) {
  n = n || 0;
  if (n < 1024) return `${n} Б`;
  if (n < 1048576) return `${(n / 1024).toFixed(0)} КБ`;
  return `${(n / 1048576).toFixed(1).replace('.', ',')} МБ`;
}

// ---- pieces ----------------------------------------------------------------------------------------------------------

// DNS and the tunnel need the service; the proxy of Telegram does not.
function serviceNeeded(k) { return k === 'telegram' || S.serviceOk; }

function sw(k) {
  const busy = S[k].busy;
  return `<button class="sw ${isOn(k) ? 'on' : ''} ${busy ? 'busy' : ''}" role="switch" aria-checked="${isOn(k)}" aria-label="${SV[k].title}"
    data-a="sw" data-v="${k}" data-f="sw-${k}" id="sw-${k}" ${busy || !serviceNeeded(k) ? 'disabled' : ''}></button>`;
}

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
      <div class="sm" style="margin-top:3px">У вас личная анонимная учётная запись Cloudflare WARP, созданная при первом включении. Весь трафик идёт через неё, поэтому открываются и другие закрытые сайты.</div></div></div></div>`;
}

function pageSettings() {
  return `<div class="card row"><div class="grow"><div class="nm">Запускать вместе с Windows</div><div class="sm">Nimb стартует тихо, значком у часов.</div></div>
      <button class="sw ${autostart ? 'on' : ''}" role="switch" aria-checked="${autostart}" aria-label="Запускать вместе с Windows" data-a="autostart" data-f="autostart" id="autostart"></button></div>
    <div class="card row"><div class="grow"><div class="nm">Работа в фоне</div><div class="sm">Закрытие окна не выключает Nimb: он остаётся у часов. Выйти можно из меню значка или кнопкой справа.</div></div>
      <button class="btn" data-a="quit" data-f="quit" id="quit">Выйти из Nimb</button></div>
    <div class="label" style="margin:16px 2px 8px">Помощь</div>
    <div class="card row"><div class="grow"><div class="nm">Сообщить о проблеме</div><div class="sm">Что-то не работает? Отчёт уйдёт разработчику, без паролей, ключей и адресов.</div></div>
      <button class="btn" data-a="report" data-f="report" id="report">Написать</button></div>
    <div class="card row"><div class="grow"><div class="nm">Первая настройка</div><div class="sm">Короткое обучение, ещё раз.</div></div>
      <button class="btn" data-a="onboard" data-f="onboard" id="onboard">Пройти заново</button></div>
    <div class="card row"><div class="grow"><div class="nm">Версия</div><div class="sm">Nimb для Windows ${esc(S.version)}</div></div></div>`;
}

function pageReport() {
  if (rep.stage === 'sent') {
    return `<div class="card"><div class="row" style="gap:8px"><span class="dot on"></span><div class="nm">Отчёт отправлен</div></div>
      <div class="sm" style="margin:6px 0 12px">Номер ${esc(rep.id)}. Спасибо, это помогает исправить ошибку.</div>
      <button class="btn main" data-a="repclose" data-f="repclose" id="repclose">Закрыть</button></div>`;
  }
  const sending = rep.stage === 'sending';
  const can = !rep.loading && !sending;
  let msg = '';
  if (rep.asked) msg = `<div class="ok-note">Отчёт скопирован. В открывшемся личном чате с разработчиком нажмите Ctrl+V и отправьте его.</div>`;
  else if (rep.stage === 'failed') msg = `<div class="err">${esc(rep.message)} Нажмите «Написать разработчику»: откроется личный чат, отчёт будет скопирован, останется вставить его и отправить.</div>`;
  return `<div class="form">
    <label class="nm" for="rep-desc">Что случилось?</label>
    <textarea id="rep-desc" data-input="description" rows="4" placeholder="Что вы делали и что пошло не так. Можно в двух словах.">${esc(rep.description)}</textarea>
    <label class="nm" for="rep-contact" style="margin-top:12px">Как вам ответить (по желанию)</label>
    <input id="rep-contact" data-input="contact" type="text" placeholder="@имя в Telegram или почта" value="${esc(rep.contact)}">
    <button class="link" data-a="repdetails" data-f="repdetails" id="repdetails">Посмотреть, что будет отправлено ${rep.details ? '▴' : '▾'}</button>
    ${rep.details ? `<pre class="preview">${esc(rep.loading ? 'Собираю…' : rep.preview)}</pre>` : ''}
    <div class="sm" style="margin-top:2px">Версия, состояние сервисов и последние строки журнала. Паролей, ключей и IP-адресов в отчёте нет.</div>
    ${msg}
    <div class="row" style="justify-content:flex-end;gap:8px;margin-top:14px;flex-wrap:wrap">
      <button class="btn" data-a="repcancel" data-f="repcancel" id="repcancel">Отмена</button>
      <button class="btn" data-a="repcopy" data-f="repcopy" id="repcopy" ${can ? '' : 'disabled'}>Скопировать</button>
      ${rep.stage === 'failed' ? `<button class="btn" data-a="repwrite" data-f="repwrite" id="repwrite">Написать разработчику</button>` : ''}
      <button class="btn main" data-a="repsend" data-f="repsend" id="repsend" ${can ? '' : 'disabled'}>${sending ? 'Отправляю…' : 'Отправить'}</button></div></div>`;
}

const PAGES = { home: pageHome, ai: pageAI, telegram: pageTelegram, media: pageMedia, settings: pageSettings, report: pageReport };
const TITLES = { home: '', ai: 'Нейросети', telegram: 'Telegram', media: 'YouTube и Discord', settings: 'Настройки', report: 'Сообщить о проблеме' };

// ---- the first setup -------------------------------------------------------------------------------------------------

const ONB_LAST = 4;

function dots() {
  let h = '';
  for (let i = 0; i <= ONB_LAST; i++) h += `<i class="${i === onb.step ? 'now' : i < onb.step ? 'past' : ''}"></i>`;
  return `<div class="dots" role="img" aria-label="Шаг ${onb.step + 1} из ${ONB_LAST + 1}">${h}</div>`;
}
const done = (t) => `<div class="done"><span class="dot on"></span><span>${esc(t)}</span></div>`;
const busyRow = (t) => `<div class="busy-row"><span class="spin"></span><span>${esc(t)}</span></div>`;
const notice = (t) => (t ? `<div class="banner" role="alert">${esc(t)}</div>` : '');

function onbStep() {
  const step = onb.step;
  const mk = (img, title, text, inner) => `${dots()}<img class="onb-ico" src="${art(img)}" alt=""><h2>${title}</h2><p>${text}</p>${inner}`;
  const next = (label = 'Далее') => `<button class="btn main wide" data-a="onbnext" data-f="onbnext" id="onbnext">${label}</button>`;
  const skip = (label = 'Пропустить') => `<button class="link center-link" data-a="onbnext" data-f="onbskip" id="onbskip">${label}</button>`;
  if (step === 0) {
    return mk('hood/on', 'Добро пожаловать в Nimb',
      'За пару минут настроим всё, чтобы работали нейросети, Telegram, YouTube и Discord. Ничего устанавливать и вводить не нужно: Nimb делает всё сам.',
      `<div class="card bullets"><div>✓ Нейросети: ChatGPT, Claude, Gemini и другие</div><div>✓ Telegram: быстрее и без блокировок</div><div>✓ YouTube и Discord</div></div>
       ${next('Начать')}<button class="link center-link" data-a="onbclose" data-f="onbskip" id="onbskip">Настрою потом</button>`);
  }
  if (step === 1) {
    const s = S.ai;
    return mk('icon-ai/planet', 'Нейросети',
      'Из-за региона ChatGPT, Claude и другие нейросети могут не открываться. Nimb переключит DNS на специальный сервис, и они заработают.',
      (s.on ? done('Включено: ' + providerName(s.provider)) + next()
        : s.busy ? busyRow('Включаю…')
        : `<button class="btn main wide" data-a="sw" data-v="ai" data-f="onbgo" id="onbgo" ${S.serviceOk ? '' : 'disabled'}>Включить</button>${skip()}`) + notice(s.error || (S.serviceOk ? '' : S.serviceError)));
  }
  if (step === 2) {
    const s = S.telegram;
    return mk('icon-telegram/plane', 'Telegram',
      'Nimb запустит на этом компьютере небольшой прокси, а Telegram будет ходить через него. После включения нажмите «Открыть в Telegram» и подтвердите окно «Добавить прокси».',
      (s.on ? done('Прокси работает') + `<button class="btn wide" data-a="openTg" data-f="onbopen" id="onbopen">Открыть в Telegram</button>` + next()
        : s.busy ? busyRow('Запускаю…')
        : `<button class="btn main wide" data-a="sw" data-v="telegram" data-f="onbgo" id="onbgo">Включить прокси</button>${skip()}`) + notice(s.error));
  }
  if (step === 3) {
    const s = S.media;
    return mk('icon-media/play', 'YouTube и Discord',
      'Nimb создаст для этого компьютера собственный анонимный аккаунт Cloudflare WARP и включит туннель. Личных данных он не передаёт.',
      (s.on ? done('Туннель работает') + next()
        : s.busy ? busyRow('Включаю…')
        : `<button class="btn main wide" data-a="sw" data-v="media" data-f="onbgo" id="onbgo" ${S.serviceOk ? '' : 'disabled'}>Включить</button>
           <div class="sm" style="text-align:center">Включая, вы принимаете условия Cloudflare WARP.</div>
           <button class="link center-link" data-a="terms" data-f="terms" id="terms">Условия Cloudflare WARP</button>${skip()}`) + notice(s.error || (S.serviceOk ? '' : S.serviceError)));
  }
  return mk('icon-gear/gear', 'Чтобы работало само',
    'Рекомендуем включить: Nimb запустится вместе с Windows и будет работать у часов при закрытом окне.',
    `<div class="card row" style="width:100%"><div class="grow"><div class="nm">Запускать вместе с Windows</div><div class="sm">Тихо, значком у часов.</div></div>
       <button class="sw ${autostart ? 'on' : ''}" role="switch" aria-checked="${autostart}" aria-label="Запускать вместе с Windows" data-a="autostart" data-f="autostart" id="autostart"></button></div>
     <button class="btn main wide" data-a="onbfinish" data-f="onbfinish" id="onbfinish">Готово</button>
     <div class="sm" style="text-align:center">Пройти настройку заново можно в «Настройках» (внизу слева).</div>`);
}

function renderOnboarding() {
  document.getElementById('app').innerHTML = `<div class="onb">
    ${onb.step > 0 && onb.step < ONB_LAST ? `<button class="link onb-close" data-a="onbclose" data-f="onbclose" id="onbclose">Закрыть</button>` : ''}
    <div class="onb-col">${onbStep()}</div></div>`;
}

// ---- the window ------------------------------------------------------------------------------------------------------

function stackMini() {
  return [0, 1, 2].map((i) => {
    const o = isOn(ORDER[2 - i]) ? 1 : 0.2;
    return `<img src="${art('header/ring-back')}" style="top:${-0.5 + i * 5}px;opacity:${o}" alt=""><img src="${art('header/ring-front')}" style="top:${-0.5 + i * 5}px;opacity:${o}" alt="">`;
  }).join('');
}

function restoreFocus(f) {
  if (!f) return;
  const el = document.querySelector(`[data-f="${f}"]`);
  if (el) el.focus();
}

function render() {
  const focused = document.activeElement && document.activeElement.dataset ? document.activeElement.dataset.f : null;
  if (onb.active) { renderOnboarding(); restoreFocus(focused); return; }
  const items = ORDER.map((k) => `<div class="si ${page === k ? 'sel' : ''}">
      <button class="row grow" style="gap:10px;min-width:0" data-a="nav" data-v="${k}" data-f="nav-${k}" id="nav-${k}" aria-label="${SV[k].title}">
        <img class="ico ${isOn(k) ? '' : 'off'}" src="${art(isOn(k) ? SV[k].ico : SV[k].off)}" alt=""><span class="name">${SV[k].title}</span></button>${sw(k)}</div>`).join('');
  const inSettings = page === 'settings' || page === 'report';
  document.getElementById('app').innerHTML = `
    <nav class="side" aria-label="Разделы">
      <button class="si ${page === 'home' ? 'sel' : ''}" data-a="nav" data-v="home" data-f="nav-home" id="nav-home"><span class="rings">${stackMini()}</span><span class="name">Главная</span></button>
      <div class="sec">Сервисы</div>${items}<div class="grow"></div>
      <button class="si ${inSettings ? 'sel' : ''}" data-a="nav" data-v="settings" data-f="nav-settings" id="nav-settings"><img class="ico" src="${art('icon-gear/gear')}" alt=""><span class="name">Настройки</span></button>
    </nav>
    <main class="main">
      ${TITLES[page] ? `<h1>${TITLES[page]}</h1>` : '<div style="height:12px"></div>'}
      ${S.serviceOk ? '' : `<div class="banner" role="alert">${esc(S.serviceError)}</div>`}
      <div class="body">${PAGES[page]()}</div>
    </main>
    <div class="foot"><span>Версия ${esc(S.version)}</span><button data-a="channel" data-f="channel" id="channel">Канал в Telegram ↗</button></div>`;
  restoreFocus(focused);
}

// ---- actions ---------------------------------------------------------------------------------------------------------

async function refresh() {
  try {
    S = await api().GetState();
  } catch (e) {
    return;
  }
  if (page === 'settings' || onb.active) { try { autostart = await api().GetAutostart(); } catch (e) { /* keep */ } }
  // A report that is being typed is not redrawn under the fingers of the person.
  const typing = page === 'report' && document.activeElement && /^(TEXTAREA|INPUT)$/.test(document.activeElement.tagName);
  const json = JSON.stringify(S) + page + autostart + JSON.stringify(onb);
  if (json !== lastJSON && !typing) { lastJSON = json; render(); }
}

async function setService(k, on) {
  if (S[k].busy) return;
  S[k].busy = true; render();
  try { await api()[SV[k].call](on); } catch (e) { /* the error text comes back with the state */ }
  await refresh();
}

function note(text) { const n = document.getElementById('note'); if (n) { n.textContent = text; setTimeout(() => { if (n.textContent === text) n.textContent = ''; }, 2500); } }

function openPage(p) { page = p; lastJSON = ''; render(); if (p === 'settings') refresh(); }

async function openReport() {
  rep = { id: '', facts: '', loading: true, description: '', contact: '', stage: 'form', message: '', details: false, preview: '', asked: false };
  openPage('report');
  try {
    const p = await api().ReportPrepare();
    rep.id = p.id; rep.facts = p.facts;
  } catch (e) { /* the form still works, the facts are empty */ }
  rep.loading = false;
  if (page === 'report') { await refreshPreview(); lastJSON = ''; render(); }
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
  previewTimer = setTimeout(async () => {
    await refreshPreview();
    const pre = document.querySelector('.preview');
    if (pre) pre.textContent = rep.preview;
  }, 300);
});

window.addEventListener('error', (e) => logPage(`error: ${e.message} at ${e.lineno}`));
window.addEventListener('unhandledrejection', (e) => logPage(`rejected: ${e.reason}`));

async function finishOnboarding() {
  onb.active = false;
  try { await api().FinishOnboarding(); } catch (e) { /* ask again next time */ }
  page = 'home'; lastJSON = ''; render();
}

document.addEventListener('click', async (e) => {
  const t = e.target.closest('[data-a]');
  logPage(`click ${t ? t.dataset.a + ' ' + (t.dataset.v || '') : e.target.tagName}${t && t.disabled ? ' (disabled)' : ''}`);
  if (!t || t.disabled) return;
  const v = t.dataset.v;
  switch (t.dataset.a) {
    case 'nav': openPage(v); break;
    case 'sw': await setService(v, !isOn(v)); break;
    case 'all': {
      const on = nOn() !== 3;
      ORDER.forEach((k) => { S[k].busy = true; }); render();
      try { await api().SetAll(on); } catch (err) { /* see the state */ }
      await refresh(); break;
    }
    case 'prov': { S.ai.provider = v; render(); await api().SetProvider(v); await refresh(); break; }
    case 'openTg': { const r = await api().OpenTelegram(); if (!r.ok) note(r.error); break; }
    case 'copy': { const r = await api().CopyLink(); note(r.ok ? 'Ссылка скопирована' : r.error); break; }
    case 'channel': api().OpenChannel(); break;
    case 'terms': api().OpenTerms(); break;
    case 'quit': api().Quit(); break;
    case 'autostart': { const r = await api().SetAutostart(!autostart); if (r.ok) autostart = !autostart; lastJSON = ''; render(); break; }
    case 'onboard': { await api().RestartOnboarding(); onb = { active: true, step: 0 }; lastJSON = ''; render(); break; }
    case 'onbnext': onb.step += 1; lastJSON = ''; render(); break;
    case 'onbclose': case 'onbfinish': await finishOnboarding(); break;
    case 'report': await openReport(); break;
    case 'repcancel': case 'repclose': openPage('settings'); break;
    case 'repdetails': rep.details = !rep.details; await refreshPreview(); lastJSON = ''; render(); break;
    case 'repcopy': { const r = await api().ReportCopy(rep.description, rep.contact); if (!r.ok) { rep.message = r.error; rep.stage = 'failed'; } lastJSON = ''; render(); break; }
    case 'repwrite': { const r = await api().ReportWrite(rep.description, rep.contact); rep.asked = r.ok; lastJSON = ''; render(); break; }
    case 'repsend': {
      rep.stage = 'sending'; rep.asked = false; lastJSON = ''; render();
      const r = await api().ReportSend(rep.description, rep.contact);
      if (r.ok) rep.stage = 'sent'; else { rep.stage = 'failed'; rep.message = r.error; }
      lastJSON = ''; render(); break;
    }
  }
});

document.addEventListener('keydown', (e) => {
  if (e.key !== 'Escape' || onb.active) return;
  if (page === 'report') openPage('settings'); else if (page !== 'home') openPage('home');
});

window.addEventListener('load', async () => {
  try { const p = await api().InitialPage(); if (TITLES[p] !== undefined && p !== 'report') page = p; } catch (e) { /* the home page */ }
  await refresh();
  // The first setup shows on a computer that has nothing set up yet; one that already has something on was set up by hand.
  try {
    if (!(await api().Onboarded())) {
      if (nOn() > 0) await api().FinishOnboarding(); else { onb = { active: true, step: 0 }; lastJSON = ''; render(); }
    }
  } catch (e) { /* no first setup */ }
  setInterval(() => { if (document.visibilityState === 'visible') refresh(); }, 2000);
  window.addEventListener('focus', refresh);
});
})();
