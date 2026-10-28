import { esc, setHTML, SV, ORDER } from './common.js';
import { HomeHero } from './home.js';
import { Stage } from './stage.js';
import { PlanetHero, PROVIDER_REGION } from './globe.js';
import { SITES } from './sites.js';

// A notice, as NoticeCard of the Mac: a sign, then the words in the small type on a card of the colour of its meaning.
const NOTICE_SIGN = {
  bad: '<svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.1" aria-hidden="true"><path d="M5.2 1.7h5.6l3.5 3.5v5.6l-3.5 3.5H5.2l-3.5-3.5V5.2z"/><path d="M5.8 5.8l4.4 4.4M10.2 5.8l-4.4 4.4" stroke-linecap="round"/></svg>',
  warn: '<svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.1" aria-hidden="true"><path d="M8 1.8l6.4 11.2H1.6z" stroke-linejoin="round"/><path d="M8 6.4v3.2M8 11.2v.1" stroke-linecap="round"/></svg>',
};
const notice = (text, tone = 'bad') => (text ? `<div class="card ${tone}" role="alert"><div class="note-in"><span class="note-sign ${tone}">${NOTICE_SIGN[tone] || NOTICE_SIGN.bad}</span><div class="note-text">${esc(text)}</div></div></div>` : '');

/** Lets a page keep its own html and skip the work when nothing it shows has changed. */
function same(page, key, value) { const j = JSON.stringify(value); if (page[key] === j) return true; page[key] = j; return false; }

const SERVICE_TITLES = ['Нейросети', 'Telegram', 'YouTube и Discord'];
const shell = (title, inner, scroll = true) => `<div class="page">${title ? `<h1 class="page-title${SERVICE_TITLES.includes(title) ? ' pt-service' : ''}">${esc(title)}</h1>` : ''}${scroll ? `<div class="pg"><div class="pg-in">${inner}</div></div>` : inner}</div>`;

// ---------------------------------------------------------------------------------------------------------------- Home

export class HomePage {
  constructor(actions) { this.actions = actions; }
  mount(root) {
    root.innerHTML = '<div class="page"><div class="center-all" style="flex:1;display:flex;align-items:center;justify-content:center"></div></div>';
    this.hero = new HomeHero(1.25, () => this.actions.toggleAll());
    root.querySelector('.center-all').appendChild(this.hero.el);
  }
  update(S) {
    const eff = ORDER.filter((k) => S[k].on || S[k].busy).length;
    const busy = ORDER.some((k) => S[k].busy);
    this.hero.update({ count: eff, busy, all: ORDER.every((k) => S[k].on) && !busy, running: busy });
  }
  destroy() { this.hero.destroy(); }
}

// ----------------------------------------------------------------------------------------------------------- Neural networks

/** How the AI services answered through a provider (the check of the providers, Sources/Nimb/ContentView.swift on the Mac). */
const PILL_ICON = {
  works: '<path d="M2.5 6.5l2.5 2.5 4.5-5"/>',
  unstable: '<path d="M6 1.8l4.6 8H1.4z"/><path d="M6 5v2.4M6 8.8v.1"/>',
  down: '<path d="M3 3l6 6M9 3l-6 6"/>',
  blocked: '<circle cx="6" cy="6" r="4.4"/><path d="M2.9 9.1l6.2-6.2"/>',
};
const PILL_WORD = { works: 'работает', unstable: 'нестабильно', down: 'не отвечает', blocked: 'закрыт' };
const pill = (r) => `<span class="svc ${r.status}" title="${esc(r.name)}: ${PILL_WORD[r.status]}"><svg viewBox="0 0 12 12" width="10" height="10" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${PILL_ICON[r.status]}</svg>${esc(r.name)}</span>`;

/** Three thin bars that fill up with speed, plus the time to the first byte. */
function speed(seconds) {
  const level = seconds == null ? 0 : seconds < 0.6 ? 3 : seconds < 1.2 ? 2 : 1;
  const color = level === 3 ? 'var(--ok)' : level === 2 ? 'var(--warn)' : 'var(--bad)';
  const bars = [0, 1, 2].map((i) => `<i style="height:${5 + i * 3.5}px;background:${i < level ? color : 'rgba(255,255,255,.16)'}"></i>`).join('');
  return `<span class="speed" role="img" aria-label="${seconds == null ? 'Нет ответа' : `Скорость ${seconds.toFixed(1)} секунды`}"><span class="bars">${bars}</span><span class="mono t1">${seconds == null ? '—' : `${seconds.toFixed(1)} с`}</span></span>`;
}

