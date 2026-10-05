import { createRequire } from 'node:module';
import { after } from 'node:test';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const require = createRequire(import.meta.url);
const doms = [];
after(() => { for (const d of doms) { try { d.window.close(); } catch (e) { /* gia' chiusa */ } } });   // ferma i timer (hb) delle pagine di test
export const UI = join(dirname(fileURLToPath(import.meta.url)), '..');

/* carica i moduli "puri" (senza DOM) in globalThis.GW */
export function loadPure() {
  for (const f of ['util', 'options', 'state', 'theme', 'icons', 'gw-bridge', 'actions']) require(join(UI, 'js', f + '.js'));
  require(join(UI, 'js/components/card-stile.js'));
  require(join(UI, 'js/preview.js'));
  return globalThis.GW;
}
export function walk(dir, ext, out = []) {
  for (const n of readdirSync(dir)) {
    if (n === 'node_modules' || n === 'dist' || n === 'tests') continue;
    const p = join(dir, n);
    if (statSync(p).isDirectory()) walk(p, ext, out); else if (p.endsWith(ext)) out.push(p);
  }
  return out;
}
export const read = (p) => readFileSync(p, 'utf8');
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* pagina costruita (dist) dentro jsdom. real=true simula hs.webview: window.webkit.messageHandlers.gw */
export async function loadPage({ real = true, html } = {}) {
  const { JSDOM, VirtualConsole } = require('jsdom');
  const { build } = await import(join(UI, 'build-inline.mjs'));
  const out = join(process.env.TMPDIR || '/tmp', 'gw-test-settings.html');
  const b = build({ out });
  const sent = [];
  const errors = [];
  const vc = new VirtualConsole();
  vc.on('jsdomError', (e) => { if (!/getContext|Not implemented/i.test(String(e.message))) errors.push(String(e.message)); });
  vc.on('error', (e) => errors.push(String(e)));
  const dom = new JSDOM(html || b.html, {
    runScripts: 'dangerously', pretendToBeVisual: true, url: 'file:///x/settings.html', virtualConsole: vc,
    beforeParse(w) { if (real) w.webkit = { messageHandlers: { gw: { postMessage: (m) => sent.push(JSON.parse(JSON.stringify(m))) } } }; }
  });
  doms.push(dom);
  return { dom, w: dom.window, d: dom.window.document, sent, errors };
}
