/* tab GENERALE: microfono, dimensione, orientamento, chiave Groq (in cima se manca, riga riducibile in fondo se c'e'). */
(function (root) {
  'use strict';
  var GW = root.GW || (root.GW = {}); GW.tabs = GW.tabs || {};
  var U = GW.util, O = GW.options, UI = GW.ui;

  function create(ctx) {
    var A = ctx.actions, S = ctx.store;
    var refs = {};

    /* ---------- chiave Groq: scheda in evidenza (nessuna chiave) ---------- */
    function keyButtons(prefix) {
      var paste = U.h('button', { class: 'btn primary press', type: 'button', on: { click: function () { A.keyPaste(); } } },
        [GW.icons.make('paste', 15), U.h('span', { text: prefix ? 'Incolla nuova chiave' : 'Incolla chiave dal clipboard' })]);
      var open = U.h('button', { class: 'btn soft press', type: 'button', on: { click: function () { A.openGroq(); } } },
        [GW.icons.make('external', 14), U.h('span', { text: 'Prendi / crea la chiave su Groq' })]);
      return { paste: paste, open: open, pasteLbl: paste.lastChild };
    }
    var tipTop = UI.infoBubble({ title: 'Come ottenere la chiave', steps: O.KEY_STEPS, top: 24 });
    var top = {}; top.b = keyButtons(false);
    top.dot = U.h('span', { class: 'key-dot' });
    top.l1 = U.h('div', { class: 'key-l1', text: 'Nessuna chiave' });
    top.l2 = U.h('div', { class: 'key-l2', text: 'Serve per trascrivere · gratis su Groq' });
    top.wrap = U.h('div', { class: 'sec-wrap' }, [
      UI.sec('CHIAVE GROQ', 'key', tipTop.btn),
      UI.box([U.h('div', { class: 'key-card' }, [U.h('div', { class: 'key-status' }, [top.dot, U.h('div', { class: 'key-txt' }, [top.l1, top.l2])]), top.b.paste, top.b.open])]),
      tipTop.bubble]);

    /* ---------- chiave Groq: riga riducibile (chiave presente) ---------- */
    var tipFold = UI.infoBubble({ title: 'Come ottenere la chiave', steps: O.KEY_STEPS, top: 52 });
    var fold = {}; fold.b = keyButtons(true);
    fold.mask = U.h('span', { class: 'mask', text: '' });
    fold.chev = GW.icons.make('chevron', 16, { cls: 'chev' });
    fold.head = U.h('button', { class: 'key-head hov', type: 'button', 'aria-expanded': 'false', aria: { label: 'Chiave Groq' }, on: { click: function () { A.toggleKeyOpen(); } } },
      [U.h('span', { class: 'key-dot is-ok' }), U.h('span', { class: 'lbl', style: { 'font-weight': '650' }, text: 'Chiave Groq' }), fold.mask, fold.chev]);
    fold.msgTxt = U.h('span', { text: '' });
    fold.msg = U.h('div', { class: 'msg' }, [fold.msgTxt, tipFold.btn]);
    fold.remove = U.h('button', { class: 'btn danger press', type: 'button', on: { click: function () { A.keyRemoveTap(); } } }, [GW.icons.make('trash', 14), U.h('span', { text: 'Rimuovi chiave' })]);
    fold.removeLbl = fold.remove.lastChild;
    fold.body = U.h('div', { class: 'key-body' }, [fold.msg, fold.b.paste, fold.b.open, fold.remove]);
    fold.card = U.h('div', { class: 'box key-fold' }, [fold.head, fold.body]);
    fold.wrap = U.h('div', { class: 'sec-wrap' }, [fold.card, tipFold.bubble]);

    /* ---------- microfono ---------- */
    refs.devSig = '';
    refs.micList = U.h('div', { class: 'mic-list', role: 'radiogroup', aria: { label: 'Microfono' } });
    refs.refreshBtn = U.h('button', { class: 'btn-ic sec-tools', type: 'button', aria: { label: 'Aggiorna elenco microfoni' }, title: 'Aggiorna elenco',
      on: { click: function () { A.refreshDevices(); } } }, [GW.icons.make('refresh', 14)]);
    var micSec = U.h('div', { class: 'sec-wrap' }, [UI.sec('MICROFONO', 'mic', refs.refreshBtn), UI.box([refs.micList])]);

    /* ---------- dimensione / orientamento ---------- */
    var size = UI.segmented({ items: O.SCHEMA.general.sizePreset.choices, value: 'standard', label: 'Dimensione', onChange: function (v) { A.set('sizePreset', v); } });
    var orient = UI.segmented({ items: O.SCHEMA.general.orientation.choices, value: 'horizontal', label: 'Orientamento', onChange: function (v) { A.set('orientation', v); } });
    size.el.style.height = orient.el.style.height = '36px';
    var sizeSec = U.h('div', { class: 'sec-wrap' }, [UI.sec('DIMENSIONE', 'sizeM'), size.el]);
    var orientSec = U.h('div', { class: 'sec-wrap' }, [UI.sec('ORIENTAMENTO', 'orientH'), orient.el]);

    var inner = U.h('div', { class: 'pane-pad inner' }, [top.wrap, micSec, sizeSec, orientSec, fold.wrap]);
    var el = U.h('div', { class: 'scroll', style: { flex: '1' } }, [inner]);

    function renderDevices(s) {
      var devs = s.general.devices, cur = s.general.micName;
      var sig = devs.map(function (d) { return d.name + (d.bt ? '*' : ''); }).join('\u0001');
      if (sig !== refs.devSig) {
        refs.devSig = sig; U.clear(refs.micList); refs.rows = [];
        if (!devs.length) refs.micList.appendChild(U.h('div', { class: 'mic-empty', text: 'Nessun microfono trovato' }));
        devs.forEach(function (d) {
          var row = U.h('button', { class: 'mic hov', type: 'button', role: 'radio', 'aria-checked': 'false', data: { name: d.name }, title: d.name,
            on: { click: function () { A.pickMic(d.name); } } },
            [U.h('span', { class: 'dot' }, [GW.icons.make('check', 12, { sw: 2.4 })]), U.h('span', { class: 'nm', text: d.name }), d.bt ? GW.icons.make('bluetooth', 14, { cls: 'bt' }) : null]);
          refs.rows.push({ el: row, name: d.name }); refs.micList.appendChild(row);
        });
      }
      (refs.rows || []).forEach(function (r) { var on = r.name === cur; r.el.classList.toggle('is-cur', on); r.el.setAttribute('aria-checked', on ? 'true' : 'false'); });
    }

    var lastOpen = false, lastBusy = null;
    function update(s) {
      var has = s.groq.has, ui = s.ui, msg = ui.msg, busy = !!(msg && msg.kind === 'busy');
      top.wrap.hidden = has; fold.wrap.hidden = !has;
      /* scheda in evidenza */
      top.dot.classList.toggle('is-ok', has);
      var l2 = msg ? msg.text : 'Serve per trascrivere · gratis su Groq';
      top.l2.textContent = l2; top.l2.className = 'key-l2' + (msg ? ' ' + msg.kind : '');
      /* riga riducibile */
      fold.mask.textContent = (msg && !ui.keyOpen && msg.kind !== 'busy') ? msg.text : (s.groq.mask || 'chiave salvata');
      fold.mask.className = 'mask' + (msg && !ui.keyOpen && msg.kind !== 'busy' ? ' ' + msg.kind : '');
      fold.msgTxt.textContent = msg ? msg.text : 'Salvata su questo Mac · incolla per sostituirla';
      fold.msg.className = 'msg' + (msg ? ' ' + msg.kind : '');
      var open = !!ui.keyOpen;
      fold.head.setAttribute('aria-expanded', open ? 'true' : 'false');
      if (open !== lastOpen) {
        lastOpen = open; fold.card.classList.toggle('is-open', open);
        if (open) requestAnimationFrame(function () { requestAnimationFrame(function () { fold.card.classList.add('is-shown'); }); }); else fold.card.classList.remove('is-shown');
      }
      if (busy !== lastBusy) {
        lastBusy = busy;
        [top.b, fold.b].forEach(function (b, i) { b.paste.disabled = busy; b.pasteLbl.textContent = busy ? 'Controllo…' : (i ? 'Incolla nuova chiave' : 'Incolla chiave dal clipboard'); });
      }
      var armed = ui.keyArmedAt > 0;
      fold.remove.classList.toggle('is-armed', armed); fold.removeLbl.textContent = armed ? 'Sicuro? Tocca ancora' : 'Rimuovi chiave';
      /* microfoni, dimensione, orientamento */
      renderDevices(s);
      refs.refreshBtn.classList.toggle('is-spin', !!ui.devicesBusy);
      size.set(s.general.sizePreset); orient.set(s.general.orientation);
    }
    update(S.get());
    return { el: el, inner: inner, natural: function () { return inner.offsetHeight; }, update: update, closeBubbles: function () { tipTop.close(); tipFold.close(); } };
  }
  GW.tabs.general = { create: create };
})(typeof globalThis !== 'undefined' ? globalThis : this);
