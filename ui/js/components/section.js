/* helper di layout: titolo sezione con icona, box, riga slider. */
(function (root) {
  'use strict';
  var GW = root.GW || (root.GW = {}); GW.ui = GW.ui || {};
  var U = GW.util;

  function sec(title, icon, extra) {
    return U.h('div', { class: 'sec' }, [icon ? GW.icons.make(icon, 14) : null, U.h('span', { text: title }), extra || null]);
  }
  function box(kids, cls) { return U.h('div', { class: 'box' + (cls ? ' ' + cls : '') }, kids); }
  function sep() { return U.h('div', { class: 'sep' }); }
  GW.ui.sec = sec; GW.ui.box = box; GW.ui.sep = sep;
})(typeof globalThis !== 'undefined' ? globalThis : this);