/** A card over the window (details of a check): it does not change the page under it, so nothing there has to make room for it. */
export function modal(label, html) {
  const wrap = document.createElement('div');
  wrap.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.72);display:flex;align-items:center;justify-content:center;z-index:50;animation:fade .2s ease-out;padding:16px';
  wrap.innerHTML = `<div role="dialog" aria-label="${esc(label)}" style="width:min(400px,100%);max-height:100%;background:#000;border:1px solid rgba(255,255,255,.16);border-radius:14px;overflow:hidden">
    <div style="padding:14px 16px 4px;display:flex;justify-content:space-between;align-items:center"><div class="nm" style="font-size:15px">${esc(label)}</div><button class="btn" id="modal-close">Закрыть</button></div>${html}</div>`;
  const close = () => { wrap.remove(); document.removeEventListener('keydown', onKey, true); };
  const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); close(); } };
  wrap.addEventListener('click', (e) => { if (e.target === wrap || e.target.id === 'modal-close') close(); });
  document.addEventListener('keydown', onKey, true);
  document.body.appendChild(wrap);
  wrap.querySelector('#modal-close').focus();
}

function details(p, name) {
  const rows = p.services.map((s) => `<div class="drow"><span>${esc(s.name)}</span><span class="mono">сайт ${s.site} · API ${s.api}</span></div>`).join('');
  const refusals = p.refusals.map((l) => `<div class="dnote bad">${esc(l)}</div>`).join('');
  const dead = p.dead.length ? `<div class="dnote warn">Без нормального ответа: ${esc(p.dead.join(', '))}</div>` : '';
  return `<div class="det" style="margin:6px 14px 14px">${rows}${refusals}${dead}
    <div class="dfoot">Цифры — сколько адресов пула ответило как положено. Отказ из-за региона, страница ограничений и ответ 403 не считаются. Сервис работает, если ответило не менее 75%. Проверка не гарантирует, что откроются приложения.</div></div>`;
}

const probeLabel = (pr) => (pr.running ? (pr.phase === 'enabling' ? 'Включаю…' : pr.total > 0 ? `Проверено ${pr.done} из ${pr.total}` : 'Определяю адреса…') : 'Проверить сервисы');

