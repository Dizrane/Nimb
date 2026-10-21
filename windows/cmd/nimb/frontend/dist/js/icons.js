import { Animator, makeCanvas, begin, now } from './anim.js';
import { Gate } from './gate.js';
import { img, seq, preload, frameName } from './art.js';

// The icons of the services (sidebar, first setup): a still, a dimmed still, and a little story that plays when the service is
// switched on or when the icon is pressed. Port of Sources/Nimb/StepIconKind.swift and StepIconPlayer.swift.
export const KINDS = {
  ai: {
    folder: 'icon-ai', still: 'flower.png', dimmed: 'flower-off.png', second: 'planet.png',
    segments: [{ p: 'change-%02d.png', n: 24, s: 1 }, { p: 'rest-%02d.png', n: 48, s: 2 }, { p: 'change-%02d.png', n: 24, s: 1, rev: true }],
  },
  telegram: {
    folder: 'icon-telegram', still: 'plane.png', dimmed: 'plane-off.png', second: 'face.png',
    segments: [{ p: 'out-%02d.png', n: 30, s: 1.25 }, { p: 'rest-%02d.png', n: 10, s: 2 }, { p: 'in-%02d.png', n: 30, s: 1.25 }],
  },
  media: {
    folder: 'icon-media', still: 'play.png', dimmed: 'play-off.png', second: 'mark.png',
    segments: [{ p: 'change-%02d.png', n: 24, s: 1 }, { p: 'rest-%02d.png', n: 24, s: 2 }, { p: 'change-%02d.png', n: 24, s: 1, rev: true }],
  },
  welcome: { folder: 'icon-welcome', still: 'disc.png', dimmed: 'disc-off.png', segments: [] },
  gear: { folder: 'icon-gear', still: 'gear.png', dimmed: 'gear-off.png', segments: [{ p: 'turn-%02d.png', n: 24, s: 1 }] },
};
const duration = (k) => KINDS[k].segments.reduce((a, s) => a + s.s, 0);

class Player {
  constructor(kind) { this.kind = kind; this.playing = false; this.started = 0; this.second = false; this.subs = new Set(); }
  play() {
    if (this.playing) return;
    const k = KINDS[this.kind];
    this.playing = true; this.started = now();
    if (Gate.reducedMotion) {
      this.second = !!k.second; this.notify();
      setTimeout(() => { this.second = false; this.playing = false; this.notify(); }, 2000);
      return;
    }
    // The pictures of the sequence are loaded now, so that the next time it plays without a hitch.
    this.load();
    this.notify();
    setTimeout(() => { this.playing = false; this.notify(); }, (duration(this.kind) + 0.05) * 1000);
  }
  load() {
    const k = KINDS[this.kind];
    return preload(k.segments.flatMap((s) => Array.from({ length: s.n }, (_, i) => `${k.folder}/${frameName(s.p, i)}`)));
  }
  notify() { this.subs.forEach((f) => f()); }
  /** The picture of the story at a moment, or null when nothing plays. */
  frame(t) {
    if (!this.playing) return null;
    const k = KINDS[this.kind];
    if (this.second) return img(`${k.folder}/${k.second}`);
    let e = t - this.started;
    for (const seg of k.segments) {
      if (e < seg.s) {
        const i = Math.min(Math.floor(e / seg.s * seg.n), seg.n - 1);
        return img(`${k.folder}/${frameName(seg.p, seg.rev ? seg.n - 1 - i : i)}`);
      }
      e -= seg.s;
    }
    const last = k.segments[k.segments.length - 1];
    return img(`${k.folder}/${frameName(last.p, last.rev ? 0 : last.n - 1)}`);
  }
}

const players = {};
export const player = (kind) => (players[kind] ||= new Player(kind));
export const playIcon = (kind) => player(kind).play();
/** Loads the stories while the window is idle, so that the first press does not wait for the pictures. */
export function preloadIcons() { setTimeout(() => Object.keys(KINDS).forEach((k) => player(k).load()), 1500); }

/** An icon of a service in a canvas of `size` points. `dimmed()` says whether the service is off. */
export class IconView {
  constructor(kind, size, dimmed) {
    this.kind = kind; this.size = size; this.dimmed = dimmed;
    [this.canvas, this.ctx, this.dpr] = makeCanvas(size, size);
    this.pl = player(kind);
    this.anim = new Animator((t) => this.draw(t), { fps: 30, fastFps: 30, wants: () => this.pl.playing, brief: () => true });
    this.pl.subs.add(() => this.anim.invalidate());
  }
  invalidate() { this.anim.invalidate(); }
  draw(t) {
    const { ctx, size } = this;
    begin(ctx, this.dpr, size, size);
    const k = KINDS[this.kind];
    const frame = this.pl.frame(t) || img(`${k.folder}/${this.dimmed() ? k.dimmed : k.still}`);
    if (frame) ctx.drawImage(frame, 0, 0, size, size);
  }
  destroy() { this.anim.destroy(); }
}
