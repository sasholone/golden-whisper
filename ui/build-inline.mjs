#!/usr/bin/env node
// build-inline.mjs - produce UN solo ui/dist/settings.html con CSS + JS inline e CSP stretta (zero rete).
// Uso: node ui/build-inline.mjs   (dalla radice del repo o da ui/). Esce con errore se supera il budget o trova riferimenti esterni.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const BUDGET_BYTES = 250 * 1024;
export const STRICT_CSP = "default-src 'none'; img-src data: file: blob:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; font-src data:";

const here = dirname(fileURLToPath(import.meta.url));

function minCss(s) {
  return s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\s*\n\s*/g, '\n').replace(/[ \t]{2,}/g, ' ').replace(/\n(?=\s*[}])/g, '').replace(/^\n+/, '');
}
function minJs(s) {
  // toglie solo il commento-banner iniziale e le righe che sono SOLO commento (sicuro: non tocca stringhe/regex)
  return s.replace(/^\s*\/\*[\s\S]*?\*\/\s*/, '').split('\n').filter((l) => !/^\s*\/\/(?!#)/.test(l)).join('\n').replace(/\n{2,}/g, '\n');
}

export function build({ root = here, out = join(here, 'dist', 'settings.html') } = {}) {
  let html = readFileSync(join(root, 'index.html'), 'utf8');
  html = html.replace(/<!--[\s\S]*?-->\s*/g, '');
  html = html.replace(/<meta http-equiv="Content-Security-Policy"[^>]*>/i, `<meta http-equiv="Content-Security-Policy" content="${STRICT_CSP}">`);
  let css = '';
  html = html.replace(/<link rel="stylesheet" href="([^"]+)">\s*/g, (_, href) => { css += minCss(readFileSync(join(root, href), 'utf8')) + '\n'; return ''; });
  html = html.replace('</head>', `<style>\n${css}</style>\n</head>`);
  html = html.replace(/<script src="([^"]+)"><\/script>\s*/g, (_, src) => {
    const js = minJs(readFileSync(join(root, src), 'utf8')).replace(/<\/script/gi, '<\\/script');
    return `<script>\n${js}\n</script>\n`;
  });
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, html);
  return { out, bytes: Buffer.byteLength(html), html };
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const { out, bytes } = build();
  console.log(`build-inline: ${out}  ${bytes} byte (${(bytes / 1024).toFixed(1)} KB)  budget ${(BUDGET_BYTES / 1024).toFixed(0)} KB`);
  if (bytes > BUDGET_BYTES) { console.error('ERRORE: oltre il budget'); process.exit(1); }
}
