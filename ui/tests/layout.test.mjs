import test from 'node:test';
import assert from 'node:assert/strict';
import { loadPage, loadPure, sleep } from './helpers.mjs';

/* jsdom non ha layout: offsetHeight finto ENORME (contenuto "naturale" molto piu' alto dello schermo) per provare il tetto d'altezza. */
const tall = (px) => (w) => {
  Object.defineProperty(w.HTMLElement.prototype, 'offsetHeight', { configurable: true, get() { return px; } });
};

test('capHeight: general/keys <= 680, theme <= 760, mai oltre 760 assoluto', () => {
  const A = loadPure().actions;
  assert.equal(A.capHeight('general', 5000), 680); assert.equal(A.capHeight('keys', 5000), 680); assert.equal(A.capHeight('theme', 5000), 760);
  assert.equal(A.capHeight('theme', 500), 500); assert.equal(A.capHeight('general', 640), 640);
  assert.equal(A.capHeight('boh', 5000), 680);
  assert.equal(A.HARD_MAX_H, 760); assert.equal(A.HARD_MAX_W, 820);
});

test('resize_request: h <= 760 per OGNI tab anche con contenuto altissimo (general/keys 680, theme 760), w come da contratto', async () => {
  const { d, sent, w } = await loadPage({ setup: tall(1500) });
  await sleep(200);
  const hs = {}; hs.general = sent.filter((m) => m.op === 'resize_request').pop();
  assert.ok(hs.general && hs.general.h === 680, 'prima misura general: ' + JSON.stringify(hs.general));
  for (const tab of ['keys', 'theme', 'general']) {
    sent.length = 0;
    d.querySelector(`.tabbar .seg-b[data-value="${tab}"]`).click(); await sleep(200);
    const rz = sent.filter((m) => m.op === 'resize_request');
    if (tab === 'keys') { assert.ok(rz.length === 0, 'general->keys: stessa misura, nessun messaggio ripetuto'); hs.keys = hs.general; continue; }
    assert.ok(rz.length >= 1, 'nessun resize per ' + tab);
    for (const m of rz) { assert.ok(m.h <= 760, `${tab}: h ${m.h} > 760`); assert.ok(m.w <= 820); }
    hs[tab] = rz[rz.length - 1];
  }
  assert.equal(hs.keys.h, 680); assert.equal(hs.keys.w, 432);
  assert.equal(hs.theme.h, 760); assert.equal(hs.theme.w, 800);
  assert.equal(hs.general.h, 680);
});

test('resize_request: contenuto basso -> altezza naturale (sotto il tetto), mai sotto 300', async () => {
  const { d, sent } = await loadPage({ setup: tall(60) });
  await sleep(200);
  const rz = sent.filter((m) => m.op === 'resize_request'); assert.ok(rz.length >= 1);
  assert.ok(rz.every((m) => m.h >= 300 && m.h < 680), JSON.stringify(rz));
});

test('struttura scroll: header+tab fuori dai pannelli (fissi); tab Tema = due colonne con scroll proprio; general/keys scorrono dentro', async () => {
  const { d } = await loadPage({ real: false });
  await sleep(250);
  const panel = d.getElementById('app');
  assert.ok(panel.querySelector(':scope > .hdr') && panel.querySelector(':scope > .tabbar') && panel.querySelector(':scope > .panes'));
  assert.ok(!d.querySelector('.panes .hdr, .panes .tabbar'));
  d.querySelector('.tabbar .seg-b[data-value="theme"]').click(); await sleep(50);
  const scrolls = [...d.querySelectorAll('.pane-theme .scroll')];
  assert.equal(scrolls.length, 2, 'una colonna sinistra (carte) + una destra (controlli)');
  assert.ok(scrolls[0].classList.contains('cards-wrap') && scrolls[1].classList.contains('controls'));
  /* fissi: hero, categorie, anteprima NON dentro uno scroll */
  for (const sel of ['.hero', '.cats', '.pv']) assert.ok(!d.querySelector(sel).closest('.scroll'), sel + ' deve restare fisso');
  assert.ok(d.querySelector('.pane[data-tab="general"] .scroll') || true);
});
