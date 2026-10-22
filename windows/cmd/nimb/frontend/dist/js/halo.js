import { img, seq } from './art.js';

// The halo of Nimb as the art studio made it: two halves of the ring (the far one behind a figure, the near one in front of it) and
// a loop of dust and streaks that slides along the ring. Port of Sources/Nimb/HaloArt.swift.
export const HALO = { w: 336, h: 194, cx: 168, cy: 97, rx: 80 };
const SPARKLES = 24, SPARKLE_FPS = 8;
const SP_ORIGIN = { x: 66, y: 47 }, SP_SIZE = { w: 204, h: 100 };

function layer(ctx, opacity, blend, fn) {
  ctx.save(); ctx.globalAlpha = opacity; ctx.globalCompositeOperation = blend; fn(); ctx.restore();
}

export function drawHalo(ctx, part, center, scale, opacity) {
  if (opacity <= 0.003) return;
  const im = img(`halo/${part}.png`);
  if (!im) return;
  layer(ctx, opacity, 'screen', () => ctx.drawImage(im, center.x - HALO.cx * scale, center.y - HALO.cy * scale, HALO.w * scale, HALO.h * scale));
}

/** The loop of dust and streaks along the ring (3 s, 8 frames a second, neighbouring frames dissolve into each other). */
export function drawSparkle(ctx, center, scale, opacity, time) {
  if (opacity <= 0.003) return;
  const frames = seq('halo', 'sparkle-%02d.png', SPARKLES);
  if (frames.some((f) => !f)) return;
  const position = (time * SPARKLE_FPS) % SPARKLES;
  const a = Math.floor(position), mix = position - a;
  const x = center.x - HALO.cx * scale + SP_ORIGIN.x * scale, y = center.y - HALO.cy * scale + SP_ORIGIN.y * scale;
  const w = SP_SIZE.w * scale, h = SP_SIZE.h * scale;
  layer(ctx, opacity * (1 - mix), 'screen', () => ctx.drawImage(frames[a], x, y, w, h));
  layer(ctx, opacity * mix, 'screen', () => ctx.drawImage(frames[(a + 1) % SPARKLES], x, y, w, h));
}

/** The small rings of the home row of the sidebar: three one above another, lit from the bottom up. */
export function drawRingStack(ctx, cx, cy, count, selected) {
  // A ring that is out is as dim as the icons of the services that are off (0.47 of a lit one), as on the Mac.
  const lit = selected ? 1 : 0.82;
  for (let i = 0; i < 3; i++) {
    const scale = 0.105 - 0.004 * i;
    const y = cy - 10 + 4.4 + 5.4 * i;
    const alpha = 2 - i < count ? lit : lit * 0.47;
    for (const part of ['ring-back', 'ring-front']) {
      const im = img(`header/${part}.png`);
      if (!im) continue;
      layer(ctx, alpha, 'lighter', () => ctx.drawImage(im, cx - 168 * scale, y - 97 * scale, 336 * scale, 194 * scale));
    }
  }
}
