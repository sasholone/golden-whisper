import test from 'node:test';
import assert from 'node:assert/strict';
import { loadPage, loadPure, sleep, walk, read, UI } from './helpers.mjs';
import { join } from 'node:path';
const GW = loadPure();
const O = GW.options, T = GW.theme, S = GW.state;

const gold = S.normalize({ styles: [{ id: 'gold', name: 'Gold', cat: 'cl',
  dark: { bg1: '#1b1914', bg2: '#0a0907', fg: '#f7f2e6', fg2: '#b8ad94', accent: '#d6af5e', grad: ['#ebcb85', '#b48b3b'] },
  light: { bg1: '#fffcf3', bg2: '#f4e8ce', fg: '#2a2012', fg2: '#6e5d3d', accent: '#b3822a', grad: ['#cb9c3a', '#966a1b'] } }] }).styles[0];
const alpha = (c) => Number(/,\s*([\d.]+)\)$/.exec(c)[1]);

test('schema: material = enum solid|glass, default solid, sanificato (invalido -> solid)', () => {
  const sc = O.SCHEMA.look.material;
  assert.equal(sc.type, 'enum'); assert.equal(sc.def, 'solid'); assert.deepEqual(sc.choices.map((c) => c.value), ['solid', 'glass']);
  assert.equal(O.clean('material', 'glass'), 'glass'); assert.equal(O.clean('material', 'solid'), 'solid');
  for (const bad of ['plastica', '', null, undefined, 5, true, {}, 'GLASS']) assert.equal(O.clean('material', bad), 'solid');
  assert.equal(O.scopeOf('material'), 'look'); assert.ok(O.LOOK_KEYS.includes('material'));
  assert.equal(S.initial().look.material, 'solid');
});
test('stato: look.material assente -> solid; glass accettato; valore strano -> solid', () => {
  assert.equal(S.normalize({}).look.material, 'solid');
  assert.equal(S.normalize({ look: { material: 'glass' } }).look.material, 'glass');
  assert.equal(S.normalize({ look: { material: 'boh' } }).look.material, 'solid');
  const st = S.createStore(); st.dispatch({ type: 'set', key: 'material', value: 'glass' }); assert.equal(st.get().look.material, 'glass');
});
test('icone: segmented Materiale ha entrambe le icone, e l\'opzione ne ha una', () => {
  for (const c of O.SCHEMA.look.material.choices) assert.ok(GW.icons.has(c.icon), c.icon);
  assert.ok(GW.icons.has(O.SCHEMA.look.material.icon));
  assert.ok(O.requiredIcons().includes('matSolid') && O.requiredIcons().includes('matGlass'));
});
test('token solid vs glass: pannello quasi opaco, bordo accento pieno, ombre a 2 strati, raggi, testo secondario piu\' contrastato', () => {
  for (const mode of ['dark', 'light']) {
    const tk = mode === 'dark' ? gold.dark : gold.light;
    const so = T.tokens(gold, mode, { ...S.initial().look, material: 'solid' }), gl = T.tokens(gold, mode, { ...S.initial().look, material: 'glass' });
    assert.ok(alpha(so['--panel-1']) >= 0.94 && alpha(so['--panel-2']) >= 0.94, 'solid: alpha pannello ' + so['--panel-1']);
    assert.equal(alpha(so['--panel-1']), 0.97); assert.equal(alpha(so['--panel-2']), 0.985);
    assert.equal(so['--panel-border'], so['--border']); assert.equal(gl['--panel-border'], gl['--border-soft']);
    assert.match(so['--sh-panel'], /^0 22px 50px rgba\(0,0,0,[\d.]+\), 0 2px 6px rgba\(0,0,0,[\d.]+\)$/, 'ambient larga + contatto stretta');
    assert.equal(so['--r-panel'], '20px'); assert.equal(so['--r-l'], '14px'); assert.equal(gl['--r-panel'], '16px'); assert.equal(gl['--r-l'], '16px');
    assert.equal(so['--r-m'], '12px'); assert.equal(so['--r-s'], '9px');
    assert.equal(so['--fw-title'], '700'); assert.equal(so['--fw-lbl'], '600'); assert.equal(so['--fs-sec'], '10px'); assert.equal(so['--ls-sec'], '.9px');
    assert.ok(T.contrast(so['--fg2'], tk.bg2) >= T.contrast(gl['--fg2'], tk.bg2) - 1e-9, 'fg2 solid >= glass: ' + mode);
    assert.ok(T.contrast(so['--fg3'], tk.bg2) > T.contrast(gl['--fg3'], tk.bg2), 'fg3 piu\' contrastato: ' + mode);
    assert.ok(alpha(so['--row']) > alpha(gl['--row']) && alpha(so['--divider']) > alpha(gl['--divider']) && alpha(so['--track']) > alpha(gl['--track']));
    assert.equal(so['--bw'], '1px'); assert.equal(gl['--bw'], '0px');
    assert.equal(so['--sheen'], 'rgba(255,255,255,0)', 'niente gloss sul pannello solid');
    assert.equal(gl['--sh-contact'], '0 0 0 0 transparent'); assert.equal(gl['--pill-shadow'], '0 0 0 0 transparent');
    /* l'HUD d'anteprima resta il vetro vero (alpha = glassOpacity), in entrambi i materiali */
    assert.equal(so['--bg1'], gl['--bg1']); assert.equal(so['--bg2'], gl['--bg2']);
    assert.equal(so['--glass-alpha'], gl['--glass-alpha']);
  }
  assert.equal(T.tokens(gold, 'dark', { ...S.initial().look, material: undefined })['--panel-1'], T.tokens(gold, 'dark', S.initial().look)['--panel-1'], 'assente = solid');
});
test('data-material sul documento + token applicati; cambio materiale dal controllo del tab Tema (messaggio set material)', async () => {
  const { w, d, sent } = await loadPage();
  w.gw.onState({ tab: 'theme', look: { style: 'gold' } }); await sleep(60);
  const root = d.documentElement;
  assert.equal(root.dataset.material, 'solid', 'default solid');
  assert.equal(root.style.getPropertyValue('--panel-1'), 'rgba(27,25,20,0.97)');
  const seg = [...d.querySelectorAll('.pane-theme .csec')].find((c) => c.querySelector('.sec')?.textContent.includes('MATERIALE'));
  assert.ok(seg, 'sezione Materiale nel tab Tema'); assert.deepEqual([...seg.querySelectorAll('.seg-b')].map((b) => b.dataset.value), ['solid', 'glass']);
  assert.equal(seg.querySelectorAll('.seg-b svg').length, 2, 'icone nel segmented');
  assert.equal(seg.querySelector('.is-sel').dataset.value, 'solid');
  assert.ok(seg === d.querySelector('.pane-theme .controls').querySelectorAll('.csec')[[...d.querySelectorAll('.pane-theme .csec')].indexOf(seg)]);
  seg.querySelector('.seg-b[data-value="glass"]').click(); await sleep(20);
  assert.deepEqual(sent[sent.length - 1], { op: 'set', key: 'material', value: 'glass' });
  assert.equal(root.dataset.material, 'glass'); assert.equal(seg.querySelector('.is-sel').dataset.value, 'glass');
  assert.match(root.style.getPropertyValue('--panel-1'), /rgba\(27,25,20,0\.95\)/);
  w.gw.onState({ tab: 'theme', look: { material: 'solid' } }); await sleep(20);
  assert.equal(root.dataset.material, 'solid');
});
test('mock: #material=glass / #material=solid / #theme&material=glass nel browser', async () => {
  for (const [hash, tab, mat] of [['#material=glass', 'general', 'glass'], ['#material=solid', 'general', 'solid'], ['#theme&material=glass', 'theme', 'glass'], ['#theme', 'theme', 'solid'], ['', 'general', 'solid']]) {
    const html = read(join(UI, 'dist', 'settings.html'));
    const { JSDOM, VirtualConsole } = (await import('node:module')).createRequire(import.meta.url)('jsdom');
    const dom = new JSDOM(html, { runScripts: 'dangerously', pretendToBeVisual: true, url: 'file:///x/settings.html' + hash, virtualConsole: new VirtualConsole() });
    await sleep(250);
    const d = dom.window.document;
    assert.equal(d.documentElement.dataset.material, mat, hash); assert.equal(d.getElementById('app').dataset.tab, tab, hash);
    dom.window.close();
  }
});
test('budget: ancora UN solo backdrop-filter (il pannello radice), nessun blur decorativo (filter: blur) nel CSS', () => {
  const css = walk(join(UI, 'css'), '.css').map(read).join('\n');
  const bf = css.split('\n').filter((l) => /(^|[^-])backdrop-filter\s*:/.test(l));
  assert.equal(bf.length, 1, 'backdrop-filter: ' + bf.length); assert.match(bf[0], /var\(--panel-blur\)/);
  assert.ok(!/[^-]filter\s*:\s*blur/.test(css), 'filter: blur decorativo');
  assert.ok(!/radial-gradient\([^)]*blur/.test(css));
  /* ombre grandi solo nei token (2 strati o 1 popup), mai con raggio > 56px */
  for (const m of css.matchAll(/box-shadow\s*:[^;]*?(\d+)px\s+(\d+)px\s+(\d+)px/g)) assert.ok(Number(m[3]) <= 56, 'blur ombra ' + m[0]);
});
test('contrasto testo secondario: solid >= glass su stili chiari/scuri, mono-colore e multicolore (gold, mono, ocean, lavanda, bordeaux, sakura, sunset, aurora, neon)', async () => {
  (await import('node:module')).createRequire(import.meta.url)('../js/mock.js');
  const all = S.normalize({ styles: GW.mock.buildStyles(70) }).styles;
  let n = 0;
  for (const id of ['gold', 'mono', 'ocean', 'lavanda', 'bordeaux', 'sakura', 'sunset', 'aurora', 'neon']) {
    const st = all.find((s) => s.id === id); assert.ok(st, id);
    for (const mode of ['dark', 'light']) {
      const tk = mode === 'dark' ? st.dark : st.light;
      const so = T.tokens(st, mode, { ...S.initial().look, material: 'solid' }), gl = T.tokens(st, mode, { ...S.initial().look, material: 'glass' });
      assert.ok(T.contrast(so['--fg2'], tk.bg2) >= 5.5, `${id} ${mode} fg2 ${T.contrast(so['--fg2'], tk.bg2)}`);
      assert.ok(T.contrast(so['--fg3'], tk.bg2) >= 3.5, `${id} ${mode} fg3 ${T.contrast(so['--fg3'], tk.bg2)}`);
      assert.ok(T.contrast(so['--fg3'], tk.bg2) > T.contrast(gl['--fg3'], tk.bg2));
      assert.equal(so['--on-accent'], gl['--on-accent'], 'testo su accento: stesso in entrambi i materiali'); n++;
    }
  }
  assert.equal(n, 18);
});
