// The lazy flight of the paper plane: a port of Sources/Nimb/Wanderer.swift (points and seconds, y down). A small simulation, not a
// formula: the plane flies at an almost constant speed, its heading turns by a smooth signal that never repeats, and near the edge of
// its area it is steered back to the middle, so it never stops, never snaps round and never leaves the stage.
const clamp = (v, a, b) => Math.min(Math.max(v, a), b);
const smooth = (a, b, v) => { const u = clamp((v - a) / (b - a), 0, 1); return u * u * (3 - 2 * u); };
const wrap = (a) => { while (a > Math.PI) a -= 2 * Math.PI; while (a < -Math.PI) a += 2 * Math.PI; return a; };
const sign = (v) => (v < 0 ? -1 : v > 0 ? 1 : 0);

export class Wanderer {
  constructor(seed = 0) {
    this.p = { ax: 165, ay: 56, cy: -8, speed: 17, turn: 0.32 };
    this.levels = [-0.9, -0.35, 0.35, 0.9]; this.weights = [0.3, 0.2, 0.2, 0.3];
    this.dwell = [5, 12]; this.outsideLimit = 82; this.depthRate = 0.7; this.speedGain = 0.25;
    this.s = [1.3, 4.1, 2.2, 5.6].map((v) => v * (1 + seed));
    this.state = (Math.trunc(seed * 1000 + 12345)) >>> 0;
    this.t = 0; this.x = -0.6 * this.p.ax; this.y = this.p.cy; this.heading = -0.3 + seed;
    this.rate = 0; this.bank = 0; this.speed = this.p.speed;
    this.z = -0.35; this.zTarget = -0.35; this.nextChange = 4; this.band = 1;
  }
  random() { // mulberry32
    this.state = (this.state + 0x6D2B79F5) >>> 0;
    let v = this.state;
    v = Math.imul(v ^ (v >>> 15), v | 1);
    v ^= v + Math.imul(v ^ (v >>> 7), v | 61);
    return ((v ^ (v >>> 14)) >>> 0) / 4294967296;
  }
  pickLevel() {
    const r = this.random(); let acc = 0;
    for (let i = 0; i < this.levels.length; i++) { acc += this.weights[i]; if (r <= acc) return this.levels[i]; }
    return this.levels[this.levels.length - 1];
  }
  bandFor(z) { return z < -0.55 ? 0 : z < 0 ? 1 : z < 0.55 ? 2 : 3; }
  step(dt) {
    const p = this.p, s = this.s;
    const n = Math.max(1, Math.ceil(dt / (1 / 120)));
    const h = dt / n;
    for (let k = 0; k < n; k++) {
      this.t += h; const t = this.t;
      let omega = p.turn * (0.55 * Math.sin(0.31 * t + s[0]) + 0.35 * Math.sin(0.77 * t + s[1]) + 0.20 * Math.sin(1.43 * t + s[2]));
      const dx = this.x, dy = this.y - p.cy;
      const r2 = (dx / p.ax) ** 2 + (dy / p.ay) ** 2;
      if (r2 > 0.3) {
        const want = Math.atan2(-dy, -dx), err = wrap(want - this.heading);
        omega += clamp(err * 1.5, -1.6, 1.6) * smooth(0.3, 0.85, r2);
      }
      this.heading += omega * h;
      const outside = Math.abs(this.x) > this.outsideLimit;
      if (t >= this.nextChange) {
        const target = this.pickLevel();
        const crosses = sign(target) !== sign(this.z) || sign(target) !== sign(this.zTarget);
        if (!crosses || outside) { this.zTarget = target; this.nextChange = t + this.dwell[0] + this.random() * (this.dwell[1] - this.dwell[0]); }
        else this.nextChange = t + 0.5;
      }
      const crossingNeeded = sign(this.zTarget) !== sign(this.z);
      if (!crossingNeeded || outside || Math.abs(this.z) > 0.45) this.z += (this.zTarget - this.z) * (1 - Math.exp(-h / this.depthRate));
      this.band = this.bandFor(this.z);
      this.speed = p.speed * (1 + 0.22 * Math.sin(0.29 * t + s[3])) * (1 + this.speedGain * this.z);
      this.x += Math.cos(this.heading) * this.speed * h;
      this.y += Math.sin(this.heading) * this.speed * h;
      this.rate += (omega - this.rate) * (1 - Math.exp(-h / 0.35));
      const target = clamp(this.rate * 26, -34, 34);
      this.bank += (target - this.bank) * (1 - Math.exp(-h / 0.30));
    }
  }
}
