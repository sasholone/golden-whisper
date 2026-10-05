/* mock.js - finto host Lua per provare la pagina in un browser normale (doppio click su index.html o dist/settings.html).
   Stato finto con 70 stili generati, ~12 microfoni, eventi simulati. NON viene mai usato dentro hs.webview. */
(function (root) {
  'use strict';
  var GW = root.GW || (root.GW = {});
  var O = GW.options || require('./options.js');

  function hsl(h, s, l) {
    h = ((h % 360) + 360) % 360; s /= 100; l /= 100;
    var a = s * Math.min(l, 1 - l);
    function f(n) { var k = (n + h / 30) % 12; var c = l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1)); return ('0' + Math.round(255 * c).toString(16)).slice(-2); }
    return '#' + f(0) + f(8) + f(4);
  }
  function gen(id, name, cat, hue, n, seed) {
    var spread = [0, 0, 38, 46, 52][n] || 40;
    var gd = [], gl = [];
    for (var i = 0; i < n; i++) { gd.push(hsl(hue + i * spread + (seed % 7) * 3, 85, 64 - i * 2)); gl.push(hsl(hue + i * spread + (seed % 7) * 3, 78, 40 - i * 2)); }
    return { id: id, name: name, cat: cat,
      dark: { bg1: hsl(hue, 34, 14), bg2: hsl(hue, 42, 6), fg: hsl(hue, 40, 95), fg2: hsl(hue, 16, 68), accent: gd[0], grad: gd },
      light: { bg1: hsl(hue, 100, 98), bg2: hsl(hue, 62, 90), fg: hsl(hue, 55, 10), fg2: hsl(hue, 25, 36), accent: gl[0], grad: gl },
      fx: seed % 5 === 0 ? { bar: 'pixel' } : seed % 4 === 0 ? { bar: 'square' } : seed % 9 === 0 ? { bar: 'ghost' } : null };
  }
  var REAL = [
    { id: 'gold', name: 'Gold', cat: 'cl',
      dark: { bg1: '#1b1914', bg2: '#0a0907', fg: '#f7f2e6', fg2: '#b8ad94', accent: '#d6af5e', grad: ['#ebcb85', '#b48b3b'] },
      light: { bg1: '#fffcf3', bg2: '#f4e8ce', fg: '#2a2012', fg2: '#6e5d3d', accent: '#b3822a', grad: ['#cb9c3a', '#966a1b'] }, fx: null },
    { id: 'mono', name: 'Mono', cat: 'cl',
      dark: { bg1: '#1e1e21', bg2: '#0c0c0e', fg: '#f5f5f7', fg2: '#a1a1a8', accent: '#e4e4e9', grad: ['#ffffff', '#b6b6be'] },
      light: { bg1: '#ffffff', bg2: '#ececf1', fg: '#17171a', fg2: '#62626b', accent: '#2b2b31', grad: ['#474750', '#18181c'] }, fx: null },
    { id: 'ocean', name: 'Ocean', cat: 'nt',
      dark: { bg1: '#101c31', bg2: '#060b16', fg: '#ebf2ff', fg2: '#93a6c6', accent: '#5c9cff', grad: ['#8ebcff', '#3b78e2'] },
      light: { bg1: '#f9fcff', bg2: '#e2edfc', fg: '#0e1a33', fg2: '#4a5e82', accent: '#2563d6', grad: ['#4380f0', '#1b4db0'] }, fx: null },
    { id: 'sunset', name: 'Sunset', cat: 'fk',
      dark: { bg1: '#2a1424', bg2: '#12060f', fg: '#fff0ea', fg2: '#d2a5a8', accent: '#ff7a59', grad: ['#ffb259', '#ff6a5a', '#e8466e', '#b45cff'] },
      light: { bg1: '#fff8f3', bg2: '#ffe3d6', fg: '#3a1620', fg2: '#865560', accent: '#e2552f', grad: ['#e8691e', '#e04a38', '#d03a6e', '#8e44d8'] }, fx: null },
    { id: 'aurora', name: 'Aurora', cat: 'nt',
      dark: { bg1: '#0e1f2b', bg2: '#050e16', fg: '#e8fff8', fg2: '#8fb8b8', accent: '#3df0b4', grad: ['#3df0b4', '#38c8f0', '#7b6cff', '#c65cff'] },
      light: { bg1: '#f5fffc', bg2: '#d8f2ee', fg: '#0b2a2e', fg2: '#43706f', accent: '#0b9e86', grad: ['#0ea07c', '#1688c8', '#5a50dc', '#a03cd0'] }, fx: null },
    { id: 'neon', name: 'Neon', cat: 'ne',
      dark: { bg1: '#12102a', bg2: '#07061a', fg: '#f2f0ff', fg2: '#a09cd0', accent: '#00f0ff', grad: ['#00f0ff', '#8a5cff', '#ff2ea6'] },
      light: { bg1: '#fbfaff', bg2: '#e4e0ff', fg: '#15123a', fg2: '#5a5690', accent: '#0aa0c8', grad: ['#0a93ba', '#6240d8', '#d81c86'] }, fx: { bar: 'square' } }
  ];
  var NAMES = {
    cl: ['Inchiostro', 'Caffè', 'Nebbia', 'Ardesia', 'Bordeaux', 'Platino', 'Rame', 'Avorio', 'Seppia'],
    fk: ['Cosmo', 'Gelato', 'Cioccolato', 'Bacche', 'Memphis', 'Candy', 'Lava', 'Citrus', 'Pop Art', 'Cometa'],
    nt: ['Deserto', 'Abissi', 'Matcha', 'Corallo', 'Lavanda', 'Forest', 'Lagoon', 'Muschio', 'Scogliera'],
    ne: ['Digital Rain', 'Cyber', 'Tokyo', 'Acido', 'UV', 'Synthwave', 'Laser'],
    rt: ['Arcade', 'Vapor', 'Pirata', 'Noir', 'Miami', 'LCD', 'Ambra', 'Steam'],
    pp: ['Blue Rush', 'Blocky', 'Turbo Ball', 'Quahog', 'Quest', 'Zap', 'Funghetto'],
    st: ['Spooky', 'Noel', 'Sakura', 'Autunno', 'Estate', 'Primavera', 'Inverno', 'Cuori', 'Brindisi']
  };
  var CAT_ORDER = ['cl', 'fk', 'nt', 'ne', 'rt', 'pp', 'st'];
  var CAT_HUE = { cl: 38, fk: 300, nt: 150, ne: 190, rt: 330, pp: 220, st: 20 };

  function buildStyles(total) {
    var out = [], seed = 0, byId = {};
    REAL.forEach(function (s) { byId[s.id] = s; });
    CAT_ORDER.forEach(function (cat) {
      NAMES[cat].forEach(function (nm, i) {
        var id = nm.toLowerCase().replace(/[^a-z0-9]+/g, '');
        seed++;
        out.push(byId[id] || gen(id, nm, cat, CAT_HUE[cat] + i * 23, cat === 'cl' ? 2 : (cat === 'ne' || cat === 'nt' ? 3 : 4), seed));
      });
    });
    var k = 0;
    while (out.length < total) { k++; var cat = CAT_ORDER[k % CAT_ORDER.length]; out.push(gen('extra' + k, 'Extra ' + k, cat, (k * 47) % 360, 2 + (k % 3), k)); }
    REAL.forEach(function (s) { if (!out.some(function (o) { return o.id === s.id; })) out.push(s); });
    // ordine: raggruppato per categoria, come in Lua
    var order = [];
    CAT_ORDER.forEach(function (c) { out.forEach(function (s) { if (s.cat === c) order.push(s); }); });
    return order;
  }

  var DEVICES = [
    { name: 'MacBook Pro Microphone', bt: false }, { name: 'AirPods Pro di Sasha', bt: true }, { name: 'Beats Studio Buds', bt: true },
    { name: 'Studio Display Microphone', bt: false }, { name: 'Blue Yeti Nano', bt: false }, { name: 'Jabra Evolve2 65', bt: true },
    { name: 'Scarlett Solo USB', bt: false }, { name: 'Rode NT-USB Mini', bt: false }, { name: 'iPhone di Sasha (Continuity)', bt: false },
    { name: 'WH-1000XM5', bt: true }, { name: 'Microfono con un nome molto molto lungo che non sta in una riga da quattrocento pixel', bt: false },
    { name: '<img src=x onerror=alert(1)> <script>alert("xss")</script>', bt: false }
  ];

  var st = null, timers = [];
  function after(ms, fn) { timers.push(setTimeout(fn, ms)); }
  function snapshot() {
    return JSON.parse(JSON.stringify({ version: '1.2.0-mock', tab: st.tab, look: st.look, general: st.general, keys: st.keys, groq: st.groq,
      styles: st.styles, cats: st.cats, effectiveMode: effective(), assets: {} }));
  }
  function effective() {
    var m = st.look.themeMode;
    if (m === 'auto') return (root.matchMedia && root.matchMedia('(prefers-color-scheme: light)').matches) ? 'light' : 'dark';
    return m;
  }
  function push() { if (root.gw && root.gw.onState) root.gw.onState(snapshot()); }
  function evt(name, payload) { if (root.gw && root.gw.onEvent) root.gw.onEvent(name, payload); }

  function init() {
    var styles = buildStyles(70);
    var counts = {}; styles.forEach(function (s) { counts[s.cat] = (counts[s.cat] || 0) + 1; });
    st = { tab: 'general', look: O.defaultsLook(), styles: styles,
      cats: O.CATS_DEFAULT.slice(),
      general: { micName: DEVICES[1].name, devices: DEVICES.slice(), sizePreset: 'standard', orientation: 'horizontal' },
      keys: { ss: [{ label: 'F5', gesture: 'double' }, { label: '⌥ dx', gesture: 'hold' }], pause: [{ label: 'F6', gesture: 'single' }] },
      groq: { has: false, mask: '' } };
  }

  function handle(m) {
    if (!st) init();
    var L = st.look;
    switch (m.op) {
      case 'ready': after(60, push); break;
      case 'set':
        if (O.scopeOf(m.key) === 'look') L[m.key] = O.clean(m.key, m.value);
        else if (O.scopeOf(m.key) === 'general') st.general[m.key] = O.clean(m.key, m.value);
        break;                                                  // come Lua: nessuna risposta obbligatoria; stato completo solo su richiesta
      case 'random_look': {
        var pick = function (a) { return a[Math.floor(Math.random() * a.length)]; };
        var s2 = pick(st.styles.filter(function (s) { return s.id !== L.style; }));
        L.style = s2.id; L.waveStyle = pick(['bars', 'thin', 'dots', 'line']); L.waveColor = s2.dark.grad.length > 2 ? 'gradient' : 'accent';
        L.cornerStyle = pick(['round', 'round', 'medium', 'square']); L.micPulse = Math.round((0.25 + Math.random() * 0.6) * 100) / 100;
        L.glassOpacity = Math.round((0.82 + Math.random() * 0.18) * 100) / 100; L.timerFont = pick(['mono', 'sf', 'rounded']); L.uiFont = pick(['sf', 'sf', 'rounded']);
        push(); evt('toast', { text: 'Sorpresa: ' + s2.name }); break;
      }
      case 'reset_look': st.look = O.defaultsLook(); push(); break;
      case 'pick_mic': st.general.micName = String(m.name || ''); break;
      case 'refresh_devices': after(700, function () { var d = DEVICES.slice().sort(function () { return Math.random() - 0.5; }); st.general.devices = d; evt('devices', d); }); break;
      case 'key_paste':
        evt('key_status', { has: st.groq.has, mask: st.groq.mask, msg: 'Controllo…', kind: 'busy' });
        after(1100, function () {
          if (Math.random() < 0.25) { evt('key_status', { has: st.groq.has, mask: st.groq.mask, msg: 'Chiave non valida: Groq ha risposto 401', kind: 'error' }); return; }
          st.groq = { has: true, mask: 'gsk_…ab12' };
          evt('key_status', { has: true, mask: st.groq.mask, msg: 'Chiave salvata e verificata', kind: 'ok' });
        });
        break;
      case 'key_remove': st.groq = { has: false, mask: '' }; evt('key_status', { has: false, mask: '', msg: 'Chiave rimossa', kind: 'ok' }); break;
      case 'open_groq': evt('toast', { text: '(mock) Apro console.groq.com nel browser' }); break;
      case 'capture_start': after(1600, function () {
        var lab = ['F13', '⌘ dx', 'F7', '⌃ sx'][Math.floor(Math.random() * 4)];
        st.keys[m.action].push({ label: lab, gesture: m.action === 'ss' ? 'double' : 'single' });
        evt('capture_result', { ok: true, label: lab, action: m.action }); push();
      }); break;
      case 'capture_cancel': break;
      case 'key_remove_binding': if (st.keys[m.action]) st.keys[m.action].splice(m.index, 1); break;
      case 'key_set_gesture': if (st.keys[m.action] && st.keys[m.action][m.index]) st.keys[m.action][m.index].gesture = m.gesture; break;
      case 'set_tab': st.tab = m.tab; break;
      case 'close': evt('toast', { text: '(mock) Finestra chiusa' }); break;
      case 'resize_request': GW.mock.lastResize = { w: m.w, h: m.h }; break;
      case 'drag_start': break;
    }
  }

  GW.mock = { handle: handle, buildStyles: buildStyles, devices: DEVICES, lastResize: null, reset: function () { timers.forEach(clearTimeout); timers = []; st = null; } };
  if (typeof module !== 'undefined') module.exports = GW.mock;
})(typeof globalThis !== 'undefined' ? globalThis : this);
