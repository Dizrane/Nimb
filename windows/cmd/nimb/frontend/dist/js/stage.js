import { Animator, Fader, makeCanvas, begin, now, smooth } from './anim.js';
import { Gate } from './gate.js';
import { img, seq } from './art.js';
import { drawHalo, drawSparkle } from './halo.js';
import { Wanderer } from './wander.js';
import { drawMedia } from './media.js';

export const POWER = '<svg viewBox="0 0 24 24" aria-hidden="true"><path class="power-icon" d="M12 3.5v8.2M7 6.9a7.6 7.6 0 1 0 10 0"/></svg>';

/**
 * The big switch of the Telegram and YouTube/Discord pages: a figure under the halo of Nimb. The halo comes down and the figure
 * lights up when the service is on, a small power button sits below. Port of Sources/Nimb/MascotHero.swift; every picture comes
 * from the art studio and everything that moves is drawn by one canvas from a clock.
 */
export class Stage {
  /** `art` is 'hood' (the dog and the plane) or 'screen' (YouTube and Discord). */
  constructor(art, onClick) {
    this.art = art; this.on = false; this.busy = false; this.disabled = false;
    this.W = 360; this.H = 218;
    this.light = new Fader(1); this.hover = new Fader(0.4);
    this.turnedOn = null; this.movingUntil = 0;
    this.plane = new Wanderer(0); this.lastStep = null;

    this.el = document.createElement('div'); this.el.className = 'hero';
    this.btn = document.createElement('button'); this.btn.className = 'stage-btn';
    this.btn.style.cssText = `width:${this.W}px;height:${this.H}px;-webkit-mask-image:linear-gradient(to bottom,transparent 0,#000 10%,#000 90%,transparent 100%)`;
    this.btn.addEventListener('click', onClick);
    this.btn.addEventListener('mouseenter', () => this.setHover(true));
    this.btn.addEventListener('mouseleave', () => this.setHover(false));
    [this.canvas, this.ctx, this.dpr] = makeCanvas(this.W, this.H);
    this.badge = document.createElement('div'); this.badge.className = 'badge'; this.badge.style.top = `${this.H / 2 + 90 - 20}px`; this.badge.innerHTML = POWER;
    this.btn.append(this.canvas, this.badge);
    this.titleEl = document.createElement('h2'); this.subEl = document.createElement('div'); this.subEl.className = 'sub';
    this.el.append(this.btn, this.titleEl, this.subEl);
    this.anim = new Animator((t) => this.draw(t), {
      fps: 20, fastFps: 30,
      wants: () => this.on || this.busy || this.moving(),
      brief: () => this.moving(),
    });
  }
  moving() { return now() < this.movingUntil; }
  setHover(h) { this.hover.set(h ? 1 : 0, now()); this.movingUntil = Math.max(this.movingUntil, now() + 0.5); this.anim.invalidate(); }

  update({ on, busy, title, subtitle, disabled, label }) {
    const t = now();
    if (on !== this.on) {
      this.light.set(on ? 1 : 0, t);
      if (on) this.turnedOn = t; else this.turnedOn = null;
      this.movingUntil = Math.max(this.movingUntil, t + (on ? 3 : 1.2));
      setTimeout(() => this.anim.invalidate(), (on ? 3.1 : 1.3) * 1000);
    }
    this.on = on; this.busy = busy; this.disabled = disabled;
    this.btn.disabled = disabled; this.btn.setAttribute('aria-label', label);
    this.badge.classList.toggle('on', on);
    this.badge.innerHTML = busy ? '<span class="spin"></span>' : POWER;
    if (this.titleEl.textContent !== title) this.titleEl.textContent = title;
    if (this.subEl.textContent !== subtitle) this.subEl.textContent = subtitle;
    this.anim.invalidate();
  }

  /** How much of something that comes after the switch has appeared. */
  appear(t, delay, duration) {
    if (this.turnedOn == null) return this.light.value(t) > 0 ? 1 : 0;
    const u = Math.min(Math.max((t - this.turnedOn - delay) / duration, 0), 1);
    return Math.min(smooth(u), this.light.value(t));
  }

