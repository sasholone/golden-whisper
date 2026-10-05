import test from 'node:test';
import assert from 'node:assert/strict';
import { loadPure } from './helpers.mjs';
const GW = loadPure();
const P = GW.preview, W = GW.ui && GW.ui.wavePoints;

test('levels: n valori in 0..1, posa statica deterministica, piu\' lenta con speed>1', () => {
  const a = P.levels(24, null, 1), b = P.levels(24, null, 1);
  assert.equal(a.length, 24); assert.deepEqual(a, b); assert.ok(a.every((v) => v >= 0 && v <= 1));
  const t1 = P.levels(24, 3.3, 1), t2 = P.levels(24, 3.3, 1.7);
  assert.notDeepEqual(t1, t2); assert.ok(t1.every((v) => v >= 0 && v <= 1));
});
test('barCount per stile onda', () => {
  assert.ok(P.barCount('thin', 100) > P.barCount('bars', 100)); assert.ok(P.barCount('bars', 100) > P.barCount('dots', 100));
});
test('waveGradientOn: accent/gradient espliciti, auto = stile multicolore', () => {
  const multi = { dark: { grad: ['#1', '#2', '#3'] }, light: { grad: ['#1', '#2', '#3'] } }, two = { dark: { grad: ['#1', '#2'] }, light: { grad: ['#1', '#2'] } };
  assert.equal(P.waveGradientOn({ waveColor: 'gradient' }, two, 'dark'), true);
  assert.equal(P.waveGradientOn({ waveColor: 'accent' }, multi, 'dark'), false);
  assert.equal(P.waveGradientOn({ waveColor: 'auto' }, multi, 'dark'), true); assert.equal(P.waveGradientOn({ waveColor: 'auto' }, two, 'light'), false);
});
test('fmtTime e ombra HUD', () => {
  assert.equal(P.fmtTime(7), '00:07'); assert.equal(P.fmtTime(125.9), '02:05');
  assert.equal(P.hudShadow({ shadowOn: false, glowOn: false, shadowIntensity: 0.5 }, '#fff', GW.theme.rgba), 'none');
  assert.match(P.hudShadow({ shadowOn: true, glowOn: true, shadowIntensity: 1 }, '#ffffff', GW.theme.rgba), /rgba\(0,0,0,0\.58\).*rgba\(255,255,255,0\.42\)/);
});
test('mini onda carta: 13 punti; quadrata alterna, a blocchi quantizzata', () => {
  const r = W('round', 74, 42), sq = W('square', 74, 42), px = W('pixel', 74, 42);
  assert.equal(r.length, 13);
  assert.ok(sq.every((p, i) => i % 2 === 0 ? p[1] >= 21 : p[1] <= 21));
  const steps = new Set(px.map((p) => Math.round((p[1] - 21) / 11 * 3))); assert.ok([...steps].every((v) => Number.isInteger(v)));
});
