import test from 'node:test';
import assert from 'node:assert/strict';
import { loadPure, loadPage, sleep } from './helpers.mjs';
const GW = loadPure();
const T = GW.theme, S = GW.state;

const style = S.normalize({ styles: [{ id: 'gold', name: 'Gold', cat: 'cl',
  dark: { bg1: '#1b1914', bg2: '#0a0907', fg: '#f7f2e6', fg2: '#b8ad94', accent: '#d6af5e', grad: ['#ebcb85', '#b48b3b'] },
  light: { bg1: '#fffcf3', bg2: '#f4e8ce', fg: '#2a2012', fg2: '#6e5d3d', accent: '#b3822a', grad: ['#cb9c3a', '#966a1b'] } }] }).styles[0];

test('contrasto WCAG di riferimento', () => {
  assert.ok(Math.abs(T.contrast('#000000', '#ffffff') - 21) < 0.01);
  assert.ok(T.contrast('#ffffff', '#ffffff') === 1);
});
test('on-accent: scuro su accento chiaro, bianco su accento scuro', () => {
  const dark = T.onAccent({ accent: '#1038e8', grad: ['#0a28b8'], bg2: '#f0f0f0' });
  assert.equal(dark, '#ffffff');
  const lightFill = T.onAccent({ accent: '#f5e626', grad: ['#faf068'], bg2: '#101004' });
  assert.notEqual(lightFill, '#ffffff'); assert.ok(T.lum(lightFill) < 0.1);
});
test('token: tutte le variabili richieste dal mandato', () => {
  const v = T.tokens(style, 'dark', S.initial().look);
  for (const k of ['--bg1', '--bg2', '--fg', '--fg2', '--accent', '--g1', '--g2', '--g3', '--g4', '--glass-alpha', '--font-ui', '--font-timer', '--density'])
    assert.ok(k in v, k);
  assert.equal(v['--accent'], '#d6af5e'); assert.equal(v['--glass-alpha'], '0.95');
});
test('vetro: glassOpacity personalizzato cambia alpha di bg1/bg2', () => {
  const l = { ...S.initial().look, glassOpacity: 0.7 };
  const v = T.tokens(style, 'dark', l);
  assert.match(v['--bg1'], /,0\.7\)$/); assert.match(v['--bg2'], /,0\.72\)$/); assert.equal(v['--glass-alpha'], '0.7');
});
test('angoli: moltiplicatori round 1 / medium .55 / square .16, minimo 1.5px', () => {
  assert.equal(T.radiusPx(12, 'round'), 12); assert.equal(T.radiusPx(12, 'medium'), 6.6); assert.equal(T.radiusPx(12, 'square'), 1.9);
  assert.equal(T.radiusPx(6, 'square'), 1.5);
});
test('font: sf / arrotondato / mono con gli stack richiesti', () => {
  const l = (o) => T.tokens(style, 'dark', { ...S.initial().look, ...o });
  assert.match(l({ uiFont: 'sf' })['--font-ui'], /^-apple-system, system-ui/);
  assert.match(l({ uiFont: 'rounded' })['--font-ui'], /^ui-rounded,/);
  assert.match(l({ uiFont: 'mono' })['--font-ui'], /^ui-monospace,/);
  for (const f of Object.values(T.FONTS)) assert.ok(!/['"]/.test(f), 'solo keyword generiche (nomi come SF Mono non risolvono in WKWebView): ' + f);
  assert.match(l({ timerFont: 'rounded' })['--font-timer'], /ui-rounded/);
});
test('densita\' e opacita\' a riposo', () => {
  const v = T.tokens(style, 'light', { ...S.initial().look, density: 'compact', idleOpacity: 0.6 });
  assert.equal(v['--density'], '0.72'); assert.equal(v['--idle-opacity'], '0.6');
});
test('apply sul DOM: variabili CSS, data-mode, e cambio stile/modo', async () => {
  const { w, d } = await loadPage();
  w.gw.onState({ effectiveMode: 'light', look: { themeMode: 'light', style: 'gold', glassOpacity: 0.8 }, styles: [style] });
  await sleep(20);
  const root = d.documentElement;
  assert.equal(root.dataset.mode, 'light'); assert.equal(root.style.getPropertyValue('--accent'), '#b3822a');
  assert.equal(root.style.getPropertyValue('--glass-alpha'), '0.8');
  w.gw.onState({ effectiveMode: 'dark', look: { themeMode: 'dark', style: 'gold', cornerStyle: 'square' }, styles: [style] });
  await sleep(20);
  assert.equal(root.dataset.mode, 'dark'); assert.equal(root.style.getPropertyValue('--accent'), '#d6af5e'); assert.equal(root.style.getPropertyValue('--r-m'), '1.9px');
});
