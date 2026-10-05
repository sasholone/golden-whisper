import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { UI, walk, read } from './helpers.mjs';
const { build, BUDGET_BYTES, STRICT_CSP } = await import(join(UI, 'build-inline.mjs'));

const tmp = mkdtempSync(join(tmpdir(), 'gwb-'));
const out = join(tmp, 'settings.html');
const res = build({ out });
const html = readFileSync(out, 'utf8');

test('build-inline: UN solo file, dimensione <= budget', () => {
  assert.equal(res.out, out); assert.ok(res.bytes > 20000);
  assert.ok(res.bytes <= BUDGET_BYTES, `${res.bytes} > ${BUDGET_BYTES}`);
  console.log(`   dimensione build: ${res.bytes} byte (${(res.bytes / 1024).toFixed(1)} KB)`);
  assert.ok((html.match(/<script>/g) || []).length >= 20);
  assert.equal((html.match(/<style>/g) || []).length, 1);
});
test('build: nessun riferimento esterno (http/https, url(), @import, link/script src, import)', () => {
  assert.ok(!/<link\b/i.test(html), 'link');
  assert.ok(!/<script[^>]*\bsrc=/i.test(html), 'script src');
  assert.ok(!/@import/.test(html), '@import');
  assert.ok(!/\burl\(/.test(html), 'url()');
  const urls = [...html.matchAll(/https?:\/\/[^\s"'<>)]+/g)].map((m) => m[0]).filter((u) => u !== 'http://www.w3.org/2000/svg');
  assert.deepEqual(urls, [], 'URL esterni: ' + urls.join(', '));
  assert.ok(!/\b(fetch|XMLHttpRequest|WebSocket|EventSource|sendBeacon|importScripts)\b/.test(html), 'API di rete');
  assert.ok(!/\bimport\s*\(|\bimport\s+[\w{*]/.test(html.replace(/\/\*[\s\S]*?\*\//g, '')), 'import');
});
test('build: CSP stretta presente e UNICA', () => {
  const metas = html.match(/<meta http-equiv="Content-Security-Policy"[^>]*>/g) || [];
  assert.equal(metas.length, 1); assert.ok(metas[0].includes(`content="${STRICT_CSP}"`));
  assert.ok(STRICT_CSP.startsWith("default-src 'none'")); assert.ok(STRICT_CSP.endsWith('font-src data:')); assert.ok(!/connect-src|script-src[^;]*https?:/.test(STRICT_CSP));
});
test('build: il file dist/settings.html del repo e\' aggiornato (stesso contenuto del build)', () => {
  const dist = join(UI, 'dist', 'settings.html');
  assert.equal(readFileSync(dist, 'utf8'), html, 'esegui: node ui/build-inline.mjs');
});

/* ---- budget di performance: scansione dei CSS ---- */
const css = walk(join(UI, 'css'), '.css').map((f) => [f, read(f).replace(/\/\*[\s\S]*?\*\//g, '')]);
function splitTop(s) { const out = []; let d = 0, cur = ''; for (const ch of s) { if (ch === '(') d++; if (ch === ')') d--; if (ch === ',' && d === 0) { out.push(cur); cur = ''; } else cur += ch; } out.push(cur); return out.map((x) => x.trim()).filter(Boolean); }
const OK = new Set(['transform', 'opacity']);

test('perf: transition anima SOLO transform/opacity', () => {
  let n = 0;
  for (const [f, c] of css) for (const m of c.matchAll(/(?:^|[;{\s])transition(-property)?\s*:\s*([^;}]+)/g)) {
    for (const part of splitTop(m[2])) { const prop = m[1] ? part : part.split(/\s+/)[0]; n++; assert.ok(OK.has(prop) || prop === 'none', `${f}: transition su "${prop}"`); }
  }
  assert.ok(n > 10);
});
test('perf: animation = solo @keyframes con transform/opacity, mai infinite', () => {
  const all = css.map(([, c]) => c).join('\n');
  assert.ok(!/infinite/.test(all), 'animation infinita');
  for (const m of all.matchAll(/@keyframes\s+[\w-]+\s*\{((?:[^{}]*\{[^{}]*\})+)\s*\}/g))
    for (const d of m[1].matchAll(/([\w-]+)\s*:/g)) assert.ok(OK.has(d[1]), 'keyframes anima ' + d[1]);
});
test('perf: will-change solo transform/opacity', () => {
  for (const [f, c] of css) for (const m of c.matchAll(/will-change\s*:\s*([^;}]+)/g)) assert.ok(m[1].split(',').every((p) => OK.has(p.trim()) || p.trim() === 'auto'), f + ': ' + m[1]);
});
test('perf: UN solo pannello con backdrop-filter (il pannello radice)', () => {
  const sels = new Set();
  for (const [, c] of css) for (const m of c.matchAll(/([^{}]+)\{([^{}]*backdrop-filter[^{}]*)\}/g)) sels.add(m[1].trim());
  assert.deepEqual([...sels], ['.panel']);
});
test('perf: niente filter/blur/box-shadow animati; scrollbar sottile; reduced-motion; content-visibility', () => {
  const all = css.map(([, c]) => c).join('\n');
  assert.ok(/::-webkit-scrollbar/.test(all)); assert.ok(/-webkit-overflow-scrolling:\s*touch/.test(all));
  assert.ok(/@media \(prefers-reduced-motion: reduce\)/.test(all)); assert.ok(/content-visibility:\s*auto/.test(all));
  assert.ok(!/-app-region/.test(all), 'niente -webkit-app-region');
});
test('perf: JS senza setInterval/.animate(); rAF solo in preview e fold', () => {
  for (const f of walk(UI, '.js')) {
    const c = read(f).replace(/\/\*[\s\S]*?\*\//g, '');
    assert.ok(!/setInterval|\.animate\(/.test(c), f);
    if (/requestAnimationFrame/.test(c)) assert.ok(/preview\.js$|tabs\/general\.js$/.test(f), 'rAF in ' + f);
  }
});
test('privacy: nessun font web, niente rete nel sorgente', () => {
  for (const f of [...walk(UI, '.js'), ...walk(UI, '.css'), join(UI, 'index.html')]) {
    const c = read(f);
    assert.ok(!/@font-face|fonts\.googleapis|cdn\.|unpkg|jsdelivr|googletagmanager|analytics/i.test(c), f);
  }
});
