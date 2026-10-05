/* chip categoria con icona, nome e conteggio. */
(function (root) {
  'use strict';
  var GW = root.GW || (root.GW = {}); GW.ui = GW.ui || {};
  var U = GW.util;

  function chip(opts) {
    var ct = U.h('span', { class: 'ct', text: String(opts.count || 0) });
    var el = U.h('button', { class: 'chip', type: 'button', role: 'tab', 'aria-selected': 'false', data: { id: opts.id }, aria: { label: opts.name + ', ' + (opts.count || 0) + ' stili' },
      on: { click: function () { if (opts.onClick) opts.onClick(opts.id); } } },
      [opts.icon ? GW.icons.make(opts.icon, 14) : null, U.h('span', { class: 'nm', text: opts.name }), ct]);
    return { el: el, set: function (sel, count) { el.classList.toggle('is-sel', !!sel); el.setAttribute('aria-selected', sel ? 'true' : 'false'); if (count !== undefined) ct.textContent = String(count); } };
  }
  GW.ui.chip = chip;
})(typeof globalThis !== 'undefined' ? globalThis : this);
