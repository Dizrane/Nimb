import { Animator, Fader, makeCanvas, begin, now, smooth, clamp } from './anim.js';
import { Gate } from './gate.js';
import { morph, setText, fadeIn } from './common.js';
import { drawHalo, drawSparkle } from './halo.js';
import { PowerButton } from './power.js';

// The planet of the Smart DNS page: the globe turns to the region of the chosen provider, a halo crowns it, a satellite flies in and
// lights the region with a beam (white, for any region by one rule). With DNS off the page is the power button alone (power.js). Port of Sources/Nimb/GlobeButton.swift, WorldMap.swift and SatelliteArt.swift. The
// coastlines are Natural Earth (public domain), 110m, in art/world.json.
export const REGIONS = {
  ru: { view: { lon: 74, lat: 52 } },
  eu: { view: { lon: 14, lat: 50 } },
  us: { view: { lon: -98, lat: 40 } },
};
// the region of each provider (Services.swift)
export const PROVIDER_REGION = { 'geohide-eu': 'eu', comss: 'ru', magicdns: 'eu', malwlink: 'eu', geohide: 'ru', 'geohide-us': 'us' };

let world = null;
fetch('art/world.json').then((r) => r.json()).then((w) => { world = w; }).catch(() => {});

/** Orthographic projection: the globe as seen from above (lon0, lat0), on the unit disc. */
function ortho(lon0, lat0) {
  const l0 = lon0 * Math.PI / 180, sinLat0 = Math.sin(lat0 * Math.PI / 180), cosLat0 = Math.cos(lat0 * Math.PI / 180);
  return (lon, lat) => {
    const phi = lat * Math.PI / 180, dl = lon * Math.PI / 180 - l0;
    const cosC = sinLat0 * Math.sin(phi) + cosLat0 * Math.cos(phi) * Math.cos(dl);
    let x = Math.cos(phi) * Math.sin(dl), y = cosLat0 * Math.sin(phi) - sinLat0 * Math.cos(phi) * Math.cos(dl);
    if (cosC < 0) { const len = Math.max(Math.hypot(x, y), 1e-9); x /= len; y /= len; }
    return { x, y, visible: cosC >= 0 };
  };
}

const RADIUS = 66;

export class PlanetHero {
  constructor(onClick) {
    this.W = 320; this.H = 218; // the same height as the figure of the other pages
    this.on = false; this.busy = false; this.disabled = false; this.region = 'eu';
    this.from = REGIONS.eu.view; this.to = REGIONS.eu.view; this.turnStarted = -1e9; this.turnDuration = 1.6;
    this.litF = new Fader(1.2); this.hoverF = new Fader(0.5);
    this.satFrom = 0; this.satStarted = -1e9; this.satTarget = 0; this.movingUntil = 0;

    this.el = document.createElement('div'); this.el.className = 'hero';
    this.btn = document.createElement('button'); this.btn.className = 'stage-btn';
    this.btn.style.cssText = `width:${this.W}px;height:${this.H}px`;
    this.btn.addEventListener('click', onClick);
    this.btn.addEventListener('mouseenter', () => this.setHover(true));
    this.btn.addEventListener('mouseleave', () => this.setHover(false));
    [this.canvas, this.ctx, this.dpr] = makeCanvas(this.W, this.H);
    this.power = new PowerButton(this.H);
    this.btn.append(this.canvas, this.power.el);
    this.titleEl = document.createElement('h2'); this.titleEl.style.marginTop = '6px';
    this.statusEl = document.createElement('div'); this.statusEl.className = 'status-line'; this.statusEl.style.minHeight = '38px';
    this.el.append(this.btn, this.titleEl, this.statusEl);
    this.anim = new Animator((t) => this.draw(t), {
      fps: 20, fastFps: 60,
      wants: () => true,
      brief: () => this.moving(),
    });
    this.applyLit(false, true);
  }
  moving() { return now() < this.movingUntil; }
  keep(sec) { this.movingUntil = Math.max(this.movingUntil, now() + sec); this.anim.invalidate(); setTimeout(() => this.anim.invalidate(), (sec + 0.2) * 1000); }
  setHover(h) { this.hoverF.set(h ? 1 : 0, now()); this.power.setHover(h); this.keep(0.6); }

