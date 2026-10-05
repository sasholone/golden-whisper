/* tab TASTI: lista tasti avvio/stop e pausa con gesto, + aggiungi (cattura), elimina. */
(function (root) {
  'use strict';
  var GW = root.GW || (root.GW = {}); GW.tabs = GW.tabs || {};
  var U = GW.util, O = GW.options, UI = GW.ui;

  function create(ctx) {
    var A = ctx.actions, S = ctx.store;
    var groups = {};

    function group(action, title, icon) {
      var g = { action: action, list: U.h('div', { class: 'binds' }), sig: '' };
      g.addLbl = U.h('span', { text: 'Aggiungi tasto' });
      g.add = U.h('button', { class: 'btn dashed add-key press', type: 'button', on: { click: function () {
        if (S.get().ui.capture === action) A.captureCancel(); else A.captureStart(action);
      } } }, [GW.icons.make('plus', 15, { sw: 1.9 }), g.addLbl]);
      g.addIc = g.add.firstChild;
      g.el = U.h('div', { class: 'sec-wrap' }, [UI.sec(title, icon), g.list, g.add]);
      groups[action] = g; return g;
    }
    var gSs = group('ss', 'AVVIO / STOP', 'play');
    var gPause = group('pause', 'PAUSA', 'pause');
    var hint = U.h('p', { class: 'hint', text: 'Premi «Aggiungi tasto», poi il tasto o la combinazione che vuoi usare. Esc annulla.' });
    var inner = U.h('div', { class: 'pane-pad inner' }, [gSs.el, gPause.el, hint]);
    var el = U.h('div', { class: 'scroll', style: { flex: '1' } }, [inner]);

    function renderGroup(g, s) {
      var list = s.keys[g.action];
      var sig = list.map(function (b) { return b.label + '|' + b.gesture; }).join('\u0001');
      if (sig !== g.sig) {
        g.sig = sig; U.clear(g.list);
        if (!list.length) g.list.appendChild(U.h('div', { class: 'box bind-empty', text: 'Nessun tasto assegnato' }));
        list.forEach(function (b, i) {
          var seg = UI.segmented({ items: O.GESTURES[g.action], value: b.gesture, size: 'sm', label: 'Gesto per ' + b.label, onChange: function (v) { A.setGesture(g.action, i, v); } });
          var del = U.h('button', { class: 'btn-ic', type: 'button', aria: { label: 'Elimina il tasto ' + b.label }, title: 'Elimina', on: { click: function () { A.removeBinding(g.action, i); } } },
            [GW.icons.make('x', 14, { sw: 1.8 })]);
          g.list.appendChild(U.h('div', { class: 'box bind' }, [U.h('span', { class: 'kcap', text: b.label }), seg.el, del]));
        });
      }
      var cap = s.ui.capture === g.action;
      g.add.classList.toggle('is-capturing', cap);
      g.addLbl.textContent = cap ? 'Premi un tasto… (tocca per annullare)' : 'Aggiungi tasto';
      g.addIc.style.display = cap ? 'none' : '';
      g.add.disabled = !!s.ui.capture && !cap;
    }
    function update(s) { renderGroup(gSs, s); renderGroup(gPause, s); }
    update(S.get());
    return { el: el, inner: inner, update: update };
  }
  GW.tabs.keys = { create: create };
})(typeof globalThis !== 'undefined' ? globalThis : this);
