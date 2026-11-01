// Every «i» of the program is one popover (infoPanel of the Mac): a dark panel by its button, 14 of margin, a width of its own, held to the
// visible window (what does not fit scrolls). A second press on the same button, a press outside and Escape close it.

let active = null; // { key, el, off }

export function closePopover() {
  if (!active) return;
  active.off();
  active.el.remove();
  active = null;
}

export function isPopoverOpen() { return !!active; }

/**
 * Opens the popover of the button `anchor` (its data-f names it; a second call from the same button closes it). `build(el, redraw)` fills `el`
 * and calls redraw() whenever its content changes; `side` is where it opens: 'below', 'above' or 'right'.
 */
export function openPopover(anchor, { width = 300, side = 'below', build }) {
  const key = anchor.dataset.f || anchor.id || 'anchor';
  if (active && active.key === key) { closePopover(); return; }
  closePopover();
  const el = document.createElement('div');
  el.className = 'popv'; el.setAttribute('role', 'dialog');
  el.style.width = `${width}px`;
  document.body.appendChild(el);
  const place = () => {
    const a = (document.getElementById(anchor.id) || anchor).getBoundingClientRect();
    const limit = innerHeight - 42 - 16; // the bar at the bottom stays free
    el.style.maxHeight = `${Math.round(Math.min(limit, innerHeight * 0.72))}px`;
    const w = el.offsetWidth, h = el.offsetHeight;
    let left, top;
    if (side === 'right') { left = a.right + 8; top = a.top + a.height / 2 - h / 2; if (left + w > innerWidth - 8) left = a.left - w - 8; }
    else if (side === 'above') { left = a.left + a.width / 2 - 24; top = a.top - h - 8; }
    else { left = a.left + a.width / 2 - w / 2; top = a.bottom + 8; }
    left = Math.max(8, Math.min(left, innerWidth - w - 8));
    top = Math.max(8, Math.min(top, innerHeight - 42 - h - 8));
    el.style.left = `${left}px`; el.style.top = `${top}px`;
  };
  const redraw = () => { place(); };
  const onDown = (e) => { if (!el.contains(e.target) && !e.target.closest(`[data-f="${key}"]`)) closePopover(); };
  const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); closePopover(); } };
  const onResize = () => place();
  document.addEventListener('pointerdown', onDown, true);
  document.addEventListener('keydown', onKey, true);
  addEventListener('resize', onResize);
  active = { key, el, off: () => { document.removeEventListener('pointerdown', onDown, true); document.removeEventListener('keydown', onKey, true); removeEventListener('resize', onResize); } };
  build(el, redraw);
  place();
}
