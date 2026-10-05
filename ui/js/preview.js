/* preview.js - anteprima viva e leggera dell'HUD.
   Onda su <canvas> 2D a <= 30 Hz; il badge pulsa con transform. Il loop gira SOLO se: mouse sopra l'anteprima + finestra visibile +
   tab Tema attivo + animazioni attive + niente prefers-reduced-motion. Altrimenti niente rAF (cancelAnimationFrame): un solo disegno statico. */
(function (root) {
  'use strict';
  var GW = root.GW || (root.GW = {});

  /* --- parti pure (testabili) --- */
  function barCount(style, w) { return style === 'thin' ? Math.floor(w / 4) : style === 'dots' ? Math.floor(w / 7) : style === 'line' ? 40 : Math.floor(w / 5.6); }
  /* ampiezze 0..1 per n barre. t = secondi (null = posa statica), speed = moltiplicatore durata (>1 piu' lento). */
  function levels(n, t, speed) {
    var out = [];
    for (var i = 0; i < n; i++) {
      var env = Math.sin(Math.PI * (i + 0.5) / n);                         // piu' alte al centro
      if (t === null) out.push(0.18 + 0.72 * Math.abs(Math.sin(i * 0.83 + 0.55)) * (0.55 + 0.45 * env));
      else {
        var ph = t / (speed || 1);
        var v = 0.5 + 0.5 * Math.sin(ph * 5.2 + i * 0.7) * Math.cos(ph * 2.3 + i * 0.23);
        out.push(0.12 + 0.88 * v * (0.45 + 0.55 * env));
      }
    }
    return out;
  }
  function waveGradientOn(look, style, mode) {
    if (look.waveColor === 'gradient') return true;
    if (look.waveColor === 'accent') return false;
    return (mode === 'light' ? style.light : style.dark).grad.length > 2;
  }
  function fmtTime(sec) { sec = Math.max(0, Math.floor(sec)); return ('0' + Math.floor(sec / 60)).slice(-2) + ':' + ('0' + (sec % 60)).slice(-2); }
  function hudShadow(look, accent, rgba) {
    var parts = [], i = look.shadowIntensity, k = look.shadowOn ? 1 : 0;
    if (k) parts.push('0 ' + Math.round(6 + 12 * i) + 'px ' + Math.round(14 + 26 * i) + 'px rgba(0,0,0,' + (0.16 + 0.42 * i).toFixed(2) + ')');
    if (look.glowOn) parts.push('0 0 ' + Math.round(16 + 12 * i) + 'px ' + rgba(accent, 0.42));
    return parts.length ? parts.join(',') : 'none';
  }

  function create(ctx) {
    var U = GW.util, S = ctx.store;
    var canvas = U.h('canvas', { class: 'hud-wave', aria: { hidden: 'true' } });
    var c2d = canvas.getContext ? canvas.getContext('2d') : null;
    var badge = U.h('div', { class: 'hud-badge' });
    var timer = U.h('span', { class: 'hud-timer', text: '00:07' });
    var hud = U.h('div', { class: 'hud' }, [badge, canvas, timer]);
    var el = U.h('div', { class: 'pv', role: 'img', aria: { label: 'Anteprima dell’HUD' } }, [hud, U.h('span', { class: 'pv-hint', text: 'passa il mouse per animare' })]);

    el.dataset.running = '0';
    var hover = false, active = false, raf = 0, last = 0, t0 = 0, dirty = false, lastIcon = '#', dpr = 1, cw = 0, chh = 0;
    var reduce = root.matchMedia && root.matchMedia('(prefers-reduced-motion: reduce)');

    function colors(s) {
      var st = GW.state.currentStyle(s), tk = s.effectiveMode === 'light' ? st.light : st.dark;
      var useG = waveGradientOn(s.look, st, s.effectiveMode);
      return { st: st, tk: tk, useG: useG };
    }
    function fit() {
      var r = canvas.getBoundingClientRect(); dpr = Math.min(2, root.devicePixelRatio || 1);
      var w = Math.max(40, Math.round(r.width || 100)), h = Math.max(16, Math.round(r.height || 30));
      if (w !== cw || h !== chh) { cw = w; chh = h; canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr); }
    }
    function draw(t) {
      if (!c2d) return;
      var s = S.get(); fit();
      var C = colors(s), kind = (C.st.fx && C.st.fx.bar) || 'round', style = s.look.waveStyle;
      c2d.setTransform(dpr, 0, 0, dpr, 0, 0); c2d.clearRect(0, 0, cw, chh);
      var fill;
      if (C.useG && C.tk.grad.length > 1) { fill = c2d.createLinearGradient(0, 0, cw, 0); C.tk.grad.forEach(function (g, i) { fill.addColorStop(i / (C.tk.grad.length - 1), g); }); } else fill = C.tk.accent;
      c2d.fillStyle = fill; c2d.strokeStyle = fill; c2d.globalAlpha = kind === 'ghost' ? 0.55 : 1;
      var speed = O_SPEED[s.look.animSpeed] || 1;
      var n = barCount(style, cw), lv = levels(n, t, speed), pitch = cw / n, mid = chh / 2, maxH = chh - 2;
      if (style === 'line') {
        c2d.lineWidth = 2; c2d.lineJoin = 'round'; c2d.lineCap = 'round'; c2d.beginPath();
        for (var i = 0; i < n; i++) { var x = (i + 0.5) * pitch, y = mid + (lv[i] - 0.5) * (maxH * 0.9) * (i % 2 ? -1 : 1) * 0.9; if (i === 0) c2d.moveTo(x, y); else c2d.lineTo(x, y); }
        c2d.stroke();
      } else if (style === 'dots') {
        for (var j = 0; j < n; j++) { var cnt = Math.max(1, Math.round(lv[j] * 4)); for (var k = 0; k < cnt; k++) { var off = (k - (cnt - 1) / 2) * 6.2; c2d.beginPath(); c2d.arc((j + 0.5) * pitch, mid + off, 1.7, 0, 6.2832); c2d.fill(); } }
      } else {
        var bw = style === 'thin' ? 1.4 : Math.max(2, pitch * 0.55);
        for (var b = 0; b < n; b++) {
          var v = lv[b]; if (kind === 'pixel') v = Math.max(0.15, Math.round(v * 4) / 4);
          var hh = Math.max(3, v * maxH), x0 = (b + 0.5) * pitch - bw / 2, rad = kind === 'square' || kind === 'pixel' ? Math.min(0.8, bw / 2) : bw / 2;
          roundRect(c2d, x0, mid - hh / 2, bw, hh, rad);
        }
      }
      c2d.globalAlpha = 1;
    }
    function roundRect(g, x, y, w, h, r) {
      g.beginPath(); g.moveTo(x + r, y); g.lineTo(x + w - r, y); g.arcTo(x + w, y, x + w, y + r, r); g.lineTo(x + w, y + h - r); g.arcTo(x + w, y + h, x + w - r, y + h, r);
      g.lineTo(x + r, y + h); g.arcTo(x, y + h, x, y + h - r, r); g.lineTo(x, y + r); g.arcTo(x, y, x + r, y, r); g.closePath(); g.fill();
    }

    function shouldRun() {
      var s = S.get();
      return hover && active && s.look.animOn && !(reduce && reduce.matches) && !(root.document && root.document.hidden);
    }
    function frame(ts) {
      raf = 0;
      if (!shouldRun()) { settle(); return; }
      raf = root.requestAnimationFrame(frame);
      if (ts - last < 33) return;                                         // <= ~30 Hz
      last = ts; var t = (ts - t0) / 1000, s = S.get();
      draw(t);
      var env = 0.5 + 0.5 * Math.sin(t * 6.1 / (O_SPEED[s.look.animSpeed] || 1));
      badge.style.transform = 'scale(' + (1 + s.look.micPulse * 0.14 * env).toFixed(3) + ')';
      timer.textContent = fmtTime(7 + t);
    }
    function settle() { el.dataset.running = '0'; badge.style.transform = ''; timer.textContent = '00:07'; draw(null); }
    function start() { if (!raf && shouldRun()) { el.dataset.running = '1'; t0 = performance.now(); last = 0; raf = root.requestAnimationFrame(frame); } }
    function stop() { if (raf) { root.cancelAnimationFrame(raf); raf = 0; settle(); } }
    function sync() { if (shouldRun()) start(); else stop(); }
    function scheduleDraw() { if (dirty || raf) return; dirty = true; root.requestAnimationFrame(function () { dirty = false; if (!raf) draw(null); }); }

    el.addEventListener('pointerenter', function () { hover = true; sync(); });
    el.addEventListener('pointerleave', function () { hover = false; sync(); });
    root.document && root.document.addEventListener('visibilitychange', sync);
    root.addEventListener('blur', function () { hover = false; sync(); });
    var O_SPEED = GW.options.SPEED_MUL;

    function update(s) {
      var C = colors(s);
      el.style.setProperty('--hud-shadow', hudShadow(s.look, C.tk.accent, GW.theme.rgba));
      var icon = s.assets[C.st.id] && s.assets[C.st.id].icon || '';
      if (icon !== lastIcon) {
        lastIcon = icon; U.clear(badge);
        badge.appendChild(icon ? U.h('img', { src: icon, alt: '', draggable: 'false' }) : GW.icons.make('mic', 18, { sw: 1.8 }));
      }
      scheduleDraw(); sync();
    }
    update(S.get());
    return { el: el, update: update, setActive: function (v) { active = !!v; if (active) scheduleDraw(); sync(); }, redraw: scheduleDraw };
  }
  GW.preview = { create: create, levels: levels, barCount: barCount, waveGradientOn: waveGradientOn, fmtTime: fmtTime, hudShadow: hudShadow };
  if (typeof module !== 'undefined') module.exports = GW.preview;
})(typeof globalThis !== 'undefined' ? globalThis : this);
