// The motion of the YouTube and Discord scene: a reference implementation (JavaScript, canvas 2D; units are points and seconds).
//
// Three quiet things say "the service works" (there is no status light on this page: it was tried and dropped):
//   1. sound: a few thin arcs travel away from the Discord mark, like a voice;
//   2. glint: every few seconds a soft band of light sweeps over the glass of the screen and the play button flares for a moment;
//   3. blink: now and then the Discord mark closes its eyes.
//
// Coordinates: S(x, y) maps a point of the 160 x 132 pt canvas of the scene picture (origin at its top left) to the place where you draw.
// Everything is drawn AFTER the scene picture and BEFORE the front half of the halo. Call drawMediaMotion once per frame.
// lit is 0..1 (how much the scene is on); the motion fades in over about 1.5 s starting 0.5 s after the switch (see the manifest).
const MEDIA = {
  mark: [111.2, 90],                                  // the middle of the Discord mark
  play: [77.6, 58],                                   // the middle of the play button
  eyes: [[103.3, 89.0], [119.1, 89.0]], eyeRadius: [3.7, 5.0],
  display: { x0: 35.2, y0: 29.2, x1: 124.8, y1: 88.4, r: 13.6 },
  eyePearl: 212,                                      // grey value of the mark at the eyes (0..255) when fully lit
};
// How strong the sound and the glint are: 1 was the first version, the chosen quiet one is the default.
const MEDIA_DEFAULTS = { sound: 0.5, glint: 0.55 };

function mediaGlow(ctx, x, y, r, a, rgb = '255,255,255') {
  const g = ctx.createRadialGradient(x, y, 0, x, y, r); g.addColorStop(0, `rgba(${rgb},${a})`); g.addColorStop(1, `rgba(${rgb},0)`);
  ctx.fillStyle = g; ctx.beginPath(); ctx.arc(x, y, r, 0, 6.2832); ctx.fill();
}

function drawMediaMotion(ctx, t, lit, S, opt = {}) {
  const o = Object.assign({}, MEDIA_DEFAULTS, opt), clamp = (v, a, b) => Math.min(Math.max(v, a), b);
  const m = S(...MEDIA.mark), pl = S(...MEDIA.play);
  ctx.save(); ctx.globalCompositeOperation = 'screen'; ctx.lineCap = 'round';

  // 1. sound: three arcs, 2.8 s per wave, spaced evenly; radius from 30 to 60 pt around the middle of the mark, from -20 to +54 degrees
  for (let i = 0; i < 3; i++) {
    const ph = ((t / 2.8) + i / 3) % 1, r = 30 + 30 * ph, a = Math.pow(Math.sin(Math.PI * ph), 1.3) * 0.55 * lit * o.sound;
    ctx.strokeStyle = `rgba(255,255,255,${a})`; ctx.lineWidth = (1.5 - 0.8 * ph) * (0.7 + 0.3 * o.sound);
    ctx.beginPath(); ctx.arc(m.x, m.y, r, -0.35, 0.95); ctx.stroke();
  }

  // 2. glint: every 5.2 s, during the first 34 % of the period, a band 32 pt wide, tilted by 0.45 rad, crosses the glass (eased)
  const q = ((t % 5.2) / 5.2) / 0.34, d = MEDIA.display, d0 = S(d.x0, d.y0), d1 = S(d.x1, d.y1);
  if (q < 1) {
    ctx.save(); ctx.beginPath(); ctx.roundRect(d0.x, d0.y, d1.x - d0.x, d1.y - d0.y, d.r); ctx.clip();
    const cx = d0.x - 30 + (d1.x - d0.x + 60) * (q * q * (3 - 2 * q));
    ctx.translate(cx, (d0.y + d1.y) / 2); ctx.rotate(0.45);
    const g = ctx.createLinearGradient(-16, 0, 16, 0);
    g.addColorStop(0, 'rgba(255,255,255,0)'); g.addColorStop(0.5, `rgba(255,255,255,${0.20 * lit * o.glint})`); g.addColorStop(1, 'rgba(255,255,255,0)');
    ctx.fillStyle = g; ctx.fillRect(-16, -120, 32, 240); ctx.restore();
    mediaGlow(ctx, pl.x, pl.y, 26, 0.35 * Math.exp(-(((cx - pl.x) / 22) ** 2)) * lit * o.glint);   // the play button flares as the band passes
  }
  ctx.restore();

  // 3. blink: every 3.9 s the eyes close for 0.2 s (a pearl lid grows over each eye and opens again)
  const b = t % 3.9, closed = b > 3.62 ? Math.sin(Math.PI * clamp((b - 3.62) / 0.2, 0, 1)) : 0;
  if (closed > 0.02) {
    const v = Math.round(MEDIA.eyePearl * (0.30 + 0.70 * lit));
    ctx.fillStyle = `rgb(${v},${v},${v})`;
    for (const e of MEDIA.eyes) { const p = S(...e); ctx.beginPath(); ctx.ellipse(p.x, p.y, MEDIA.eyeRadius[0] + 0.6, (MEDIA.eyeRadius[1] + 0.6) * closed, 0, 0, 6.2832); ctx.fill(); }
  }
}
