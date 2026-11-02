import { Gate } from './gate.js';

const SVG = (w) => `<svg viewBox="0 0 24 24" aria-hidden="true"><path class="power-icon" style="stroke-width:${w}" d="M12 3.5v8.2M7 6.9a7.6 7.6 0 1 0 10 0"/></svg>`;

/**
 * The power button of the pages of a service (PowerButton.swift). With the service off it is the whole page: a large dark disc with a fine
 * ring, in the middle. Switching on, the ring lights up white where it is, then the button grows small and settles under the figure, where it
 * stays, white, as the switch-off button. One number, `progress` (0 off, 1 on), runs all of it along a straight line of time, and the two
 * parts are cut out of it: the ring lights up in the first third, the button travels in the rest. Going back is the same road the other way.
 */
export const POWER_ON_SECONDS = 1.7, POWER_OFF_SECONDS = 1.4;
const LARGE = 112, SMALL = 40, TRAVEL_START = 0.28;
/** Where the middle of the large and of the small button are, from the middle of the stage (the same on every page). */
export const REST_Y = 32, SETTLED_Y = 90;

const ease = (x) => { const u = Math.min(Math.max(x, 0), 1); return u * u * (3 - 2 * u); };

export class PowerButton {
  /** `height` is the height of the stage that the button stands in. */
  constructor(height) {
    this.H = height;
    this.el = document.createElement('div'); this.el.className = 'pwr';
    this.progress = 0; this.target = 0; this.hover = 0; this.hoverTarget = 0; this.hoverFrom = 0; this.hoverAt = 0; this.busy = false;
    this.last = 0; this.raf = 0; this.glyph = ''; this.state = '';
    this.draw();
    this.onVis = () => this.kick();
    document.addEventListener('visibilitychange', this.onVis);
  }
  /** `initial` puts it where it belongs at once (the page was just opened). */
  setOn(on, initial = false) {
    this.target = on ? 1 : 0;
    if (initial || Gate.reducedMotion) this.progress = this.target;
    this.kick();
  }
  setBusy(busy) { if (busy !== this.busy) { this.busy = busy; this.draw(); } }
  setHover(h) {
    const target = h ? 1 : 0;
    if (target === this.hoverTarget) return;
    this.hoverFrom = this.hover; this.hoverTarget = target; this.hoverAt = performance.now(); this.kick();
  }
  kick() { if (!this.raf) { this.last = performance.now(); this.raf = requestAnimationFrame((t) => this.frame(t)); } }
  frame(ts) {
    this.raf = 0;
    const dt = Math.min((ts - this.last) / 1000, 0.1);
    this.last = ts;
    if (this.progress !== this.target) {
      if (Gate.reducedMotion || document.visibilityState !== 'visible') this.progress = this.target;
      else {
        const step = dt / (this.target > this.progress ? POWER_ON_SECONDS : POWER_OFF_SECONDS);
        this.progress = this.target > this.progress ? Math.min(this.progress + step, this.target) : Math.max(this.progress - step, this.target);
      }
    }
    if (this.hover !== this.hoverTarget) {
      // easeInOut over 0.45 s, as on the Mac (not a chase of the target, which starts fast and ends slowly)
      const u = Math.min((ts - this.hoverAt) / 450, 1);
      this.hover = this.hoverFrom + (this.hoverTarget - this.hoverFrom) * ease(u);
      if (u >= 1) this.hover = this.hoverTarget;
    }
    this.draw();
    if (this.progress !== this.target || this.hover !== this.hoverTarget) this.raf = requestAnimationFrame((t) => this.frame(t));
  }
  draw() {
    const p = this.progress, h = this.hover;
    const glow = ease(p / 0.3), travel = ease((p - TRAVEL_START) / (1 - TRAVEL_START));
    // The ring burns brightest while the button is still large and calms down on its way.
    const flare = glow * (1 - travel);
    const size = LARGE + (SMALL - LARGE) * travel;
    const ring = (0.30 + 0.25 * h) * (1 - glow) + glow * (0.75 + 0.20 * flare);
    const glyphOpacity = 0.85 + 0.15 * Math.max(glow, h);
    const y = REST_Y + (SETTLED_Y - REST_Y) * travel;
    const s = this.el.style;
    s.width = s.height = `${size}px`;
    s.left = `calc(50% - ${size / 2}px)`;
    s.top = `${this.H / 2 + y - size / 2}px`;
    s.borderWidth = `${1.4 - 0.4 * travel}px`;
    s.borderColor = `rgba(255,255,255,${ring})`;
    s.boxShadow = `0 6px 12px rgba(0,0,0,${0.4 * (1 - travel)}), 0 0 ${size * 0.14}px rgba(255,255,255,${0.55 * flare + 0.12 * glow})`;
    const glyphSize = 40 - 23 * travel;
    // The spinner is made once for each of its two sizes: made again at every pixel of the way it would start turning from nothing each time.
    const key = this.busy ? `busy|${travel < 0.5}` : `glyph|${Math.round(glyphSize)}`;
    if (this.state !== key) {
      this.state = key;
      this.el.innerHTML = this.busy ? `<span class="spin" style="width:${travel < 0.5 ? 20 : 14}px;height:${travel < 0.5 ? 20 : 14}px"></span>` : SVG(1.2 + 0.5 * travel);
    }
    const svg = this.el.firstElementChild;
    if (svg && !this.busy) { svg.style.width = svg.style.height = `${glyphSize}px`; svg.style.opacity = glyphOpacity; }
  }
  destroy() { if (this.raf) cancelAnimationFrame(this.raf); document.removeEventListener('visibilitychange', this.onVis); }
}
