// The pictures of the art studio (art/…): loaded when first asked for, kept, and the page is told when one arrives, so that a
// canvas that wanted it can be drawn again.
const cache = new Map();
const listeners = new Set();

function notify() { listeners.forEach((f) => f()); }
export function onArtLoad(f) { listeners.add(f); return () => listeners.delete(f); }

/** The picture or null if it is not here yet (it starts loading). */
export function img(path) {
  let e = cache.get(path);
  if (!e) {
    const im = new Image();
    e = { im, ok: false };
    im.onload = () => { e.ok = true; notify(); };
    im.src = `art/${path}`;
    cache.set(path, e);
  }
  return e.ok ? e.im : null;
}

export const frameName = (pattern, i) => pattern.replace(/%02d/, String(i).padStart(2, '0'));

/** A numbered run of pictures: an array with nulls where a picture has not arrived. */
export function seq(folder, pattern, n) {
  return Array.from({ length: n }, (_, i) => img(`${folder}/${frameName(pattern, i)}`));
}

/** Loads pictures ahead (the sequences play without a hitch the first time). */
export function preload(paths) {
  return Promise.all(paths.map((p) => new Promise((resolve) => {
    let e = cache.get(p);
    if (e && e.ok) return resolve();
    if (!e) { img(p); e = cache.get(p); }
    e.im.addEventListener('load', resolve, { once: true });
    e.im.addEventListener('error', resolve, { once: true });
  })));
}
