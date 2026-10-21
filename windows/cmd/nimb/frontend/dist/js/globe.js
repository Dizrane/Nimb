import { Animator, Fader, makeCanvas, begin, now, smooth, clamp } from './anim.js';
import { Gate } from './gate.js';
import { drawHalo, drawSparkle } from './halo.js';
import { POWER } from './stage.js';

// The planet of the Smart DNS page: the globe turns to the region of the chosen provider, a halo crowns it, a satellite flies in and
// sends a beam to a city of the region. Port of Sources/Nimb/GlobeButton.swift, WorldMap.swift and SatelliteArt.swift. The
// coastlines are Natural Earth (public domain), 110m, in art/world.json.
export const REGIONS = {
  ru: { view: { lon: 74, lat: 52 }, landing: { lon: 37.6, lat: 55.75 } },
  eu: { view: { lon: 14, lat: 50 }, landing: { lon: 8.7, lat: 50.1 } },
  us: { view: { lon: -98, lat: 40 }, landing: { lon: -78.9, lat: 42.9 } },
};
// the region of each provider (Services.swift)
export const PROVIDER_REGION = { 'geohide-eu': 'eu', comss: 'ru', geohide: 'ru', 'geohide-us': 'us' };

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
    this.W = 320; this.H = 214;
    this.on = false; this.busy = false; this.disabled = false; this.region = 'eu';
    this.from = REGIONS.eu.view; this.to = REGIONS.eu.view; this.turnStarted = -1e9; this.turnDuration = 1.6;
    this.litF = new Fader(1.2); this.hoverF = new Fader(0.5);
    this.satFrom = 0; this.satStarted = -1e9; this.satTarget = 0; this.movingUntil = 0;

    this.el = document.createElement('div'); this.el.className = 'hero';
    this.btn = document.createElement('button'); this.btn.className = 'stage-btn';
    this.btn.style.cssText = `width:${this.W}px;height:${this.H}px;margin:-22px 0`;
    this.btn.addEventListener('click', onClick);
    this.btn.addEventListener('mouseenter', () => this.setHover(true));
    this.btn.addEventListener('mouseleave', () => this.setHover(false));
    [this.canvas, this.ctx, this.dpr] = makeCanvas(this.W, this.H);
    // the big button while DNS is off
    this.big = document.createElement('div');
    this.big.style.cssText = 'position:absolute;left:87px;top:48px;width:146px;height:146px;transition:opacity .9s ease-in-out,transform .9s ease-in-out;pointer-events:none';
    this.big.innerHTML = `<div class="big-ring"></div><div class="big-disc"><div class="big-power">${POWER}</div></div>`;
    this.badge = document.createElement('div'); this.badge.className = 'badge on';
    this.badge.style.cssText = `top:${this.H / 2 + RADIUS * 0.56 + 8 - 20}px;transition:opacity 1.2s ease-in-out,transform 1.2s ease-in-out`;
    this.badge.innerHTML = POWER;
    this.btn.append(this.canvas, this.big, this.badge);
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
  setHover(h) { this.hoverF.set(h ? 1 : 0, now()); this.keep(0.6); }

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
    if (region !== this.region) {
      this.from = this.center(t); this.to = REGIONS[region].view; this.turnStarted = t; this.region = region; this.keep(this.turnDuration);
    }
    if (on !== this.on) this.applyLit(on, false);
    this.on = on; this.busy = busy; this.disabled = disabled;
    this.btn.disabled = disabled; this.btn.setAttribute('aria-label', label);
    if (this.titleEl.textContent !== title) this.titleEl.textContent = title;
    this.statusEl.innerHTML = on && !busy ? `<span class="dot"></span><span>${providerName}</span>` : `<span style="font-size:13px;font-weight:400;color:var(--t2)">${subtitle}</span>`;
    this.big.querySelector('.big-power').innerHTML = busy ? '<span class="spin" style="width:22px;height:22px"></span>' : POWER;
    this.anim.invalidate();
  }
  applyLit(on, initial) {
    const t = now();
    this.satFrom = this.satellite(t);
    this.litF.set(on ? 1 : 0, t);
    this.satTarget = on ? 1 : 0; this.satStarted = t;
    this.big.style.opacity = on ? 0 : 1; this.big.style.transform = on ? 'scale(.5)' : 'scale(1)';
    this.badge.style.opacity = on ? 1 : 0; this.badge.style.transform = on ? 'scale(1)' : 'scale(.5)';
    this.badge.style.transitionDelay = on ? '.5s' : '0s';
    if (!initial) this.keep(on ? 0.25 + 2.6 + 0.2 : 1.4);
  }

  draw(t) {
    const { ctx, W, H } = this;
    begin(ctx, this.dpr, W, H);
    const still = Gate.reducedMotion;
    const tt = still ? 0 : t;
    const lit = this.litF.value(t), hover = this.hoverF.value(t), satellite = this.satellite(t);
    const c = { x: W / 2, y: H / 2 + 8 };
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

      // The region of the chosen provider: a faint outline before connecting, solid white after.
      const hl = this.ringsPath(world.regions[this.region] || [], project, screen);
      ctx.lineJoin = 'round';
      ctx.strokeStyle = `rgba(255,255,255,${0.09 * lit})`; ctx.lineWidth = 7; ctx.stroke(hl);
      ctx.strokeStyle = `rgba(255,255,255,${0.14 * lit})`; ctx.lineWidth = 3.5; ctx.stroke(hl);
      ctx.fillStyle = `rgba(255,255,255,${0.10 + 0.55 * lit})`; ctx.fill(hl);
      ctx.strokeStyle = `rgba(255,255,255,${0.35 + 0.25 * lit})`; ctx.lineWidth = 0.7; ctx.stroke(hl);

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

    if (satellite > 0.001 && world) this.drawSatellite(ctx, c, r, satellite, project, screen, tt);
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

  drawSatellite(ctx, c, r, satellite, project, screen, t) {
    const landing = project(REGIONS[this.region].landing.lon, REGIONS[this.region].landing.lat);
    const target = landing.visible ? screen(landing) : c;
    // The satellite flies in once, slows down and then stays at its station.
    const rx = r * 1.62, ry = r * 1.32;
    const eased = 1 - Math.pow(1 - satellite, 3);
    const angle = -2.7 + (-0.55 + 2.7) * eased;
    const sat = { x: c.x + rx * Math.cos(angle), y: c.y + ry * Math.sin(angle) };
    sat.y += Math.sin(t * 0.9) * 1.2 * Math.pow(eased, 4);
    const aim = Math.atan2(target.y - sat.y, target.x - sat.x);
    const beam = clamp((satellite - 0.6) / 0.4, 0, 1);
    const dx = target.x - sat.x, dy = target.y - sat.y, len = Math.max(Math.hypot(dx, dy), 1);
    const nx = -dy / len * 9, ny = dx / len * 9;
    const green = '48,209,89';
    ctx.save();
    ctx.globalAlpha = beam;
    const cone = new Path2D(); cone.moveTo(sat.x, sat.y); cone.lineTo(target.x + nx, target.y + ny); cone.lineTo(target.x - nx, target.y - ny); cone.closePath();
    const cg = ctx.createLinearGradient(sat.x, sat.y, target.x, target.y);
    cg.addColorStop(0, `rgba(${green},0.28)`); cg.addColorStop(1, `rgba(${green},0.02)`);
    ctx.fillStyle = cg; ctx.fill(cone);
    ctx.strokeStyle = `rgba(${green},0.8)`; ctx.lineWidth = 0.9; ctx.lineCap = 'round'; ctx.setLineDash([1.5, 4]); ctx.lineDashOffset = t * 8;
    ctx.beginPath(); ctx.moveTo(sat.x, sat.y); ctx.lineTo(target.x, target.y); ctx.stroke(); ctx.setLineDash([]);
    if (landing.visible) {
      const ping = (t * 0.33) % 1, pr = 2.5 + 11 * ping;
      ctx.strokeStyle = `rgba(${green},${(1 - ping) * 0.85})`; ctx.lineWidth = 1.1; ctx.beginPath(); ctx.arc(target.x, target.y, pr, 0, Math.PI * 2); ctx.stroke();
      ctx.fillStyle = `rgb(${green})`; ctx.beginPath(); ctx.arc(target.x, target.y, 2.2, 0, Math.PI * 2); ctx.fill();
    }
    ctx.restore();

    ctx.save();
    ctx.globalAlpha = Math.min(satellite * 5, 1);
    ctx.translate(sat.x, sat.y); ctx.rotate(aim - Math.PI / 2 + Math.sin(t * 0.6) * 0.04);
    drawSatelliteBody(ctx, 0.5 + 0.5 * Math.sin(t * 3));
    ctx.restore();
  }
  destroy() { this.anim.destroy(); }
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
