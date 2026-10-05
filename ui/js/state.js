/* state.js - stato (normalizzazione difensiva), reducer puro e store. Nessun DOM, nessun ponte. */
(function (root) {
  'use strict';
  var GW = root.GW || (root.GW = {});
  var U = GW.util || require('./util.js');
  var O = GW.options || require('./options.js');

  var TABS = ['general', 'keys', 'theme'];

  function fallbackStyle() {
    return { id: 'gold', name: 'Gold', cat: 'cl',
      dark: { bg1: '#1b1914', bg2: '#0a0907', fg: '#f7f2e6', fg2: '#b8ad94', accent: '#d6af5e', grad: ['#ebcb85', '#b48b3b'] },
      light: { bg1: '#fffcf3', bg2: '#f4e8ce', fg: '#2a2012', fg2: '#6e5d3d', accent: '#b3822a', grad: ['#cb9c3a', '#966a1b'] }, fx: null };
  }

  function normTokens(t, d) {
    t = t || {};
    var g = Array.isArray(t.grad) ? t.grad.map(function (c) { return U.cleanHex(c, null); }).filter(Boolean).slice(0, 7) : [];
    var acc = U.cleanHex(t.accent, d.accent);
    if (g.length === 0) g = [acc, acc];
    if (g.length === 1) g = [g[0], g[0]];
    return { bg1: U.cleanHex(t.bg1, d.bg1), bg2: U.cleanHex(t.bg2, d.bg2), fg: U.cleanHex(t.fg, d.fg), fg2: U.cleanHex(t.fg2, d.fg2), accent: acc, grad: g };
  }
  function normStyle(s) {
    if (!s || typeof s !== 'object') return null;
    var id = typeof s.id === 'string' && /^[a-z0-9_\-]{1,40}$/i.test(s.id) ? s.id : null;
    if (!id) return null;
    var f = fallbackStyle();
    var fx = null;
    if (s.fx && typeof s.fx === 'object') {
      var bar = s.fx.bar; if (['round', 'square', 'pixel', 'ghost'].indexOf(bar) < 0) bar = null;
      fx = { icon: s.fx.icon ? U.cleanText(s.fx.icon, 30) : null, bar: bar, part: s.fx.part ? U.cleanText(s.fx.part, 30) : null };
    }
    return { id: id, name: U.cleanText(s.name || id, 40), cat: U.cleanText(s.cat || 'cl', 8),
      dark: normTokens(s.dark, f.dark), light: normTokens(s.light, f.light), fx: fx };
  }
  function normBindings(list) {
    if (!Array.isArray(list)) return [];
    return list.slice(0, 12).map(function (b) {
      b = b || {};
      var g = ['single', 'double', 'hold'].indexOf(b.gesture) >= 0 ? b.gesture : 'single';
      return { label: U.cleanText(b.label, 40) || '?', gesture: g };
    });
  }
  function normAssets(a) {
    var out = {};
    if (!a || typeof a !== 'object') return out;
    Object.keys(a).slice(0, 200).forEach(function (id) {
      if (!/^[a-z0-9_\-]{1,40}$/i.test(id) || !a[id] || typeof a[id] !== 'object') return;
      var o = {};
      Object.keys(a[id]).slice(0, 8).forEach(function (k) { var u = U.cleanUrl(a[id][k]); if (u) o[k] = u; });
      if (Object.keys(o).length) out[id] = o;
    });
    return out;
  }

  function initialUi() {
    return { cat: 'all', catTouched: false, hoverStyle: null, capture: null, keyOpen: false, keyArmedAt: 0, msg: null, toast: null, devicesBusy: false, ready: false, bridgeMock: false };
  }
  function initial() {
    return { version: '', tab: 'general', look: O.defaultsLook(), general: O.defaultsGeneral(), keys: { ss: [], pause: [] },
      groq: { has: false, mask: '' }, styles: [fallbackStyle()], cats: O.CATS_DEFAULT.slice(), effectiveMode: 'dark', assets: {}, ui: initialUi() };
  }

  /* Stato completo da Lua -> stato valido (campi mancanti = default sensati). Mantiene ui. */
  function normalize(raw, prev) {
    var s = initial();
    if (prev && prev.ui) s.ui = prev.ui;
    if (!raw || typeof raw !== 'object') return prev || s;
    s.version = U.cleanText(raw.version, 20);
    s.tab = TABS.indexOf(raw.tab) >= 0 ? raw.tab : 'general';
    var look = raw.look || {};
    O.LOOK_KEYS.forEach(function (k) { s.look[k] = O.clean(k, look[k]); });
    var gen = raw.general || {};
    O.GENERAL_KEYS.forEach(function (k) { s.general[k] = O.clean(k, gen[k]); });
    s.general.micName = U.cleanText(gen.micName, 160);
    s.general.devices = Array.isArray(gen.devices) ? gen.devices.slice(0, 64).map(function (d) {
      if (typeof d === 'string') d = { name: d };
      return { name: U.cleanText(d && d.name, 160), bt: U.asBool(d && d.bt, false) };
    }).filter(function (d) { return d.name; }) : [];
    var keys = raw.keys || {};
    s.keys = { ss: normBindings(keys.ss), pause: normBindings(keys.pause) };
    var gq = raw.groq || {};
    s.groq = { has: U.asBool(gq.has, false), mask: U.cleanText(gq.mask, 40) };
    var styles = Array.isArray(raw.styles) ? raw.styles.slice(0, 400).map(normStyle).filter(Boolean) : [];
    s.styles = styles.length ? styles : [fallbackStyle()];
    var cats = Array.isArray(raw.cats) ? raw.cats.map(function (c) {
      return (c && typeof c.id === 'string') ? { id: U.cleanText(c.id, 8), name: U.cleanText(c.name || c.id, 24) } : null;
    }).filter(Boolean) : [];
    s.cats = cats.length ? cats : O.CATS_DEFAULT.slice();
    if (!s.cats.some(function (c) { return c.id === 'all'; })) s.cats.unshift({ id: 'all', name: 'Tutti' });
    s.effectiveMode = raw.effectiveMode === 'light' ? 'light' : raw.effectiveMode === 'dark' ? 'dark' : (s.look.themeMode === 'light' ? 'light' : 'dark');
    s.assets = normAssets(raw.assets);
    if (!s.styles.some(function (st) { return st.id === s.look.style; })) { /* stile sconosciuto: resta l'id, la UI usa il primo */ }
    /* categoria iniziale = quella dello stile CORRENTE (non 'Tutti'), finche' l'utente non sceglie una categoria */
    if (!s.ui.catTouched) { var cs = currentStyle(s); if (cs && s.cats.some(function (c) { return c.id === cs.cat; })) s.ui = Object.assign({}, s.ui, { cat: cs.cat }); }
    if (!s.cats.some(function (c) { return c.id === s.ui.cat; })) s.ui = Object.assign({}, s.ui, { cat: 'all' });
    return s;
  }

  function currentStyle(s) {
    for (var i = 0; i < s.styles.length; i++) if (s.styles[i].id === s.look.style) return s.styles[i];
    return s.styles[0];
  }

  function withUi(s, patch) { return Object.assign({}, s, { ui: Object.assign({}, s.ui, patch) }); }
  function setIn(obj, key, val) { var o = Object.assign({}, obj); o[key] = val; return o; }

  /* Reducer puro. Mai muta lo stato in ingresso. */
  function reduce(s, a) {
    switch (a.type) {
      case 'replace': return normalize(a.state, s);
      case 'set': {
        var scope = O.scopeOf(a.key); if (!scope) return s;
        var v = O.clean(a.key, a.value);
        var n = Object.assign({}, s); n[scope] = setIn(s[scope], a.key, v);
        if (a.key === 'themeMode') n.effectiveMode = v === 'auto' ? s.effectiveMode : v;
        return n;
      }
      case 'reset_look': return Object.assign({}, s, { look: O.defaultsLook(), effectiveMode: 'dark' });
      case 'tab': return TABS.indexOf(a.tab) >= 0 ? Object.assign({}, s, { tab: a.tab }) : s;
      case 'pick_mic': return Object.assign({}, s, { general: setIn(s.general, 'micName', U.cleanText(a.name, 160)) });
      case 'remove_binding': {
        if (a.action !== 'ss' && a.action !== 'pause') return s;
        var list = s.keys[a.action].filter(function (_, i) { return i !== a.index; });
        return Object.assign({}, s, { keys: setIn(s.keys, a.action, list) });
      }
      case 'set_gesture': {
        if (a.action !== 'ss' && a.action !== 'pause') return s;
        if (['single', 'double', 'hold'].indexOf(a.gesture) < 0) return s;
        var l2 = s.keys[a.action].map(function (b, i) { return i === a.index ? { label: b.label, gesture: a.gesture } : b; });
        return Object.assign({}, s, { keys: setIn(s.keys, a.action, l2) });
      }
      case 'ui': return withUi(s, a.patch);
      case 'event': return reduceEvent(s, a.name, a.payload || {});
    }
    return s;
  }

  function reduceEvent(s, name, p) {
    switch (name) {
      case 'key_status': {
        var kind = ['ok', 'error', 'busy'].indexOf(p.kind) >= 0 ? p.kind : 'ok';
        var n = Object.assign({}, s, { groq: { has: p.has === undefined ? s.groq.has : U.asBool(p.has, s.groq.has),
          mask: p.mask === undefined ? s.groq.mask : U.cleanText(p.mask, 40) } });
        var text = U.cleanText(p.msg, 140);
        return withUi(n, { msg: text ? { text: text, kind: kind } : (kind === 'busy' ? { text: 'Controllo…', kind: 'busy' } : null) });
      }
      case 'devices': {
        var devs = normalize({ general: { devices: Array.isArray(p) ? p : p.devices } }, s).general.devices;
        return withUi(Object.assign({}, s, { general: setIn(s.general, 'devices', devs) }), { devicesBusy: false });
      }
      case 'capture_result': return withUi(s, { capture: null });
      case 'toast': { var t = U.cleanText(p.text, 120); return withUi(s, { toast: t ? { text: t, id: Date.now() + Math.random() } : null }); }
    }
    return s;
  }

  function createStore(start) {
    var state = start || initial();
    var subs = [];
    return {
      get: function () { return state; },
      dispatch: function (a) { var prev = state; state = reduce(state, a); if (state !== prev) subs.slice().forEach(function (f) { f(state, prev, a); }); return state; },
      subscribe: function (f) { subs.push(f); return function () { subs = subs.filter(function (x) { return x !== f; }); }; }
    };
  }

  GW.state = { TABS: TABS, initial: initial, initialUi: initialUi, normalize: normalize, reduce: reduce, createStore: createStore, currentStyle: currentStyle };
  if (typeof module !== 'undefined') module.exports = GW.state;
})(typeof globalThis !== 'undefined' ? globalThis : this);