export class AIPage {
  constructor(actions) { this.actions = actions; this.open = null; }
  mount(root) {
    root.innerHTML = shell('Нейросети', '<div class="two"><div class="left" id="slot"></div><div class="right" id="right"></div></div>');
    this.hero = new PlanetHero(() => this.actions.toggle('ai'));
    root.querySelector('#slot').appendChild(this.hero.el);
    this.right = root.querySelector('#right');
  }
  toggleDetails(id) {
    const r = (this.S.probe.reports || []).find((x) => x.id === id), p = this.S.providers.find((x) => x.id === id);
    if (r && p) modal(p.name, details(r, p.name));
  }
  update(S) {
    this.S = S;
    const a = S.ai, pr = S.probe, name = (S.providers.find((p) => p.id === a.provider) || {}).name || '';
    this.hero.update({
      on: a.on && !pr.running, busy: a.busy || pr.running, region: PROVIDER_REGION[a.provider] || 'eu', disabled: a.busy || pr.running || !S.serviceOk,
      title: pr.running ? 'Проверяю сервисы' : a.busy ? 'Применяю DNS' : a.on ? 'Включено' : 'Выключено', providerName: esc(name),
      subtitle: pr.running ? 'Спрашиваю DNS и запрашиваю сайты и API' : a.busy ? 'Меняю DNS на всех подключениях' : 'Включите, чтобы открывались ChatGPT, Claude, Gemini и другие нейросети',
      label: a.on ? 'Выключить Smart DNS' : 'Включить Smart DNS',
    });
    if (same(this, 'rj', [a, S.providers, pr])) return;
    const view = Object.fromEntries(pr.reports.map((r) => [r.id, r]));
    const fill = pr.running && pr.total > 0 ? Math.round((100 * pr.done) / pr.total) : 0;
    const button = `<button class="probe-btn ${pr.running ? 'run' : ''}" data-a="probe" data-f="probe" id="probe" ${pr.running || a.busy ? 'disabled' : ''}>
      <span class="fill" style="width:${fill}%"></span><span class="lbl"><svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M1 8h3l2-5 3 10 2-5h4"/></svg>${probeLabel(pr)}</span></button>`;
    const best = pr.best && view[pr.best] ? view[pr.best] : null;
    const bestName = best ? (S.providers.find((p) => p.id === best.id) || {}).name : '';
    const banner = best ? `<div class="best"><div><div class="label" style="color:var(--warn)">Рекомендуем</div>
        <div class="bn"><span class="nm">${esc(bestName)}</span><span class="sm" style="margin:0">работает ${best.working} из ${best.total}</span></div></div><span class="grow"></span>
        ${a.provider === best.id ? '<span class="chosen"><svg viewBox="0 0 12 12" width="10" height="10" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2.5 6.5l2.5 2.5 4.5-5"/></svg>Выбран</span>'
          : `<button class="btn warnbtn" data-a="prov" data-v="${best.id}" data-f="bestsel" id="bestsel" ${pr.running || a.busy ? 'disabled' : ''}>Выбрать</button>`}</div>` : '';
    const locked = pr.running || a.busy;
    // After the check the cards stand two by two (as far as the width lets them) and all have the same two lines at the top: the name and
    // the choice, then «активен» and the speed. Before it each card is one line.
    const two = pr.reports.length > 0; // after the check the cards stand two by two, as on the Mac
    const cards = S.providers.map((p) => {
      const sel = p.id === a.provider, r = view[p.id], isBest = best && best.id === p.id, active = sel && a.on;
      const radio = `<span class="radio" style="border-color:rgba(255,255,255,${sel ? 0.9 : 0.28})">${sel ? '<i></i>' : ''}</span>`;
      const gem = isBest ? '<span class="gem" title="Лучший по итогам проверки">◆</span>' : '';
      const row = `<button class="prov" role="radio" aria-checked="${sel}" data-a="prov" data-v="${p.id}" data-f="prov-${p.id}" id="prov-${p.id}" ${locked ? 'disabled' : ''}>
        <span class="nm">${esc(p.name)}</span>${two ? '' : gem + (active ? '<span class="on">· активен</span>' : '')}<span class="grow"></span>${two ? gem : (r ? speed(r.median ?? null) + '<span class="ispace"></span>' : '')}${radio}</button>`;
      const info = r ? `<button class="info" data-a="det" data-v="${p.id}" data-f="det-${p.id}" id="det-${p.id}" aria-label="Подробности проверки" title="Подробности проверки">
        <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1" aria-hidden="true"><circle cx="8" cy="8" r="6.5"/><path d="M8 7.2v4.2M8 4.6v.1" stroke-linecap="round"/></svg></button>` : '';
      // the second line takes the click of the mouse too (the first line is the button for the keyboard)
      const second = two ? `<div class="r2" ${locked ? '' : `data-a="prov" data-v="${p.id}"`}>${active ? '<span class="on">активен</span>' : ''}<span class="grow"></span>${r ? speed(r.median ?? null) : ''}${info}</div>` : '';
      const pills = r ? `<div class="pills">${r.services.map(pill).join('')}</div>` : '';
      return `<div class="provc ${sel ? 'sel' : ''} ${locked ? 'dim' : ''} ${two ? 'c' : ''} ${r ? 'has' : ''}">${row}${two ? '' : info}${second}${pills}</div>`;
    }).join('');
    const warnings = (a.warnings || []).map((w) => notice(w, 'warn')).join('');
    setHTML(this.right, `<div class="prov-head"><div class="label">DNS-провайдеры</div>${button}</div>${banner}
      <div class="grid ${two ? 'two-up' : ''}" role="radiogroup" aria-label="DNS-провайдеры">${cards}</div>${warnings}${notice(a.error)}`);
  }
  destroy() { this.hero.destroy(); }
}

// ------------------------------------------------------------------------------------------------------------------ Telegram

