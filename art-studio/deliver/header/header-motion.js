// Window header: one small halo ring that goes round the selected tab word.
// Reference code in canvas 2D, all numbers in points. Port to SwiftUI as is.
// Chosen variant: "behind the word" (both halves of the ring lie BEHIND the labels).

const HEADER = {
  ring: { file: ['ring-back.png', 'ring-front.png'], size: [336, 194], center: [168, 97], ringRx: 80, ringRy: 25 },
  tween: 0.9,            // seconds, smootherstep
  oldFade: 3,            // the old ring fades out in 1/3 of the tween
  breathe: { base: 0.93, amount: 0.07, speed: 1.7 },   // alpha = base + amount * sin(t * speed)
  word: { across: 15, ry: 8.8, dy: 0.5 },   // ring semi-width = word width / 2 + 15, semi-height = 8.8, centre = word centre + 0.5 down
  home: { across: 6, ry: 9 },               // round the home tab (the stack of three rings)
  labelShadowBlur: [2, 5, 8],               // three stacked black text shadows (blur radius, pt, no offset) under every label, so the letters stay clean over the light
  stack: { scale: 0.105, scaleStep: -0.004, firstY: 4.4, stepY: 5.4, order: ['media', 'tg', 'ai'], box: [26, 20] },
  stackAlpha: { onHome: 1, onOtherTab: 0.82, off: 0.14 },
};

const smoother = u => u * u * u * (u * (u * 6 - 15) + 10);

// pose of the ring for a word: word = { cx, cy, w } in header coordinates
function wordPose(word) {
  return { x: word.cx, y: word.cy + HEADER.word.dy, rx: word.w / 2 + HEADER.word.across, ry: HEADER.word.ry };
}
function homePose(icon) { return { x: icon.cx, y: icon.cy, rx: icon.w / 2 + HEADER.home.across, ry: HEADER.home.ry }; }

// draw one half of the ring: part = 'back' | 'front'; reveal 0..1 draws it round the word like a pen (wedge clip from the left, clockwise)
function drawRing(ctx, images, part, pose, alpha, reveal) {
  const R = HEADER.ring;
  ctx.save();
  ctx.translate(pose.x, pose.y);
  ctx.scale(pose.rx / R.ringRx, pose.ry / R.ringRy);
  if (reveal !== undefined && reveal < 1) {
    ctx.beginPath(); ctx.moveTo(0, 0); ctx.arc(0, 0, 600, Math.PI, Math.PI + 2 * Math.PI * reveal); ctx.closePath(); ctx.clip();
  }
  ctx.globalCompositeOperation = 'lighter';   // adds light to the black
  ctx.globalAlpha = alpha;
  ctx.drawImage(images[part], -R.center[0], -R.center[1], R.size[0], R.size[1]);
  ctx.restore();
}

// one frame while a tab is selected. from/to are poses, raw = elapsed / HEADER.tween (0..1), t = seconds
function frame(ctx, images, from, to, raw, t) {
  const b = HEADER.breathe, hb = b.base + b.amount * Math.sin(t * b.speed), u = smoother(Math.min(raw, 1));
  const parts = ['back', 'front'];            // both below the labels in this variant
  if (raw < 1) {
    const fade = Math.max(1 - raw * HEADER.oldFade, 0);
    for (const p of parts) drawRing(ctx, images, p, from, hb * fade);    // the old ring goes out
    for (const p of parts) drawRing(ctx, images, p, to, hb, u);           // the new one is drawn round the word
  } else for (const p of parts) drawRing(ctx, images, p, to, hb);
}

// home tab: three small rings one above another, one per service, drawn into a 26x20 pt box.
// enabled = { media, tg, ai } booleans; selected = whether the home tab is the selected one
function drawStack(ctx, images, enabled, selected) {
  const S = HEADER.stack, A = HEADER.stackAlpha;
  ctx.globalCompositeOperation = 'lighter';
  S.order.forEach((k, i) => {
    const s = S.scale + S.scaleStep * i, cy = S.firstY + S.stepY * i;
    ctx.globalAlpha = enabled[k] ? (selected ? A.onHome : A.onOtherTab) : A.off;
    for (const p of ['back', 'front']) ctx.drawImage(images[p], S.box[0] / 2 - 168 * s, cy - 97 * s, 336 * s, 194 * s);
  });
  ctx.globalAlpha = 1; ctx.globalCompositeOperation = 'source-over';
}