  satellite(t) {
    const e = t - this.satStarted;
    if (this.satTarget > 0.5) return clamp(this.satFrom + Math.max(e - 0.25, 0) / 2.6, 0, 1);
    return clamp(this.satFrom - e / 0.8, 0, 1);
  }
  center(t) {
    const e = smooth((t - this.turnStarted) / this.turnDuration);
    let d = this.to.lon - this.from.lon;
    while (d > 180) d -= 360;
    while (d < -180) d += 360;
    return { lon: this.from.lon + d * e, lat: this.from.lat + (this.to.lat - this.from.lat) * e };
  }

  /** `on` is whether Smart DNS works; `region` is 'eu', 'ru' or 'us'. */
  update({ on, busy, region, disabled, title, providerName, subtitle, label }) {
    const t = now();
    if (!this.shown) {
      // The page was just opened (HeroState.init of the Mac): the planet is not turned (the region is where it belongs), the button
      // stands where it belongs at once, and with Smart DNS already on the planet comes up once, 0.5 s later, as at a switch-on.
      this.shown = true;
      this.from = this.to = REGIONS[region].view; this.region = region; this.turnStarted = -1e9;
      this.litF = new Fader(1.2, 0); this.satFrom = 0; this.satTarget = 0; this.satStarted = -1e9;
      this.power.setOn(on, true);
      if (on) this.applyLit(true, true);
      this.on = on;
    }
    if (region !== this.region) {
      this.from = this.center(t); this.to = REGIONS[region].view; this.turnStarted = t; this.region = region; this.keep(this.turnDuration);
    }
    if (on !== this.on) this.applyLit(on, false);
    this.on = on; this.busy = busy; this.disabled = disabled;
    this.btn.disabled = disabled; this.btn.setAttribute('aria-label', label);
    setText(this.titleEl, title, 350);
    const mode = on && !busy ? `who|${providerName}` : `sub|${subtitle}`;
    if (this.statusMode !== undefined && this.statusMode !== mode) fadeIn(this.statusEl, 450); // easeInOut 0.45 of the Mac (`model.mode`)
    this.statusMode = mode;
    morph(this.statusEl, on && !busy ? `<span class="who"><span class="dot"></span><span>${providerName}</span></span>` : `<span style="font-size:13px;font-weight:400;color:var(--t2)">${subtitle}</span>`);
    this.power.setBusy(busy);
    this.anim.invalidate();
  }
  applyLit(on, initial) {
    const t = now();
    // The planet comes up while the button is on its way (power.js); switching off it goes at once.
    const delay = on ? 0.5 : 0;
    this.satFrom = this.satellite(t);
    this.litF.set(on ? 1 : 0, t, delay);
    this.satTarget = on ? 1 : 0; this.satStarted = t + delay;
    this.power.setOn(on, initial);
    this.keep(delay + (on ? 0.25 + 2.6 + 0.2 : 1.4));
  }

