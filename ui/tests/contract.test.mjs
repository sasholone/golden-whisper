import test from 'node:test';
import assert from 'node:assert/strict';
import { loadPure, loadPage, sleep, walk, read, UI } from './helpers.mjs';
const GW = loadPure();
const O = GW.options;

/* contratto del ponte, copiato alla lettera dal mandato */
const CONTRACT_OPS = ['ready', 'set', 'random_look', 'reset_look', 'pick_mic', 'refresh_devices', 'key_paste', 'key_remove', 'open_groq', 'capture_start', 'capture_cancel',
  'key_remove_binding', 'key_set_gesture', 'set_tab', 'close', 'drag_start', 'resize_request', 'interact', 'hb'];
const CONTRACT_SET_KEYS = ['style', 'themeMode', 'glassOpacity', 'cornerStyle', 'animOn', 'animSpeed', 'waveStyle', 'waveColor', 'micPulse', 'glowOn', 'uiFont', 'timerFont',
  'density', 'idleOpacity', 'shadowOn', 'shadowIntensity', 'sizePreset', 'orientation'];

test('OPS = contratto', () => assert.deepEqual([...O.OPS].sort(), [...CONTRACT_OPS].sort()));
test('chiavi di set = contratto (look + general)', () => assert.deepEqual([...O.LOOK_KEYS, ...O.GENERAL_KEYS].sort(), [...CONTRACT_SET_KEYS].sort()));
test('ogni {op:"..."} scritto nel codice e\' nel contratto', () => {
  const found = new Set();
  for (const f of walk(UI, '.js')) for (const m of read(f).matchAll(/op:\s*'([a-z_]+)'/g)) found.add(m[1]);
  for (const op of found) assert.ok(CONTRACT_OPS.includes(op), 'op fuori contratto: ' + op);
  for (const op of CONTRACT_OPS) assert.ok(found.has(op), 'op mai usata: ' + op);
});
test('il ponte scarta op sconosciute e non serializzabili', () => {
  const b = GW.bridge;
  assert.equal(b.post({ op: 'format_disk' }), false);
  assert.equal(b.post({ op: 'close' }), true);
  const cyc = { op: 'set' }; cyc.self = cyc;
  assert.equal(b.post(cyc), false);
});

test('azioni -> messaggi esatti (host reale simulato)', async () => {
  const { w, d, sent } = await loadPage();
  w.gw.onState({ keys: { ss: [{ label: 'F5', gesture: 'double' }], pause: [{ label: 'F6', gesture: 'single' }] }, groq: { has: true, mask: 'gsk_…abcd' },
    general: { micName: 'A', devices: [{ name: 'A' }, { name: 'B' }] } });
  await sleep(30);
  assert.equal(sent[0].op, 'ready');
  const last = () => sent[sent.length - 1];
  d.querySelector('.mic[data-name="B"]').click(); assert.deepEqual(last(), { op: 'pick_mic', name: 'B' });
  d.querySelector('.seg-b[data-value="large"]').click(); assert.deepEqual(last(), { op: 'set', key: 'sizePreset', value: 'large' });
  d.querySelector('.seg-b[data-value="vertical"]').click(); assert.deepEqual(last(), { op: 'set', key: 'orientation', value: 'vertical' });
  d.querySelector('.btn-ic.sec-tools').click(); assert.deepEqual(last(), { op: 'refresh_devices' });
  /* tasti */
  d.querySelector('.tabbar .seg-b[data-value="keys"]').click(); assert.deepEqual(last(), { op: 'set_tab', tab: 'keys' });
  const hold = d.querySelectorAll('.bind')[0].querySelector('.seg-b[data-value="hold"]'); hold.click();
  assert.deepEqual(last(), { op: 'key_set_gesture', action: 'ss', index: 0, gesture: 'hold' });
  d.querySelectorAll('.bind')[1].querySelector('.btn-ic').click();
  assert.deepEqual(last(), { op: 'key_remove_binding', action: 'pause', index: 0 });
  const adds = d.querySelectorAll('.add-key'); adds[0].click(); assert.deepEqual(last(), { op: 'capture_start', action: 'ss' });
  adds[0].click(); assert.deepEqual(last(), { op: 'capture_cancel' });
  /* tema */
  d.querySelector('.tabbar .seg-b[data-value="theme"]').click(); assert.deepEqual(last(), { op: 'set_tab', tab: 'theme' });
  d.querySelector('.card[data-id]').click(); assert.equal(last().op, 'set'); assert.equal(last().key, 'style');
  d.querySelector('.csec .seg-b[data-value="light"]').click(); assert.deepEqual(last(), { op: 'set', key: 'themeMode', value: 'light' });
  d.querySelector('.csec .seg-b[data-value="thin"]').click(); assert.deepEqual(last(), { op: 'set', key: 'waveStyle', value: 'thin' });
  d.querySelector('.csec .seg-b[data-value="square"]').click(); assert.deepEqual(last(), { op: 'set', key: 'cornerStyle', value: 'square' });
  d.querySelector('.csec .seg-b[data-value="lively"]').click(); assert.deepEqual(last(), { op: 'set', key: 'animSpeed', value: 'lively' });
  d.querySelector('.csec .seg-b[data-value="rounded"]').click(); assert.equal(last().key === 'uiFont' || last().key === 'timerFont', true);
  d.querySelector('.csec .seg-b[data-value="wide"]').click(); assert.deepEqual(last(), { op: 'set', key: 'density', value: 'wide' });
  const sw = [...d.querySelectorAll('.pane-theme .sw')];
  sw[0].click(); assert.deepEqual(last(), { op: 'set', key: 'shadowOn', value: false });
  sw[1].click(); assert.deepEqual(last(), { op: 'set', key: 'glowOn', value: true });
  sw[2].click(); assert.deepEqual(last(), { op: 'set', key: 'animOn', value: false });
  [...d.querySelectorAll('.actions .btn')][0].click(); assert.deepEqual(last(), { op: 'random_look' });
  /* reset: doppio tocco */
  const n0 = sent.length; const rst = d.querySelectorAll('.actions .btn')[1];
  rst.click(); assert.equal(sent.length, n0); rst.click(); assert.deepEqual(last(), { op: 'reset_look' });
  /* drag / close / resize */
  d.querySelector('.hdr').dispatchEvent(new w.MouseEvent('mousedown', { bubbles: true, button: 0 })); assert.deepEqual(last(), { op: 'drag_start', sx: 0, sy: 0 });
  const n1 = sent.length; d.querySelector('.hdr-x').dispatchEvent(new w.MouseEvent('mousedown', { bubbles: true, button: 0 })); assert.equal(sent.length, n1);
  d.querySelector('.hdr-x').click(); assert.deepEqual(last(), { op: 'close' });
  await sleep(150);
  const rz = sent.filter((m) => m.op === 'resize_request'); assert.ok(rz.length >= 1); assert.ok(rz.every((m) => m.w === 432 || m.w === 800));
});

