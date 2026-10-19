// The "scan" of the welcome step: a reference implementation (JavaScript; units are points, y down, the middle of the disc is (0, 0)).
//
// The step is a plain black disc (disc.png) with the small halo above it. A tap moves the halo down through the disc and back, and what the ring has
// passed turns into something else. Taps alternate:
//   odd tap  ("mid"):  the ring goes to the middle of the disc and cannot finish: static noise (white noise) appears behind it, the ring shudders;
//   even tap ("edge"): the ring goes to the lower edge and everything it has passed becomes the planet (../icon-ai/planet.png); on the way back
//                      it turns black again below the ring.
// Both are drawn from the same ring position, so the app only needs: ring(), passed() and the noise rule. No pixel is ever read from an image:
// cut the planet picture with a mask you build yourself (alpha = 1 where the ring has passed).
const SCAN = {
  R: 30,                    // radius of the disc
  rest: -36.4,              // height of the centre of the ring above the middle of the disc when at rest (negative = above)
  s0: 0.38,                 // scale of the halo pictures at rest (the same as the small halo of the other steps)
  hug: 0.14,                // how much wider the ring gets where it goes through the disc (14 % at the middle)
  yMid: 0, yEdge: 28.2,     // the lowest point of the ring in the two taps
  down: 1.8, hold: 2.0, up: 1.8,     // seconds
};
// zero speed and zero acceleration at both ends: the motion has no jerk
const smoother = u => u * u * u * (u * (u * 6 - 15) + 10);

// where the ring is for progress p (0 at rest, 1 at its lowest point); mode is 'mid' or 'edge'
function ring(p, mode) {
  const y1 = mode === 'mid' ? SCAN.yMid : SCAN.yEdge, y = SCAN.rest + (y1 - SCAN.rest) * p;
  const a = Math.abs(y) / SCAN.R, bump = a < 1 ? Math.pow(Math.cos(Math.PI / 2 * a), 2) : 0;   // smooth, no kink where the ring meets the disc
  const scale = SCAN.s0 * (1 + SCAN.hug * bump);
  const rx = 80 * scale;                                                                        // half width of the ring (the halo picture is built on rx = 80 at scale 1)
  return { y, scale, rx, ry: rx * 0.3125 };
}
// progress over time: down, hold at the lowest point, up. t in seconds since the tap
function progress(t) {
  if (t < SCAN.down) return smoother(t / SCAN.down);
  if (t < SCAN.down + SCAN.hold) return 1;
  if (t < SCAN.down + SCAN.hold + SCAN.up) return 1 - smoother((t - SCAN.down - SCAN.hold) / SCAN.up);
  return 0;
}
// has the ring passed the point (x, y)? The border is the near (upper) arc of the ring, so the planet starts exactly at the bright line.
function passed(x, y, r) {
  const e = Math.min(Math.abs(x) / r.rx, 1);
  return (r.y - r.ry * Math.sqrt(1 - e * e)) - y > 0;
}
// the noise of the 'mid' tap, per point that has been passed: grey 0..230 at random, 30 times a second, sometimes a bright torn line (rows of 2 pt).
// strength pulses between 0.55 and 1 (sin(6.3 t)^2) and fades in during the first 40 % of the way down.
function noiseAt(x, y, t, p, rand) {
  const n = rand(x, y, Math.floor(t * 30)), tear = rand(Math.floor(y / 2), 7, Math.floor(t * 30)) > 0.93;
  const gain = (0.55 + 0.45 * Math.pow(Math.sin(t * 6.3), 2)) * Math.min(p * 2.5, 1);
  return { grey: tear ? 235 : n * 230, alpha: Math.min((tear ? 1.0 : 0.9) * gain, 1) };
}
// the ring shudders while it rests in the 'mid' tap: a random shift of up to 0.8 pt across and 0.4 pt up and down, 24 times a second
function shudder(t, rand) { const k = Math.floor(t * 24); return { x: (rand(k, 1, 2) - 0.5) * 0.8, y: (rand(k, 2, 3) - 0.5) * 0.4 }; }
// in the 'edge' tap the ring floats a little while it rests: y += sin(1.6 t) * 0.45
if (typeof module !== 'undefined') module.exports = { SCAN, ring, progress, passed, noiseAt, shudder, smoother };
