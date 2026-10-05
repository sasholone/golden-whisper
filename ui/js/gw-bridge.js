/* gw-bridge.js - adattatore del ponte Lua <-> JS.
   JS -> Lua : window.webkit.messageHandlers.gw.postMessage({op, ...args})
   Lua -> JS : window.gw = { onState(state), onEvent(name, payload) }  (definito da app.js via GW.bridge.attach)
   Fuori da hs.webview (browser normale) non esiste messageHandlers.gw: si usa il MOCK (js/mock.js). */
(function (root) {
  'use strict';
  var GW = root.GW || (root.GW = {});
  var O = GW.options || require('./options.js');

  function nativeHandler() {
    try { return root.webkit && root.webkit.messageHandlers && root.webkit.messageHandlers.gw || null; } catch (e) { return null; }
  }
  var native = nativeHandler();

  var bridge = {
    isMock: !native,
    log: [],                       // ultimi messaggi inviati (debug / test)
    post: function (msg) {
      if (!msg || typeof msg.op !== 'string' || O.OPS.indexOf(msg.op) < 0) { return false; }   // solo op del contratto
      var clean;
      try { clean = JSON.parse(JSON.stringify(msg)); } catch (e) { return false; }
      bridge.log.push(clean); if (bridge.log.length > 50) bridge.log.shift();
      if (native) { try { native.postMessage(clean); } catch (e) { return false; } }
      else if (GW.mock && GW.mock.handle) GW.mock.handle(clean);
      return true;
    },
    /* Definisce window.gw (Lua -> JS). onState sostituisce lo stato; onEvent applica un evento parziale. */
    attach: function (store) {
      root.gw = {
        onState: function (state) { store.dispatch({ type: 'replace', state: state }); },
        onEvent: function (name, payload) { store.dispatch({ type: 'event', name: String(name), payload: payload }); }
      };
      return root.gw;
    }
  };
  GW.bridge = bridge;
  if (typeof module !== 'undefined') module.exports = bridge;
})(typeof globalThis !== 'undefined' ? globalThis : this);
