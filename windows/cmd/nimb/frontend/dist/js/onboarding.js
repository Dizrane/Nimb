import { Animator, makeCanvas, begin } from './anim.js';
import { Gate } from './gate.js';
import { img, preload } from './art.js';
import { drawHalo, drawSparkle } from './halo.js';
import { KINDS, SCAN, player, playIcon } from './icons.js';
import { esc, setHTML } from './common.js';
import { notifyCard } from './pages.js';

const LAST = 4;

// The scan of the welcome step (WelcomeScan.swift): the small halo goes down through the black disc, and what it has passed turns
// into the planet (every second tap goes to the lower edge) or into static noise (the others go to the middle).
const smoother = (u) => u * u * u * (u * (u * 6 - 15) + 10);
function scanProgress(t) {
  if (t < SCAN.down) return smoother(t / SCAN.down);
  if (t < SCAN.down + SCAN.hold) return 1;
  if (t < SCAN.total) return 1 - smoother((t - SCAN.down - SCAN.hold) / SCAN.up);
  return 0;
}
function scanRing(p, edge) {
  const y1 = edge ? SCAN.yEdge : SCAN.yMid;
  const y = SCAN.rest + (y1 - SCAN.rest) * p;
  const a = Math.abs(y) / SCAN.radius;
  const bump = a < 1 ? Math.cos(Math.PI / 2 * a) ** 2 : 0;
  const scale = SCAN.restScale * (1 + SCAN.hug * bump);
  const rx = 80 * scale;
  return { y, scale, rx, ry: rx * 0.3125 };
}
const arcY = (x, r) => { const e = Math.min(Math.abs(x) / r.rx, 1); return r.y - r.ry * Math.sqrt(1 - e * e); };
function hash(a, b, c) {
  let h = (Math.imul(a, 374761393) + Math.imul(b, 668265263) + Math.imul(c, 1274126177)) >>> 0;
  h = Math.imul(h ^ (h >>> 13), 1274126177) >>> 0;
  h = (h ^ (h >>> 16)) >>> 0;
  return h / 4294967296;
}


/** An icon of a step: a black glass disc with a white sign, the small halo of Nimb above it. A press plays its story. */
class StepIcon {
  constructor(kind, size = 80) {
    this.kind = kind; this.size = size;
    this.w = size * 1.62; this.h = size * 1.3;
    [this.canvas, this.ctx, this.dpr] = makeCanvas(this.w, this.h);
    this.pl = player(kind);
    if (kind === 'welcome') preload(['icon-ai/planet.png']);
    this.anim = new Animator((t) => this.draw(t), { fps: 15, fastFps: 30, wants: () => true, brief: () => this.pl.playing });
    this.pl.subs.add(() => this.anim.invalidate());
    this.canvas.style.cursor = 'pointer';
    this.canvas.addEventListener('click', () => playIcon(kind));
  }
  draw(t) {
    if (this.kind === 'welcome') return this.drawWelcome(t);
    const { ctx, size: s } = this;
    begin(ctx, this.dpr, this.w, this.h);
    const k = s / 80, still = Gate.reducedMotion;
    const mid = { x: this.w / 2, y: this.h - s / 2 - s * 0.02 };
    const ring = { x: mid.x, y: mid.y - 36.4 * k };
    const life = still ? { o: 1, s: 1 } : { o: 0.93 + 0.07 * Math.sin(1.7 * t), s: 1 + 0.012 * Math.sin(1.3 * t) };
    const scale = 0.38 * k;
    drawHalo(ctx, 'back', ring, scale * life.s, life.o);
    const def = KINDS[this.kind];
    const frame = this.pl.frame(t) || img(`${def.folder}/${def.still}`);
    if (frame) ctx.drawImage(frame, mid.x - 40 * k, mid.y - 40 * k, 80 * k, 80 * k);
    drawHalo(ctx, 'front', ring, scale * life.s, life.o);
    drawSparkle(ctx, ring, scale * life.s, life.o, still ? 0 : t);
  }
  drawWelcome(t) {
    const { ctx, size: s } = this;
    begin(ctx, this.dpr, this.w, this.h);
    const k = s / 80, still = Gate.reducedMotion;
    const mid = { x: this.w / 2, y: this.h - s / 2 - s * 0.02 };
    const playing = this.pl.playing && !still;
    const e = playing ? Math.max(t - this.pl.started, 0) : 0;
    const p = playing ? scanProgress(e) : 0;
    const edge = this.pl.taps % 2 === 0;
    const ring = scanRing(p, edge);
    let dx = 0, dy = ring.y;
    if (playing && p >= 1) {
      if (!edge) { const n = Math.floor(e * 24); dx = (hash(n, 1, 2) - 0.5) * 0.8; dy += (hash(n, 2, 3) - 0.5) * 0.4; }
      else dy += Math.sin(1.6 * e) * 0.45;
    }
    const center = { x: mid.x + dx * k, y: mid.y + dy * k };
    const life = still ? { o: 1, s: 1 } : { o: 0.93 + 0.07 * Math.sin(1.7 * t), s: 1 + 0.012 * Math.sin(1.3 * t) };
    drawHalo(ctx, 'back', center, ring.scale * k * life.s, life.o);
    const disc = img(`${KINDS.welcome.folder}/${KINDS.welcome.still}`);
    if (disc) ctx.drawImage(disc, mid.x - 40 * k, mid.y - 40 * k, 80 * k, 80 * k);
    if (playing && p > 0) {
      const r = SCAN.radius;
      ctx.save();
      ctx.translate(mid.x, mid.y); ctx.scale(k, k);
      ctx.beginPath(); ctx.arc(0, 0, r, 0, Math.PI * 2); ctx.clip();
      ctx.beginPath(); ctx.moveTo(-r - 1, -r - 2); ctx.lineTo(r + 1, -r - 2);
      for (let x = r + 1; x >= -(r + 1); x -= 1) ctx.lineTo(x, arcY(x, ring));
      ctx.closePath(); ctx.clip();
      if (edge) {
        const planet = img('icon-ai/planet.png');
        if (planet) ctx.drawImage(planet, -40, -40, 80, 80);
      } else {
        const frame = Math.floor(e * 30);
        const gain = (0.55 + 0.45 * Math.sin(e * 6.3) ** 2) * Math.min(p * 2.5, 1);
        for (let y = -r; y <= r; y += 2) {
          const tear = hash(Math.floor(y / 2), 7, frame) > 0.93;
          for (let x = -r; x <= r; x += 2) {
            if (x * x + y * y > r * r) continue;
            const grey = tear ? 235 : hash(x, y, frame) * 230;
            const a = Math.min((tear ? 1 : 0.9) * gain, 1);
            ctx.fillStyle = `rgba(${grey | 0},${grey | 0},${grey | 0},${a})`;
            ctx.fillRect(x, y, 2, 2);
          }
        }
      }
      ctx.restore();
    }
    drawHalo(ctx, 'front', center, ring.scale * k * life.s, life.o);
    drawSparkle(ctx, center, ring.scale * k * life.s, life.o, still ? 0 : t);
  }
  destroy() { this.anim.destroy(); }
}

