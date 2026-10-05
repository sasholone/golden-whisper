/* actions.js - azioni utente: aggiornamento ottimistico dello store + messaggio verso Lua. */
(function (root) {
  'use strict';
  var GW = root.GW || (root.GW = {});
  var U = GW.util || require('./util.js');
  var O = GW.options || require('./options.js');

  var SIZES = { general: { w: 432 }, keys: { w: 432 }, theme: { w: 800 } };

  function create(store, bridge) {
    var post = function (m) { return bridge.post(m); };
    var sendSetThrottled = {};
    var A = {
      /* Cambia una opzione: la UI si aggiorna subito, poi {op:'set'}. */
      set: function (key, value) {
        if (!O.schemaOf(key)) return;
        var v = O.clean(key, value);
        store.dispatch({ type: 'set', key: key, value: v });
        post({ op: 'set', key: key, value: v });
      },
      /* Per gli slider: store subito, messaggio al massimo ogni 80 ms (+ ultimo valore garantito con flush). */
      setLive: function (key, value) {
        if (!O.schemaOf(key)) return;
        var v = O.clean(key, value);
        store.dispatch({ type: 'set', key: key, value: v });
        var t = sendSetThrottled[key] || (sendSetThrottled[key] = U.throttle(function (val) { post({ op: 'set', key: key, value: val }); }, 80));
        t(v);
      },
      flush: function (key) { if (sendSetThrottled[key]) sendSetThrottled[key].flush(); },
      randomLook: function () { post({ op: 'random_look' }); },
      resetLook: function () { store.dispatch({ type: 'reset_look' }); post({ op: 'reset_look' }); },
      pickMic: function (name) { store.dispatch({ type: 'pick_mic', name: name }); post({ op: 'pick_mic', name: name }); },
      refreshDevices: function () { store.dispatch({ type: 'ui', patch: { devicesBusy: true } }); post({ op: 'refresh_devices' }); },
      keyPaste: function () { store.dispatch({ type: 'event', name: 'key_status', payload: { kind: 'busy', msg: 'Controllo…' } }); post({ op: 'key_paste' }); },
      /* Rimuovi con doppio tocco: il primo tocco arma per 3 s, il secondo invia key_remove. */
      keyRemoveTap: function () {
        var ui = store.get().ui, now = Date.now();
        if (ui.keyArmedAt && now - ui.keyArmedAt < 3000) {
          store.dispatch({ type: 'ui', patch: { keyArmedAt: 0 } });
          post({ op: 'key_remove' });
          return true;
        }
        store.dispatch({ type: 'ui', patch: { keyArmedAt: now } });
        setTimeout(function () { var u = store.get().ui; if (u.keyArmedAt === now) store.dispatch({ type: 'ui', patch: { keyArmedAt: 0 } }); }, 3050);
        return false;
      },
      openGroq: function () { post({ op: 'open_groq' }); },
      captureStart: function (action) { store.dispatch({ type: 'ui', patch: { capture: action } }); post({ op: 'capture_start', action: action }); },
      captureCancel: function () { store.dispatch({ type: 'ui', patch: { capture: null } }); post({ op: 'capture_cancel' }); },
      removeBinding: function (action, index) { store.dispatch({ type: 'remove_binding', action: action, index: index }); post({ op: 'key_remove_binding', action: action, index: index }); },
      setGesture: function (action, index, gesture) { store.dispatch({ type: 'set_gesture', action: action, index: index, gesture: gesture }); post({ op: 'key_set_gesture', action: action, index: index, gesture: gesture }); },
      setTab: function (tab) { if (store.get().tab === tab) return; store.dispatch({ type: 'tab', tab: tab }); post({ op: 'set_tab', tab: tab }); },
      close: function () { post({ op: 'close' }); },
      dragStart: function () { post({ op: 'drag_start' }); },
      resizeRequest: function (w, h) { post({ op: 'resize_request', w: Math.round(w), h: Math.round(h) }); },
      ready: function () { post({ op: 'ready' }); },
      toggleKeyOpen: function () { store.dispatch({ type: 'ui', patch: { keyOpen: !store.get().ui.keyOpen } }); },
      setCat: function (id) { store.dispatch({ type: 'ui', patch: { cat: id } }); },
      hoverStyle: function (id) { if (store.get().ui.hoverStyle !== id) store.dispatch({ type: 'ui', patch: { hoverStyle: id } }); }
    };
    return A;
  }
  GW.actions = { create: create, SIZES: SIZES };
  if (typeof module !== 'undefined') module.exports = GW.actions;
})(typeof globalThis !== 'undefined' ? globalThis : this);
