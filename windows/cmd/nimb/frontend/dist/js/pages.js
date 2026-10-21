import { esc, setHTML, SV, ORDER } from './common.js';
import { HomeHero } from './home.js';
import { Stage } from './stage.js';
import { PlanetHero, PROVIDER_REGION } from './globe.js';
import { SITES } from './sites.js';

const notice = (text, tone = 'bad') => (text ? `<div class="card ${tone}" role="alert"><div class="sm" style="margin:0;color:rgba(255,255,255,.86)">${esc(text)}</div></div>` : '');

/** Lets a page keep its own html and skip the work when nothing it shows has changed. */
function same(page, key, value) { const j = JSON.stringify(value); if (page[key] === j) return true; page[key] = j; return false; }

const shell = (title, inner, scroll = true) => `<div class="page">${title ? `<h1 class="page-title">${esc(title)}</h1>` : ''}${scroll ? `<div class="scroll">${inner}</div>` : inner}</div>`;

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

export class AIPage {
  constructor(actions) { this.actions = actions; }
  mount(root) {
    root.innerHTML = shell('Нейросети', '<div class="two"><div class="left" id="slot"></div><div class="right" id="right"></div></div>');
    this.hero = new PlanetHero(() => this.actions.toggle('ai'));
    root.querySelector('#slot').appendChild(this.hero.el);
    this.right = root.querySelector('#right');
  }
  update(S) {
    const a = S.ai, name = (S.providers.find((p) => p.id === a.provider) || {}).name || '';
    this.hero.update({
      on: a.on, busy: a.busy, region: PROVIDER_REGION[a.provider] || 'eu', disabled: a.busy || !S.serviceOk,
      title: a.busy ? 'Применяю DNS' : a.on ? 'Включено' : 'Выключено', providerName: esc(name),
      subtitle: a.busy ? 'Меняю DNS на всех подключениях' : 'Включите, чтобы открывались ChatGPT, Claude, Gemini и другие нейросети',
      label: a.on ? 'Выключить Smart DNS' : 'Включить Smart DNS',
    });
    if (same(this, 'rj', [a, S.providers])) return;
    const cards = S.providers.map((p) => {
      const sel = p.id === a.provider;
      return `<button class="prov ${sel ? 'sel' : ''}" role="radio" aria-checked="${sel}" data-a="prov" data-v="${p.id}" data-f="prov-${p.id}" id="prov-${p.id}">
        <span class="nm">${esc(p.name)}</span>${sel && a.on ? '<span class="on">· активен</span>' : ''}<span class="grow"></span>
        <span class="radio" style="border-color:rgba(255,255,255,${sel ? 0.9 : 0.28})">${sel ? '<i></i>' : ''}</span></button>`;
    }).join('');
    setHTML(this.right, `<div class="prov-head"><div class="label">DNS-провайдеры</div></div>
      <div class="grid" role="radiogroup" aria-label="DNS-провайдеры">${cards}</div>${notice(a.error)}`);
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
    if (same(this, 'rj', [t.on, t.error])) return;
    const body = t.on
      ? `<div class="card"><div class="nm">Подключить Telegram</div>
          <div class="sm">Откроется окно «Добавить прокси» в Telegram Desktop: подтвердите его.</div>
          <div style="display:flex;justify-content:flex-end;gap:8px;margin-top:8px">
            <button class="btn" data-a="copy" data-f="copy" id="copy">Скопировать ссылку</button>
            <button class="btn" data-a="openTg" data-f="open" id="open">Открыть в Telegram</button></div>
          <div id="note" class="sm" style="text-align:right;min-height:16px"></div></div>`
      : `<div class="card"><div class="nm">Как это работает</div><div class="sm">Включите прокси и подтвердите окно «Добавить прокси» в Telegram.</div></div>`;
    setHTML(this.right, body + notice(t.error));
  }
  destroy() { this.hero.destroy(); }
}

// -------------------------------------------------------------------------------------------------------- YouTube and Discord

export class MediaPage {
  constructor(actions) { this.actions = actions; }
  mount(root) {
    root.innerHTML = shell('YouTube и Discord', '<div class="two"><div class="left" id="slot"></div><div class="right" id="right"></div></div>');
    this.hero = new Stage('screen', () => this.actions.toggle('media'));
    root.querySelector('#slot').appendChild(this.hero.el);
    this.right = root.querySelector('#right');
  }
  update(S) {
    const m = S.media;
    this.hero.update({
      on: m.on, busy: m.busy, disabled: m.busy || !S.serviceOk,
      title: m.busy ? 'Подождите' : m.on ? 'Включено' : 'Выключено',
      subtitle: m.busy ? (m.on ? 'Выключаю туннель…' : 'Включаю туннель…') : m.on ? 'Трафик идёт через Cloudflare WARP.' : 'Включите, чтобы открывались YouTube и Discord. Всё настроится само.',
      label: m.on ? 'Выключить туннель WARP' : 'Включить туннель WARP',
    });
    if (same(this, 'rj', [m.on, m.error])) return;
    const first = m.on ? '' : `<div class="card"><div class="nm">Что произойдёт при включении</div>
      <div class="sm" style="line-height:1.45">Nimb создаст для этого компьютера анонимный аккаунт Cloudflare WARP. Включая, вы принимаете условия Cloudflare WARP.</div>
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

export class SettingsPage {
  constructor(actions) { this.actions = actions; }
  mount(root) { root.innerHTML = shell('Настройки', '<div class="settings" id="body"></div>'); this.body = root.querySelector('#body'); }
  update(S, extra) {
    if (same(this, 'rj', [extra.autostart, S.version])) return;
    const card = (title, text, button) => `<div class="card row"><div class="grow"><div class="nm">${title}</div><div class="sm">${text}</div></div>${button}</div>`;
    setHTML(this.body, `<div class="col">
        <div class="group"><div class="label" style="padding:0 2px">Работа</div>
          ${card('Работа в фоне', 'Закрытие окна не выключает Nimb: он остаётся у часов. Выйти можно из меню значка или кнопкой справа.', '<button class="btn" data-a="quit" data-f="quit" id="quit">Выйти из Nimb</button>')}
          ${card('Запускать вместе с Windows', 'Nimb стартует тихо, значком у часов.', `<button class="pill ${extra.autostart ? 'on' : ''}" role="switch" aria-checked="${extra.autostart}" aria-label="Запускать вместе с Windows" data-a="autostart" data-f="autostart" id="autostart"></button>`)}
        </div>
        <div class="group"><div class="label" style="padding:0 2px">Помощь</div>
          ${card('Сообщить о проблеме', 'Отчёт придёт разработчику. Паролей и адресов в нём нет.', '<button class="btn" data-a="report" data-f="report" id="report">Отправить…</button>')}
          ${card('Первая настройка', 'Короткое обучение по шагам.', '<button class="btn" data-a="onboard" data-f="onboard" id="onboard">Пройти заново</button>')}
        </div></div>
      <div class="col">
        <div class="group"><div class="label" style="padding:0 2px">Удаление</div>
          ${card('Удалить Nimb', 'Вернёт DNS к автоматическому и удалит приложение вместе с настройками.', '<button class="btn red" data-a="uninstall" data-f="uninstall" id="uninstall">Удалить…</button>')}
        </div>
        <div class="group"><div class="label" style="padding:0 2px">О программе</div>
          ${card('Версия', `Nimb для Windows ${esc(S.version)}`, '')}
        </div></div>`);
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
      <div class="sm" style="margin:0">Версия, состояние сервисов и последние строки журнала. Паролей, ключей и IP-адресов в отчёте нет.</div>
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
