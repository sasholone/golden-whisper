/* slider: input range nativo (tastiera/accessibilita' gratis), riempimento con --r. onInput throttolato dal chiamante. */
(function (root) {
  'use strict';
  var GW = root.GW || (root.GW = {}); GW.ui = GW.ui || {};
  var U = GW.util;

  /* opts: { icon, label, min, max, step, value, fmt(v), onInput(v), onCommit(v) } */
  function slider(opts) {
    var min = opts.min, max = opts.max;
    var fmt = opts.fmt || function (v) { return Math.round(v * 100) + '%'; };
    var input = U.h('input', { class: 'rng', type: 'range', min: min, max: max, step: opts.step || 0.01, aria: { label: opts.label } });
    var val = U.h('span', { class: 'val', text: '' });
    var el = U.h('div', { class: 'slider' }, [opts.icon ? GW.icons.make(opts.icon, 15) : null, U.h('span', { class: 'lbl', text: opts.label }), input, val]);
    function paint(v) { input.style.setProperty('--r', String(U.clamp((v - min) / (max - min), 0, 1))); val.textContent = fmt(v); }
    input.addEventListener('input', function () { var v = parseFloat(input.value); paint(v); if (opts.onInput) opts.onInput(v); });
    input.addEventListener('change', function () { if (opts.onCommit) opts.onCommit(parseFloat(input.value)); });
    var dragging = false;
    input.addEventListener('pointerdown', function () { dragging = true; });
    root.addEventListener('pointerup', function () { dragging = false; });
    var api = { el: el, input: input, set: function (v) { if (dragging) return; input.value = String(v); paint(v); } };
    api.set(opts.value === undefined ? min : opts.value);
    return api;
  }
  GW.ui.slider = slider;
})(typeof globalThis !== 'undefined' ? globalThis : this);