export class TelegramPage {
  constructor(actions) { this.actions = actions; }
  mount(root) {
    root.innerHTML = shell('Telegram', '<div class="two"><div class="left" id="slot"></div><div class="right" id="right"></div></div>');
    this.hero = new Stage('hood', () => this.actions.toggle('telegram'));
    root.querySelector('#slot').appendChild(this.hero.el);
    this.right = root.querySelector('#right');
  }
  update(S) {
    const t = S.telegram;
    this.hero.update({
      on: t.on, busy: t.busy, disabled: t.busy,
      title: t.on ? 'Включено' : t.busy ? 'Запускаю' : 'Выключено',
      subtitle: t.on ? 'Прокси работает на этом компьютере. Telegram ходит через него.' : 'Включите, чтобы Telegram открывался и грузил файлы быстрее.',
      label: t.on ? 'Остановить прокси для Telegram' : 'Включить прокси для Telegram',
    });
    if (same(this, 'rj', [t.on, t.error, t.wrongKeyRecently])) return;
    const body = t.on
      ? `<div class="card stack8"><div class="nm">Подключить Telegram</div>
          <div class="sm">Откроется окно «Добавить прокси» в Telegram Desktop: подтвердите его.</div>
          <div style="display:flex;justify-content:flex-end;gap:8px">
            <button class="btn" data-a="copy" data-f="copy" id="copy">Скопировать ссылку</button>
            <button class="btn" data-a="openTg" data-f="open" id="open">Открыть в Telegram</button></div>
          <div id="note" class="sm" style="text-align:right;min-height:16px"></div></div>`
      : `<div class="card"><div class="nm">Как это работает</div><div class="sm">Включите прокси и подтвердите окно «Добавить прокси» в Telegram.</div></div>`;
    // As on the Mac: only while it goes on; it goes away by itself ten seconds after the last connection with another key.
    const wrongKey = t.on && t.wrongKeyRecently ? notice('Telegram подключается с чужим ключом: в нём, похоже, указан другой прокси на этом порту. Нажмите «Открыть в Telegram» и подтвердите, а старый прокси удалите.', 'warn') : '';
    setHTML(this.right, body + wrongKey + notice(t.error));
  }
  destroy() { this.hero.destroy(); }
}

// -------------------------------------------------------------------------------------------------------- YouTube and Discord

/** The result for one site: a mark, its name, how it went and a small ⓘ with the details (CheckRow and CheckDetails of the Mac). */
const MARK = { works: '<path d="M2.5 6.5l2.5 2.5 4.5-5"/>', partial: PILL_ICON.unstable, down: '<path d="M3 3l6 6M9 3l-6 6"/>' };
function siteDetails(c) {
  const probes = c.probes.map((p) => `<div><div class="drow"><span><span class="pm ${p.answered ? 'ok' : 'bad'}">${p.answered ? '✓' : '✕'}</span>${esc(p.name)}</span><span class="mono">${esc(p.summary)}</span></div>
      <div class="mono host">${esc(p.host)}</div></div>`).join('');
  return `<div class="det" style="margin:6px 14px 14px">${probes}
    <div class="dfoot">Проверка спрашивает у сайта несколько адресов: страницу, картинки, видео или файлы. Если часть ответила, а часть нет, чаще всего это случайная задержка, а не поломка: сам сайт обычно открывается. Каждый адрес при неудаче спрашивается дважды.</div></div>`;
}

function checkRow(c) {
  const id = `site-${c.name}`;
  return `<div class="crow"><svg class="cm ${c.verdict}" viewBox="0 0 12 12" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${MARK[c.verdict]}</svg>
    <span class="cn">${esc(c.name)}</span><span class="grow"></span><span class="mono">${esc(c.result)}</span>
    <button class="cinfo" data-a="det" data-v="${esc(id)}" data-f="det-${esc(id)}" id="det-${esc(id)}" aria-label="Подробности проверки ${esc(c.name)}" title="Подробности проверки">
      <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1" aria-hidden="true"><circle cx="8" cy="8" r="6.5"/><path d="M8 7.2v4.2M8 4.6v.1" stroke-linecap="round"/></svg></button></div>`;
}

