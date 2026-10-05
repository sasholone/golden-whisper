/* theme.js - token dello stile -> CSS custom properties sul :root. Funzioni di colore pure (testabili senza DOM). */
(function (root) {
  'use strict';
  var GW = root.GW || (root.GW = {});
  var U = GW.util || require('./util.js');
  var O = GW.options || require('./options.js');

  function rgb(hex) { var n = parseInt(hex.slice(1), 16); return [(n >> 16) & 255, (n >> 8) & 255, n & 255]; }
  function toHex(c) { return '#' + c.map(function (v) { return ('0' + Math.round(U.clamp(v, 0, 255)).toString(16)).slice(-2); }).join(''); }
  function rgba(hex, a) { var c = rgb(hex); return 'rgba(' + c[0] + ',' + c[1] + ',' + c[2] + ',' + (Math.round(a * 1000) / 1000) + ')'; }
  function mix(a, b, t) { var x = rgb(a), y = rgb(b); return toHex([x[0] + (y[0] - x[0]) * t, x[1] + (y[1] - x[1]) * t, x[2] + (y[2] - x[2]) * t]); }
  function lum(hex) {
    var c = rgb(hex).map(function (v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  }
  function contrast(a, b) { var x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); }

  /* Testo SU riempimento accento: bianco o inchiostro scuro, vince il contrasto minimo piu' alto su accento + stop del gradiente. */
  function onAccent(tk) {
    var fills = [tk.accent].concat(tk.grad);
    function minC(c) { return Math.min.apply(null, fills.map(function (f) { return contrast(c, f); })); }
    var ink = mix(tk.bg2, '#000000', 0.82);
    return minC('#ffffff') >= minC(ink) ? '#ffffff' : ink;
  }
  /* Accento usato COME TESTO su sfondo del pannello: schiarito (dark) / scurito (light) fino a un contrasto leggibile. */
  function accentInk(tk, dark) {
    var c = tk.accent;
    for (var i = 0; i < 8; i++) {
      if (dark ? lum(c) >= 0.33 : lum(c) <= 0.17) break;
      c = dark ? mix(c, '#ffffff', 0.15) : mix(c, '#000000', 0.14);
    }
    return c;
  }

  var FONTS = {
    sf: '-apple-system, system-ui, sans-serif',                    // SF
    rounded: 'ui-rounded, -apple-system, system-ui, sans-serif',  // SF Rounded
    mono: 'ui-monospace, monospace'
  };
  var DEFAULT_GLASS = 0.95;          // alpha di default dei due toni del vetro (Lua: 0.95 / 0.97)

  function gradientCss(list, angle) { return 'linear-gradient(' + (angle === undefined ? 90 : angle) + 'deg,' + list.join(',') + ')'; }
  function radiusPx(v, corner) { return Math.max(1.5, Math.round(v * (O.RADIUS_MUL[corner] || 1) * 10) / 10); }


  /* MATERIALE del pannello Impostazioni: 'solid' (default, robusto: pannello quasi opaco, bordo accento, ombre statiche a 2 strati, controlli con
     bordo netto e testo piu' contrastato) oppure 'glass' (morbido: come prima). Cambia SOLO l'aspetto della finestra, mai l'anteprima HUD (--bg1/--bg2 restano il vetro vero). */
  var MATERIALS = ['solid', 'glass'];
  var NO_SHADOW = '0 0 0 0 transparent';
  function materialOf(look) { return look && look.material === 'glass' ? 'glass' : 'solid'; }
  function applyMaterial(v, tk, dark, look) {
    var m = materialOf(look), k = dark ? 1 : 0.55, solid = m === 'solid';
    var blk = function (a) { return 'rgba(0,0,0,' + (Math.round(a * k * 1000) / 1000) + ')'; };
    var ga = look.glassOpacity > 0 ? U.clamp(look.glassOpacity, 0.5, 1) : DEFAULT_GLASS;
    var edge = rgba(tk.fg, dark ? 0.20 : 0.17);
    v['--panel-1'] = solid ? rgba(tk.bg1, 0.97) : rgba(tk.bg1, ga);
    v['--panel-2'] = solid ? rgba(tk.bg2, 0.985) : rgba(tk.bg2, Math.min(1, ga + 0.02));
    v['--panel-border'] = solid ? v['--border'] : v['--border-soft'];
    v['--panel-blur'] = solid ? 'blur(14px) saturate(1.2)' : 'blur(24px) saturate(1.4)';
    v['--r-panel'] = radiusPx(solid ? 20 : 16, look.cornerStyle) + 'px';
    v['--r-l'] = radiusPx(solid ? 14 : 16, look.cornerStyle) + 'px';
    v['--sheen'] = solid ? 'rgba(255,255,255,0)' : v['--sheen'];
    v['--hi'] = dark ? 'rgba(255,255,255,0.22)' : 'rgba(255,255,255,0.9)';
    v['--hi-soft'] = solid ? (dark ? 'rgba(255,255,255,0.07)' : 'rgba(255,255,255,0.7)') : 'rgba(255,255,255,0)';
    v['--edge'] = solid ? edge : v['--divider'];
    v['--ring-ctrl'] = solid ? 'inset 0 0 0 1px ' + edge : NO_SHADOW;
    v['--bw'] = solid ? '1px' : '0px';
    if (solid) {
      v['--row'] = rgba(tk.fg, dark ? 0.07 : 0.06); v['--row-hover'] = rgba(tk.fg, dark ? 0.12 : 0.10);
      v['--track'] = rgba(tk.fg, dark ? 0.20 : 0.16); v['--divider'] = rgba(tk.fg, dark ? 0.15 : 0.13);
      v['--fg2'] = mix(tk.fg2, tk.fg, 0.2); v['--fg3'] = mix(tk.fg2, tk.bg2, dark ? 0.22 : 0.12);
    }
    v['--seg-track'] = solid ? (dark ? 'rgba(0,0,0,0.30)' : rgba(tk.fg, 0.10)) : v['--track'];
    v['--seg-inset'] = solid ? 'inset 0 1px 2px ' + blk(0.32) : NO_SHADOW;
    v['--sh-contact'] = solid ? '0 1px 2px ' + blk(0.30) : NO_SHADOW;
    v['--sh-panel'] = solid ? '0 22px 50px ' + blk(0.30) + ', 0 2px 6px ' + blk(0.34) : '0 20px 50px ' + blk(0.28);
    v['--sh-pop'] = solid ? '0 10px 24px ' + blk(0.32) + ', 0 1px 3px ' + blk(0.40) : '0 8px 20px ' + blk(0.30);
    v['--sh-knob'] = solid ? '0 1px 3px rgba(0,0,0,0.55), 0 0 0 1px rgba(0,0,0,0.20)' : '0 1px 2px rgba(0,0,0,0.35)';
    v['--knob-edge'] = solid ? 'rgba(0,0,0,0.30)' : 'rgba(0,0,0,0.20)';
    v['--pill-shadow'] = solid ? 'inset 0 1px 0 rgba(255,255,255,' + (dark ? 0.20 : 0.32) + '), 0 1px 3px ' + blk(0.45) + ', 0 0 0 1px rgba(0,0,0,' + (dark ? 0.20 : 0.14) + ')' : NO_SHADOW;
    v['--btn-edge'] = solid ? v['--border'] : v['--border-soft'];
    v['--hero-edge'] = solid ? 'rgba(0,0,0,' + (dark ? 0.24 : 0.14) + ')' : 'rgba(0,0,0,0)';
    v['--sw-ring'] = solid ? 'inset 0 0 0 1px rgba(0,0,0,0.22)' : NO_SHADOW;
    v['--pv-bg'] = solid ? 'var(--row)' : 'linear-gradient(160deg, var(--accent-faint), transparent 70%), var(--row)';
    v['--rng-h'] = solid ? '6px' : '5px';
    v['--fw-title'] = solid ? '700' : '650'; v['--fw-lbl'] = '600';
    v['--fs-base'] = solid ? '12.5px' : '13px'; v['--fs-lbl'] = solid ? '12.5px' : '13px';
    v['--fs-sec'] = solid ? '10px' : '10.5px'; v['--ls-sec'] = solid ? '.9px' : '.7px'; v['--row-h'] = solid ? '38px' : '40px';
    return v;
  }

  /* Mappa nome-variabile -> valore, per stile + modo + look. Pura. */
  function tokens(style, mode, look) {
    var dark = mode !== 'light';
    var tk = dark ? style.dark : style.light;
    var g = tk.grad.slice();
    var ga = look.glassOpacity > 0 ? U.clamp(look.glassOpacity, 0.5, 1) : DEFAULT_GLASS;
    var a2 = Math.min(1, ga + 0.02);
    var fg3 = mix(tk.fg2, tk.bg2, dark ? 0.40 : 0.25);
    var ink = accentInk(tk, dark);
    var v = {
      '--bg1': rgba(tk.bg1, ga), '--bg2': rgba(tk.bg2, a2), '--bg1-solid': tk.bg1, '--bg2-solid': tk.bg2,
      '--fg': tk.fg, '--fg2': tk.fg2, '--fg3': fg3,
      '--accent': tk.accent, '--accent-ink': ink, '--on-accent': onAccent(tk),
      '--g1': g[0], '--g2': g[1] || g[0], '--g3': g[2] || g[g.length - 1], '--g4': g[3] || g[g.length - 1],
      '--grad': gradientCss(g, 90), '--grad-diag': gradientCss(g, 135),
      '--accent-soft': rgba(tk.accent, dark ? 0.20 : 0.15), '--accent-faint': rgba(tk.accent, dark ? 0.10 : 0.08),
      '--border': rgba(tk.accent, dark ? 0.36 : 0.42), '--border-soft': rgba(tk.accent, dark ? 0.18 : 0.24),
      '--row': rgba(tk.fg, dark ? 0.05 : 0.045), '--row-hover': rgba(tk.fg, dark ? 0.10 : 0.085),
      '--track': rgba(tk.fg, dark ? 0.13 : 0.11), '--divider': rgba(tk.fg, dark ? 0.10 : 0.09),
      '--warn': dark ? '#ff5c54' : '#d93025', '--ok': dark ? '#4ade80' : '#12904a',
      '--glass-alpha': String(ga),
      '--r-xs': radiusPx(6, look.cornerStyle) + 'px', '--r-s': radiusPx(9, look.cornerStyle) + 'px', '--r-m': radiusPx(12, look.cornerStyle) + 'px',
      '--r-l': radiusPx(16, look.cornerStyle) + 'px', '--r-pill': look.cornerStyle === 'square' ? '4px' : look.cornerStyle === 'medium' ? '12px' : '999px',
      '--font-ui': FONTS[look.uiFont] || FONTS.sf, '--font-timer': FONTS[look.timerFont] || FONTS.mono,
      '--density': String(O.DENS[look.density] || 1), '--idle-opacity': String(look.idleOpacity),
      '--shadow-k': dark ? '1' : '0.55', '--r-hud': radiusPx(26, look.cornerStyle) + 'px',
      '--warn-soft': rgba(dark ? '#ff5c54' : '#d93025', 0.14), '--warn-soft2': rgba(dark ? '#ff5c54' : '#d93025', 0.24),
      '--ok-soft': rgba(dark ? '#4ade80' : '#12904a', 0.24), '--bubble-bg': mix(tk.bg2, tk.accent, 0.07)
    };
    v['--sheen'] = dark ? 'rgba(255,255,255,0.035)' : 'rgba(255,255,255,0.28)';
    return applyMaterial(v, tk, dark, look);
  }

  /* Variabili per carta stile: entrambi i modi, cosi' il cambio dark/light non costa nulla in JS (si sceglie via [data-mode]). */
  function cardVars(style) {
    return { '--gd': gradientCss(style.dark.grad, 90), '--gl': gradientCss(style.light.grad, 90), '--ond': onAccent(style.dark), '--onl': onAccent(style.light),
      '--ad': style.dark.accent, '--al': style.light.accent };
  }

  var lastSig = '';
  /* Applica i token al documento. Salta se nulla e' cambiato (evita ricalcolo stile). */
  function apply(state, el) {
    el = el || (typeof document !== 'undefined' ? document.documentElement : null);
    var style = GW.state.currentStyle(state);
    var v = tokens(style, state.effectiveMode, state.look);
    var sig = state.effectiveMode + '|' + JSON.stringify(v);
    if (sig === lastSig) return v;
    lastSig = sig;
    if (el) {
      for (var k in v) el.style.setProperty(k, v[k]);
      el.dataset.mode = state.effectiveMode;
      el.dataset.material = materialOf(state.look);
      el.dataset.shadow = state.look.shadowOn ? '1' : '0';
      el.dataset.glow = state.look.glowOn ? '1' : '0';
      el.dataset.anim = state.look.animOn ? '1' : '0';
      el.style.setProperty('color-scheme', state.effectiveMode);
    }
    return v;
  }

  GW.theme = { MATERIALS: MATERIALS, materialOf: materialOf, rgb: rgb, rgba: rgba, mix: mix, lum: lum, contrast: contrast, onAccent: onAccent, accentInk: accentInk, tokens: tokens, cardVars: cardVars,
    apply: apply, FONTS: FONTS, DEFAULT_GLASS: DEFAULT_GLASS, gradientCss: gradientCss, radiusPx: radiusPx };
  if (typeof module !== 'undefined') module.exports = GW.theme;
})(typeof globalThis !== 'undefined' ? globalThis : this);
