/* app.js - monta la pagina: header (maniglia di trascinamento), tab con pillola, pannelli, store <-> ponte <-> tema. */
(function (root) {
  'use strict';
  var GW = root.GW, U = GW.util, O = GW.options, UI = GW.ui;
  var doc = root.document;

  root.__gwErrors = [];
  root.addEventListener('error', function (e) { root.__gwErrors.push(String(e.message || e)); });

  var store = GW.state.createStore();
  var bridge = GW.bridge;
  var A = GW.actions.create(store, bridge);
  GW.app = { store: store, actions: A };
  var ctx = { store: store, actions: A };

  if (bridge.isMock) doc.documentElement.classList.add('mock');
  var panel = doc.getElementById('app');

  /* ---------- header + tab ---------- */
  var ver = U.h('span', { class: 'hdr-ver', text: '' });
  var closeBtn = U.h('button', { class: 'hdr-x hov', type: 'button', aria: { label: 'Chiudi impostazioni' }, title: 'Chiudi', on: { click: function () { A.close(); } } }, [GW.icons.make('x', 15, { sw: 1.8 })]);
  var hdr = U.h('div', { class: 'hdr' }, [U.h('div', { class: 'hdr-ic' }, [GW.icons.make('gear', 17, { sw: 1.7 })]), U.h('div', { class: 'hdr-title', text: 'Impostazioni' }), ver, closeBtn]);
  /* l'header e' la maniglia: mousedown -> drag_start (Lua sposta la finestra seguendo il mouse). Niente -webkit-app-region. */
  hdr.addEventListener('mousedown', function (e) { if (e.button === 0 && !(e.target.closest && e.target.closest('button'))) A.dragStart(e.screenX, e.screenY); });

  var TAB_ITEMS = [{ value: 'general', label: 'Generale', icon: 'sliders' }, { value: 'keys', label: 'Tasti', icon: 'keyboard' }, { value: 'theme', label: 'Tema', icon: 'palette' }];
  var tabs = UI.segmented({ items: TAB_ITEMS, value: 'general', label: 'Sezioni', iconSize: 15, onChange: function (v) { A.setTab(v); } });
  var tabbar = U.h('div', { class: 'tabbar' }, [tabs.el]);

  /* ---------- pannelli: il guscio c'e' subito, il CONTENUTO di ogni tab si costruisce alla prima apertura (meno nodi DOM all'avvio) ---------- */
  var T = {}, ro = null;
  var panes = U.h('div', { class: 'panes' });
  var P = {};
  GW.state.TABS.forEach(function (name) {
    P[name] = U.h('div', { class: 'pane', role: 'tabpanel', data: { tab: name } });
    panes.appendChild(P[name]);
  });
  function tabOf(name) {
    if (!T[name]) { T[name] = GW.tabs[name].create(ctx); P[name].appendChild(T[name].el); if (ro) ro.observe(T[name].inner); }
    return T[name];
  }
  var toast = UI.toast(panel);
  U.append(panel, [hdr, tabbar, panes]);
  panel.appendChild(toast.el);
  if (bridge.isMock) doc.body.appendChild(U.h('div', { class: 'mock-note', text: 'MOCK: nessun host Lua collegato · le azioni sono simulate' }));

  /* scroll: filo sotto i tab quando il contenuto e' scorso */
  panes.addEventListener('scroll', function (e) { var t = e.target; if (t && t.classList && t.classList.contains('scroll')) panes.classList.toggle('is-scrolled', t.scrollTop > 2); }, true);

  /* ---------- cambio tab: cross-fade + translate ---------- */
  var shownTab = null, hideTimers = {};
  function showTab(name) {
    if (name === shownTab) return;
    var prev = shownTab, dir = prev ? (GW.state.TABS.indexOf(name) > GW.state.TABS.indexOf(prev) ? 1 : -1) : 1;
    panel.dataset.tab = name; tabs.set(name);
    var nu = P[name], old = prev && P[prev];
    tabOf(name);
    clearTimeout(hideTimers[name]);
    nu.classList.add('is-shown'); nu.classList.toggle('is-left', dir < 0); nu.classList.remove('is-active');
    void nu.offsetWidth;                                                  // reflow: parte la transizione
    nu.classList.remove('is-left'); nu.classList.add('is-active');
    if (old) {
      old.classList.remove('is-active'); old.classList.toggle('is-left', dir > 0);
      hideTimers[prev] = setTimeout(function () { if (shownTab !== prev) old.classList.remove('is-shown', 'is-left'); }, 280);
    }
    shownTab = name;
    tabOf(name);
    if (T.theme) T.theme.setActive(name === 'theme');
    if (T.general && T.general.closeBubbles && name !== 'general') T.general.closeBubbles();
    requestResize();
  }

  /* ---------- richiesta di resize (la finestra la ridimensiona Lua; qui niente animazioni di width/height) ---------- */
  var resizeT = 0, lastReq = '';
  function requestResize() {
    clearTimeout(resizeT);
    resizeT = setTimeout(function () {
      var name = shownTab || 'general', t = T[name];
      if (!t) return;
      var chrome = hdr.offsetHeight + tabbar.offsetHeight + 1;
      var natural = t.natural ? t.natural() : 0;
      var w = GW.actions.SIZES[name].w, h = GW.actions.capHeight(name, Math.max(300, Math.round(chrome + natural + (name === 'theme' ? 0 : 6))));   // tetto: oltre scorre dentro
      var k = w + 'x' + h; if (k === lastReq) return; lastReq = k;
      A.resizeRequest(w, h);
    }, 90);
  }
  if (root.ResizeObserver) {
    ro = new root.ResizeObserver(requestResize);
  }

  /* ---------- store -> UI ---------- */
  var msgTimer = 0, lastMsg = null, lastToast = null, rendered = false;
  function render(s) {
    GW.theme.apply(s);
    ver.textContent = s.version ? 'v' + s.version : '';
    showTab(s.tab);
    rendered = true;
    Object.keys(T).forEach(function (n) { T[n].update(s); });
    if (s.ui.msg !== lastMsg) {                                           // i messaggi della chiave spariscono dopo 9 s (come in Lua)
      lastMsg = s.ui.msg; clearTimeout(msgTimer);
      if (lastMsg && lastMsg.kind !== 'busy') { var m = lastMsg; msgTimer = setTimeout(function () { if (store.get().ui.msg === m) store.dispatch({ type: 'ui', patch: { msg: null } }); }, 9000); }
    }
    if (s.ui.toast !== lastToast) { lastToast = s.ui.toast; if (lastToast) toast.show(lastToast.text); }
  }
  store.dispatch({ type: 'ui', patch: { bridgeMock: bridge.isMock } });
  GW.theme.apply(store.get());
  store.subscribe(render);
  bridge.attach(store);
  /* niente render a vuoto: la pagina e' invisibile finche' Lua non manda lo stato (se tarda, dopo 400 ms si mostra comunque il default) */
  setTimeout(function () { if (!rendered) render(store.get()); }, 400);
  A.ready();                                                              // Lua risponde con gw.onState(stato completo)
  /* interact: UNA volta, al primo pointerdown (l'host restituisce il focus all'app in primo piano). hb: heartbeat ogni 1000 ms (catena di setTimeout). */
  var interacted = false;
  doc.addEventListener('pointerdown', function () { if (!interacted) { interacted = true; A.interact(); } }, true);
  (function beat() { A.hb(); setTimeout(beat, 1000); })();
  /* Esc lo gestisce l'host (chiude la finestra): qui solo capture_cancel se la cattura tasti e' attiva. */
  doc.addEventListener('keydown', function (e) { if (e.key === 'Escape' && store.get().ui.capture) A.captureCancel(); });
})(typeof globalThis !== 'undefined' ? globalThis : this);
