import { esc, api, spring } from './common.js';

// The window of the update (UpdateWindow.swift): what is new in the version, and then the installation step by step, so that a failure says
// where it stopped. It stands over the page; closing it while an installation goes only hides it, the installation goes on, and a failure
// brings it back (the program asks the page to open it).

/** The points of a release are written with **bold** and `code`; nothing else of markdown is read. */
const inline = (text) => esc(text).replace(/\*\*(.+?)\*\*/g, '<b>$1</b>').replace(/`(.+?)`/g, '<code>$1</code>');

const MARK = {
  pending: '<span class="us-pend"></span>',
  running: '<span class="spin"></span>',
  done: '<svg viewBox="0 0 20 20" width="18" height="18" aria-hidden="true"><circle cx="10" cy="10" r="9" fill="var(--ok)"/><path d="M5.8 10.4l2.6 2.6 5.2-5.6" fill="none" stroke="#000" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  failed: '<svg viewBox="0 0 20 20" width="18" height="18" aria-hidden="true"><circle cx="10" cy="10" r="9" fill="var(--bad)"/><path d="M6.8 6.8l6.4 6.4M13.2 6.8l-6.4 6.4" fill="none" stroke="#000" stroke-width="1.7" stroke-linecap="round"/></svg>',
};

export class UpdateWindow {
  constructor(actions) { this.actions = actions; this.el = null; this.key = ''; }
  get isOpen() { return !!this.el; }