  draw(t) {
    const { ctx, W, H } = this;
    begin(ctx, this.dpr, W, H);
    const still = Gate.reducedMotion;
    const tt = still ? 0 : t;
    const lit = this.litF.value(t), hover = this.hoverF.value(t), satellite = this.satellite(t);
    // The light of the satellite on the region: it reaches the planet as the satellite comes to its station.
    const beam = clamp((satellite - 0.6) / 0.4, 0, 1);
    const c = { x: W / 2, y: H / 2 + 2 };
    const r = RADIUS * (0.88 + 0.12 * lit);
    const cen = this.center(t);
    const project = ortho(cen.lon + Math.sin(tt * 0.15) * 8, cen.lat + Math.sin(tt * 0.1) * 3);
    const spin = this.busy ? 2 : 1;
    const pulse = this.busy ? 0.75 + 0.25 * Math.sin(tt * 5) : 1;
    const strength = lit * pulse;
    const crown = r * 1.22 / 80;
    const halo = { center: { x: c.x, y: c.y - r * 0.02 - lit * r * 0.91 }, scale: crown * (1.55 - 0.55 * lit) };
    const screen = (p) => ({ x: c.x + p.x * r, y: c.y - p.y * r });

    if (strength > 0.01) drawHalo(ctx, 'back', halo.center, halo.scale, strength);

    // The planet
    if (lit > 0.003 && world) {
      ctx.save();
      ctx.globalAlpha = lit;
      const atm = ctx.createRadialGradient(c.x, c.y, 0, c.x, c.y, r * 1.6);
      atm.addColorStop(0, 'rgba(255,255,255,0)');
      atm.addColorStop(0.62, `rgba(255,255,255,${0.03 + 0.10 * lit + 0.06 * hover * lit})`);
      atm.addColorStop(1, 'rgba(255,255,255,0)');
      ctx.fillStyle = atm; ctx.beginPath(); ctx.arc(c.x, c.y, r * 1.6, 0, Math.PI * 2); ctx.fill();

      ctx.save();
      ctx.beginPath(); ctx.arc(c.x, c.y, r, 0, Math.PI * 2); ctx.clip();
      const body = ctx.createLinearGradient(c.x - r, c.y - r, c.x + r, c.y + r);
      body.addColorStop(0, 'rgb(28,28,28)'); body.addColorStop(1, 'rgb(3,3,3)');
      ctx.fillStyle = body; ctx.fillRect(c.x - r, c.y - r, 2 * r, 2 * r);

      ctx.strokeStyle = `rgba(255,255,255,${0.06 + 0.04 * lit})`; ctx.lineWidth = 0.5;
      ctx.stroke(this.graticule(project, screen));

      const land = this.ringsPath(world.land, project, screen);
      ctx.fillStyle = `rgba(255,255,255,${0.10 + 0.08 * lit})`; ctx.fill(land);
      ctx.strokeStyle = `rgba(255,255,255,${0.22 + 0.12 * lit})`; ctx.lineWidth = 0.5; ctx.stroke(land);

      // The region of the chosen provider: a faint outline until the satellite lights it, then white.
      const hl = this.ringsPath(world.regions[this.region] || [], project, screen);
      ctx.lineJoin = 'round';
      ctx.strokeStyle = `rgba(255,255,255,${0.09 * beam})`; ctx.lineWidth = 7; ctx.stroke(hl);
      ctx.strokeStyle = `rgba(255,255,255,${0.14 * beam})`; ctx.lineWidth = 3.5; ctx.stroke(hl);
      ctx.fillStyle = `rgba(255,255,255,${0.10 + 0.55 * beam})`; ctx.fill(hl);
      ctx.strokeStyle = `rgba(255,255,255,${0.35 + 0.25 * beam})`; ctx.lineWidth = 0.7; ctx.stroke(hl);

      // Night side.
      const night = ctx.createLinearGradient(c.x - r + r * 0.5, c.y - r, c.x + r, c.y + r);
      night.addColorStop(0.3, 'rgba(0,0,0,0)'); night.addColorStop(1, 'rgba(0,0,0,0.65)');
      ctx.fillStyle = night; ctx.fillRect(c.x - r, c.y - r, 2 * r, 2 * r);
      ctx.restore();

      const rim = ctx.createLinearGradient(c.x - r, c.y - r, c.x + r, c.y + r);
      rim.addColorStop(0, `rgba(255,255,255,${0.25 + 0.3 * lit + 0.15 * hover * lit})`); rim.addColorStop(1, 'rgba(255,255,255,0.03)');
      ctx.strokeStyle = rim; ctx.lineWidth = 1; ctx.beginPath(); ctx.arc(c.x, c.y, r, 0, Math.PI * 2); ctx.stroke();
      ctx.restore();
    }

    // The near half of the halo and the sparks that drift along it.
    if (strength > 0.01) {
      drawHalo(ctx, 'front', halo.center, halo.scale, strength);
      drawSparkle(ctx, halo.center, halo.scale, strength, tt * spin);
    }

    if (satellite > 0.001 && world) this.drawSatellite(ctx, c, r, satellite, beam, project, screen, tt);
  }

