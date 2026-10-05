import test from 'node:test';
import assert from 'node:assert/strict';
import { loadPage, sleep } from './helpers.mjs';

test('mock (browser normale): 70 stili generati, carte a finestra (mai tutte nel DOM), 0 errori', async () => {
  const { w, d, errors } = await loadPage({ real: false });
  await sleep(250);
  const st = w.GW.app.store.get();
  assert.equal(st.styles.length, 70);
  d.querySelector('.tabbar .seg-b[data-value="theme"]').click(); await sleep(60);
  const grid = d.querySelector('.cards');
  assert.equal(Number(grid.dataset.count), st.styles.filter((x) => x.cat === st.ui.cat).length);
  assert.ok(d.querySelectorAll('.card').length >= 1 && d.querySelectorAll('.card').length <= Number(grid.dataset.count));
  d.querySelector('.chip[data-id="all"]').click(); await sleep(20);
  assert.equal(Number(grid.dataset.count), 70);
  assert.ok(d.querySelectorAll('.card').length < 70 && d.querySelectorAll('.card').length >= 6, 'carte nel DOM: ' + d.querySelectorAll('.card').length);
  assert.ok(d.documentElement.classList.contains('mock'));
  assert.ok(st.general.devices.length >= 12 - 1);
  assert.equal(w.__gwErrors.length, 0, [...w.__gwErrors].join(';')); assert.equal(errors.length, 0, errors.join(';'));
});
test('categorie: conteggi e filtro (Tutti = 70, somma categorie = 70), cambio categoria = ricostruzione della sola lista', async () => {
  const { w, d } = await loadPage({ real: false });
  await sleep(250);
  d.querySelector('.tabbar .seg-b[data-value="theme"]').click(); await sleep(60);
  const chips = [...d.querySelectorAll('.chip')];
  assert.equal(chips.map((c) => c.dataset.id).join(','), 'all,cl,fk,nt,ne,rt,pp,st');
  const counts = Object.fromEntries(chips.map((c) => [c.dataset.id, Number(c.querySelector('.ct').textContent)]));
  assert.equal(counts.all, 70); assert.equal(Object.entries(counts).filter(([k]) => k !== 'all').reduce((a, [, v]) => a + v, 0), 70);
  const grid = d.querySelector('.cards');
  const chipsEl = d.querySelector('.cats'); const firstChip = chipsEl.firstChild;
  chips.find((c) => c.dataset.id === 'fk').click(); await sleep(10);
  assert.equal(Number(grid.dataset.count), counts.fk);
  assert.ok([...d.querySelectorAll('.card')].every((c) => w.GW.app.store.get().styles.find((x) => x.id === c.dataset.id).cat === 'fk'), 'solo carte della categoria');
  assert.ok(d.querySelector('.chip.is-sel').dataset.id === 'fk');
  assert.equal(chipsEl.firstChild, firstChip, 'le categorie non vengono ricostruite');
  chips[0].click(); await sleep(10);
  assert.equal(Number(grid.dataset.count), 70);
});
test('carta: stile attuale evidenziato (una sola, con spunta), click cambia lo stile (ottimistico) e il tema', async () => {
  const { w, d } = await loadPage({ real: false });
  await sleep(250);
  d.querySelector('.tabbar .seg-b[data-value="theme"]').click(); await sleep(60);
  d.querySelector('.chip[data-id="ne"]').click(); await sleep(20);
  assert.ok(d.querySelectorAll('.card.is-cur').length <= 1);
  const neon = d.querySelector('.card[data-id="neon"]'); assert.ok(neon, 'neon nella categoria Neon'); neon.click(); await sleep(10);
  assert.ok(neon.classList.contains('is-cur')); assert.equal(d.querySelectorAll('.card.is-cur').length, 1);
  assert.equal(d.querySelectorAll('.card .tick').length, 1, 'la spunta esiste solo sulla carta corrente');
  assert.equal(d.documentElement.style.getPropertyValue('--accent'), '#00f0ff');
  assert.match(d.querySelector('.hero-n').textContent, /Neon/);
});
test('assets locali: l\'icona del tema (file:) appare nella carta, http no', async () => {
  const { w, d } = await loadPage();
  w.gw.onState({ tab: 'theme', styles: [{ id: 'a', name: 'A', cat: 'cl' }, { id: 'b', name: 'B', cat: 'cl' }], look: { style: 'a' },
    assets: { a: { icon: 'file:///Users/x/.config/groq-dictation/themes/a/icon.png' }, b: { icon: 'https://evil.example/x.png' } } });
  await sleep(20);
  assert.equal(d.querySelectorAll('.card .sw-g img').length, 1);
  assert.match(d.querySelector('.hud-badge img').getAttribute('src'), /^file:\/\//);
});
test('tab: cross-fade (classi), un solo pannello attivo, data-tab sul pannello', async () => {
  const { w, d } = await loadPage();
  w.gw.onState({ tab: 'general' }); await sleep(20);
  const active = () => [...d.querySelectorAll('.pane.is-active')].map((p) => p.dataset.tab);
  assert.deepEqual(active(), ['general']);
  d.querySelector('.tabbar .seg-b[data-value="theme"]').click(); await sleep(10);
  assert.deepEqual(active(), ['theme']); assert.equal(d.getElementById('app').dataset.tab, 'theme');
  assert.equal(d.querySelector('.tabbar .seg').style.getPropertyValue('--i'), '2');
  await sleep(320);
  assert.equal(d.querySelectorAll('.pane.is-shown').length, 1);
  w.gw.onState({ tab: 'keys' }); await sleep(10);
  assert.deepEqual(active(), ['keys']);
});
test('anteprima: il loop rAF parte solo con hover + tab Tema + animazioni attive, e si ferma', async () => {
  const { w, d } = await loadPage();
  w.gw.onState({ tab: 'general' }); await sleep(20);
  assert.equal(d.querySelector('.pv'), null, 'tab Tema non costruito finche\' non si apre');
  d.querySelector('.tabbar .seg-b[data-value="theme"]').click(); await sleep(10);
  const pv = d.querySelector('.pv');
  pv.dispatchEvent(new w.Event('pointerenter')); assert.equal(pv.dataset.running, '1');
  pv.dispatchEvent(new w.Event('pointerleave')); assert.equal(pv.dataset.running, '0');
  pv.dispatchEvent(new w.Event('pointerenter')); assert.equal(pv.dataset.running, '1');
  d.querySelector('.tabbar .seg-b[data-value="keys"]').click(); await sleep(10);
  assert.equal(pv.dataset.running, '0', 'cambio tab: ferma');
  d.querySelector('.tabbar .seg-b[data-value="theme"]').click(); await sleep(10);
  w.gw.onState({ tab: 'theme', look: { animOn: false } }); await sleep(10);
  pv.dispatchEvent(new w.Event('pointerenter')); assert.equal(pv.dataset.running, '0', 'animazioni off: ferma');
});
test('opzioni: lo stato di Lua si riflette nei controlli (segmented, switch, slider)', async () => {
  const { w, d } = await loadPage();
  w.gw.onState({ tab: 'theme', look: { themeMode: 'light', shadowOn: false, glowOn: true, waveStyle: 'dots', cornerStyle: 'medium', density: 'wide', animOn: false, glassOpacity: 0.7, idleOpacity: 0.5 } });
  await sleep(20);
  const sel = (grp) => [...d.querySelectorAll('.pane-theme .seg')].map((s) => s.querySelector('.is-sel')?.dataset.value);
  const vals = sel();
  assert.ok(vals.includes('light') && vals.includes('dots') && vals.includes('medium') && vals.includes('wide'));
  const sws = [...d.querySelectorAll('.pane-theme .sw')].map((x) => x.getAttribute('aria-checked'));
  assert.deepEqual(sws, ['false', 'true', 'false']);
  assert.ok(d.querySelector('.pane-theme .sw').closest('.row').textContent.includes('Ombra disattivata'));
  const rngs = [...d.querySelectorAll('.pane-theme .rng')].map((r) => r.value);
  assert.ok(rngs.includes('0.7') && rngs.includes('0.5'));
});
