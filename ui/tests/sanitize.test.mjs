import test from 'node:test';
import assert from 'node:assert/strict';
import { loadPure, loadPage, sleep, walk, read, UI } from './helpers.mjs';
const GW = loadPure();
const U = GW.util;

test('cleanText: toglie caratteri di controllo, accorcia, mai null', () => {
  assert.equal(U.cleanText('a\u0000b\nc'), 'a b c');
  assert.equal(U.cleanText(null), ''); assert.equal(U.cleanText(42), '42');
  assert.equal(U.cleanText('x'.repeat(500), 20).length, 20);
});
test('cleanHex / cleanUrl', () => {
  assert.equal(U.cleanHex('#ABCDEF', null), '#abcdef'); assert.equal(U.cleanHex('abcdef', null), '#abcdef');
  assert.equal(U.cleanHex('url(x)', 'D'), 'D');
  assert.equal(U.cleanUrl('http://a/b.png'), null); assert.equal(U.cleanUrl('javascript:alert(1)'), null);
  assert.ok(U.cleanUrl('file:///Users/x/a.png')); assert.ok(U.cleanUrl('data:image/png;base64,AAAA'));
});
test('nessun innerHTML / outerHTML / insertAdjacentHTML / document.write / eval nel codice', () => {
  const bad = /(innerHTML|outerHTML|insertAdjacentHTML|document\.write|\beval\s*\(|new Function)/;
  for (const f of walk(UI, '.js')) { const lines = read(f).split('\n'); lines.forEach((l, i) => { const t = l.trim(); if (/^(\/\*|\*|\/\/)/.test(t)) return; assert.ok(!bad.test(l), `${f}:${i + 1}: ${t}`); }); }
});
test('nomi microfono ostili restano testo: nessun <script>/<img> iniettato', async () => {
  const { w, d, sent } = await loadPage();
  w.gw.onState({ general: { micName: 'x', devices: [{ name: '<script>window.__pwn=1</script>' }, { name: '<img src=x onerror="window.__pwn=2">', bt: true }, { name: 'ok' }] } });
  await sleep(30);
  const rows = [...d.querySelectorAll('.mic')];
  assert.equal(rows.length, 3);
  assert.equal(rows[0].querySelector('.nm').textContent, '<script>window.__pwn=1</script>');
  assert.equal(d.querySelectorAll('#app script').length, 0);
  assert.equal(d.querySelectorAll('#app img[src="x"]').length, 0);
  assert.equal(w.__pwn, undefined);
  assert.ok(sent.length >= 1);
});
test('la chiave Groq non transita dal JS: nessun riferimento a api_key/readKey, key_paste senza payload', async () => {
  for (const f of walk(UI, '.js')) assert.ok(!/api_key|readKey|gsk_[A-Za-z0-9]{8}/.test(read(f)), f);
  const { w, d, sent } = await loadPage();
  w.gw.onState({ groq: { has: false, mask: '' } }); await sleep(20);
  [...d.querySelectorAll('.btn.primary')].find((b) => /Incolla/.test(b.textContent)).click();
  const m = sent.filter((x) => x.op === 'key_paste');
  assert.equal(m.length, 1); assert.deepEqual(m[0], { op: 'key_paste' });
});
