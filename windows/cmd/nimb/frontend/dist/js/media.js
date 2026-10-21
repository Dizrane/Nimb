// The motion of the YouTube and Discord scene, ported from Sources/Nimb/MediaMotion.swift: sound arcs from the Discord mark, a glint
// over the glass of the screen with a flare of the play button, and a blink of the mark. A few strokes and gradients per frame.
const MARK = { x: 111.2, y: 90 }, PLAY = { x: 77.6, y: 58 };
const EYES = [{ x: 103.3, y: 89.0 }, { x: 119.1, y: 89.0 }];
const EYE_R = { x: 3.7, y: 5.0 };
const DISPLAY = { x: 35.2, y: 29.2, w: 124.8 - 35.2, h: 88.4 - 29.2 }, DISPLAY_R = 13.6;
const PEARL = 212, SOUND = 0.5, GLINT = 0.55;

/** `origin` is where the top left of the scene picture is on the stage, `t` the clock in seconds, `lit` 0...1. */
export function drawMedia(ctx, origin, t, lit) {
  if (lit <= 0.003) return;
  const S = (p) => ({ x: origin.x + p.x, y: origin.y + p.y });
  const m = S(MARK), pl = S(PLAY);

  ctx.save();
  ctx.globalCompositeOperation = 'screen';
  // 1. Sound: three arcs, 2.8 s per wave, radius 30 to 60 around the mark, from -20 to +54 degrees.
  for (let i = 0; i < 3; i++) {
    const phase = ((t / 2.8) + i / 3) % 1;
    const r = 30 + 30 * phase;
    const alpha = Math.pow(Math.sin(Math.PI * phase), 1.3) * 0.55 * lit * SOUND;
    ctx.beginPath();
    for (let k = 0; k <= 14; k++) {
      const a = -0.35 + (0.95 + 0.35) * k / 14;
      const x = m.x + r * Math.cos(a), y = m.y + r * Math.sin(a);
      if (k === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    }
    ctx.strokeStyle = `rgba(255,255,255,${alpha})`;
    ctx.lineWidth = (1.5 - 0.8 * phase) * (0.7 + 0.3 * SOUND);
    ctx.lineCap = 'round';
    ctx.stroke();
  }

  // 2. Glint: every 5.2 s, in the first 34 % of the period, a band 32 pt wide, tilted by 0.45 rad, crosses the glass.
  const q = ((t % 5.2) / 5.2) / 0.34;
  if (q < 1) {
    const d0 = S(DISPLAY);
    const eased = q * q * (3 - 2 * q);
    const cx = d0.x - 30 + (DISPLAY.w + 60) * eased;
    ctx.save();
    ctx.beginPath(); ctx.roundRect(d0.x, d0.y, DISPLAY.w, DISPLAY.h, DISPLAY_R); ctx.clip();
    ctx.translate(cx, d0.y + DISPLAY.h / 2); ctx.rotate(0.45);
    const g = ctx.createLinearGradient(-16, 0, 16, 0);
    g.addColorStop(0, 'rgba(255,255,255,0)'); g.addColorStop(0.5, `rgba(255,255,255,${0.20 * lit * GLINT})`); g.addColorStop(1, 'rgba(255,255,255,0)');
    ctx.fillStyle = g; ctx.fillRect(-16, -120, 32, 240);
    ctx.restore();
    // The play button flares as the band passes.
    const flare = 0.35 * Math.exp(-(((cx - pl.x) / 22) ** 2)) * lit * GLINT;
    const f = ctx.createRadialGradient(pl.x, pl.y, 0, pl.x, pl.y, 26);
    f.addColorStop(0, `rgba(255,255,255,${flare})`); f.addColorStop(1, 'rgba(255,255,255,0)');
    ctx.fillStyle = f; ctx.beginPath(); ctx.arc(pl.x, pl.y, 26, 0, Math.PI * 2); ctx.fill();
  }
  ctx.restore();

  // 3. Blink: every 3.9 s the eyes close for 0.2 s (a pearl lid grows over each eye and opens again).
  const b = t % 3.9;
  const closed = b > 3.62 ? Math.sin(Math.PI * Math.min(Math.max((b - 3.62) / 0.2, 0), 1)) : 0;
  if (closed > 0.02) {
    const v = Math.round(PEARL * (0.30 + 0.70 * lit));
    ctx.fillStyle = `rgb(${v},${v},${v})`;
    for (const eye of EYES) {
      const p = S(eye), ry = (EYE_R.y + 0.6) * closed;
      ctx.beginPath(); ctx.ellipse(p.x, p.y, EYE_R.x + 0.6, ry, 0, 0, Math.PI * 2); ctx.fill();
    }
  }
}
