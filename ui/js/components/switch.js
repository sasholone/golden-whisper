/* switch accessibile: knob (translateX) + overlay accento (opacity). */
(function (root) {
  'use strict';
  var GW = root.GW || (root.GW = {}); GW.ui = GW.ui || {};
  var U = GW.util;

  function toggle(opts) {
    var on = !!opts.checked;
    var el = U.h('button', { class: 'sw', type: 'button', role: 'switch', 'aria-checked': on ? 'true' : 'false', aria: { label: opts.label || '' },
      on: { click: function () { api.set(!on); if (opts.onChange) opts.onChange(on); } } }, [U.h('i')]);
    var api = { el: el, set: function (v) { on = !!v; el.setAttribute('aria-checked', on ? 'true' : 'false'); }, get: function () { return on; } };
    return api;
  }
  /* riga cliccabile con icona, etichetta e switch */
  function switchRow(opts) {
    var sw = toggle({ checked: opts.checked, label: opts.label, onChange: opts.onChange });
    var ic = opts.icon ? GW.icons.make(opts.icon, 15) : null;
    var lbl = U.h('span', { class: 'lbl', text: opts.label });
    var row = U.h('div', { class: 'row hov' + (opts.checked ? ' is-on' : ''), on: { click: function (e) { if (e.target.closest && e.target.closest('.sw')) return; sw.el.click(); } } }, [ic, lbl, sw.el]);
    return { el: row, set: function (v, label) { sw.set(v); row.classList.toggle('is-on', !!v); if (label) lbl.textContent = label; }, sw: sw };
  }
  GW.ui.toggle = toggle; GW.ui.switchRow = switchRow;
})(typeof globalThis !== 'undefined' ? globalThis : this);
