import test from 'node:test';
import assert from 'node:assert/strict';
import { loadPage, loadPure, sleep } from './helpers.mjs';

const many = (n, cat = 'cl') => Array.from({ length: n }, (_, i) => ({ id: 's' + i, name: 'Stile ' + i, cat: typeof cat === 'function' ? cat(i) : cat }));
const CATS7 = ['cl', 'fk', 'nt', 'ne', 'rt', 'pp', 'st'];
/* jsdom: scrollTop non e' scrivibile -> proprieta' finta sul contenitore delle carte, prima che la pagina parta */
const scrollable = (w) => {
  const orig = Object.getOwnPropertyDescriptor(w.Element.prototype, 'scrollTop');
  Object.defineProperty(w.Element.prototype, 'scrollTop', { configurable: true,
    get() { return this.__st || 0; }, set(v) { this.__st = Math.max(0, +v || 0); } });
  return orig;
};

test('apertura del tab Tema con 70 stili: nodi DOM totali < 600, carte nel DOM << 70', async () => {
  const { w, d } = await loadPage({ setup: scrollable });
  w.gw.onState({ tab: 'theme', look: { style: 's35' }, styles: many(70, (i) => CATS7[i % 7]) });
  await sleep(200);
  const total = d.querySelectorAll('*').length, cards = d.querySelectorAll('.card').length;
  assert.ok(total < 600, 'nodi DOM totali: ' + total);
  assert.ok(cards >= 6 && cards <= 40, 'carte nel DOM: ' + cards);
  assert.equal(d.querySelector('.pane[data-tab="general"]').children.length, 0, 'tab Generale non costruito');
  assert.equal(d.querySelector('.pane[data-tab="keys"]').children.length, 0, 'tab Tasti non costruito');
  /* nessuna mini onda creata per le carte fuori finestra */
  assert.equal(d.querySelectorAll('.card .sw-g svg polyline').length, cards);
});

test('categoria iniziale = quella dello stile CORRENTE (non Tutti); la scelta esplicita dell\'utente poi resta', async () => {
  const GW = loadPure();
  const raw = { tab: 'theme', look: { style: 's3' }, styles: many(70, (i) => CATS7[i % 7]) };
  assert.equal(GW.state.normalize(raw).ui.cat, CATS7[3], 'stile s3 -> categoria ' + CATS7[3]);
  const { w, d } = await loadPage({ setup: scrollable });
  w.gw.onState(raw); await sleep(100);
  assert.equal(d.querySelector('.chip.is-sel').dataset.id, 'ne');
  assert.notEqual(d.querySelector('.chip.is-sel').dataset.id, 'all');
  assert.equal(Number(d.querySelector('.cards').dataset.count), 10);
  d.querySelector('.chip[data-id="all"]').click(); await sleep(20);
  w.gw.onState(raw); await sleep(20);                                     // nuovo stato da Lua: la scelta dell'utente non viene sovrascritta
  assert.equal(d.querySelector('.chip.is-sel').dataset.id, 'all');
  assert.equal(Number(d.querySelector('.cards').dataset.count), 70);
});

test('finestra di righe: scorrendo cambiano le carte nel DOM, il numero resta basso, gli spaziatori tengono l\'altezza totale', async () => {
  const { w, d } = await loadPage({ setup: scrollable });
  w.gw.onState({ tab: 'theme', look: { style: 's0' }, styles: many(70) }); await sleep(100);
  const sc = d.querySelector('.cards-wrap'), grid = d.querySelector('.cards');
  const ids = () => [...d.querySelectorAll('.card')].map((c) => c.dataset.id);
  const first = ids();
  assert.ok(first.includes('s0') && !first.includes('s69'));
  const PITCH = 84, rows = Math.ceil(70 / 3);
  const totalH = () => [...grid.children].reduce((a, c) => a + (c.classList.contains('cards-sp') ? parseFloat(c.style.height) + 8 : 0), 0) + 0;
  sc.scrollTop = 1500; sc.dispatchEvent(new w.Event('scroll'));
  const mid = ids();
  assert.ok(!mid.includes('s0') && mid.includes('s54'), 'carte a ~riga 18: ' + mid.join(','));
  assert.ok(mid.length <= 40);
  /* righe nel DOM + spaziatori = righe totali */
  const rowsInDom = Math.ceil(mid.length / 3);
  const spRows = [...grid.querySelectorAll('.cards-sp')].reduce((a, e) => a + Math.round((parseFloat(e.style.height) + 8) / PITCH), 0);
  assert.equal(rowsInDom + spRows, rows, 'righe: ' + rowsInDom + ' + ' + spRows);
  sc.scrollTop = 99999; sc.dispatchEvent(new w.Event('scroll'));
  assert.ok(ids().includes('s69') && ids().length <= 40);
  assert.equal(grid.dataset.count, '70');
});

test('apertura: scroll alla carta selezionata (centrata) e carta corrente presente nel DOM con la spunta', async () => {
  const { w, d } = await loadPage({ setup: scrollable });
  w.gw.onState({ tab: 'theme', look: { style: 's60' }, styles: many(70) }); await sleep(100);
  const cur = d.querySelector('.card[data-id="s60"]');
  assert.ok(cur && cur.classList.contains('is-cur') && cur.querySelector('.tick'));
  const sc = d.querySelector('.cards-wrap');
  assert.ok(sc.scrollTop > 1000, 'scrollTop ' + sc.scrollTop);
  assert.equal(d.querySelectorAll('.card.is-cur').length, 1);
});

test('cambio categoria: scroll in cima e solo la lista cambia (chip non ricostruiti); stile corrente evidenziato se nella lista', async () => {
  const { w, d } = await loadPage({ setup: scrollable });
  w.gw.onState({ tab: 'theme', look: { style: 's5' }, styles: many(70, (i) => CATS7[i % 7]) }); await sleep(100);
  const chip0 = d.querySelector('.chip[data-id="cl"]');
  d.querySelector('.chip[data-id="all"]').click(); await sleep(10);
  d.querySelector('.cards-wrap').scrollTop = 800; d.querySelector('.cards-wrap').dispatchEvent(new w.Event('scroll'));
  d.querySelector('.chip[data-id="nt"]').click(); await sleep(10);       // s5 e' 'pp' (5%7=5): non e' in 'nt'
  assert.equal(d.querySelector('.cards-wrap').scrollTop, 0);
  assert.equal(d.querySelectorAll('.card.is-cur').length, 0);
  d.querySelector('.chip[data-id="pp"]').click(); await sleep(10);
  assert.equal(d.querySelectorAll('.card.is-cur').length, 1);
  assert.equal(d.querySelector('.chip[data-id="cl"]'), chip0);
});