/** The first set-up: five steps, one for each thing Nimb does, then the switch that makes it work without the person. */
export class Onboarding {
  constructor(actions) {
    this.actions = actions; this.step = 0; this.icon = null; this.iconStep = -1;
    this.el = document.createElement('div'); this.el.className = 'onb';
    this.el.innerHTML = '<button class="link onb-close" data-a="onbclose" data-f="onbclose" id="onbclose" style="display:none">Закрыть</button><div class="onb-col"><div id="onb-dots"></div><div id="onb-icon" class="onb-icon"></div><div id="onb-body" style="display:contents"></div></div>';
    document.body.appendChild(this.el);
  }
  next() { this.step += 1; this.iconStep = -1; }
  destroy() { if (this.icon) this.icon.destroy(); this.el.remove(); }

  update(S, extra) {
    const step = this.step;
    this.el.querySelector('#onbclose').style.display = step > 0 && step < LAST ? '' : 'none';
    let dots = '';
    for (let i = 0; i <= LAST; i++) dots += `<i class="${i === step ? 'now' : i < step ? 'past' : ''}"></i>`;
    this.el.querySelector('#onb-dots').innerHTML = `<div class="dots" role="img" aria-label="Шаг ${step + 1} из ${LAST + 1}">${dots}</div>`;
    if (this.iconStep !== step) {
      if (this.icon) this.icon.destroy();
      const kind = ['welcome', 'ai', 'telegram', 'media', 'gear'][step];
      this.icon = new StepIcon(kind, 80);
      const slot = this.el.querySelector('#onb-icon');
      slot.style.cssText = `width:${this.icon.w}px;height:${this.icon.h}px`;
      slot.replaceChildren(this.icon.canvas);
      this.iconStep = step;
    }
    setHTML(this.el.querySelector('#onb-body'), this.body(S, extra));
  }

