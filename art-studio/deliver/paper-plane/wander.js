// The lazy flight of the paper plane: a reference implementation (units: points and seconds, y down, angles in radians).
//
// It is a small simulation, not a formula: the plane flies at an almost constant speed, its heading turns by a smooth,
// never repeating signal, and near the edge of its area it is gently steered back towards the middle. So it never stops,
// never snaps round and never leaves the stage. Call step(dt) once per frame; read x, y, heading, bank, z, band.
//
//   x, y      position relative to the centre of the figure
//   heading   direction of flight (0 = to the right, positive = clockwise on screen); the nose of the picture points up, so rotate by heading + pi/2
//   bank      roll in degrees, positive = turning right (clockwise); pick the picture frame (bank + 36) / 6 and dissolve between neighbours
//   z         depth, -1 far behind the figure ... +1 far in front of it (it passes the figure at 0)
//   band      which layer to draw it in: 0 behind the back half of the halo, 1 between the back half of the halo and the figure,
//             2 between the figure and the front half of the halo, 3 in front of everything
//
// Depth changes only while the plane is far to the side of the figure (|x| > p.outside), so it never jumps over the figure
// or the halo: the plane goes round the scene, now in front of it, now behind it.
function makeWanderer(p, seed = 0) {
  const clamp = (v, a, b) => Math.min(Math.max(v, a), b);
  const smooth = (a, b, v) => { const t = clamp((v - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); };
  const wrap = a => { while (a > Math.PI) a -= 2 * Math.PI; while (a < -Math.PI) a += 2 * Math.PI; return a; };
  // a tiny deterministic random generator (mulberry32), so that the same seed gives the same flight
  let rs = Math.floor(seed * 1000 + 12345) >>> 0;
  const rnd = () => { rs = (rs + 0x6D2B79F5) >>> 0; let t = rs; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  const s = [1.3, 4.1, 2.2, 5.6].map(v => v * (1 + seed));
  const d = Object.assign({ levels: [-0.9, -0.35, 0.35, 0.9], weights: [0.3, 0.2, 0.2, 0.3], dwell: [5, 12], outside: 82, rate: 0.7, speedGain: 0.25 }, p.depth || {});
  const pick = () => { let r = rnd(), acc = 0; for (let i = 0; i < d.levels.length; i++) { acc += d.weights[i]; if (r <= acc) return d.levels[i]; } return d.levels[d.levels.length - 1]; };
  const w = { t: 0, x: -0.6 * p.ax, y: p.cy, heading: -0.3 + seed, rate: 0, bank: 0, speed: p.speed, z: -0.35, zTarget: -0.35, nextChange: 4, band: 1 };
  const bandOf = z => (z < -0.55 ? 0 : z < 0 ? 1 : z < 0.55 ? 2 : 3);
  w.step = function (dt) {
    const n = Math.max(1, Math.ceil(dt / (1 / 120))), h = dt / n;
    for (let i = 0; i < n; i++) {
      w.t += h;
      const t = w.t;
      // the free will of the plane: three slow waves of turning
      let omega = p.turn * (0.55 * Math.sin(0.31 * t + s[0]) + 0.35 * Math.sin(0.77 * t + s[1]) + 0.20 * Math.sin(1.43 * t + s[2]));
      // near the edge of its area: turn towards the middle, the harder the closer to the edge
      const dx = w.x, dy = w.y - p.cy, r2 = (dx / p.ax) ** 2 + (dy / p.ay) ** 2;
      if (r2 > 0.3) {
        const want = Math.atan2(-dy, -dx), err = wrap(want - w.heading);
        omega += clamp(err * 1.5, -1.6, 1.6) * smooth(0.3, 0.85, r2);
      }
      w.heading += omega * h;
      // depth: from time to time pick a new level; to get to the other side of the figure wait until the plane is out at the side
      const outside = Math.abs(w.x) > d.outside;
      if (t >= w.nextChange) {
        const target = pick(), crosses = Math.sign(target) !== Math.sign(w.z) || Math.sign(target) !== Math.sign(w.zTarget);
        if (!crosses || outside) { w.zTarget = target; w.nextChange = t + d.dwell[0] + rnd() * (d.dwell[1] - d.dwell[0]); }
        else w.nextChange = t + 0.5;                                          // not now: try again in half a second
      }
      // a level that is on the other side of the figure is only chased while the plane is outside; if it comes back in too early, it waits at the edge of the figure's side
      const crossingNeeded = Math.sign(w.zTarget) !== Math.sign(w.z);
      if (!crossingNeeded || outside || Math.abs(w.z) > 0.45) w.z += (w.zTarget - w.z) * (1 - Math.exp(-h / d.rate));
      w.band = bandOf(w.z);
      w.speed = p.speed * (1 + 0.22 * Math.sin(0.29 * t + s[3])) * (1 + d.speedGain * w.z);   // nearer things seem to move faster
      w.x += Math.cos(w.heading) * w.speed * h;
      w.y += Math.sin(w.heading) * w.speed * h;
      w.rate += (omega - w.rate) * (1 - Math.exp(-h / 0.35));                // the turn rate, smoothed
      const target = clamp(w.rate * 26, -34, 34);
      w.bank += (target - w.bank) * (1 - Math.exp(-h / 0.30));               // the bank follows the turn a moment later
    }
  };
  return w;
}
if (typeof module !== 'undefined') module.exports = { makeWanderer };
