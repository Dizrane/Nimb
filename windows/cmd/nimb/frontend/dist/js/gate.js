// Whether the animations have anyone to show themselves to: the window is seen and in front. A window that is hidden, minimised or
// not in front (the person works in another program) is not watched, so nothing is drawn for it. A short animation (something
// is changing right now) may also run while the window is seen but not in front.
let focused = document.hasFocus();
const subs = new Set();
const update = () => subs.forEach((f) => f());
window.addEventListener('focus', () => { focused = true; update(); });
window.addEventListener('blur', () => { focused = false; update(); });
document.addEventListener('visibilitychange', update);

export const Gate = {
  shouldRun(brief = false) { return document.visibilityState === 'visible' && (focused || brief); },
  subscribe(f) { subs.add(f); return () => subs.delete(f); },
  reducedMotion: matchMedia('(prefers-reduced-motion: reduce)').matches,
};
