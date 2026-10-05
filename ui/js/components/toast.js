/* toast: opacity + translate, sparisce da solo. */
(function (root) {
  'use strict';
  var GW = root.GW || (root.GW = {}); GW.ui = GW.ui || {};
  var U = GW.util;

  function toast(host) {
    var el = U.h('div', { class: 'toast', role: 'status', 'aria-live': 'polite' });
    host.appendChild(el);
    var t = null;
    return { el: el, show: function (text) {
      el.textContent = text; el.classList.add('is-on');
      clearTimeout(t); t = setTimeout(function () { el.classList.remove('is-on'); }, 2600);
    } };
  }
  GW.ui.toast = toast;
})(typeof globalThis !== 'undefined' ? globalThis : this);
