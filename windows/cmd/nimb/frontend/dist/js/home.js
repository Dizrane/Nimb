import { Animator, Fader, makeCanvas, begin, now } from './anim.js';
import { Gate } from './gate.js';
import { drawHalo, drawSparkle } from './halo.js';

const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

/**
 * The home page: a stack of halos (one for each service that works), the title, the subtitle and the one button that switches
 * everything. There is no figure: the dog belongs to the Telegram page only. Port of Sources/Nimb/HomeHero.swift.
 */
export class HomeHero {
  constructor(scale, onToggle) {
    this.scale = scale; this.bleed = 70 * scale; this.onToggle = onToggle;
    this.rings = [new Fader(1), new Fader(1), new Fader(1)];
    this.light = new Fader(1);
    this.count = -1; this.movingUntil = 0;
    this.el = document.createElement('div');
    this.el.className = 'hero';
    const W = 220 * scale, H = 150 * scale, b = this.bleed;
    this.wrap = document.createElement('div');
    this.wrap.style.cssText = `position:relative;width:${W}px;height:0;transition:height .55s ease-in-out`;
    [this.canvas, this.ctx, this.dpr] = makeCanvas(W + 2 * b, H + 2 * b);
    this.canvas.style.cssText += `;position:absolute;left:${-b}px;bottom:${-b}px;pointer-events:none`;
    this.wrap.appendChild(this.canvas);
    this.title = document.createElement('h2');
    this.title.style.cssText = `font-size:${22 + 8 * scale}px;margin-top:6px;transition:opacity .35s`;
    this.sub = document.createElement('div'); this.sub.className = 'sub'; this.sub.style.minHeight = '0';
    this.button = document.createElement('button'); this.button.className = 'home-btn'; this.button.id = 'all'; this.button.dataset.a = 'all';
    this.button.style.fontSize = `${13 + 2 * (scale - 1)}px`;
    this.button.style.padding = `${6 + 3 * (scale - 1)}px ${14 + 10 * (scale - 1)}px`;
    this.button.addEventListener('click', () => this.onToggle());
    this.el.append(this.wrap, this.title, this.sub, this.button);
    this.size = { W, H };
    this.anim = new Animator((t) => this.draw(t), {
      fps: 20, fastFps: 30,
      wants: () => this.count > 0 || this.moving(),
      brief: () => this.moving(),
    });
  }
  moving() { return now() < this.movingUntil; }

  /** `s` is { count, busy, all, running }: services that work (or are being switched on), whether one is switching, whether all work. */
  update(s) {
    const t = now();
    if (s.count !== this.count) {
      this.count = s.count;
      for (let i = 0; i < 3; i++) this.rings[i].set(i < s.count ? 1 : 0, t);
      this.light.set(s.count > 0 ? 1 : 0, t);
      this.movingUntil = Math.max(this.movingUntil, t + 1.2);
      this.wrap.style.height = s.count > 0 ? `${this.size.H}px` : '0px';
      this.anim.invalidate();
      setTimeout(() => this.anim.invalidate(), 1300);
    }
    const title = s.busy ? 'Подождите' : s.all ? 'Всё включено' : s.count === 0 ? 'Выключено' : 'Включено частично';
    const sub = s.busy ? 'Секунду, переключаю сервисы.' : s.all ? 'Нейросети, Telegram, YouTube и Discord работают.'
      : s.count === 0 ? 'Одна кнопка включает нейросети, Telegram, YouTube и Discord.' : 'Включите остальное кнопкой или переключателями.';
    if (this.title.textContent !== title) this.title.textContent = title;
    if (this.sub.textContent !== sub) this.sub.textContent = sub;
    this.button.disabled = s.busy;
    this.button.innerHTML = `${s.running ? '<span class="spin"></span>' : ''}<span>${s.all ? 'Выключить всё' : 'Включить всё'}</span>`;
  }

  draw(t) {
    const { ctx, scale, bleed: b } = this;
    const { W, H } = this.size;
    begin(ctx, this.dpr, W + 2 * b, H + 2 * b);
    ctx.translate(b, b);
    const still = Gate.reducedMotion;
    const tt = still ? 0 : t;
    const middle = W / 2, multiplier = [0.80, 0.92, 1.0];
    for (let i = 0; i < 3; i++) {
      const value = this.rings[i].value(t);
      const breathe = still ? 1 : 0.93 + 0.07 * Math.sin(1.7 * tt - 0.8 * i);
      const size = still ? 1 : 1 + 0.012 * Math.sin(1.3 * tt - 0.8 * i);
      const drop = still ? 0 : (value - 1) * 18 * scale;
      const center = { x: middle, y: (84 - 22 * i + 8) * scale + drop };
      const sc = (0.78 - 0.055 * i) * scale * size;
      const opacity = value * multiplier[i] * breathe;
      drawHalo(ctx, 'back', center, sc, opacity);
      drawHalo(ctx, 'front', center, sc, opacity);
      drawSparkle(ctx, center, sc, opacity, still ? 0 : tt + i * 0.37);
    }
  }
  destroy() { this.anim.destroy(); }
}