function checkCard(sites) {
  return `<div class="card stack8"><div class="nm">Проверка</div>
    ${sites.checks.length ? sites.checks.map(checkRow).join('') : '<div class="sm">Проверит, открываются ли YouTube и Discord.</div>'}
    <div class="chk-act">${sites.running ? '<span class="spin"></span>' : ''}<button class="btn" data-a="sitecheck" data-f="sitecheck" id="sitecheck" ${sites.running ? 'disabled' : ''}>Проверить YouTube и Discord</button></div></div>`;
}

export class MediaPage {
  constructor(actions) { this.actions = actions; }
  toggleDetails(id) {
    const c = ((this.S || {}).sites || { checks: [] }).checks.find((x) => `site-${x.name}` === id);
    if (c) modal(c.name, siteDetails(c));
  }
  mount(root) {
    root.innerHTML = shell('YouTube и Discord', '<div class="two"><div class="left" id="slot"></div><div class="right" id="right"></div></div>');
    this.hero = new Stage('screen', () => this.actions.toggle('media'));
    root.querySelector('#slot').appendChild(this.hero.el);
    this.right = root.querySelector('#right');
  }
  update(S) {
    this.S = S;
    const m = S.media;
    this.hero.update({
      on: m.on, busy: m.busy, disabled: m.busy || !S.serviceOk,
      title: m.busy ? 'Подождите' : m.on ? 'Включено' : 'Выключено',
      subtitle: m.busy ? (m.on ? 'Выключаю туннель…' : 'Включаю туннель…') : m.on ? 'Весь трафик этого компьютера идёт через Cloudflare WARP. Если не открывается банк или Госуслуги, выключите туннель.' : 'Включите, чтобы открывались YouTube и Discord. Всё настроится само.',
      label: m.on ? 'Выключить туннель WARP' : 'Включить туннель WARP',
    });
    if (same(this, 'rj', [m.on, m.error, S.sites])) return;
    const first = m.on ? checkCard(S.sites) : `<div class="card"><div class="nm">Что произойдёт при включении</div>
      <div class="sm" style="line-height:1.45">Nimb создаст для этого компьютера анонимный аккаунт Cloudflare WARP. Пока туннель включён, через Cloudflare идёт весь трафик компьютера, и некоторые сайты, например банки и Госуслуги, могут не открываться: тогда выключите туннель. Включая, вы принимаете условия Cloudflare WARP.</div>
      <button class="link" data-a="terms" data-f="terms" id="terms" style="margin-top:4px;color:#6ea8ff">Условия Cloudflare WARP</button></div>`;
    const sites = `<div style="display:flex;align-items:center;gap:4px;padding:0 2px"><span style="font-size:12px;color:var(--t2)">Туннель даёт доступ и к другим сервисам</span>
      <button data-a="sites" data-f="sites" id="sites" aria-label="Что ещё открывает туннель" title="Что ещё открывает туннель" style="width:20px;height:22px;display:flex;align-items:center;justify-content:center;color:var(--t2)">
      <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1"><circle cx="8" cy="8" r="6.5"/><path d="M8 7.2v4.2M8 4.6v.1" stroke-linecap="round"/></svg></button></div>`;
    setHTML(this.right, first + notice(m.error) + sites);
  }
  destroy() { this.hero.destroy(); }
}

/** The list of what the tunnel opens, over the window. */
export function showSites() {
  const half = Math.ceil(SITES.length / 2);
  const col = (items, from) => `<div style="flex:1;min-width:0">${items.map(([n, k], i) => `<div style="display:flex;align-items:center;gap:10px;padding:6.5px 0;${i < items.length - 1 ? 'border-bottom:1px solid rgba(255,255,255,.06)' : ''}">
    <span class="mono" style="width:20px;text-align:right;opacity:.7">${from + i}</span><span style="font-size:13.5px;font-weight:500;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${esc(n)}</span>
    <span style="font-size:12px;color:var(--t2)">${esc(k)}</span></div>`).join('')}</div>`;
  const wrap = document.createElement('div');
  wrap.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.72);display:flex;align-items:center;justify-content:center;z-index:50;animation:fade .2s ease-out';
  wrap.innerHTML = `<div role="dialog" aria-label="Что открывает туннель" style="width:min(720px,92vw);background:#000;border:1px solid rgba(255,255,255,.16);border-radius:14px;overflow:hidden">
    <div style="display:flex;justify-content:space-between;align-items:center;padding:22px 22px 12px"><h2 style="font:400 24px var(--serif);margin:0">Что открывает туннель</h2>
    <button class="btn" id="sites-close">Закрыть</button></div>
    <div style="display:flex;gap:28px;padding:0 22px 16px">${col(SITES.slice(0, half), 1)}${col(SITES.slice(half), half + 1)}</div>
    <div style="padding:12px 22px;font-size:12px;color:var(--t2);background:rgba(255,255,255,.04);border-top:1px solid rgba(255,255,255,.08)">Туннель не поможет там, где сервис сам закрыт для российских IP-адресов.</div></div>`;
  const close = () => wrap.remove();
  wrap.addEventListener('click', (e) => { if (e.target === wrap || e.target.id === 'sites-close') close(); });
  document.addEventListener('keydown', function onKey(e) { if (e.key === 'Escape') { close(); document.removeEventListener('keydown', onKey, true); } }, true);
  document.body.appendChild(wrap);
  wrap.querySelector('#sites-close').focus();
}