test('slider: set throttolato (<= 1 / 80 ms) con ultimo valore garantito', async () => {
  const { w, d, sent } = await loadPage();
  await sleep(20); d.querySelector('.tabbar .seg-b[data-value="theme"]').click();
  const input = d.querySelectorAll('.pane-theme .rng')[1];                    // intensita' pulsazione? (primo=ombra, secondo=vetro)
  const before = sent.length;
  for (let i = 0; i < 20; i++) { input.value = String(0.5 + i * 0.02); input.dispatchEvent(new w.Event('input', { bubbles: true })); }
  input.dispatchEvent(new w.Event('change', { bubbles: true }));
  const sets = sent.slice(before).filter((m) => m.op === 'set');
  assert.ok(sets.length >= 1 && sets.length <= 3, 'messaggi: ' + sets.length);
  assert.equal(sets[sets.length - 1].key, 'glassOpacity'); assert.ok(Math.abs(sets[sets.length - 1].value - 0.88) < 1e-9);
});

test('key_remove: doppio tocco (primo arma, secondo invia); key_status aggiorna la maschera', async () => {
  const { w, d, sent } = await loadPage();
  w.gw.onState({ groq: { has: true, mask: 'gsk_…wxyz' } }); await sleep(20);
  assert.match(d.querySelector('.key-head .mask').textContent, /wxyz/);
  const rm = [...d.querySelectorAll('.key-body .btn.danger')][0];
  rm.click(); assert.equal(sent.filter((m) => m.op === 'key_remove').length, 0); assert.match(rm.textContent, /Sicuro/);
  rm.click(); assert.equal(sent.filter((m) => m.op === 'key_remove').length, 1);
  w.gw.onEvent('key_status', { has: false, mask: '', msg: 'Chiave rimossa', kind: 'ok' }); await sleep(10);
  assert.equal(d.querySelector('.sec-wrap:not([hidden]) .key-l1').textContent, 'Nessuna chiave');
});
test('eventi: devices, capture_result, toast', async () => {
  const { w, d } = await loadPage();
  w.gw.onEvent('devices', [{ name: 'Z1' }, { name: 'Z2', bt: true }]); await sleep(10);
  assert.equal(d.querySelectorAll('.mic').length, 2); assert.ok(d.querySelector('.mic .bt'));
  w.gw.onEvent('toast', { text: 'ciao' }); await sleep(10);
  assert.equal(d.querySelector('.toast').textContent, 'ciao'); assert.ok(d.querySelector('.toast').classList.contains('is-on'));
});

test('interact: UNA volta al primo pointerdown; hb: ogni ~1000 ms; Esc con cattura attiva -> capture_cancel', async () => {
  const { w, d, sent } = await loadPage();
  await sleep(30);
  assert.equal(sent.filter((m) => m.op === 'hb').length, 1);
  assert.equal(sent.filter((m) => m.op === 'interact').length, 0);
  d.querySelector('.seg-b').dispatchEvent(new w.Event('pointerdown', { bubbles: true }));
  d.querySelector('.mic, .btn').dispatchEvent(new w.Event('pointerdown', { bubbles: true }));
  assert.equal(sent.filter((m) => m.op === 'interact').length, 1);
  await sleep(1100);
  assert.ok(sent.filter((m) => m.op === 'hb').length >= 2);
  /* Esc senza cattura: nessun messaggio (la chiusura la gestisce l'host) */
  const n = sent.length; d.dispatchEvent(new w.KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); assert.equal(sent.length, n);
  d.querySelector('.tabbar .seg-b[data-value="keys"]').click();
  d.querySelector('.add-key').click(); assert.equal(sent[sent.length - 1].op, 'capture_start');
  d.dispatchEvent(new w.KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); assert.deepEqual(sent[sent.length - 1], { op: 'capture_cancel' });
});
