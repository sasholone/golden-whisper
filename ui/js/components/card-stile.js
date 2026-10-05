/* carta stile: gradiente CSS statico (entrambi i modi via variabili) + mini onda SVG statica + nome. Nessuna animazione per carta. */
(function (root) {
  'use strict';
  var GW = root.GW || (root.GW = {}); GW.ui = GW.ui || {};
  var U = GW.util;

  /* punti della mini onda (come la carta Lua): rotonda / a blocchi ('pixel') / a punta ('square'). Pura. */
  function wavePoints(kind, w, h) {
    var pts = [], n = 12, pad = 12, x0 = pad, span = (w || 74) - pad * 2, cy = (h || 42) / 2 + 0;
    for (var i = 0; i <= n; i++) {
      var u = i / n, v = Math.sin(u * Math.PI * 3.4 + 0.6) * Math.sin(u * Math.PI);
      if (kind === 'pixel') v = Math.floor(v * 3 + 0.5) / 3;
      else if (kind === 'square') v = (i % 2 === 0 ? 1 : -1) * Math.abs(v);
      pts.push([+(x0 + u * span).toFixed(1), +(cy + v * 11).toFixed(1)]);
    }
    return pts;
  }

  function card(style, assets, onPick) {
    var kind = style.fx && style.fx.bar || 'round';
    var W = 74, H = 42;
    var pl = U.svg('polyline', { points: wavePoints(kind, W, H).map(function (p) { return p.join(','); }).join(' '), fill: 'none', 'stroke-width': 2,
      'stroke-linecap': 'round', 'stroke-linejoin': 'round', opacity: kind === 'ghost' ? 0.6 : 0.92 });
    var svg = U.svg('svg', { viewBox: '0 0 ' + W + ' ' + H, preserveAspectRatio: 'xMidYMid meet', 'aria-hidden': 'true' }, [pl]);
    var g = U.h('span', { class: 'sw-g' }, [svg]);
    var icon = assets && assets[style.id] && assets[style.id].icon;
    if (icon) g.appendChild(U.h('img', { src: icon, alt: '', draggable: 'false' }));
    var el = U.h('button', { class: 'card', type: 'button', role: 'option', 'aria-selected': 'false', data: { id: style.id }, aria: { label: style.name },
      style: GW.theme.cardVars(style), on: { click: function () { onPick(style.id); } } },
      [g, U.h('span', { class: 'nm', text: style.name }), U.h('span', { class: 'tick', aria: { hidden: 'true' } }, [GW.icons.make('check', 11, { sw: 2.4 })])]);
    return el;
  }
  GW.ui.card = card; GW.ui.wavePoints = wavePoints;
  if (typeof module !== 'undefined') module.exports = { wavePoints: wavePoints };
})(typeof globalThis !== 'undefined' ? globalThis : this);