  body(S, extra) {
    const step = this.step;
    const head = (title, text) => `<h2>${title}</h2><p>${text}</p>`;
    const done = (t) => `<div class="done"><span class="dot"></span><span>${esc(t)}</span></div>`;
    const busy = (t) => `<div class="busy-row"><span class="spin"></span><span>${esc(t)}</span></div>`;
    const banner = (t) => (t ? `<div class="banner" role="alert">${esc(t)}</div>` : '');
    const next = (label = 'Далее') => `<button class="btn main wide" data-a="onbnext" data-f="onbnext" id="onbnext">${label}</button>`;
    const skip = (label = 'Пропустить') => `<button class="link center-link" data-a="onbnext" data-f="onbskip" id="onbskip">${label}</button>`;
    const go = (k, label, disabled = false) => `<button class="btn main wide" data-a="sw" data-v="${k}" data-f="onbgo" id="onbgo" ${disabled ? 'disabled' : ''}>${label}</button>`;
    const providerName = (S.providers.find((p) => p.id === S.ai.provider) || {}).name || '';

    if (step === 0) {
      return head('Добро пожаловать в Nimb', 'За пару минут настроим всё, чтобы работали нейросети, Telegram, YouTube и Discord. Ничего устанавливать и вводить не нужно: Nimb делает всё сам.')
        + `<div class="card bullets" style="width:100%"><div>✓ Нейросети: ChatGPT, Claude, Gemini и другие</div><div>✓ Telegram: быстрее и без блокировок</div><div>✓ YouTube и Discord</div></div>`
        + next('Начать') + `<button class="link center-link" data-a="onbclose" data-f="onbskip" id="onbskip">Настрою потом</button>`;
    }
    if (step === 1) {
      const s = S.ai, p = S.probe;
      const progress = p.phase === 'enabling' ? 'Включаю…' : p.total > 0 ? `Проверено ${p.done} из ${p.total}` : 'Определяю адреса…';
      return head('Нейросети', 'Из-за региона ChatGPT, Claude и другие нейросети могут не открываться. Nimb переключит DNS на специальный сервис, и они заработают. Лучший сервис он подберёт сам.')
        + (p.running ? busy(progress) : s.on ? done(`Включено: ${providerName}`) + next() : s.busy ? busy('Включаю…')
          : `<button class="btn main wide" data-a="onbbest" data-f="onbgo" id="onbgo" ${S.serviceOk ? '' : 'disabled'}>Подобрать и включить</button>` + skip())
        + banner(s.error || (S.serviceOk ? '' : S.serviceError));
    }
    if (step === 2) {
      const s = S.telegram;
      return head('Telegram', 'Nimb запустит на этом компьютере небольшой прокси, а Telegram будет ходить через него. После включения нажмите «Открыть в Telegram» и подтвердите окно «Добавить прокси».')
        + (s.on ? done('Прокси работает') + '<button class="btn wide" data-a="openTg" data-f="onbopen" id="onbopen">Открыть в Telegram</button>' + next()
          : s.busy ? busy('Запускаю…') : go('telegram', 'Включить прокси') + skip())
        + banner(s.error);
    }
    if (step === 3) {
      const s = S.media;
      return head('YouTube и Discord', 'Nimb создаст для этого компьютера собственный анонимный аккаунт Cloudflare WARP и включит туннель. Личных данных он не передаёт. Пока туннель включён, через Cloudflare идёт весь трафик компьютера: если не открывается банк или Госуслуги, выключите его.')
        + (s.on ? done('Туннель работает') + next()
          : s.busy ? busy('Включаю…')
          : go('media', 'Включить', !S.serviceOk) + `<div class="sm" style="text-align:center;font-size:12px;color:var(--t2)">Включая, вы принимаете условия Cloudflare WARP.</div>
             <button class="link center-link" data-a="terms" data-f="terms" id="terms" style="color:#6ea8ff">Условия Cloudflare WARP</button>` + skip())
        + banner(s.error || (S.serviceOk ? '' : S.serviceError));
    }
    return head('Чтобы работало само', 'Рекомендуем включить: Nimb запустится вместе с Windows, будет работать у часов при закрытом окне и скажет о новой версии.')
      + `<div class="card row" style="width:100%;text-align:left"><div class="grow"><div class="nm">Запускать вместе с Windows</div></div>
         <button class="pill ${extra.autostart ? 'on' : ''}" role="switch" aria-checked="${extra.autostart}" aria-label="Запускать вместе с Windows" data-a="autostart" data-f="autostart" id="autostart"></button></div>`
      + `<div style="width:100%;text-align:left">${notifyCard(S, extra)}</div>`
      + `<button class="btn main wide" data-a="onbfinish" data-f="onbfinish" id="onbfinish">Готово</button>
         <div class="sm" style="text-align:center;font-size:12px;color:var(--t2)">Пройти настройку заново можно в «Настройках» (внизу слева).</div>`;
  }
}