// ---------------------------------------------------------------------------------------------------------------- Settings

/** The switch for the notifications about new versions; the test button is there only while they are on. */
export function notifyCard(S, extra) {
  const on = S.update.notify;
  return `<div class="card row top"><div class="grow"><div class="nm">Уведомления об обновлениях</div><div class="sm">Nimb скажет, когда выйдет новая версия.</div>
    ${on ? `<button class="btn" style="margin-top:5px" data-a="notifytest" data-f="notifytest" id="notifytest" aria-label="Отправить тестовое уведомление" ${extra.testSent ? 'disabled' : ''}>${extra.testSent ? 'Отправлено' : 'Отправить тестовое уведомление'}</button>` : ''}</div>
    <button class="pill ${on ? 'on' : ''}" role="switch" aria-checked="${on}" aria-label="Уведомления об обновлениях" data-a="notify" data-f="notify" id="notify"></button></div>`;
}

const INFO_CIRCLE = '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1" aria-hidden="true"><circle cx="8" cy="8" r="6.5"/><path d="M8 7.2v4.2M8 4.6v.1" stroke-linecap="round"/></svg>';

/** «сегодня в 14:20», «23 октября в 14:20»: when the last report of «Помогать тестированию» went. */
function lastWords(unix) {
  const at = new Date(unix * 1000), now = new Date();
  const time = at.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' });
  return at.toDateString() === now.toDateString() ? `сегодня в ${time}` : `${at.toLocaleDateString('ru-RU', { day: 'numeric', month: 'long' })} в ${time}`;
}

/** The second line of the card «Сообщить о проблеме» (HelpTestingRow.swift): the switch «Помогать тестированию» and what it is. */
function helpRow(S) {
  const h = S.help || {};
  const detail = !h.on ? 'Сам отправит отчёт, если что-то пойдёт не так.'
    : !h.last ? 'Включено. Пока ничего не отправлено.' : `Отправлено: ${h.count}, последний ${lastWords(h.last)}.`;
  return `<div class="hr"></div><div class="rowline"><div class="grow"><div class="nm-line"><span class="nm">Помогать тестированию</span>
    <button class="info" data-a="helpinfo" data-f="helpinfo" id="helpinfo" aria-label="Что такое «Помогать тестированию»" title="Что это и что отправляется">${INFO_CIRCLE}</button></div>
    <div class="sm">${detail}</div></div>
    <button class="pill ${h.on ? 'on' : ''}" role="switch" aria-checked="${!!h.on}" aria-label="Помогать тестированию" data-a="helptest" data-f="helptest" id="helptest"></button></div>`;
}