  ringsPath(rings, project, screen) {
    const path = new Path2D();
    for (const ring of rings) {
      const pts = []; let any = false;
      for (let i = 0; i < ring.length - 1; i += 2) { const p = project(ring[i], ring[i + 1]); if (p.visible) any = true; pts.push(screen(p)); }
      if (!any || pts.length <= 2) continue;
      path.moveTo(pts[0].x, pts[0].y);
      for (let i = 1; i < pts.length; i++) path.lineTo(pts[i].x, pts[i].y);
      path.closePath();
    }
    return path;
  }
  graticule(project, screen) {
    const path = new Path2D();
    const add = (coords) => {
      let drawing = false;
      for (const [lon, lat] of coords) {
        const p = project(lon, lat);
        if (p.visible) { const s = screen(p); if (drawing) path.lineTo(s.x, s.y); else { path.moveTo(s.x, s.y); drawing = true; } } else drawing = false;
      }
    };
    for (let lon = -180; lon < 180; lon += 30) { const cs = []; for (let lat = -90; lat <= 90; lat += 5) cs.push([lon, lat]); add(cs); }
    for (let lat = -60; lat <= 60; lat += 30) { const cs = []; for (let lon = -180; lon <= 180; lon += 5) cs.push([lon, lat]); add(cs); }
    return path;
  }

  /**
   * The satellite lights the whole region, whatever its shape: for each piece of land of the region the beam is the hull of the satellite and
   * of the visible outline of that piece, so it widens exactly as far as the land is wide and does not cross the sea between the pieces
   * (Alaska, Hawaii); the land itself is the area that lights.
   */
  drawSatellite(ctx, c, r, satellite, beam, project, screen, t) {
    const rings = world.regions[this.region] || [];
    const pieces = visiblePieces(rings, project, screen, 240);
    let target = c, biggest = -1;
    for (const piece of pieces) { const b = bounds(piece); if (b.w * b.h > biggest) { biggest = b.w * b.h; target = { x: b.x + b.w / 2, y: b.y + b.h / 2 }; } }
    // The satellite flies in once, slows down and then stays at its station.
    const rx = r * 1.62, ry = r * 1.32;
    const eased = 1 - Math.pow(1 - satellite, 3);
    const angle = -2.7 + (-0.55 + 2.7) * eased;
    const sat = { x: c.x + rx * Math.cos(angle), y: c.y + ry * Math.sin(angle) };
    sat.y += Math.sin(t * 0.9) * 1.2 * Math.pow(eased, 4);
    const aim = Math.atan2(target.y - sat.y, target.x - sat.x);
    const flicker = 0.94 + 0.06 * Math.sin(t * 1.4);
    ctx.save();
    ctx.globalAlpha = beam * flicker;
    if (pieces.length) {
      const cone = new Path2D();
      for (const piece of pieces) {
        const hull = convexHull([...piece, sat]);
        hull.forEach((p, i) => (i ? cone.lineTo(p.x, p.y) : cone.moveTo(p.x, p.y)));
        cone.closePath();
      }
      const cg = ctx.createLinearGradient(sat.x, sat.y, target.x, target.y);
      cg.addColorStop(0, 'rgba(255,255,255,0.03)'); cg.addColorStop(1, 'rgba(255,255,255,0.17)');
      ctx.fillStyle = cg; ctx.fill(cone);
    }
    // The light on the ground: the area of the country itself, over the shading of the night side, not over the edge of the disc.
    ctx.save();
    ctx.beginPath(); ctx.arc(c.x, c.y, r, 0, Math.PI * 2); ctx.clip();
    ctx.fillStyle = 'rgba(255,255,255,0.14)'; ctx.fill(this.ringsPath(rings, project, screen));
    ctx.restore();
    ctx.restore();

    ctx.save();
    ctx.globalAlpha = Math.min(satellite * 5, 1);
    ctx.translate(sat.x, sat.y); ctx.rotate(aim - Math.PI / 2 + Math.sin(t * 0.6) * 0.04);
    drawSatelliteBody(ctx, 0.5 + 0.5 * Math.sin(t * 3));
    ctx.restore();
  }
  destroy() { this.anim.destroy(); this.power.destroy(); }
}

