/* icons.js - set di icone SVG inline, griglia 24x24, tratto uniforme 1.5, estremi arrotondati (stile Lucide/Phosphor "line").
   Disegnate per questo progetto (vedi LICENSES.md). Registro DATI (testabile senza DOM) + costruttore SVG con createElementNS (mai HTML da stringa).
   Elementi: ['p', d] path · ['pf', d, opacita'] path pieno · ['c', cx, cy, r] cerchio · ['cf', cx, cy, r] cerchio pieno · ['r', x, y, w, h, rx] rettangolo ·
   ['t', testo, fontKey] testo nel font vero. Definizione: { sw?: spessore, els: [...] }. */
(function (root) {
  'use strict';
  var GW = root.GW || (root.GW = {});

  function rays(cx, cy, r1, r2, n, rot) {
    var d = '';
    for (var i = 0; i < n; i++) {
      var a = (rot || 0) + i * 2 * Math.PI / n, c = Math.cos(a), s = Math.sin(a);
      d += 'M' + (cx + r1 * c).toFixed(2) + ' ' + (cy + r1 * s).toFixed(2) + 'L' + (cx + r2 * c).toFixed(2) + ' ' + (cy + r2 * s).toFixed(2);
    }
    return d;
  }
  function micShape(bx, by, bw, bh, arc, stem) { return [['r', bx, by, bw, bh, bw / 2], ['p', arc], ['p', stem]]; }
  function sine(n, amp) {
    var w = 20 / n, h = w / 2, k = w * 0.33;
    var d = 'M2 12';
    for (var i = 0; i < n; i++) d += 'c' + k.toFixed(2) + ' ' + (-amp) + ' ' + (h - k).toFixed(2) + ' ' + (-amp) + ' ' + h.toFixed(2) + ' 0s' + (h - k).toFixed(2) + ' ' + amp + ' ' + h.toFixed(2) + ' 0';
    return d;
  }

  var D = {
    /* --- sezioni / generali --- */
    gear: { els: [['c', 12, 12, 3], ['c', 12, 12, 6.6], ['p', rays(12, 12, 6.6, 9.4, 8, Math.PI / 8)]] },
    mic: { els: micShape(9, 3, 6, 11, 'M5.5 11a6.5 6.5 0 0 0 13 0', 'M12 17.5V21M9 21h6') },
    keyboard: { els: [['r', 2.5, 5.5, 19, 13, 2.5], ['p', 'M6.5 9.5h.01M10 9.5h.01M14 9.5h.01M17.5 9.5h.01M6.5 13h.01M10 13h.01M14 13h.01M17.5 13h.01M8 16h8']] },
    palette: { els: [['p', 'M12 3.2a8.8 8.8 0 1 0 0 17.6c1.1 0 1.8-.8 1.8-1.7 0-.5-.2-.9-.5-1.3-.3-.4-.5-.8-.5-1.3 0-1 .8-1.7 1.8-1.7H17a3.9 3.9 0 0 0 3.9-3.9c0-4.2-4-7.7-8.9-7.7z'], ['p', 'M7.5 11.5h.01M10 7.8h.01M14.5 7.8h.01']] },
    sliders: { els: [['p', 'M4 7h3M11.5 7H20M4 17h8.5M17 17h3'], ['c', 9.25, 7, 2.25], ['c', 14.75, 17, 2.25]] },
    key: { els: [['c', 8, 15.5, 3.8], ['p', 'M10.8 12.7 20 3.5M16.2 7.3l2.8 2.8M13.6 9.9l2 2']] },
    info: { els: [['c', 12, 12, 9], ['p', 'M12 11v5.2M12 7.9h.01']] },
    check: { els: [['p', 'M5 12.5l4.5 4.5L19 7.5']] },
    x: { els: [['p', 'M6 6l12 12M18 6L6 18']] },
    plus: { els: [['p', 'M12 5v14M5 12h14']] },
    trash: { els: [['p', 'M4 7h16M9.5 7V4.5h5V7M6.5 7l.8 12.5h9.4L17.5 7M10 11v5M14 11v5']] },
    external: { els: [['p', 'M7 17 17 7M9 7h8v8']] },
    eye: { els: [['p', 'M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z'], ['c', 12, 12, 2.8]] },
    chevron: { els: [['p', 'M6 9l6 6 6-6']] },
    bluetooth: { els: [['p', 'M7 7.5l10 9-5 4.5V3l5 4.5-10 9']] },
    refresh: { els: [['p', 'M19.5 12a7.5 7.5 0 1 1-2.2-5.3'], ['p', 'M19.5 4.5V9H15']] },
    play: { els: [['p', 'M8 5.5v13l11-6.5z']] },
    pause: { sw: 2.2, els: [['p', 'M8.5 5.5v13M15.5 5.5v13']] },
    paste: { els: [['p', 'M8.5 4.5H7a2 2 0 0 0-2 2V19a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V6.5a2 2 0 0 0-2-2h-1.5'], ['r', 8.5, 2.8, 7, 3.4, 1.2], ['p', 'M9 13h6M9 16.5h4']] },
    warn: { els: [['p', 'M12 4 2.8 19.5h18.4z'], ['p', 'M12 10v4.2M12 17h.01']] },
    sparkle: { els: [['p', 'M10.5 4l1.6 4.9 4.9 1.6-4.9 1.6-1.6 4.9-1.6-4.9L4 10.5l4.9-1.6z'], ['p', 'M18.5 15v5M16 17.5h5']] },
    reset: { els: [['p', 'M4.3 12a7.8 7.8 0 1 0 2.3-5.5L4 9'], ['p', 'M4 4.2V9h4.8']] },
    ghost: { els: [['p', 'M5 20.5V11a7 7 0 0 1 14 0v9.5l-2.33-1.8L14.33 20.5 12 18.7l-2.33 1.8-2.34-1.8z'], ['p', 'M9.5 11h.01M14.5 11h.01']] },
    clock: { els: [['c', 12, 12, 9], ['p', 'M12 7v5l3 2']] },
    /* --- tema: modo, ombra, vetro, ... --- */
    moon: { els: [['p', 'M20 14.5A8.5 8.5 0 1 1 9.5 4a6.7 6.7 0 0 0 10.5 10.5z']] },
    sun: { els: [['c', 12, 12, 3.6], ['p', rays(12, 12, 6.6, 8.9, 8, 0)]] },
    glow: { els: [['c', 12, 12, 3.6], ['p', rays(12, 12, 6.6, 8.9, 8, 0)]] },
    auto: { els: [['c', 12, 12, 8.5], ['pf', 'M12 3.5a8.5 8.5 0 0 0 0 17z']] },
    shadow: { els: [['r', 4, 4, 11.5, 11.5, 2.5], ['p', 'M18.5 8.5v8a2 2 0 0 1-2 2h-8']] },
    glass: { els: [['p', 'M12 3.5s6 6.2 6 10.6a6 6 0 0 1-12 0C6 9.7 12 3.5 12 3.5z'], ['p', 'M9.2 14.6a2.9 2.9 0 0 0 2.2 2.4']] },
    micPulse: { els: [['r', 9.5, 6, 5, 8.5, 2.5], ['p', 'M7.2 12.4a4.8 4.8 0 0 0 9.6 0M12 17.2v3'], ['p', 'M4.2 9.2c-.8 1.9-.8 4.1 0 6M19.8 9.2c.8 1.9.8 4.1 0 6']] },
    cornerSq: { els: [['p', 'M4.5 20V4.5H20']] },
    cornerMd: { els: [['p', 'M4.5 20v-9a6.5 6.5 0 0 1 6.5-6.5h9']] },
    cornerRd: { els: [['p', 'M4.5 20v-5.5A10 10 0 0 1 14.5 4.5H20']] },
    wvBars: { sw: 3, els: [['p', 'M4.5 10v4M9.2 6v12M14 9v6M18.8 4.5v15']] },
    wvThin: { sw: 1.3, els: [['p', 'M3.5 10v4M6.5 7v10M9.5 5v14M12.5 8.5v7M15.5 6v12M18.5 8.5v7M21 10.5v3']] },
    wvDots: { els: [['cf', 4.5, 12, 1.3], ['cf', 8, 9, 1.3], ['cf', 8, 15, 1.3], ['cf', 11.5, 6, 1.3], ['cf', 11.5, 12, 1.3], ['cf', 11.5, 18, 1.3], ['cf', 15, 9, 1.3], ['cf', 15, 15, 1.3], ['cf', 18.5, 12, 1.3]] },
    wvLine: { els: [['p', 'M2.5 12c1.6 0 2-6.5 3.6-6.5S8.2 18.5 9.8 18.5 12 5.5 13.8 5.5s1.8 13 3.4 13 1.4-6.5 3.3-6.5']] },
    dotAcc: { els: [['cf', 12, 12, 5.5], ['c', 12, 12, 8.5]] },
    dotGrad: { els: [['c', 12, 12, 8.5], ['pf', 'M12 6.5a5.5 5.5 0 0 1 0 11z', 1], ['pf', 'M12 6.5a5.5 5.5 0 0 0 0 11z', 0.35]] },
    sine1: { els: [['p', sine(1, 7)]] },
    sine2: { els: [['p', sine(2, 6)]] },
    sine3: { els: [['p', sine(3, 5)]] },
    aa: { els: [['t', 'Aa', 'sf']] }, aaSf: { els: [['t', 'Aa', 'sf']] }, aaRounded: { els: [['t', 'Aa', 'rounded']] }, aaMono: { els: [['t', 'Aa', 'mono']] },
    tnMono: { els: [['t', '09', 'mono']] }, tnSf: { els: [['t', '09', 'sf']] }, tnRounded: { els: [['t', '09', 'rounded']] },
    rowsC: { els: [['p', 'M5 5.5h14M5 9h14M5 12.5h14M5 16h14M5 19.5h14']] },
    rowsN: { els: [['p', 'M5 6h14M5 10.7h14M5 15.3h14M5 20h14']] },
    rowsW: { els: [['p', 'M5 5.5h14M5 12h14M5 18.5h14']] },
    sizeS: { els: micShape(10.4, 8.6, 3.2, 5.8, 'M8.6 13.4a3.4 3.4 0 0 0 6.8 0', 'M12 16.9v1.9') },
    sizeM: { els: micShape(9.4, 5.2, 5.2, 9.2, 'M7 12.4a5 5 0 0 0 10 0', 'M12 17.4v3') },
    sizeL: { els: micShape(8.4, 2.4, 7.2, 12.4, 'M5 11.6a7 7 0 0 0 14 0', 'M12 18.6v2.9M8.5 21.5h7') },
    orientH: { els: [['r', 2.5, 8, 19, 8, 4]] },
    orientV: { els: [['r', 8, 2.5, 8, 19, 4]] },
    /* --- categorie stile --- */
    catAll: { els: [['r', 4, 4, 6.5, 6.5, 1.6], ['r', 13.5, 4, 6.5, 6.5, 1.6], ['r', 4, 13.5, 6.5, 6.5, 1.6], ['r', 13.5, 13.5, 6.5, 6.5, 1.6]] },
    catGem: { els: [['p', 'M6.5 4h11L21 9l-9 11L3 9z'], ['p', 'M3 9h18M9.5 9 12 4l2.5 5L12 20z']] },
    catLeaf: { els: [['p', 'M20 4C11 4 5 8.5 5 15.5c0 1.8.4 3.2.8 4.5C14.5 20 20 14 20 4z'], ['p', 'M5.8 20C9 15 12 11.5 16 9']] },
    catBolt: { els: [['p', 'M13 3 5 13.5h6L10 21l8-10.5h-6z']] },
    catRetro: { els: [['r', 3, 7, 18, 13, 2.5], ['p', 'M8.5 3.2 12 7l3.5-3.8']] },
    catPop: { els: [['p', 'M12 3.5l2.6 5.5 6 .8-4.4 4.2 1.1 6-5.3-2.9-5.3 2.9 1.1-6L3.4 9.8l6-.8z']] },
    catSnow: { els: [['p', 'M12 3v18M4.2 7.5l15.6 9M4.2 16.5l15.6-9'], ['p', 'M9.5 4.5 12 6.5l2.5-2M9.5 19.5l2.5-2 2.5 2']] }
  };

  function has(name) { return Object.prototype.hasOwnProperty.call(D, name); }
  function names() { return Object.keys(D); }

  /* costruttore SVG (solo browser) */
  function make(name, size, opts) {
    var U = GW.util, def = D[name] || D.info;
    opts = opts || {};
    var svg = U.svg('svg', { viewBox: '0 0 24 24', width: size || 16, height: size || 16, fill: 'none', stroke: 'currentColor',
      'stroke-width': opts.sw || def.sw || 1.5, 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true', focusable: 'false' });
    svg.setAttribute('class', 'ic' + (opts.cls ? ' ' + opts.cls : ''));
    def.els.forEach(function (e) {
      var k = e[0], n;
      if (k === 'p') n = U.svg('path', { d: e[1] });
      else if (k === 'pf') { n = U.svg('path', { d: e[1], fill: 'currentColor', stroke: 'none' }); if (e[2] !== undefined) n.setAttribute('opacity', e[2]); }
      else if (k === 'c') n = U.svg('circle', { cx: e[1], cy: e[2], r: e[3] });
      else if (k === 'cf') n = U.svg('circle', { cx: e[1], cy: e[2], r: e[3], fill: 'currentColor', stroke: 'none' });
      else if (k === 'r') n = U.svg('rect', { x: e[1], y: e[2], width: e[3], height: e[4], rx: e[5] || 0 });
      else if (k === 't') {
        n = U.svg('text', { x: 12, y: 16.4, 'text-anchor': 'middle', fill: 'currentColor', stroke: 'none', 'font-size': 13.5, 'font-weight': 700 });
        n.setAttribute('style', 'font-family:' + (GW.theme ? GW.theme.FONTS[e[2]] : 'sans-serif'));
        n.textContent = e[1];
      }
      if (n) svg.appendChild(n);
    });
    return svg;
  }

  GW.icons = { defs: D, has: has, names: names, make: make };
  if (typeof module !== 'undefined') module.exports = GW.icons;
})(typeof globalThis !== 'undefined' ? globalThis : this);
