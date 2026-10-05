import test from 'node:test';
import assert from 'node:assert/strict';
import { loadPure, loadPage } from './helpers.mjs';
const GW = loadPure();
const O = GW.options, I = GW.icons;

test('ogni opzione, ogni scelta e ogni categoria ha un\'icona definita', () => {
  for (const grp of [O.SCHEMA.look, O.SCHEMA.general]) for (const [k, s] of Object.entries(grp)) {
    assert.ok(s.icon && I.has(s.icon), `opzione ${k}: icona mancante (${s.icon})`);
    for (const c of s.choices || []) assert.ok(c.icon && I.has(c.icon), `scelta ${k}.${c.value}: icona mancante`);
  }
  for (const [cat, ic] of Object.entries(O.CAT_ICONS)) assert.ok(I.has(ic), 'categoria ' + cat);
  for (const need of ['mic', 'keyboard', 'palette', 'sliders', 'gear', 'key', 'info', 'check', 'x', 'plus', 'trash', 'external', 'eye', 'sparkle', 'reset', 'shadow', 'glow',
    'glass', 'micPulse', 'ghost', 'aa', 'clock', 'rowsC', 'rowsN', 'rowsW', 'sine1', 'sine2', 'sine3', 'cornerSq', 'cornerMd', 'cornerRd', 'wvBars', 'wvThin', 'wvDots', 'wvLine'])
    assert.ok(I.has(need), 'icona richiesta: ' + need);
});
test('definizioni valide: solo elementi noti, coordinate finite', () => {
  for (const [n, def] of Object.entries(I.defs)) {
    assert.ok(Array.isArray(def.els) && def.els.length, n);
    for (const e of def.els) {
      assert.ok(['p', 'pf', 'c', 'cf', 'r', 't'].includes(e[0]), n + ' elemento ' + e[0]);
      if (e[0] === 'c' || e[0] === 'cf') assert.ok(e.slice(1, 4).every(Number.isFinite), n);
      if (e[0] === 'p' || e[0] === 'pf') assert.ok(!/NaN|undefined/.test(e[1]), n);
    }
  }
});
test('sine1/2/3: 1, 2, 3 periodi (conteggio dei segmenti c)', () => {
  const cnt = (n) => (I.defs[n].els[0][1].match(/c/g) || []).length;
  assert.deepEqual([cnt('sine1'), cnt('sine2'), cnt('sine3')], [1, 2, 3]);
});
test('righe: compatta 5, normale 4, ampia 3', () => {
  const cnt = (n) => (I.defs[n].els[0][1].match(/M/g) || []).length;
  assert.deepEqual([cnt('rowsC'), cnt('rowsN'), cnt('rowsW')], [5, 4, 3]);
});
test('make() costruisce SVG con tratto 1.5 uniforme (tranne dichiarati) e nel font vero per "Aa"', async () => {
  const { w } = await loadPage();
  const GWw = w.GW;
  const svg = GWw.icons.make('check', 16);
  assert.equal(svg.getAttribute('stroke-width'), '1.5'); assert.equal(svg.getAttribute('aria-hidden'), 'true');
  const aa = GWw.icons.make('aaRounded', 16).querySelector('text');
  assert.match(aa.getAttribute('style'), /ui-rounded/); assert.equal(aa.textContent, 'Aa');
  assert.match(GWw.icons.make('tnMono', 16).querySelector('text').getAttribute('style'), /ui-monospace/);
  const odd = Object.entries(GWw.icons.defs).filter(([, d]) => d.sw && d.sw !== 1.5).map(([n]) => n).sort();
  assert.deepEqual(odd, ['pause', 'wvBars', 'wvThin']);       // eccezioni volute (barre piene/sottili)
});