  draw(t) {
    const { ctx, W, H } = this;
    begin(ctx, this.dpr, W, H);
    const still = Gate.reducedMotion;
    const tt = still ? 0 : t;
    const pulse = this.busy && !still ? 0.75 + 0.25 * Math.sin(tt * 5) : 1;
    if (this.art === 'hood' && !still) {
      if (this.lastStep != null) { const dt = Math.min(Math.max(t - this.lastStep, 0), 0.1); if (dt > 0) this.plane.step(dt * (this.busy ? 1.5 : 1)); }
      this.lastStep = t;
    }
    const lit = this.light.value(t), hover = this.hover.value(t);
    const mid = { x: W / 2, y: H / 2 }, figureY = 2;
    const bob = lit > 0 && !still ? Math.sin(tt * 0.9) * 2.2 * lit : 0;
    const sway = lit > 0 && !still && this.art === 'hood' ? Math.sin(tt * 0.6) * 0.9 * lit : 0;
    const figure = { x: mid.x, y: mid.y + figureY + bob };

    // The soft light behind the figure.
    const glow = 0.05 + 0.13 * lit + 0.04 * hover * lit;
    const gc = { x: mid.x, y: mid.y + figureY + 2 };
    const g = ctx.createRadialGradient(gc.x, gc.y, 8, gc.x, gc.y, 128);
    g.addColorStop(0, `rgba(255,255,255,${glow})`); g.addColorStop(1, 'rgba(255,255,255,0)');
    ctx.fillStyle = g; ctx.beginPath(); ctx.arc(gc.x, gc.y, 135, 0, Math.PI * 2); ctx.fill();

    // The halo: it comes down as the service lights up.
    const breathe = still ? 1 : (0.93 + 0.07 * Math.sin(1.7 * tt)) * pulse;
    const grow = still ? 1 : 1 + 0.012 * Math.sin(1.3 * tt);
    const drop = still ? 0 : (lit - 1) * 18;
    const halo = { center: { x: mid.x, y: mid.y - 61 + drop + bob * 0.7 }, scale: 0.8 * grow, opacity: lit * breathe };
    const planeOpacity = this.art === 'hood' && !still ? this.appear(t, 0.4, 1.8) : 0;

    this.drawPlane(0, figure, planeOpacity, tt);
    drawHalo(ctx, 'back', halo.center, halo.scale, halo.opacity);
    this.drawPlane(1, figure, planeOpacity, tt);

    this.drawFigure(figure, lit, sway);
    if (this.art === 'screen' && !still) {
      drawMedia(ctx, { x: figure.x - 80, y: figure.y - 66 }, tt * (this.busy ? 1.6 : 1), this.appear(t, 0.5, 1.5));
    }

    this.drawPlane(2, figure, planeOpacity, tt);
    drawHalo(ctx, 'front', halo.center, halo.scale, halo.opacity);
    drawSparkle(ctx, halo.center, halo.scale, halo.opacity, still ? 0 : tt * (this.busy ? 2 : 1));
    this.drawPlane(3, figure, planeOpacity, tt);
  }

  drawFigure(figure, lit, sway) {
    const { ctx } = this;
    const folder = this.art === 'hood' ? 'hood' : 'media-scene';
    const size = this.art === 'hood' ? { w: 128, h: 154 } : { w: 160, h: 132 };
    ctx.save();
    ctx.translate(figure.x, figure.y); ctx.rotate(sway * Math.PI / 180);
    const off = img(`${folder}/off.png`), on = img(`${folder}/on.png`);
    if (off && lit < 0.999) ctx.drawImage(off, -size.w / 2, -size.h / 2, size.w, size.h);
    if (on && lit > 0.003) { ctx.globalAlpha = lit; ctx.drawImage(on, -size.w / 2, -size.h / 2, size.w, size.h); }
    ctx.restore();
  }

  /** The paper plane that wanders round the dog, in one of four layers, with depth. */
  drawPlane(band, figure, opacity, t) {
    const pl = this.plane;
    if (this.art !== 'hood' || pl.band !== band || opacity <= 0.003) return;
    const frames = seq('paper-plane', 'bank-%02d.png', 13);
    if (frames.some((f) => !f)) return;
    const { ctx } = this;
    const z = pl.z, k = 1 + 0.08 * z, cy = -8;
    const pos = { x: figure.x + pl.x * k, y: figure.y + (pl.y - cy) * k + cy + 0.8 * Math.sin(1.3 * t) };
    const scale = 0.88 * (1 + 0.17 * z) * (1 + 0.04 * Math.sin(0.21 * t));
    const alpha = (0.72 + 0.28 * (z + 1) / 2) * opacity;
    const index = Math.min(Math.max((pl.bank + 36) / 6, 0), 12);
    const lower = Math.min(Math.floor(index), 11), mix = index - lower;
    ctx.save();
    ctx.translate(pos.x, pos.y); ctx.rotate(pl.heading + Math.PI / 2); ctx.scale(scale, scale);
    ctx.globalAlpha = alpha;
    // The neighbouring bank pictures dissolve over an opaque lower one, so that the plane never gets thinner for a moment.
    ctx.drawImage(frames[lower], -32, -32, 64, 64);
    if (mix > 0.002) { ctx.globalAlpha = alpha * mix; ctx.drawImage(frames[lower + 1], -32, -32, 64, 64); }
    ctx.restore();
  }
  destroy() { this.anim.destroy(); }
}