/** Body, two solar panels and a blinking antenna, around the origin, in grey. Port of SatelliteArt.swift. */
function drawSatelliteBody(g, pulse) {
  for (const side of [-1, 1]) {
    const x = side < 0 ? -23 : 8;
    g.beginPath(); g.roundRect(x, -4, 15, 8, 1); g.fillStyle = 'rgb(26,26,26)'; g.fill();
    g.beginPath();
    for (let i = 1; i < 4; i++) { g.moveTo(x + 15 * i / 4, -4); g.lineTo(x + 15 * i / 4, 4); }
    g.moveTo(x, 0); g.lineTo(x + 15, 0);
    g.strokeStyle = 'rgba(255,255,255,0.35)'; g.lineWidth = 0.5; g.stroke();
    g.beginPath(); g.roundRect(x, -4, 15, 8, 1); g.strokeStyle = 'rgba(255,255,255,0.85)'; g.lineWidth = 0.7; g.stroke();
  }
  g.beginPath(); g.moveTo(-8, 0); g.lineTo(-5, 0); g.moveTo(5, 0); g.lineTo(8, 0); g.strokeStyle = 'rgba(255,255,255,0.8)'; g.lineWidth = 1; g.stroke();
  g.beginPath(); g.roundRect(-5, -5, 10, 10, 2.2);
  const bg = g.createLinearGradient(-5, -5, 5, 5); bg.addColorStop(0, 'rgb(250,250,250)'); bg.addColorStop(1, 'rgb(153,153,153)');
  g.fillStyle = bg; g.fill(); g.strokeStyle = 'rgba(255,255,255,0.9)'; g.lineWidth = 0.6; g.stroke();
  const gl = g.createRadialGradient(0, 10, 0, 0, 10, 9);
  gl.addColorStop(0, `rgba(255,255,255,${0.6 * pulse + 0.2})`); gl.addColorStop(1, 'rgba(255,255,255,0)');
  g.fillStyle = gl; g.beginPath(); g.arc(0, 10, 9, 0, Math.PI * 2); g.fill();
  g.fillStyle = '#fff'; g.beginPath(); g.arc(0, 10, 1.8, 0, Math.PI * 2); g.fill();
  g.beginPath(); g.moveTo(0, 5); g.lineTo(0, 8.5); g.strokeStyle = 'rgba(255,255,255,0.9)'; g.lineWidth = 1; g.stroke();
}

/** The outline of each piece of land of the rings that faces us, on the screen, about `limit` points in all; the pieces that are hardly seen
 * (an island a few points wide) get no beam of their own; they light up with the region all the same. */
function visiblePieces(rings, project, screen, limit) {
  const total = rings.reduce((n, ring) => n + ring.length / 2, 0);
  const step = Math.max(Math.floor(total / limit), 1);
  const pieces = [];
  for (const ring of rings) {
    const points = [];
    for (let i = 0; i < ring.length - 1; i += 2 * step) { const p = project(ring[i], ring[i + 1]); if (p.visible) points.push(screen(p)); }
    if (points.length > 2) { const b = bounds(points); if (Math.max(b.w, b.h) >= 8) pieces.push(points); }
  }
  return pieces;
}

function bounds(points) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const p of points) { x0 = Math.min(x0, p.x); y0 = Math.min(y0, p.y); x1 = Math.max(x1, p.x); y1 = Math.max(y1, p.y); }
  return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
}

/** The smallest convex polygon around the points (Andrew's monotone chain). */
function convexHull(input) {
  const points = [...input].sort((a, b) => (a.x === b.x ? a.y - b.y : a.x - b.x));
  if (points.length <= 2) return points;
  const cross = (o, a, b) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  const lower = [];
  for (const p of points) { while (lower.length >= 2 && cross(lower[lower.length - 2], lower[lower.length - 1], p) <= 0) lower.pop(); lower.push(p); }
  const upper = [];
  for (const p of [...points].reverse()) { while (upper.length >= 2 && cross(upper[upper.length - 2], upper[upper.length - 1], p) <= 0) upper.pop(); upper.push(p); }
  return [...lower.slice(0, -1), ...upper.slice(0, -1)];
}
