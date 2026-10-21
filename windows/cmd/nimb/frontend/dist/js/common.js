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

/** Sets the html of an element and gives the focus back to the same control (found by data-f) if it was inside. */
export function setHTML(el, html) {
  const f = el.contains(document.activeElement) && document.activeElement.dataset ? document.activeElement.dataset.f : null;
  el.innerHTML = html;
  if (f) { const n = el.querySelector(`[data-f="${f}"]`); if (n) n.focus(); }
}

export function el(html) { const t = document.createElement('template'); t.innerHTML = html.trim(); return t.content.firstElementChild; }