  open(S) {
    if (this.el) { this.update(S); return; }
    this.el = document.createElement('div');
    this.el.className = 'upw-back';
    this.el.addEventListener('click', (e) => { if (e.target === this.el) this.close(); });
    this.onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); this.close(); } };
    document.addEventListener('keydown', this.onKey, true);
    document.body.appendChild(this.el);
    this.key = '';
    this.update(S);
  }

  close() {
    if (!this.el) return;
    document.removeEventListener('keydown', this.onKey, true);
    this.el.remove(); this.el = null; this.key = '';
  }

  /** Draws the state; the bar and the line move without the rest being drawn again. */
  update(S) {
    if (!this.el) return;
    const u = S.update;
    const phase = u.started ? 'steps' : u.available ? 'available' : 'idle';
    const busy = S.ai.busy || S.telegram.busy || S.media.busy || S.probe.running;
    const structure = JSON.stringify([phase, u.version, u.available, u.checking, u.stages.map((s) => s.state), u.failedStage, u.restarting, u.error, busy, u.notes]);
    if (structure !== this.key) { this.key = structure; this.draw(S, phase, busy); }
    const bar = this.el.querySelector('.us-fill');
    if (bar) {
      bar.style.width = `${Math.max(1, Math.round(u.fraction * 100))}%`;
      this.el.querySelector('.us-line').textContent = u.line || '';
      this.el.querySelector('.us-pct').textContent = `${Math.round(u.fraction * 100)} %`;
    }
  }

  draw(S, phase, busy) {
    const u = S.update;
    const head = `<div class="us-head"><div class="us-title">${u.available ? `Nimb ${esc(u.version)}` : 'Nimb'}</div><div class="sm">Сейчас стоит ${esc(u.current)}</div></div>`;
    let body = '', buttons = '';
    const page = u.available ? '<button class="us-link" data-a="updpage" data-f="updpage" id="updpage">Страница релиза</button>' : '';
    const primary = (label, action) => `<button class="us-primary" data-a="${action}" data-f="${action}" id="${action}" ${busy ? 'disabled title="Подождите: идёт другое переключение"' : ''}>${label}</button>`;
    if (phase === 'available') {
      body = `<div class="us-new"><div class="us-cap">ЧТО НОВОГО</div>${u.notes.length
        ? `<div class="us-notes">${u.notes.map((n) => `<div class="us-note"><i></i><span>${inline(n)}</span></div>`).join('')}</div>`
        : '<div class="us-plain">Описание этого релиза смотрите на его странице.</div>'}</div>`;
      buttons = `${page}<span class="grow"></span><button class="btn" data-a="updclose" data-f="updclose" id="updclose">Позже</button>${primary('Обновить', 'updgo')}`;
    } else if (phase === 'steps') {
      const failed = !!u.failedStage;
      const rows = u.stages.map((s) => `<div class="us-step st-${s.state}"><span class="us-mark">${MARK[s.state]}</span><span>${esc(s.title)}</span></div>`).join('');
      const tail = u.restarting ? '<div class="us-restart"><span class="spin"></span><span>Перезапускаю Nimb…</span></div>'
        : failed ? `<div class="us-fail"><div class="us-failt">Остановилось на этапе «${esc(u.failedStage)}»</div><div class="us-failm">${esc(u.error)}</div></div>`
        : '<div class="sm" style="margin-top:4px">Окно можно закрыть: обновление продолжится само.</div>';
      body = `<div class="us-steps"><div class="us-bar ${failed ? 'bad' : ''}"><div class="us-row"><span class="us-line"></span><span class="us-pct"></span></div>
        <div class="us-track"><div class="us-fill"></div></div></div>${rows}${tail}</div>`;
      buttons = failed ? `${page}<span class="grow"></span><button class="btn" data-a="updcopy" data-f="updcopy" id="updcopy" title="Скопировать подробности ошибки: версии, систему, этап и текст">Скопировать</button>${u.available ? primary('Повторить', 'updgo') : ''}`
        : `${page}<span class="grow"></span>`;
    } else {
      body = `<div class="us-plain">${u.checking ? 'Проверяю обновления…' : 'Установлена последняя версия.'}</div>`;
      buttons = '<span class="grow"></span><button class="btn" data-a="updclose" data-f="updclose" id="updclose">Закрыть</button>';
    }
    const again = !!this.el.firstElementChild, before = this.drawn || {};
    const oldHeight = again ? this.el.firstElementChild.getBoundingClientRect().height : 0;
    this.el.innerHTML = `<div class="upw" role="dialog" aria-label="Обновление Nimb">${head}<div class="us-body">${body}</div><div class="us-buttons">${buttons}</div></div>`;
    this.drawn = { phase, states: u.stages.map((s) => s.state), fail: !!u.failedStage, restarting: !!u.restarting };
    const calm = !this.el.animate || matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (again && !calm) {
      if (before.phase !== phase) {
        // A change of phase: the body and the buttons come in with a short rise (opacity and 6 points, easeInOut 0.28 of the Mac).
        for (const n of this.el.querySelectorAll('.us-body, .us-buttons')) n.animate([{ opacity: 0, transform: 'translateY(6px)' }, { opacity: 1, transform: 'none' }], { duration: 280, easing: 'ease-in-out' });
      } else {
        // The same phase: what changed in the steps moves with the spring of the Mac (.spring(response: 0.38, dampingFraction: 0.82)): a new mark
        // grows from 0.4 and fades in, the box of a failure comes down 6 points, the line of the restart fades in.
        const sp = spring(0.38, 0.82);
        this.el.querySelectorAll('.us-step').forEach((row, i) => {
          if (before.states && before.states[i] !== u.stages[i].state) row.querySelector('.us-mark').firstElementChild?.animate([{ opacity: 0, transform: 'scale(.4)' }, { opacity: 1, transform: 'none' }], sp);
        });
        if (u.failedStage && !before.fail) this.el.querySelector('.us-fail')?.animate([{ opacity: 0, transform: 'translateY(-6px)' }, { opacity: 1, transform: 'none' }], sp);
        if (u.restarting && !before.restarting) this.el.querySelector('.us-restart')?.animate([{ opacity: 0 }, { opacity: 1 }], sp);
        // The card grows or shrinks with the same spring (the Mac animates the whole column of the steps), not at once.
        const card = this.el.firstElementChild, height = card.getBoundingClientRect().height;
        if (Math.abs(height - oldHeight) > 1) card.animate([{ height: `${oldHeight}px`, overflow: 'hidden' }, { height: `${height}px`, overflow: 'hidden' }], sp);
      }
    }
    const first = this.el.querySelector('#updgo:not([disabled]), #updclose');
    if (first && document.activeElement === document.body) first.focus();
  }
}