/** What the switch does, in words, and a report as it would go now (HelpTestingInfo of the Mac). */
function helpPopover(help) {
  const point = (title, text) => `<div class="pt"><div class="pt-t">${title}</div><div class="pt-x">${text}</div></div>`;
  const example = help.preview != null ? `<div class="sm" style="margin:0">Так выглядит отчёт сейчас</div><pre class="preview pop-pre">${esc(help.preview)}</pre>`
    : `<button class="btn" data-a="helppreview" data-f="helppreview" id="helppreview" ${help.loading ? 'disabled' : ''}>${help.loading ? 'Собираю…' : 'Показать пример отчёта'}</button>`;
  return `<div class="pop-back" data-a="helpclose"><div class="pop" role="dialog" aria-label="Помогать тестированию" data-stop="1">
    <div class="pop-head"><h3>Помогать тестированию</h3><button class="btn soft" data-a="helpclose" data-f="helpclose" id="helpclose">Закрыть</button></div>
    <div class="pop-body">
    ${point('Когда', 'Сразу уходит отчёт, если сломалось что-то серьёзное: программа закрылась неожиданно, туннель остановился сам или включён, но сервер не отвечает больше 10 минут, сервис работает не так, как должен, больше 10 минут, включение или выключение закончилось ошибкой, проверка обновлений не удаётся несколько раз подряд. Если сайт или сервис просто не открылся, это не причина: такое бывает у всех.')}
    ${point('Как часто', 'О сбоях: не чаще одного отчёта в час и пяти в сутки, одно и то же не чаще раза в 6 часов. И раз в сутки одна сводка: цифры за день, чтобы видеть мелочи, которые не стоят отдельного отчёта. Отчёт, который не удалось отправить (сети нет), ждёт в файле на этом компьютере не дольше суток и уходит, когда сеть вернётся.')}
    ${point('Что внутри', 'То же, что в «Сообщить о проблеме»: версии, состояние сервисов, журнал и состояние раз в 5 минут за сутки. Паролей, ключей и ваших личных данных (адрес, адреса вашей сети, имя компьютера) нет. Адреса серверов провайдеров и сервера туннеля (они принадлежат Cloudflare) есть: они помогают найти ошибку.')}
    ${point('Номер установки', 'Случайный. По нему отчёты с одного компьютера связываются между собой (видно, что это один и тот же компьютер), но не с вами лично. Когда вы выключаете переключатель, он стирается.')}
    ${point('Пока работает Nimb', 'Записи и отчёты идут, пока Nimb запущен (в том числе у часов). После «Выйти из Nimb» ничего не пишется и не отправляется.')}
    <div class="hr"></div>${example}</div></div></div>`;
}

export class SettingsPage {
  constructor(actions) { this.actions = actions; }
  mount(root) { root.innerHTML = shell('Настройки', '<div class="settings" id="body"></div>'); this.body = root.querySelector('#body'); }
  update(S, extra) {
    const help = extra.help || {};
    if (same(this, 'rj', [extra.autostart, S.version, S.update.notify, extra.testSent, S.ai.error, S.media.error, S.help, help.open, help.preview, help.loading])) return;
    const card = (title, text, button, top = false) => `<div class="card row ${top ? 'top' : ''}"><div class="grow"><div class="nm">${title}</div>${text ? `<div class="sm">${text}</div>` : ''}</div>${button}</div>`;
    const group = (title, ...cards) => `<div class="group"><div class="label">${title}</div><div class="cards">${cards.join('')}</div></div>`;
    // The columns of the Mac (SettingsView.swift); the block «Пароль администратора» is not here (the service has the rights), so Помощь
    // stands over Удаление in the right column.
    setHTML(this.body, `<div class="col">${group('Работа',
        card('Работа в фоне', 'Закрытие окна не выключает Nimb: он остаётся у часов. Выйти можно из меню значка или кнопкой справа.', '<button class="btn" data-a="quit" data-f="quit" id="quit">Выйти из Nimb</button>'),
        card('Запускать вместе с Windows', '', `<button class="pill ${extra.autostart ? 'on' : ''}" role="switch" aria-checked="${extra.autostart}" aria-label="Запускать вместе с Windows" data-a="autostart" data-f="autostart" id="autostart"></button>`, true),
        notifyCard(S, extra))}</div>
      <div class="col">${group('Помощь',
        `<div class="card stack12"><div class="rowline"><div class="grow"><div class="nm">Сообщить о проблеме</div><div class="sm">Отчёт придёт разработчику. Паролей и адресов в нём нет.</div></div><button class="btn" data-a="report" data-f="report" id="report">Отправить…</button></div>${helpRow(S)}</div>`,
        card('Первая настройка', 'Короткое обучение по шагам.', '<button class="btn" data-a="onboard" data-f="onboard" id="onboard">Пройти заново</button>'))}
        ${group('Удаление',
        card('Удалить Nimb', 'Вернёт DNS к автоматическому и удалит приложение вместе с настройками.', '<button class="btn red" data-a="uninstall" data-f="uninstall" id="uninstall">Удалить…</button>'))}
        ${notice(S.ai.error || S.media.error)}</div>${help.open ? helpPopover(help) : ''}`);
  }
  destroy() {}
}

