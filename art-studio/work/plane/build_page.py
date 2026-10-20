import json, os
root = '../../previews/03-samolet'
looks = [('paper', 'Бумага', 'Белая бумага со складками и мягким светом: самый «настоящий» бумажный самолётик.', 'мой выбор'),
         ('arrow', 'Стрела', 'Уже и длиннее: быстрее, острее, больше похож на стрелу.', ''),
         ('edge', 'Контур', 'Тёмные грани и светящиеся рёбра: язык нимба, самолётик как будто из света.', '')]
meta = {k: json.load(open(os.path.join(root, k, 'meta.json'))) for k, *_ in looks}
cards = ''
for i, (k, title, text, reco) in enumerate(looks, 1):
    strip = ''.join('<img src="%s/bank-%02d.png" width="56" height="56" alt="">' % (k, j) for j in range(13))
    cards += f'''<section class="variant"><header><span class="num">{i}</span><h2>{title}</h2>{'<span class="reco">'+reco+'</span>' if reco else ''}</header><p>{text}</p>
<div class="row"><div><canvas data-k="{k}"></canvas><div class="cap">Страница Telegram: влетает по дуге, останавливается, шлёт луч.</div></div>
<div><div class="strip">{strip}</div><div class="cap">13 кадров крена, от левого до правого (так он наклоняется на виражах).</div></div></div></section>'''
html = '''<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><title>Самолётик: три характера</title><meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root{color-scheme:dark}body{margin:0;background:#141416;color:#d9d9de;font:14px/1.5 -apple-system,system-ui,sans-serif;padding:28px 32px 80px}
h1{font:600 22px -apple-system,system-ui,sans-serif;margin:0 0 4px}h2{font:600 17px -apple-system,system-ui,sans-serif;margin:0}p{margin:4px 0 0;color:#9a9aa3;max-width:760px}
.bar{position:sticky;top:0;z-index:5;background:#141416ee;padding:12px 0;margin:14px 0 6px;display:flex;gap:8px;flex-wrap:wrap;align-items:center}
button{font:inherit;color:#d9d9de;background:#26262b;border:1px solid #38383f;border-radius:8px;padding:6px 12px;cursor:pointer}button.on{background:#ececf0;color:#101012;border-color:#ececf0}
.variant{margin-top:34px;padding-top:20px;border-top:1px solid #2a2a2f}.variant header{display:flex;align-items:baseline;gap:12px}
.num{font:600 13px ui-monospace,Menlo,monospace;background:#ececf0;color:#101012;border-radius:6px;padding:2px 8px}.reco{color:#cdb98a;font-size:12px}
.row{display:flex;gap:18px;flex-wrap:wrap;margin-top:14px;align-items:flex-start}canvas{background:#000;border-radius:12px;display:block}
.strip{display:flex;flex-wrap:wrap;width:400px;background:#000;border-radius:12px;padding:6px}.strip img{display:block}.cap{font-size:12px;color:#8a8a93;margin-top:6px;max-width:400px}
</style></head><body>
<h1>Самолётик: три характера</h1>
<p>Настоящая 3D-модель бумажного самолётика: грани, сгибы, вырез на хвосте, свет сверху. Он наклоняется на виражах, оставляет искристый след, у хвоста тихо светится, а зелёный луч (цвет статуса «работает») идёт к носу пёсика. Пёсик и нимб здесь уже настоящие, из deliver/.</p>
<div class="bar"><span style="color:#8a8a93">Состояние:</span>
<button data-state="off">Выключено</button><button id="replay">Включить ▶</button><button data-state="on" class="on">Включено</button><button data-state="busy">Занято</button>
<span style="width:14px"></span><span style="color:#8a8a93">Размер:</span><button data-zoom="1" class="on">1×</button><button data-zoom="2">2×</button></div>
''' + cards + '''
<script>
const META = ''' + json.dumps(meta) + ''';
const HALO = '../../deliver/halo/', HOOD = '../../deliver/hood/';
const FRAMES = 24, FPS = 8, CROP = { w: 204, h: 100, x: 66, y: 47 }, HC = { w: 336, h: 194 };
const OK = [118, 204, 171];
const imgs = {};
const img = s => (imgs[s] ||= Object.assign(new Image(), { src: s }));
img(HALO + 'back.png'); img(HALO + 'front.png'); img(HOOD + 'on.png'); img(HOOD + 'off.png');
for (let i = 0; i < FRAMES; i++) img(HALO + 'sparkle-' + String(i).padStart(2, '0') + '.png');
for (const k in META) { img(k + '/glow.png'); for (let j = 0; j < 13; j++) img(k + '/bank-' + String(j).padStart(2, '0') + '.png'); }

let state = 'on', zoom = 1, speed = 1, t0 = performance.now(), startedAt = -100, lit = 1;
let wasOn = true;
const canvases = [...document.querySelectorAll('canvas')];
function size() { for (const c of canvases) { const k = zoom * 2; c.width = 400 * k; c.height = 240 * k; c.style.width = 400 * zoom + 'px'; c.style.height = 240 * zoom + 'px'; } }
size();
const ease = x => x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2;
const clamp = (x, a, b) => Math.min(Math.max(x, a), b);
const smooth = (a, b, x) => { const t = clamp((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); };
const wrap = a => { while (a > Math.PI) a -= 2 * Math.PI; while (a < -Math.PI) a += 2 * Math.PI; return a; };

function layer(ctx, im, cx, cy, s, alpha, ox = 0, oy = 0, w = HC.w, h = HC.h) {
  if (!im.complete || !im.naturalWidth) return;
  ctx.globalAlpha = alpha; ctx.drawImage(im, cx + (ox - HC.w / 2) * s, cy + (oy - HC.h / 2) * s, w * s, h * s); ctx.globalAlpha = 1;
}
function halo(ctx, part, cx, cy, s, alpha, time) {
  ctx.globalCompositeOperation = 'screen';
  if (part === 'back') layer(ctx, imgs[HALO + 'back.png'], cx, cy, s, alpha);
  else {
    layer(ctx, imgs[HALO + 'front.png'], cx, cy, s, alpha);
    const f = (time * FPS * speed) % FRAMES, i0 = Math.floor(f), fr = f - i0, n = i => imgs[HALO + 'sparkle-' + String(i).padStart(2, '0') + '.png'];
    layer(ctx, n(i0), cx, cy, s, alpha * (1 - fr), CROP.x, CROP.y, CROP.w, CROP.h);
    layer(ctx, n((i0 + 1) % FRAMES), cx, cy, s, alpha * fr, CROP.x, CROP.y, CROP.w, CROP.h);
  }
  ctx.globalCompositeOperation = 'source-over';
}

// Where the plane is at time t after the start (seconds), relative to the figure centre c. Same path as in the app: an ellipse 112 x 78,
// from angle -2.7 to -0.55 in 2.6 s after a 0.25 s pause, eased out; the beam target is the nose of the dog.
const TARGET = { x: 1.4, y: 33.7 };
function planeAt(t, c, bob) {
  const raw = clamp((t - 0.25) / 2.6, 0, 1), e = 1 - Math.pow(1 - raw, 3);
  const a = -2.7 + (-0.55 + 2.7) * e;
  let x = c.x + 112 * Math.cos(a), y = c.y + 78 * Math.sin(a);
  const hover = Math.pow(e, 4);
  x += Math.cos(t * 0.7) * 1.6 * hover; y += Math.sin(t * 0.9) * 1.6 * hover;
  return { x, y, raw, e, a };
}
function state_(t, c, bob) {
  const p = planeAt(t, c, bob), q = planeAt(t - 0.04, c, bob);
  const tx = c.x + TARGET.x, ty = c.y + TARGET.y + bob;
  const tangent = Math.atan2(p.y - q.y, p.x - q.x), aim = Math.atan2(ty - p.y, tx - p.x);
  const head = tangent + wrap(aim - tangent) * smooth(0.62, 0.98, p.raw);
  return { p, head, aim, tx, ty };
}

const trails = {};
function frame(now) {
  const time = (now - t0) / 1000;
  const on = state !== 'off';
  if (on && !wasOn) startedAt = time; if (!on && wasOn) startedAt = -100;
  wasOn = on;
  lit += ((on ? 1 : 0) - lit) * 0.12;
  speed = state === 'busy' ? 2 : 1;
  const pulse = state === 'busy' ? 0.75 + 0.25 * Math.sin(time * 5) : 1;
  const t = on ? time - startedAt : 0;
  for (const c of canvases) {
    const k = zoom * 2, ctx = c.getContext('2d'); ctx.setTransform(k, 0, 0, k, 0, 0);
    const W = c.width / k, H = c.height / k, key = c.dataset.k, m = META[key];
    ctx.fillStyle = '#000'; ctx.fillRect(0, 0, W, H);
    const cx = W / 2, cy = H / 2, ctr = { x: cx, y: cy + 2 };
    const g = ctx.createRadialGradient(cx, cy + 4, 8, cx, cy + 4, 128);
    g.addColorStop(0, `rgba(255,255,255,${0.05 + 0.13 * lit})`); g.addColorStop(1, 'rgba(255,255,255,0)'); ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
    const bob = lit > 0.5 ? Math.sin(time * 0.9) * 2.2 : 0;
    const hy = cy - 49 + (lit - 1) * 18 + bob * 0.7, hs = 0.8 * (1 + 0.012 * Math.sin(time * 1.3)), ho = lit * (0.93 + 0.07 * Math.sin(time * 1.7)) * pulse;
    halo(ctx, 'back', cx, hy, hs, ho, time);
    ctx.save(); ctx.translate(ctr.x, ctr.y + bob); ctx.rotate((lit > 0.5 ? Math.sin(time * 0.6) * 0.9 : 0) * Math.PI / 180);
    const off = imgs[HOOD + 'off.png'], onI = imgs[HOOD + 'on.png'];
    if (off.complete && onI.complete) { ctx.globalAlpha = 1 - lit; ctx.drawImage(off, -64, -77, 128, 154); ctx.globalAlpha = lit; ctx.drawImage(onI, -64, -77, 128, 154); ctx.globalAlpha = 1; }
    ctx.restore();
    halo(ctx, 'front', cx, hy, hs, ho, time);

    // ---- the plane
    const tr = (trails[key] ||= []);
    if (on) {
      const s = state_(t, ctr, bob), p = s.p;
      const dh = wrap(s.head - state_(t - 0.05, ctr, bob).head) / 0.05;
      const bank = clamp(dh * 20, -36, 36) + 4 * Math.sin(time * 1.3) * Math.pow(p.e, 4);
      const alpha = Math.min(p.raw * 6, 1) * (state === 'busy' ? 1 : 1);
      // trail: where the tail has been
      const rot = s.head + Math.PI / 2;
      const tail = { x: p.x - Math.cos(s.head) * (m.tail[1] - 32), y: p.y - Math.sin(s.head) * (m.tail[1] - 32) };
      if (p.raw > 0 && p.raw < 1) tr.push({ x: tail.x, y: tail.y, t: time, r: Math.random() });
      while (tr.length && time - tr[0].t > 0.9) tr.shift();
      for (let i = 1; i < tr.length; i++) {
        const a0 = tr[i - 1], a1 = tr[i], age = (time - a1.t) / 0.9, al = Math.pow(1 - age, 1.7) * 0.6 * alpha;
        ctx.strokeStyle = `rgba(255,255,255,${al})`; ctx.lineWidth = 0.4 + 2.0 * (1 - age); ctx.lineCap = 'round';
        ctx.beginPath(); ctx.moveTo(a0.x, a0.y); ctx.lineTo(a1.x, a1.y); ctx.stroke();
        if (i % 2 === 0) {
          const ox = (a1.r - 0.5) * 7, oy = ((a1.r * 7.3) % 1 - 0.5) * 7;
          ctx.fillStyle = `rgba(255,255,255,${al * (0.5 + 0.5 * Math.sin(time * 30 + i))})`; ctx.fillRect(a1.x + ox, a1.y + oy, 0.9, 0.9);
        }
      }
      // beam
      const beam = clamp((p.raw - 0.6) / 0.4, 0, 1);
      if (beam > 0) {
        const sx = p.x + Math.cos(s.aim) * 14, sy = p.y + Math.sin(s.aim) * 14, dx = s.tx - sx, dy = s.ty - sy, len = Math.hypot(dx, dy), nx = -dy / len * 8, ny = dx / len * 8;
        ctx.save(); ctx.globalAlpha = beam;
        const gr = ctx.createLinearGradient(sx, sy, s.tx, s.ty); gr.addColorStop(0, `rgba(${OK},0.28)`); gr.addColorStop(1, `rgba(${OK},0.02)`);
        ctx.fillStyle = gr; ctx.beginPath(); ctx.moveTo(sx, sy); ctx.lineTo(s.tx + nx, s.ty + ny); ctx.lineTo(s.tx - nx, s.ty - ny); ctx.closePath(); ctx.fill();
        ctx.setLineDash([1.5, 4]); ctx.lineDashOffset = -time * 8 * speed; ctx.strokeStyle = `rgba(${OK},0.8)`; ctx.lineWidth = 0.9; ctx.beginPath(); ctx.moveTo(sx, sy); ctx.lineTo(s.tx, s.ty); ctx.stroke(); ctx.setLineDash([]);
        // little packets of light running along the beam
        for (let i = 0; i < 3; i++) {
          const ph = (time * 0.55 * speed + i / 3) % 1, px = sx + dx * ph, py = sy + dy * ph, pa = Math.sin(Math.PI * ph);
          ctx.fillStyle = `rgba(${OK},${0.25 * pa})`; ctx.beginPath(); ctx.arc(px, py, 3.2, 0, 6.3); ctx.fill();
          ctx.fillStyle = `rgba(255,255,255,${0.9 * pa})`; ctx.beginPath(); ctx.arc(px, py, 1.1, 0, 6.3); ctx.fill();
        }
        const ping = (time * 0.33 * speed) % 1, pr = 2.5 + 11 * ping;
        ctx.strokeStyle = `rgba(255,255,255,${(1 - ping) * 0.6})`; ctx.lineWidth = 0.9; ctx.beginPath(); ctx.arc(s.tx, s.ty, pr, 0, 6.3); ctx.stroke();
        ctx.fillStyle = '#fff'; ctx.beginPath(); ctx.arc(s.tx, s.ty, 1.8, 0, 6.3); ctx.fill();
        ctx.restore();
      }
      // the plane itself: two neighbouring bank frames, rotated towards the heading
      const f = clamp((bank + 36) / 6, 0, 12), i0 = Math.min(Math.floor(f), 11), fr = f - i0;
      ctx.save(); ctx.translate(p.x, p.y); ctx.rotate(rot);
      // soft light where the engine would be
      const gl = imgs[key + '/glow.png'];
      if (gl.complete) { ctx.globalCompositeOperation = 'screen'; ctx.globalAlpha = alpha * (0.22 + 0.45 * (0.5 + 0.5 * Math.sin(time * 3))); ctx.drawImage(gl, -12, (m.tail[1] - 32) - 11, 24, 24); ctx.globalCompositeOperation = 'source-over'; }
      for (const [j, w] of [[i0, 1 - fr], [i0 + 1, fr]]) { const im = imgs[key + '/bank-' + String(j).padStart(2, '0') + '.png']; if (im.complete && w > 0.001) { ctx.globalAlpha = alpha * w; ctx.drawImage(im, -32, -32, 64, 64); } }
      ctx.restore(); ctx.globalAlpha = 1;
    } else tr.length = 0;
  }
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
document.querySelectorAll('[data-state]').forEach(b => b.onclick = () => { state = b.dataset.state; document.querySelectorAll('[data-state]').forEach(x => x.classList.toggle('on', x === b)); });
document.getElementById('replay').onclick = () => { startedAt = (performance.now() - t0) / 1000; wasOn = true; lit = 0.2; state = 'on'; document.querySelectorAll('[data-state]').forEach(x => x.classList.toggle('on', x.dataset.state === 'on')); };
document.querySelectorAll('[data-zoom]').forEach(b => b.onclick = () => { zoom = +b.dataset.zoom; size(); document.querySelectorAll('[data-zoom]').forEach(x => x.classList.toggle('on', x === b)); });
</script></body></html>'''
open(os.path.join(root, 'index.html'), 'w').write(html)
print('page ok')
