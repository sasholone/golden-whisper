import test from 'node:test';
import assert from 'node:assert/strict';
import { loadPure } from './helpers.mjs';
const GW = loadPure();
const { state: S, options: O } = GW;

test('stato iniziale: default = LOOK_DEFAULTS di Lua', () => {
  const s = S.initial();
  assert.deepEqual(s.look, { style: 'gold', themeMode: 'dark', shadowOn: true, shadowIntensity: 0.5, glassOpacity: 0, cornerStyle: 'round', animOn: true,
    animSpeed: 'normal', waveStyle: 'bars', waveColor: 'auto', micPulse: 0.5, glowOn: false, uiFont: 'sf', timerFont: 'mono', density: 'normal', idleOpacity: 1 });
  assert.equal(s.general.sizePreset, 'standard'); assert.equal(s.general.orientation, 'horizontal');
});

test('normalize: valori invalidi -> default, campi mancanti -> default sensati', () => {
  const s = S.normalize({ look: { themeMode: 'rosa', glassOpacity: 0.2, shadowIntensity: 7, micPulse: 'x', idleOpacity: 0.1, cornerStyle: 'boh', waveStyle: 'zig' }, general: { sizePreset: 'enorme' }, tab: 'nope' });
  assert.equal(s.look.themeMode, 'dark'); assert.equal(s.look.glassOpacity, 0.5); assert.equal(s.look.shadowIntensity, 1);
  assert.equal(s.look.micPulse, 0.5); assert.equal(s.look.idleOpacity, 0.3); assert.equal(s.look.cornerStyle, 'round'); assert.equal(s.look.waveStyle, 'bars');
  assert.equal(s.general.sizePreset, 'standard'); assert.equal(s.tab, 'general');
  assert.ok(s.styles.length >= 1 && s.cats.length >= 1);
  assert.equal(S.normalize(null).tab, 'general');
});
test('glassOpacity: 0 = default del tema, altrimenti 0.5..1', () => {
  assert.equal(O.clean('glassOpacity', 0), 0); assert.equal(O.clean('glassOpacity', -3), 0);
  assert.equal(O.clean('glassOpacity', 0.7), 0.7); assert.equal(O.clean('glassOpacity', 5), 1);
});
test('normalize: colori, id e url asset sanificati', () => {
  const s = S.normalize({ styles: [{ id: 'ok1', name: 'A', cat: 'cl', dark: { accent: 'red; background:url(//evil)', grad: ['#112233', 'zzz'] } }, { id: '../x' }, null],
    assets: { ok1: { icon: 'https://evil/x.png', spin: 'file:///tmp/a.gif' }, 'bad id': { icon: 'file:///a.png' } } });
  assert.equal(s.styles.length, 1);
  assert.match(s.styles[0].dark.accent, /^#[0-9a-f]{6}$/);
  assert.deepEqual(s.styles[0].dark.grad, ['#112233']  .concat([]).length === 1 ? ['#112233', '#112233'] : []);
  assert.deepEqual(s.assets, { ok1: { spin: 'file:///tmp/a.gif' } });
});
test('reducer set: ottimistico, puro, instrada look/general', () => {
  const a = S.initial();
  const b = S.reduce(a, { type: 'set', key: 'cornerStyle', value: 'square' });
  assert.equal(a.look.cornerStyle, 'round'); assert.equal(b.look.cornerStyle, 'square');
  const c = S.reduce(b, { type: 'set', key: 'orientation', value: 'vertical' });
  assert.equal(c.general.orientation, 'vertical');
  assert.equal(S.reduce(c, { type: 'set', key: 'boh', value: 1 }), c);                 // chiave sconosciuta: ignorata
  assert.equal(S.reduce(c, { type: 'set', key: 'waveStyle', value: 'zig' }).look.waveStyle, 'bars');
});
test('reducer: themeMode aggiorna effectiveMode (auto lo lascia)', () => {
  let s = S.initial();
  s = S.reduce(s, { type: 'set', key: 'themeMode', value: 'light' }); assert.equal(s.effectiveMode, 'light');
  s = S.reduce(s, { type: 'set', key: 'themeMode', value: 'auto' }); assert.equal(s.effectiveMode, 'light');
});
test('replace da Lua sostituisce ma conserva ui', () => {
  let s = S.initial();
  s = S.reduce(s, { type: 'ui', patch: { cat: 'fk', capture: 'ss' } });
  s = S.reduce(s, { type: 'replace', state: { cats: [{ id: 'all', name: 'Tutti' }, { id: 'fk', name: 'Funky' }], look: { style: 'neon' } } });
  assert.equal(s.look.style, 'neon'); assert.equal(s.ui.cat, 'fk'); assert.equal(s.ui.capture, 'ss');
  s = S.reduce(s, { type: 'replace', state: { cats: [{ id: 'all', name: 'Tutti' }] } });
  assert.equal(s.ui.cat, 'all');                                                       // categoria sparita -> Tutti
});
test('reset_look: ripristina i default del look, non tocca general', () => {
  let s = S.reduce(S.initial(), { type: 'set', key: 'sizePreset', value: 'large' });
  s = S.reduce(s, { type: 'set', key: 'style', value: 'neon' });
  s = S.reduce(s, { type: 'reset_look' });
  assert.equal(s.look.style, 'gold'); assert.equal(s.general.sizePreset, 'large');
});
test('tasti: rimuovi / gesto ottimistici', () => {
  let s = S.normalize({ keys: { ss: [{ label: 'F5', gesture: 'double' }, { label: 'F6', gesture: 'hold' }], pause: [{ label: 'F7', gesture: 'single' }] } });
  s = S.reduce(s, { type: 'remove_binding', action: 'ss', index: 0 });
  assert.deepEqual(s.keys.ss, [{ label: 'F6', gesture: 'hold' }]);
  s = S.reduce(s, { type: 'set_gesture', action: 'pause', index: 0, gesture: 'double' });
  assert.equal(s.keys.pause[0].gesture, 'double');
  assert.equal(S.reduce(s, { type: 'set_gesture', action: 'pause', index: 0, gesture: 'volo' }), s);
});
test('eventi: key_status, devices, capture_result, toast', () => {
  let s = S.initial();
  s = S.reduce(s, { type: 'event', name: 'key_status', payload: { has: true, mask: 'gsk_…abcd', msg: 'ok!', kind: 'ok' } });
  assert.equal(s.groq.has, true); assert.equal(s.groq.mask, 'gsk_…abcd'); assert.deepEqual(s.ui.msg, { text: 'ok!', kind: 'ok' });
  s = S.reduce(s, { type: 'event', name: 'devices', payload: [{ name: 'A', bt: true }, 'B', { name: '' }] });
  assert.deepEqual(s.general.devices, [{ name: 'A', bt: true }, { name: 'B', bt: false }]);
  s = S.reduce(s, { type: 'ui', patch: { capture: 'ss' } });
  s = S.reduce(s, { type: 'event', name: 'capture_result', payload: { ok: true, label: 'F13', action: 'ss' } });
  assert.equal(s.ui.capture, null);
  s = S.reduce(s, { type: 'event', name: 'toast', payload: { text: 'ciao' } });
  assert.equal(s.ui.toast.text, 'ciao');
});
test('store: notifica solo se lo stato cambia', () => {
  const st = S.createStore(); let n = 0; st.subscribe(() => n++);
  st.dispatch({ type: 'set', key: 'boh', value: 1 }); assert.equal(n, 0);
  st.dispatch({ type: 'set', key: 'density', value: 'wide' }); assert.equal(n, 1);
});
