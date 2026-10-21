import { Gate } from './gate.js';
import { onArtLoad } from './art.js';

export const now = () => performance.now() / 1000;
export const smooth = (u) => { u = Math.min(Math.max(u, 0), 1); return u * u * (3 - 2 * u); };
export const clamp = (v, a, b) => Math.min(Math.max(v, a), b);

/** A value that goes to a target in `seconds`, with a soft start and stop. */
export class Fader {
  constructor(seconds = 1, value = 0) { this.from = value; this.target = value; this.started = -1e9; this.seconds = seconds; }
  value(t) { return this.from + (this.target - this.from) * smooth((t - this.started) / this.seconds); }
  set(target, t) { if (target === this.target) return; this.from = this.value(t); this.target = target; this.started = t; }
}

/**
 * Draws something again and again while it should move, and once when it is still (so that a figure that stopped shows what is true
 * now). `draw(t)` gets the clock in seconds; `wants()` says whether anything moves; `brief()` whether a change is going on that
 * is worth a few frames even when the window is not in front.
 */
export class Animator {
  constructor(draw, { fps = 20, fastFps = 30, wants = () => true, brief = () => false } = {}) {
    Object.assign(this, { drawFn: draw, fps, fastFps, wants, brief });
    this.raf = 0; this.last = 0; this.dirty = true; this.dead = false;
    this.kick = this.kick.bind(this);
    this.unsubs = [Gate.subscribe(this.kick), onArtLoad(() => this.invalidate())];
    this.kick();
  }
  invalidate() { this.dirty = true; this.kick(); }
  kick() { if (!this.raf && !this.dead) this.raf = requestAnimationFrame((ts) => this.frame(ts)); }
  frame(ts) {
    this.raf = 0;
    if (this.dead) return;
    const brief = this.brief();
    const run = this.wants() && Gate.shouldRun(brief) && !Gate.reducedMotion;
    if (run) {
      const interval = 1000 / (brief ? this.fastFps : this.fps);
      if (ts - this.last >= interval - 2) { this.last = ts; this.drawFn(now()); this.dirty = false; }
      this.raf = requestAnimationFrame((t2) => this.frame(t2));
    } else if (this.dirty) {
      this.dirty = false;
      this.drawFn(now());
    }
  }
  destroy() { this.dead = true; if (this.raf) cancelAnimationFrame(this.raf); this.unsubs.forEach((u) => u()); }
}

/** A canvas of `w` x `h` points that draws sharply on any screen; returns [canvas, ctx]. */
export function makeCanvas(w, h) {
  const c = document.createElement('canvas');
  c.style.width = `${w}px`; c.style.height = `${h}px`;
  const dpr = Math.max(window.devicePixelRatio || 1, 1);
  c.width = Math.round(w * dpr); c.height = Math.round(h * dpr);
  const ctx = c.getContext('2d');
  return [c, ctx, dpr];
}
export function begin(ctx, dpr, w, h) { ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.clearRect(0, 0, w, h); ctx.globalAlpha = 1; ctx.globalCompositeOperation = 'source-over'; }
