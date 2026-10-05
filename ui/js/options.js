/* options.js - SCHEMA delle opzioni (chiavi del contratto, enum, default, icone) + sanificazione.
   Rispecchia config.LOOK.def / K.clean di src/groq_dictation.lua. Ogni opzione ha un'icona (test). */
(function (root) {
  'use strict';
  var GW = root.GW || (root.GW = {});
  var U = GW.util || require('./util.js');

  var VERSION_CONTRACT = 1;

  /* Operazioni JS -> Lua ammesse (contratto del ponte). */
  var OPS = ['ready', 'set', 'random_look', 'reset_look', 'pick_mic', 'refresh_devices', 'key_paste', 'key_remove', 'open_groq',
    'capture_start', 'capture_cancel', 'key_remove_binding', 'key_set_gesture', 'set_tab', 'close', 'drag_start', 'resize_request'];

  var SPEED_MUL = { calm: 1.7, normal: 1, lively: 0.65 };           // moltiplicatore durata (>1 = piu' lento)
  var RADIUS_MUL = { round: 1, medium: 0.55, square: 0.16 };
  var DENS = { compact: 0.72, normal: 1, wide: 1.22 };

  function ch(value, label, icon) { return { value: value, label: label, icon: icon }; }

  var SCHEMA = {
    look: {
      themeMode: { type: 'enum', def: 'dark', icon: 'auto', section: 'MODO',
        choices: [ch('dark', 'Dark', 'moon'), ch('light', 'Light', 'sun'), ch('auto', 'Auto', 'auto')] },
      shadowOn: { type: 'bool', def: true, icon: 'shadow', section: 'OMBRA E ALONE' },
      shadowIntensity: { type: 'num', min: 0, max: 1, def: 0.5, icon: 'shadow', label: 'Intensità' },
      glowOn: { type: 'bool', def: false, icon: 'glow', section: 'OMBRA E ALONE' },
      glassOpacity: { type: 'num0', min: 0.5, max: 1, def: 0, uiDef: 0.95, icon: 'glass', section: 'VETRO', label: 'Opacità' },
      cornerStyle: { type: 'enum', def: 'round', icon: 'cornerMd', section: 'ANGOLI',
        choices: [ch('square', 'Squadrati', 'cornerSq'), ch('medium', 'Medi', 'cornerMd'), ch('round', 'Tondi', 'cornerRd')] },
      waveStyle: { type: 'enum', def: 'bars', icon: 'wvBars', section: 'ONDA',
        choices: [ch('bars', 'Barre', 'wvBars'), ch('thin', 'Sottili', 'wvThin'), ch('dots', 'Punti', 'wvDots'), ch('line', 'Linea', 'wvLine')] },
      waveColor: { type: 'enum', def: 'auto', icon: 'dotGrad', section: 'ONDA',
        choices: [ch('accent', 'Accento', 'dotAcc'), ch('gradient', 'Gradiente', 'dotGrad')] },   // 'auto' valido ma non mostrato
      micPulse: { type: 'num', min: 0, max: 1, def: 0.5, icon: 'micPulse', section: 'PULSAZIONE MIC', label: 'Intensità' },
      animOn: { type: 'bool', def: true, icon: 'sine2', section: 'ANIMAZIONI' },
      animSpeed: { type: 'enum', def: 'normal', icon: 'sine2', section: 'ANIMAZIONI',
        choices: [ch('calm', 'Calme', 'sine1'), ch('normal', 'Normali', 'sine2'), ch('lively', 'Vivaci', 'sine3')] },
      uiFont: { type: 'enum', def: 'sf', icon: 'aa', section: 'TESTO',
        choices: [ch('sf', 'SF', 'aaSf'), ch('rounded', 'Arrotondato', 'aaRounded'), ch('mono', 'Mono', 'aaMono')] },
      timerFont: { type: 'enum', def: 'mono', icon: 'clock', section: 'TIMER',
        choices: [ch('mono', 'Mono', 'tnMono'), ch('sf', 'SF', 'tnSf'), ch('rounded', 'Arrotondato', 'tnRounded')] },
      density: { type: 'enum', def: 'normal', icon: 'rowsN', section: 'DENSITÀ',
        choices: [ch('compact', 'Compatta', 'rowsC'), ch('normal', 'Normale', 'rowsN'), ch('wide', 'Ampia', 'rowsW')] },
      idleOpacity: { type: 'num', min: 0.3, max: 1, def: 1, icon: 'ghost', section: 'HUD A RIPOSO', label: 'Opacità' },
      style: { type: 'style', def: 'gold', icon: 'palette', section: 'STILE' }
    },
    general: {
      sizePreset: { type: 'enum', def: 'standard', icon: 'sizeM', section: 'DIMENSIONE',
        choices: [ch('minimal', 'Minimal', 'sizeS'), ch('standard', 'Standard', 'sizeM'), ch('large', 'Grande', 'sizeL')] },
      orientation: { type: 'enum', def: 'horizontal', icon: 'orientH', section: 'ORIENTAMENTO',
        choices: [ch('horizontal', 'Orizzontale', 'orientH'), ch('vertical', 'Verticale', 'orientV')] }
    }
  };

  var LOOK_KEYS = Object.keys(SCHEMA.look);
  var GENERAL_KEYS = Object.keys(SCHEMA.general);

  var CAT_ICONS = { all: 'catAll', cl: 'catGem', fk: 'sparkle', nt: 'catLeaf', ne: 'catBolt', rt: 'catRetro', pp: 'catPop', st: 'catSnow' };
  var CATS_DEFAULT = [{ id: 'all', name: 'Tutti' }, { id: 'cl', name: 'Classici' }, { id: 'fk', name: 'Funky' }, { id: 'nt', name: 'Natura' },
    { id: 'ne', name: 'Neon' }, { id: 'rt', name: 'Retro' }, { id: 'pp', name: 'Pop' }, { id: 'st', name: 'Stagioni' }];
  var GESTURES = {
    ss: [ch('double', '2 tap'), ch('single', '1 tap'), ch('hold', 'hold')],
    pause: [ch('single', '1 tap'), ch('double', '2 tap')]
  };
  var KEY_STEPS = ['1) Premi «Prendi / crea la chiave»: si apre il sito Groq.',
    '2) Registrati (è gratis: bastano Google o email, nessuna carta).',
    '3) Premi «Create API Key», dai un nome qualsiasi e conferma.',
    '4) Copia la chiave (inizia con gsk_).',
    '5) Torna qui e premi «Incolla chiave».'];

  function schemaOf(key) { return SCHEMA.look[key] || SCHEMA.general[key] || null; }
  function scopeOf(key) { return SCHEMA.look[key] ? 'look' : SCHEMA.general[key] ? 'general' : null; }
  function defaultOf(key) { var s = schemaOf(key); return s ? s.def : undefined; }

  /* Valore valido per la chiave (invalido -> default). Come K.clean in Lua. */
  function clean(key, v) {
    var s = schemaOf(key); if (!s) return v;
    switch (s.type) {
      case 'enum':
        if (key === 'waveColor') return (v === 'accent' || v === 'gradient' || v === 'auto') ? v : s.def;
        for (var i = 0; i < s.choices.length; i++) if (s.choices[i].value === v) return v;
        return s.def;
      case 'bool': return U.asBool(v, s.def);
      case 'num': { var n = U.asNum(v); return U.clamp(n === null ? s.def : n, s.min, s.max); }
      case 'num0': { var m = U.asNum(v); if (m === null || m <= 0) return 0; return U.clamp(m, s.min, s.max); }
      case 'style': return (typeof v === 'string' && /^[a-z0-9_\-]{1,40}$/i.test(v)) ? v : s.def;
    }
    return v;
  }
  function defaultsLook() { var o = {}; LOOK_KEYS.forEach(function (k) { o[k] = SCHEMA.look[k].def; }); return o; }
  function defaultsGeneral() { var o = { micName: '', devices: [] }; GENERAL_KEYS.forEach(function (k) { o[k] = SCHEMA.general[k].def; }); return o; }

  /* Tutte le icone richieste dallo schema (per il test "ogni opzione ha un'icona"). */
  function requiredIcons() {
    var out = {};
    [SCHEMA.look, SCHEMA.general].forEach(function (grp) {
      Object.keys(grp).forEach(function (k) {
        var s = grp[k]; if (s.icon) out[s.icon] = 1;
        (s.choices || []).forEach(function (c) { if (c.icon) out[c.icon] = 1; });
      });
    });
    Object.keys(CAT_ICONS).forEach(function (k) { out[CAT_ICONS[k]] = 1; });
    return Object.keys(out);
  }

  GW.options = { VERSION_CONTRACT: VERSION_CONTRACT, OPS: OPS, SCHEMA: SCHEMA, LOOK_KEYS: LOOK_KEYS, GENERAL_KEYS: GENERAL_KEYS,
    SPEED_MUL: SPEED_MUL, RADIUS_MUL: RADIUS_MUL, DENS: DENS, CAT_ICONS: CAT_ICONS, CATS_DEFAULT: CATS_DEFAULT, GESTURES: GESTURES,
    KEY_STEPS: KEY_STEPS, schemaOf: schemaOf, scopeOf: scopeOf, defaultOf: defaultOf, clean: clean, defaultsLook: defaultsLook,
    defaultsGeneral: defaultsGeneral, requiredIcons: requiredIcons };
  if (typeof module !== 'undefined') module.exports = GW.options;
})(typeof globalThis !== 'undefined' ? globalThis : this);
