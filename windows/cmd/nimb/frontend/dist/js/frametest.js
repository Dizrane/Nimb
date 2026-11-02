import { api, logPage } from './common.js';

// A tour of the pages that counts the frames the browser draws, for trying the smoothness on a real machine (NIMB_FRAMELOG=1 before the start,
// the numbers go to the log of the window). It touches no service except the switch of Smart DNS, which it turns on and off again.
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const press = (id) => document.getElementById(id)?.click();

function measure(name, ms) {
  return new Promise((resolve) => {
    const stamps = []; let longTasks = 0;
    let po = null;
    try { po = new PerformanceObserver((l) => { longTasks += l.getEntries().length; }); po.observe({ entryTypes: ['longtask'] }); } catch (e) { /* not there */ }
    const t0 = performance.now();
    const tick = (t) => {
      stamps.push(t);
      if (t - t0 < ms) requestAnimationFrame(tick); else {
        if (po) po.disconnect();
        const d = stamps.slice(1).map((v, i) => v - stamps[i]).sort((a, b) => a - b);
        const q = (p) => (d.length ? d[Math.min(d.length - 1, Math.floor(d.length * p))] : 0).toFixed(1);
        const slow = d.filter((v) => v > 25).length;
        logPage(`кадры «${name}»: ${stamps.length} за ${((stamps.at(-1) - stamps[0]) / 1000).toFixed(1)} с, шаг медиана ${q(0.5)} мс, 95% ${q(0.95)} мс, самый долгий ${q(1)} мс, дольше 25 мс: ${slow}, долгих задач: ${longTasks}`);
        const pg = document.querySelector('.pg');
        if (pg && pg.firstElementChild) logPage(`место «${name}»: страница ${pg.clientHeight}, содержимое ${pg.firstElementChild.scrollHeight}${pg.firstElementChild.scrollHeight > pg.clientHeight ? ' (НЕ ПОМЕЩАЕТСЯ)' : ''}`);
        resolve();
      }
    };
    requestAnimationFrame(tick);
  });
}

export async function runFrameTest() {
  logPage(`кадры: проверка плавности начата, экран ${innerWidth}×${innerHeight}, масштаб ${Math.round(devicePixelRatio * 100)}%, в фокусе: ${document.hasFocus()}`);
  const step = async (name, act, ms) => { act?.(); await wait(50); await measure(name, ms); };
  await wait(2000);
  await step('главная', () => press('nav-home'), 3000);
  await step('нейросети, выключено', () => press('nav-ai'), 3000);
  await step('telegram, выключено', () => press('nav-telegram'), 3000);
  await step('youtube и discord, выключено', () => press('nav-media'), 3000);
  await step('настройки', () => press('nav-settings'), 3000);
  await step('нейросети: включение', () => { press('nav-ai'); setTimeout(() => press('sw-ai'), 600); }, 9000);
  await step('нейросети: включено, покой', null, 4000);
  await step('нейросети: выключение', () => press('sw-ai'), 4000);
  await step('главная', () => press('nav-home'), 2000);
  logPage('кадры: проверка плавности закончена');
}
