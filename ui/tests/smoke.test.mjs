// Smoke in Chrome headless (UNA volta): GW_SMOKE=1 node --test ui/tests/smoke.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { join } from 'node:path';
import { UI } from './helpers.mjs';
const CH = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

test('Chrome headless apre dist/settings.html: 0 errori console, 70 carte', { skip: !process.env.GW_SMOKE }, async () => {
  const p = spawn(CH, ['--headless=new', '--disable-gpu', '--no-first-run', '--user-data-dir=' + join(process.env.TMPDIR || '/tmp', 'gw-smoke'), '--enable-logging=stderr', '--v=0',
    '--virtual-time-budget=4000', '--dump-dom', 'file://' + join(UI, 'dist', 'settings.html') + '#theme']);
  let out = '', err = '';
  p.stdout.on('data', (d) => (out += d)); p.stderr.on('data', (d) => (err += d));
  await new Promise((r) => { const t = setTimeout(() => { p.kill('SIGKILL'); r(); }, 60000); p.on('exit', () => { clearTimeout(t); r(); }); const iv = setInterval(() => { if (/<\/html>/.test(out)) { clearInterval(iv); setTimeout(() => { p.kill('SIGKILL'); }, 300); } }, 200); });
  const cons = err.split('\n').filter((l) => /CONSOLE|Uncaught/i.test(l));
  assert.deepEqual(cons, []);
  assert.equal((out.match(/class="card( |")/g) || []).length, 70);
});