// ------------------------------------------------------------------------------------------------------------------- Report

export class ReportPage {
  constructor(actions, rep) { this.actions = actions; this.rep = rep; }
  mount(root) { root.innerHTML = shell('Сообщить о проблеме', '<div class="form" id="form"></div>'); this.form = root.querySelector('#form'); this.render(); }
  update() { /* the form is drawn by render(), when the report changes */ }
  render() {
    const rep = this.rep;
    if (rep.stage === 'sent') {
      setHTML(this.form, `<div class="card"><div style="display:flex;align-items:center;gap:8px"><span class="dot"></span><div class="nm">Отчёт отправлен</div></div>
        <div class="sm" style="margin:6px 0 12px">Номер ${esc(rep.id)}. Спасибо, это помогает исправить ошибку.</div>
        <button class="btn" data-a="repclose" data-f="repclose" id="repclose">Закрыть</button></div>`);
      return;
    }
    const sending = rep.stage === 'sending', can = !rep.loading && !sending;
    let msg = '';
    if (rep.asked) msg = '<div class="ok-note">Отчёт скопирован. В открывшемся личном чате с разработчиком нажмите Ctrl+V и отправьте его.</div>';
    else if (rep.stage === 'failed') msg = `<div class="err">${esc(rep.message)} Нажмите «Написать разработчику»: откроется личный чат, отчёт будет скопирован, останется вставить его и отправить.</div>`;
    const keep = document.activeElement && this.form.contains(document.activeElement) && /^(TEXTAREA|INPUT)$/.test(document.activeElement.tagName) ? document.activeElement : null;
    if (keep && this.form.querySelector('textarea')) { this.patch(sending, can, msg); return; }
    setHTML(this.form, `<label class="nm" for="rep-desc">Что случилось?</label>
      <textarea id="rep-desc" data-input="description" rows="4" placeholder="Что вы делали и что пошло не так. Можно в двух словах.">${esc(rep.description)}</textarea>
      <label class="nm" for="rep-contact" style="margin-top:12px">Как вам ответить (по желанию)</label>
      <input id="rep-contact" data-input="contact" type="text" placeholder="@имя в Telegram или почта" value="${esc(rep.contact)}">
      <button class="link" data-a="repdetails" data-f="repdetails" id="repdetails" style="align-self:flex-start">Посмотреть, что будет отправлено ${rep.details ? '▴' : '▾'}</button>
      ${rep.details ? `<pre class="preview">${esc(rep.loading ? 'Собираю…' : rep.preview)}</pre>` : ''}
      <div class="sm" style="margin:0">Версия, состояние сервисов и последние строки журнала. Паролей, ключей и ваших личных данных (адрес, имя компьютера и пользователя) в отчёте нет; адреса серверов сервисов и провайдеров есть, они помогают найти ошибку.</div>
      <div id="rep-msg">${msg}</div>
      <div style="display:flex;justify-content:flex-end;gap:8px;margin-top:10px;flex-wrap:wrap" id="rep-buttons">${this.buttons(sending, can)}</div>`);
  }
  buttons(sending, can) {
    return `<button class="btn soft" data-a="repcancel" data-f="repcancel" id="repcancel">Отмена</button>
      <button class="btn" data-a="repcopy" data-f="repcopy" id="repcopy" ${can ? '' : 'disabled'}>Скопировать</button>
      ${this.rep.stage === 'failed' ? '<button class="btn" data-a="repwrite" data-f="repwrite" id="repwrite">Написать разработчику</button>' : ''}
      <button class="btn main" data-a="repsend" data-f="repsend" id="repsend" ${can ? '' : 'disabled'}>${sending ? 'Отправляю…' : 'Отправить'}</button>`;
  }
  /** While a field has the cursor only the parts around it change. */
  patch(sending, can, msg) {
    this.form.querySelector('#rep-msg').innerHTML = msg;
    this.form.querySelector('#rep-buttons').innerHTML = this.buttons(sending, can);
  }
  destroy() {}
}
