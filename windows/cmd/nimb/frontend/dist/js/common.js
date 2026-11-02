// Small helpers shared by the pages.
export const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
export const api = () => window.go.main.App;
export const logPage = (what) => { try { api().Log(String(what)); } catch (e) { /* no bridge */ } };

export const SV = {
  ai: { title: 'Нейросети', call: 'SetAI', icon: 'ai' },
  telegram: { title: 'Telegram', call: 'SetTelegram', icon: 'telegram' },
  media: { title: 'YouTube и Discord', call: 'SetMedia', icon: 'media' },
};
export const ORDER = ['ai', 'telegram', 'media'];

/** Makes the children of `to` look like those of `from`, changing only what differs: a node that is already there stays (a spinner goes on
 * turning, a switch moves to its new place instead of being made again at the end, a bar grows), where setting innerHTML would make every
 * node again and every animation and transition would start from nothing at each look at the state. */
function patch(to, from) {
  const old = Array.from(to.childNodes), next = Array.from(from.childNodes);
  next.forEach((n, i) => {
    const o = old[i];
    if (!o) { to.appendChild(n); return; }
    if (o.nodeType !== n.nodeType || o.nodeName !== n.nodeName) { to.replaceChild(n, o); return; }
    if (n.nodeType !== 1) { if (o.nodeValue !== n.nodeValue) o.nodeValue = n.nodeValue; return; }
    for (const a of Array.from(o.attributes)) if (!n.hasAttribute(a.name)) o.removeAttribute(a.name);
    for (const a of Array.from(n.attributes)) if (o.getAttribute(a.name) !== a.value) o.setAttribute(a.name, a.value);
    if (o === document.activeElement && (o.nodeName === 'TEXTAREA' || o.nodeName === 'INPUT')) return; // what the person types stays
    patch(o, n);
  });
  for (let i = old.length - 1; i >= next.length; i--) to.removeChild(old[i]);
}
export function morph(el, html) {
  if (el.__html === html) return;
  el.__html = html;
  const t = document.createElement('template'); t.innerHTML = html;
  patch(el, t.content);
}

/** Sets the html of an element (nodes that did not change are kept, see morph) and gives the focus back to the same control (found by
 * data-f) if it was inside and got lost. */
export function setHTML(el, html) {
  const f = el.contains(document.activeElement) && document.activeElement.dataset ? document.activeElement.dataset.f : null;
  morph(el, html);
  if (f && !el.contains(document.activeElement)) { const n = el.querySelector(`[data-f="${f}"]`); if (n) n.focus(); }
}

export function el(html) { const t = document.createElement('template'); t.innerHTML = html.trim(); return t.content.firstElementChild; }
