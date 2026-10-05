/* segmented con pillola che scivola (translateX via --i / --n): niente width/left animati. */
(function (root) {
  'use strict';
  var GW = root.GW || (root.GW = {}); GW.ui = GW.ui || {};
  var U = GW.util;

  /* opts: { items:[{value,label,icon}], value, onChange(v), size:'sm'|'xs'|'', label (aria), iconSize, cls } */
  function segmented(opts) {
    var items = opts.items, btns = [];
    var el = U.h('div', { class: 'seg' + (opts.size ? ' ' + opts.size : '') + (opts.cls ? ' ' + opts.cls : ''), role: 'radiogroup', aria: { label: opts.label || '' } });
    var pill = U.h('span', { class: 'seg-pill', aria: { hidden: 'true' } });
    el.appendChild(pill);
    el.style.setProperty('--n', items.length);
    items.forEach(function (it, i) {
      var b = U.h('button', { class: 'seg-b', type: 'button', role: 'radio', 'aria-checked': 'false', tabindex: '-1', data: { value: it.value }, title: it.label,
        on: { click: function () { choose(i, true); },
          keydown: function (e) {
            var d = e.key === 'ArrowRight' || e.key === 'ArrowDown' ? 1 : e.key === 'ArrowLeft' || e.key === 'ArrowUp' ? -1 : 0;
            if (d) { e.preventDefault(); var n = (i + d + items.length) % items.length; choose(n, true); btns[n].focus(); }
          } } });
      if (it.icon) b.appendChild(GW.icons.make(it.icon, opts.iconSize || (opts.size ? 13 : 15)));
      b.appendChild(U.h('span', { text: it.label }));
      btns.push(b); el.appendChild(b);
    });
    var cur = -1;
    function paint(i) {
      cur = i;
      el.style.setProperty('--i', Math.max(0, i));
      pill.style.opacity = i < 0 ? '0' : '1';
      btns.forEach(function (b, k) { var on = k === i; b.classList.toggle('is-sel', on); b.setAttribute('aria-checked', on ? 'true' : 'false'); b.tabIndex = on || (i < 0 && k === 0) ? 0 : -1; });
    }
    function indexOf(v) { for (var i = 0; i < items.length; i++) if (items[i].value === v) return i; return -1; }
    function choose(i, user) { if (i === cur) return; paint(i); if (user && opts.onChange) opts.onChange(items[i].value); }
    paint(indexOf(opts.value));
    return { el: el, set: function (v) { var i = indexOf(v); if (i !== cur) paint(i); }, get: function () { return cur >= 0 ? items[cur].value : null; } };
  }
  GW.ui.segmented = segmented;
})(typeof globalThis !== 'undefined' ? globalThis : this);
