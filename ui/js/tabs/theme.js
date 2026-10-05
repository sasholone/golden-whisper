/* tab TEMA: colonna sinistra (stile attuale/anteprima in hover, categorie con conteggio, carte) + destra (anteprima fissa + controlli). */
(function (root) {
  'use strict';
  var GW = root.GW || (root.GW = {}); GW.tabs = GW.tabs || {};
  var U = GW.util, O = GW.options, UI = GW.ui, SC = O.SCHEMA.look;

  function create(ctx) {
    var A = ctx.actions, S = ctx.store;
    var preview = GW.preview.create(ctx);

    /* ---------- hero: stile attuale / anteprima ---------- */
    var heroN = U.h('div', { class: 'hero-n', text: '' }), heroS = U.h('div', { class: 'hero-s', text: '' });
    var wave = U.svg('svg', { class: 'hero-w', viewBox: '0 0 110 40', 'aria-hidden': 'true' });
    for (var i = 0; i <= 10; i++) { var bh = 8 + 24 * Math.abs(Math.sin(i * 0.83 + 0.55)); wave.appendChild(U.svg('rect', { x: 4 + i * 10, y: (40 - bh) / 2, width: 3.2, height: bh, rx: 1.6 })); }
    var hero = U.h('div', { class: 'hero', role: 'status', 'aria-live': 'polite' }, [U.h('div', { class: 'hero-t' }, [heroN, heroS]), wave]);

    /* ---------- categorie + carte ---------- */
    var catsEl = U.h('div', { class: 'cats', role: 'tablist', aria: { label: 'Categorie' } });
    var grid = U.h('div', { class: 'cards', role: 'listbox', aria: { label: 'Stili' } });
    var cardsScroll = U.h('div', { class: 'cards-wrap scroll' }, [grid]);
    var empty = U.h('div', { class: 'cards-empty', text: 'Nessuno stile in questa categoria', hidden: true });
    cardsScroll.appendChild(empty);
    var left = U.h('div', { class: 'col' }, [hero, U.h('div', { class: 'theme-body' }, [catsEl, cardsScroll])]);

    /* Carte a FINESTRA: nel DOM solo le righe visibili +- BUF righe (spaziatori sopra/sotto per l'altezza). Una carta (e la sua mini onda SVG)
       nasce solo quando la sua riga entra nella finestra; cambio categoria = si rifa' solo la lista. */
    var PITCH = 84, ROWH = 76, GAP = 8, BUF = 3, FALLBACK_VH = 480, FALLBACK_COLS = 3;
    var built = { sig: '', cache: {}, chips: {} }, list = [], win = { r0: -1, r1: -2 }, cols = FALLBACK_COLS;
    var lastStyle = null, lastCat = null, hoverId = null, active = false, curId = null, picked = false, userScrolled = false, keepCat = null;
    var spTop = U.h('div', { class: 'cards-sp', 'aria-hidden': 'true' }), spBot = U.h('div', { class: 'cards-sp', 'aria-hidden': 'true' });

    function catName(s, id) { for (var i = 0; i < s.cats.length; i++) if (s.cats[i].id === id) return s.cats[i].name; return ''; }
    function setHero(s, id, isPreview) {
      var st = null; for (var i = 0; i < s.styles.length; i++) if (s.styles[i].id === id) st = s.styles[i];
      st = st || GW.state.currentStyle(s);
      var tk = s.effectiveMode === 'light' ? st.light : st.dark;
      hero.style.setProperty('--hero-grad', GW.theme.gradientCss(tk.grad, 90));
      hero.style.setProperty('--hero-on', GW.theme.onAccent(tk));
      heroN.textContent = st.name;
      heroS.textContent = (isPreview ? 'Anteprima · ' : 'Stile attuale · ') + catName(s, st.cat);
    }
    /* categorie (chip) + dati: si rifanno solo se cambiano stili/categorie/asset */
    function buildData(s) {
      var sig = s.styles.map(function (x) { return x.id + x.name + x.cat; }).join('|') + '#' + s.cats.map(function (c) { return c.id + c.name; }).join('|') + '#' + JSON.stringify(s.assets);
      if (sig === built.sig) return;
      built.sig = sig; built.cache = {}; built.chips = {}; U.clear(catsEl);
      var counts = { all: s.styles.length };
      s.styles.forEach(function (st) { counts[st.cat] = (counts[st.cat] || 0) + 1; });
      s.cats.forEach(function (c) {
        var ch = UI.chip({ id: c.id, name: c.name, icon: O.CAT_ICONS[c.id] || 'catAll', count: counts[c.id] || 0, onClick: function (id) { A.setCat(id); } });
        ch.el.classList.add('cat'); built.chips[c.id] = ch; catsEl.appendChild(ch.el);
      });
      keepCat = lastCat; lastCat = null; win = { r0: -1, r1: -2 };       // dati rifatti: se la categoria e' la stessa si resta dove si e'
    }
    function getCard(s, st) {
      var el = built.cache[st.id];
      if (!el) {
        el = built.cache[st.id] = UI.card(st, s.assets, function (id) { picked = true; A.set('style', id); });
        if (st.id === curId) UI.cardSetCurrent(el, true);
      }
      return el;
    }
    function layoutCols() {
      var w = grid.clientWidth;
      cols = w > 0 ? Math.max(1, Math.floor((w - 6 + GAP) / (84 + GAP))) : FALLBACK_COLS;
      grid.style.setProperty('--cols', String(cols));
    }
    function viewH() { return cardsScroll.clientHeight || FALLBACK_VH; }
    /* ricostruisce il contenuto della griglia per la finestra di righe corrente (force = anche se la finestra e' uguale) */
    function renderWindow(force) {
      var s = S.get(), rows = Math.ceil(list.length / cols);
      var vh = viewH(), top = Math.min(Math.max(0, cardsScroll.scrollTop - 3), Math.max(0, rows * PITCH - vh));
      var r0 = Math.max(0, Math.floor(top / PITCH) - BUF), r1 = Math.min(rows - 1, Math.floor((top + vh) / PITCH) + BUF);
      if (!force && r0 === win.r0 && r1 === win.r1) return;
      win = { r0: r0, r1: r1 };
      var frag = root.document.createDocumentFragment();
      if (r0 > 0) { spTop.style.height = (r0 * PITCH - GAP) + 'px'; frag.appendChild(spTop); }
      for (var i = r0 * cols; i <= Math.min(list.length - 1, (r1 + 1) * cols - 1); i++) frag.appendChild(getCard(s, list[i]));
      if (r1 < rows - 1) { spBot.style.height = ((rows - 1 - r1) * PITCH - GAP) + 'px'; frag.appendChild(spBot); }
      U.clear(grid); grid.appendChild(frag);
      grid.dataset.count = String(list.length); grid.dataset.rendered = String(grid.querySelectorAll('.card').length);
    }
    function curIndex() { for (var i = 0; i < list.length; i++) if (list[i].id === curId) return i; return -1; }
    function scrollToRow(idx, center) {
      if (idx < 0) { cardsScroll.scrollTop = 0; return; }
      var y = Math.floor(idx / cols) * PITCH, vh = viewH();
      cardsScroll.scrollTop = Math.max(0, center ? y - (vh - ROWH) / 2 : y);
    }
    /* nuova lista (categoria cambiata / prima apertura): filtra, mette a posto le colonne, porta la carta corrente in vista */
    function applyList(s) {
      var cat = s.ui.cat;
      list = s.styles.filter(function (st) { return cat === 'all' || st.cat === cat; });
      empty.hidden = list.length > 0;
      layoutCols();
      var idx = curIndex();
      if (keepCat === cat && userScrolled) cardsScroll.scrollTop = Math.min(cardsScroll.scrollTop, Math.max(0, Math.ceil(list.length / cols) * PITCH - viewH()));
      else { userScrolled = false; scrollToRow(idx, true); }
      keepCat = null;
      renderWindow(true);
      Object.keys(built.chips).forEach(function (id) { built.chips[id].set(id === cat); });
      lastCat = cat;
    }
    function syncCur(s) {
      var id = GW.state.currentStyle(s).id;
      if (id === curId) return;
      var old = built.cache[curId], nu = built.cache[id]; curId = id;
      if (old) UI.cardSetCurrent(old, false);
      if (nu) UI.cardSetCurrent(nu, true);
    }
    cardsScroll.addEventListener('scroll', function () { if (active) renderWindow(false); }, { passive: true });
    ['wheel', 'pointerdown', 'keydown', 'touchstart'].forEach(function (ev) { cardsScroll.addEventListener(ev, function () { userScrolled = true; }, { passive: true }); });
    /* la finestra cambia misura (resize dell'host): colonne e righe visibili cambiano; se l'utente non ha ancora scorso si ricentra la carta corrente */
    if (root.ResizeObserver) new root.ResizeObserver(function () {
      if (!active) return; var c = cols; layoutCols();
      if (!userScrolled) scrollToRow(curIndex(), true);
      renderWindow(c !== cols);
    }).observe(cardsScroll);
    grid.addEventListener('pointerover', function (e) {
      var c = e.target.closest && e.target.closest('.card'); var id = c ? c.dataset.id : null;
      if (id === hoverId) return; hoverId = id; setHero(S.get(), id || S.get().look.style, !!id && id !== S.get().look.style);
    });
    grid.addEventListener('pointerleave', function () { if (hoverId) { hoverId = null; var s = S.get(); setHero(s, s.look.style, false); } });

    /* ---------- controlli (colonna destra) ---------- */
    var C = {};
    function seg(key, size, label) { return UI.segmented({ items: SC[key].choices, value: SC[key].def, size: size, label: label || SC[key].section, onChange: function (v) { A.set(key, v); } }); }
    function sl(key, label) {
      var d = SC[key];
      return UI.slider({ icon: d.icon, label: label || d.label, min: d.min, max: d.max, value: d.uiDef || d.def,
        onInput: function (v) { A.setLive(key, v); }, onCommit: function () { A.flush(key); } });
    }
    function cs(title, icon, kids) { return U.h('div', { class: 'csec' }, [UI.sec(title, icon)].concat(kids)); }

    C.mode = seg('themeMode');
    C.shadow = UI.switchRow({ icon: 'shadow', label: 'Ombra attiva', checked: true, onChange: function (v) { A.set('shadowOn', v); } });
    C.shadowI = sl('shadowIntensity');
    C.glow = UI.switchRow({ icon: 'glow', label: 'Alone accento', checked: false, onChange: function (v) { A.set('glowOn', v); } });
    C.shadowSep = UI.sep(); C.glowSep = UI.sep();
    C.glass = sl('glassOpacity');
    C.corner = seg('cornerStyle', 'sm');
    C.wave = seg('waveStyle', 'sm'); C.wcol = seg('waveColor');
    C.pulse = sl('micPulse');
    C.anim = UI.switchRow({ icon: 'sine2', label: 'Animazioni attive', checked: true, onChange: function (v) { A.set('animOn', v); } });
    C.speed = seg('animSpeed', 'xs'); C.speedWrap = U.h('div', { style: { padding: '0 10px 10px' } }, [C.speed.el]); C.speedSep = UI.sep();
    C.ui = seg('uiFont', 'sm'); C.timer = seg('timerFont', 'sm'); C.dens = seg('density'); C.idle = sl('idleOpacity');
    C.material = seg('material');

    var armTimer = 0;
    C.random = U.h('button', { class: 'btn primary press', type: 'button', on: { click: function () { A.randomLook(); } } }, [GW.icons.make('sparkle', 15), U.h('span', { text: 'Sorprendimi' })]);
    C.resetLbl = U.h('span', { text: 'Reset look' });
    C.reset = U.h('button', { class: 'btn soft press', type: 'button', on: { click: function () {
      if (armTimer) { clearTimeout(armTimer); armTimer = 0; setArmed(false); A.resetLook(); return; }
      setArmed(true); armTimer = setTimeout(function () { armTimer = 0; setArmed(false); }, 3000);
    } } }, [GW.icons.make('reset', 14), C.resetLbl]);
    function setArmed(v) { C.reset.classList.toggle('is-armed', v); C.resetLbl.textContent = v ? 'Confermi?' : 'Reset look'; }

    var controlsInner = U.h('div', { class: 'inner-c' }, [
      cs('MODO', 'auto', [C.mode.el]),
      cs('OMBRA E ALONE', 'shadow', [UI.box([C.shadow.el, C.shadowSep, C.shadowI.el, C.glowSep, C.glow.el])]),
      cs('VETRO', 'glass', [UI.box([C.glass.el])]),
      cs('ANGOLI', 'cornerMd', [C.corner.el]),
      cs('ONDA', 'wvBars', [C.wave.el, C.wcol.el]),
      cs('PULSAZIONE MIC', 'micPulse', [UI.box([C.pulse.el])]),
      cs('ANIMAZIONI', 'sine2', [UI.box([C.anim.el, C.speedSep, C.speedWrap])]),
      cs('TESTO', 'aa', [C.ui.el]),
      cs('TIMER', 'clock', [C.timer.el]),
      cs('DENSITÀ', 'rowsN', [C.dens.el]),
      cs('HUD A RIPOSO', 'ghost', [UI.box([C.idle.el])]),
      cs('MATERIALE', 'matSolid', [C.material.el]),
      U.h('div', { class: 'actions' }, [C.random, C.reset])
    ]);
    var controls = U.h('div', { class: 'controls scroll' }, [controlsInner]);
    var pvHead = UI.sec('ANTEPRIMA', 'eye'); pvHead.style.marginBottom = '8px';
    var right = U.h('div', { class: 'col' }, [pvHead, preview.el, controls]);
    var el = U.h('div', { class: 'pane-theme' }, [left, right]);

    function update(s) {
      buildData(s);
      var L = s.look;
      if (active) {
        if (lastCat !== s.ui.cat) { curId = GW.state.currentStyle(s).id; Object.keys(built.cache).forEach(function (id) { UI.cardSetCurrent(built.cache[id], id === curId); }); applyList(s); lastStyle = L.style; }
        else if (lastStyle !== L.style) {
          syncCur(s); lastStyle = L.style;
          if (!picked) { var ix = curIndex(); if (ix >= 0) { var rr = Math.floor(ix / cols) * PITCH; if (rr < cardsScroll.scrollTop || rr + ROWH > cardsScroll.scrollTop + viewH()) { scrollToRow(ix, true); renderWindow(false); } } }
        }
        picked = false;
      }
      if (!hoverId) setHero(s, L.style, false);
      C.mode.set(L.themeMode);
      C.shadow.set(L.shadowOn, L.shadowOn ? 'Ombra attiva' : 'Ombra disattivata');
      C.shadowI.el.hidden = C.shadowSep.hidden = !L.shadowOn;
      C.shadowI.set(L.shadowIntensity);
      C.glow.set(L.glowOn, L.glowOn ? 'Alone accento attivo' : 'Alone accento');
      C.glass.set(L.glassOpacity > 0 ? L.glassOpacity : SC.glassOpacity.uiDef);
      C.corner.set(L.cornerStyle); C.wave.set(L.waveStyle);
      C.wcol.set(GW.preview.waveGradientOn(L, GW.state.currentStyle(s), s.effectiveMode) ? 'gradient' : 'accent');
      C.pulse.set(L.micPulse);
      C.anim.set(L.animOn, L.animOn ? 'Animazioni attive' : 'Animazioni disattivate');
      C.speedWrap.hidden = C.speedSep.hidden = !L.animOn; C.speed.set(L.animSpeed);
      C.ui.set(L.uiFont); C.timer.set(L.timerFont); C.dens.set(L.density); C.idle.set(L.idleOpacity); C.material.set(L.material);
      preview.update(s);
    }
    update(S.get());
    return { el: el, update: update, inner: controlsInner,
      natural: function () { return pvHead.offsetHeight + 8 + preview.el.offsetHeight + 12 + controlsInner.offsetHeight + 24; },
      setActive: function (v) {
        preview.setActive(v);
        if (v && !active) { active = true; lastCat = null; update(S.get()); }       // prima apertura (o riapertura): categoria dello stile corrente + scroll alla carta
        else if (!v) active = false;
      } };
  }
  GW.tabs.theme = { create: create };
})(typeof globalThis !== 'undefined' ? globalThis : this);
