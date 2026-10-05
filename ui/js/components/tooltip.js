/* bolla (i): bottone info + popover con titolo e passi. Si chiude con Esc o click fuori. */
(function (root) {
  'use strict';
  var GW = root.GW || (root.GW = {}); GW.ui = GW.ui || {};
  var U = GW.util;

  /* opts: { title, steps[], anchorTop } -> { btn, bubble, close() }. Il bubble va messo in un contenitore position:relative. */
  function infoBubble(opts) {
    var bubble = U.h('div', { class: 'bubble', role: 'tooltip' }, [U.h('h4', { text: opts.title }),
      U.h('ol', null, opts.steps.map(function (s) { return U.h('li', { text: s }); }))]);
    bubble.style.top = (opts.top || 26) + 'px';
    var btn = U.h('button', { class: 'info-btn', type: 'button', 'aria-expanded': 'false', aria: { label: opts.title }, on: { click: function (e) { e.stopPropagation(); toggle(); } } },
      [GW.icons.make('info', 11, { sw: 2 })]);
    function isOpen() { return bubble.classList.contains('is-open'); }
    function set(v) { bubble.classList.toggle('is-open', v); btn.setAttribute('aria-expanded', v ? 'true' : 'false'); }
    function toggle() { set(!isOpen()); }
    root.document && root.document.addEventListener('click', function (e) { if (isOpen() && !bubble.contains(e.target)) set(false); });
    root.document && root.document.addEventListener('keydown', function (e) { if (e.key === 'Escape' && isOpen()) { set(false); btn.focus(); } });
    return { btn: btn, bubble: bubble, close: function () { set(false); } };
  }
  GW.ui.infoBubble = infoBubble;
})(typeof globalThis !== 'undefined' ? globalThis : this);
