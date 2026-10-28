// What is behind the controls (NimbBackground of Sources/Nimb/Scenes.swift): black, a soft glow of the halo at the top, still stars and a
// vignette. Nothing here moves: the stars are drawn once (and again when the window changes its size), the glow and the vignette are
// gradients that fade in 1.7 s when a service goes on or off (at once for a person who asked for less motion, see style.css).
const STARS = 70;

/** The stars of the Mac: a generator with a seed of 21, so that they stand in the same places on every start. */
function drawStars(canvas) {
  const w = innerWidth, h = innerHeight, dpr = Math.max(devicePixelRatio || 1, 1);
  canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr);
  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);
  let state = 21n;
  const next = () => {
    state = BigInt.asUintN(64, state * 6364136223846793005n + 1442695040888963407n);
    return Number(state >> 33n) / 2147483648;
  };
  for (let i = 0; i < STARS; i++) {
    const x = next() * w, y = next() * h, r = 0.5 + next() * 1.1;
    ctx.fillStyle = `rgba(255,255,255,${0.10 + next() * 0.32})`;
    ctx.beginPath(); ctx.ellipse(x, y, r / 2, r / 2, 0, 0, Math.PI * 2); ctx.fill();
  }
}

export function mountSky() {
  const sky = document.getElementById('sky');
  sky.innerHTML = '<div class="sky-glow"></div><canvas class="sky-stars"></canvas><div class="sky-vig"></div>';
  const stars = sky.querySelector('canvas');
  drawStars(stars);
  let timer = 0;
  addEventListener('resize', () => { clearTimeout(timer); timer = setTimeout(() => drawStars(stars), 150); });
  return (lit) => sky.classList.toggle('lit', lit);
}
