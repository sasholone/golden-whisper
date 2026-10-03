-- groq_dictation.lua  (Golden Whisper)
-- Dettatura vocale stile Whisper Flow per macOS.
-- Tasti configurabili (gesto: 1 tap / 2 tap / tieni premuto) dal menu Impostazioni.
-- Registra (ffmpeg) -> Groq Whisper -> incolla al cursore (+ resta in clipboard).
-- HUD trascinabile con hover, ombra, stili (gold/mono + light), orizzontale o verticale.

local M = {}

------------------------------------------------------------------------
-- CONFIG
------------------------------------------------------------------------
local config = {
  keyPath      = os.getenv("HOME") .. "/.config/groq-dictation/api_key",
  settingsPath = os.getenv("HOME") .. "/.config/groq-dictation/settings.lua",
  recDir       = os.getenv("HOME") .. "/.config/groq-dictation/recordings",
  workDir      = os.getenv("HOME") .. "/.config/groq-dictation/segments",
  historyPath  = os.getenv("HOME") .. "/.config/groq-dictation/history.json",
  historyMax   = 30,
  audioDevice  = ":0",
  language     = "it",
  model        = "whisper-large-v3-turbo",
  ffmpeg       = "/opt/homebrew/bin/ffmpeg",
  curl         = "/usr/bin/curl",
  kill         = "/bin/kill",
  ssBindings   = {},           -- lista {kc=, mod=} — più tasti che avviano/fermano (impostabili dal menu)
  ssGesture    = "double",     -- double | single | hold
  pauseBindings = {},          -- lista {kc=, mod=}
  pauseGesture = "single",     -- single | double
  -- default/back-compat (usati se non ci sono bindings salvati)
  startStopKeycode = 61, startStopFlag = "alt",
  pauseKeycode = 60, pauseFlag = "shift",
  doubleTapSec = 0.50,
  maxSegmentSec = 480,
  silenceWarnSec = 6,          -- nessun audio dal mic per N secondi → avviso
  silenceDb    = -70,          -- sotto questa soglia (dB RMS) conta come "nessun audio"
  micAutoFallback = true,      -- mic Bluetooth che resta muto dopo il ritentativo -> per QUESTA registrazione usa il mic del Mac (non cambia il mic salvato)
  restoreClipboard = false,
  autoUpdate   = true,
  updateCheckHours = 24,
  autoTranscribeRecovered = true,  -- audio salvato per errore/interruzione → ritrascritto in automatico
  recoveredRetryDone = {},         -- runtime: evita ritentativi in loop sugli stessi file
  git          = "/usr/bin/git",
  repoDir      = os.getenv("HOME") .. "/golden-whisper",
  sizePreset   = "standard",   -- standard | large | minimal
  orientation  = "horizontal", -- horizontal | vertical
  style        = "gold",       -- famiglia: gold | mono | ocean | violet | emerald | rose
  themeMode    = "dark",       -- dark | light | auto (auto segue il sistema)
  shadowOn     = true,         -- ombra della card on/off
  shadowIntensity = 0.5,       -- 0..1 = quanto lontano si estende l'ombra (0.5 = metà)
  scale        = 1.0,
  -- ---- LOOK (tab "Tema"): tutti retrocompatibili, il default = aspetto originale ----
  glassOpacity = nil,          -- 0.5..1 opacità del vetro (nil/0 = default del tema, ~0.95)
  cornerStyle  = "round",      -- round | medium | square
  animOn       = true,         -- animazioni/transizioni on/off
  layers       = true,         -- kill-switch: false = HUD e impostazioni su canvas singola (niente strati / scroll a immagine)
  animSpeed    = "normal",     -- calm | normal | lively
  waveStyle    = "bars",       -- bars | thin | dots | line
  waveColor    = nil,          -- accent | gradient (nil/auto = gradiente solo sugli stili multi-colore)
  micPulse     = 0.5,          -- 0..1 intensità anelli/pulsazione del mic (0.5 = originale)
  glowOn       = false,        -- alone accento attorno alle card
  uiFont       = "sf",         -- sf | rounded | mono (testo UI)
  timerFont    = "mono",       -- mono | sf | rounded
  density      = "normal",     -- compact | normal | wide
  idleOpacity  = 1.0,          -- 0.3..1 opacità dell'HUD quando il mouse non è sopra
}

------------------------------------------------------------------------
-- STATO
------------------------------------------------------------------------
local recording, paused, busy = false, false, false
local recTask, intent = nil, nil
local segments, segIndex = {}, 0
local elapsed, segStart = 0, nil
local levels = {}
local lastSoundAt, lastRmsAt, micWarned, micName = 0, 0, false, nil   -- rilevamento "mic muto"

local overlay, uiTimer, rotTimer, dragTap = nil, nil, nil, nil
local finalFrame, mode, RECIDX = nil, nil, nil
local procTextIdx = nil
local taps = {}
local hoverMap = {}     -- id -> {idx, fill, hoverFill, stroke, hoverStroke}  (overlay)

local placeCanvas, mouseCb, startDrag, pushShadow, pushGlass
local setRecordingElements, setProcessingElements, setStatus, updateUI
local showAnimated, hideAnimated, showRecordingHUD, stopUITimer
local openSettings, rebuildHUD, renderSettings, settingsMouse, closeSettings, dragCanvas
local startCapture, saveBindings, gwAlert

-- Modulo nativo opzionale (~/.hammerspoon/gw_sticky.so): tiene l'HUD fermo durante il cambio Space
-- (Ctrl+freccia) invece di farlo scorrere col desktop. Se manca, tutto funziona lo stesso.
local stickyOk, sticky = pcall(require, "gw_sticky")
if not stickyOk then sticky = nil end
local function pinOverlay()
  if sticky and overlay then
    local f = overlay:frame()
    pcall(sticky.pin, f.x, f.y, f.w, f.h)
  end
end
local settingsCanvas
local settingsDevices = {}
local sHoverMap = {}
local settingsPage = "general"   -- general | keys | theme
local openHistory, closeHistory, renderHistoryPanel, historyMouse
local historyCanvas
local hHoverMap = {}

------------------------------------------------------------------------
-- NUMERI SICURI. Lezione del bug NaN: una potenza con base negativa dava NaN, un errore nel
-- tick UI bloccava timer+onda+pulsazione. Regola: clamp prima di ^ / sqrt / log, e nessun
-- NaN/inf verso hs.canvas (finite()).
------------------------------------------------------------------------
local function finite(v, d)
  if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return d or 0 end
  return v
end
local function clampN(v, lo, hi)
  v = finite(v, lo)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end
local function spow(b, e)               -- potenza sicura: base < 0 → 0
  b = finite(b, 0); if b < 0 then b = 0 end
  return finite(b ^ e, 0)
end

------------------------------------------------------------------------
-- PALETTE / STILI  ("clear glass": rampe tonali per famiglia, dark + light)
-- Ogni tema ha: sfondo a due toni (top/bot), testo a 3 livelli, accento a 3 toni
-- (hi/base/lo per i gradienti), bordo + hairline, superfici (riga/hover/track),
-- stati (warn/ok). Tutto derivato da ~9 esadecimali per tema.
-- Gli stili "funky" hanno in più g = 3-4 colori: il gradiente multi-stop (onda, anelli,
-- pulsanti, interruttori, campioni, bordo).
------------------------------------------------------------------------
local function hex(h, a)
  h = h:gsub("#", "")
  return { red = tonumber(h:sub(1, 2), 16) / 255, green = tonumber(h:sub(3, 4), 16) / 255,
           blue = tonumber(h:sub(5, 6), 16) / 255, alpha = a or 1 }
end
local function withA(c, a) return { red = c.red, green = c.green, blue = c.blue, alpha = finite(a, 1) } end
local function mix(a, b, t)
  t = finite(t, 0)
  local aa, ba = a.alpha or 1, b.alpha or 1
  return { red = a.red + (b.red - a.red) * t, green = a.green + (b.green - a.green) * t,
           blue = a.blue + (b.blue - a.blue) * t, alpha = aa + (ba - aa) * t }
end
local CLEAR = { red = 0, green = 0, blue = 0, alpha = 0 }

-- colore lungo il gradiente del tema, t in 0..1
local function gradAt(T, t)
  local g = T.grad; local n = #g
  if n == 1 then return g[1] end
  t = clampN(t, 0, 1)
  local p = t * (n - 1)
  local i = math.floor(p)
  if i >= n - 1 then return g[n] end
  return mix(g[i + 1], g[i + 2], p - i)
end
-- lista colori del gradiente (per fillGradientColors), opzionalmente con alpha
local function gradA(T, a)
  if a == nil then return T.grad end
  local out = {}
  for i, c in ipairs(T.grad) do out[i] = withA(c, a) end
  return out
end

local FAMILIES, FAMILY_ORDER
do   -- (blocco: limite di 200 variabili locali del chunk)
local function lighten(c, t) return mix(c, { red = 1, green = 1, blue = 1, alpha = c.alpha or 1 }, t) end
-- d = { top, bot, fg, fg2, acc, hi, lo, on, ink, g }  (esadecimali)
local function theme(d, isDark)
  local T = { dark = isDark, clear = CLEAR }
  local solid = hex(d.bot)
  T.bg      = hex(d.top, isDark and 0.95 or 0.96)      -- vetro: top (più chiaro)
  T.bg2     = hex(d.bot, isDark and 0.97 or 0.97)      -- vetro: bottom
  T.solid   = solid                                    -- opaco, per "ritagli" e testo su accento
  T.fg      = hex(d.fg)                                -- testo primario
  T.fg2     = hex(d.fg2)                               -- testo secondario
  T.fg3     = mix(hex(d.fg2), solid, isDark and 0.40 or 0.25)             -- testo terziario / etichette
  T.accent  = hex(d.acc)                               -- accento base
  T.accentHi= hex(d.hi)                                -- gradiente: cima
  T.accentLo= hex(d.lo)                                -- gradiente: fondo
  -- gradiente multi-stop (2 colori per le famiglie classiche, 3-4 per quelle funky)
  local gl = {}
  for _, h in ipairs(d.g or { d.hi, d.lo }) do gl[#gl + 1] = hex(h) end
  T.grad    = gl
  T.multi   = (#gl > 2)
  T.accent2 = gl[2]
  T.accent3 = gl[3] or gl[#gl]
  T.accent4 = gl[4] or gl[#gl]
  T.accentInk = hex(d.ink or d.acc)                    -- accento usato COME TESTO (contrasto su sfondo)
  T.accentText= hex(d.on)                              -- testo SU riempimento accento
  T.accentHover = lighten(T.accent, 0.28)
  T.accentDim   = mix(T.accent, solid, isDark and 0.50 or 0.42)
  T.accentSoft  = withA(T.accent, isDark and 0.20 or 0.15)
  T.accentFaint = withA(T.accent, isDark and 0.10 or 0.08)
  T.border      = withA(T.accent, isDark and 0.36 or 0.42)   -- bordo carta
  T.borderSoft  = withA(T.accent, isDark and 0.18 or 0.24)   -- hairline interne
  T.hi          = isDark and { red = 1, green = 1, blue = 1, alpha = 0.28 } or { red = 1, green = 1, blue = 1, alpha = 0.95 }
  T.sheen       = isDark and { red = 1, green = 1, blue = 1, alpha = 0.035 } or { red = 1, green = 1, blue = 1, alpha = 0.28 }
  T.rowBg       = withA(hex(d.fg), isDark and 0.05 or 0.045)
  T.rowHover    = withA(hex(d.fg), isDark and 0.10 or 0.085)
  T.track       = withA(hex(d.fg), isDark and 0.13 or 0.11)
  T.divider     = withA(hex(d.fg), isDark and 0.10 or 0.09)
  T.warn        = isDark and hex("#FF5C54") or hex("#D93025")
  T.ok          = isDark and hex("#4ADE80") or hex("#12904A")
  T.shadowK     = isDark and 1.0 or 0.55                      -- le ombre su fondo chiaro sono più leggere
  T.fgWhite     = { red = 1, green = 1, blue = 1, alpha = 1 }
  T.fx = {}                                          -- icona/barre/particelle (impostato da family)
  return T
end

-- luminanza relativa (WCAG) e colore -> esadecimale
local function lum(c)
  local function f(v) v = clampN(v, 0, 1); if v <= 0.03928 then return v / 12.92 end return spow((v + 0.055) / 1.055, 2.4) end
  return 0.2126 * f(c.red) + 0.7152 * f(c.green) + 0.0722 * f(c.blue)
end
local function hx(c)
  local function b(v) return string.format("%02X", math.floor(clampN(v, 0, 1) * 255 + 0.5)) end
  return b(c.red) .. b(c.green) .. b(c.blue)
end
-- "top bot accento g1 g2 [g3 g4]" -> d completo (testo, hi/lo, inchiostro e "on" derivati dal contrasto)
local function derive(str, isDark)
  local cols = {}
  for h in tostring(str):gmatch("%x%x%x%x%x%x") do cols[#cols + 1] = h end
  if #cols < 5 then cols = { "202020", "101010", "D6AF5E", "EBCB85", "B48B3B" } end
  local W, K = hex("FFFFFF"), hex("000000")
  local T, B, A = hex(cols[1]), hex(cols[2]), hex(cols[3])
  local g = {}; for i = 4, #cols do g[#g + 1] = cols[i] end
  -- in light il testo su accento è bianco: se i riempimenti sono troppo chiari li scuriamo un filo (stessa tinta)
  local ONK = mix(B, K, 0.82)
  local function minC(c, A_)
    local m, Lc = 1e9, lum(c)
    for _, s in ipairs({ A_, table.unpack(g) }) do
      local L = lum(hex(s))
      m = math.min(m, (math.max(L, Lc) + 0.05) / (math.min(L, Lc) + 0.05))
    end
    return m
  end
  local accH = cols[3]
  if not isDark then
    for _ = 1, 8 do
      if minC(W, accH) >= 3.4 or minC(W, accH) < 2.0 then break end
      accH = hx(mix(hex(accH), K, 0.07))
      for i2, gh in ipairs(g) do g[i2] = hx(mix(hex(gh), K, 0.07)) end
    end
  end
  A = hex(accH)
  local fg, fg2, hi, lo, ink
  if isDark then
    fg = mix(T, W, 0.93); fg2 = mix(T, W, 0.6); hi = mix(A, W, 0.3); lo = mix(A, K, 0.18)
    ink = A; for _ = 1, 6 do if lum(ink) < 0.33 then ink = mix(ink, W, 0.15) end end
  else
    fg = mix(B, K, 0.9); fg2 = mix(B, K, 0.6); hi = mix(A, W, 0.14); lo = mix(A, K, 0.22)
    ink = A; for _ = 1, 8 do if lum(ink) > 0.17 then ink = mix(ink, K, 0.14) end end
  end
  local on = (minC(W, accH) >= minC(ONK, accH)) and W or ONK
  return { top = cols[1], bot = cols[2], fg = hx(fg), fg2 = hx(fg2), acc = accH, hi = hx(hi), lo = hx(lo),
           on = hx(on), ink = hx(ink), g = g }
end

local function family(name, dark, light, fx)
  if type(dark) == "string" then dark = derive(dark, true) end
  if type(light) == "string" then light = derive(light, false) end
  local F = { name = name, dark = theme(dark, true), light = theme(light, false), fx = fx or {} }
  F.dark.fx = F.fx; F.light.fx = F.fx          -- icona/forma barre/particelle: per stile, uguali in dark e light
  return F
end

-- Famiglie. Dark gold = carattere originale (nero caldo + oro); light gold = champagne + oro caldo.
FAMILIES = {
  gold = family("Gold",
    { top = "#1B1914", bot = "#0A0907", fg = "#F7F2E6", fg2 = "#B8AD94", acc = "#D6AF5E", hi = "#EBCB85", lo = "#B48B3B", on = "#1A1304" },
    { top = "#FFFCF3", bot = "#F4E8CE", fg = "#2A2012", fg2 = "#6E5D3D", acc = "#B3822A", hi = "#CB9C3A", lo = "#966A1B", on = "#FFFBEF", ink = "#8A5F12" }),
  mono = family("Mono",
    { top = "#1E1E21", bot = "#0C0C0E", fg = "#F5F5F7", fg2 = "#A1A1A8", acc = "#E4E4E9", hi = "#FFFFFF", lo = "#B6B6BE", on = "#111114" },
    { top = "#FFFFFF", bot = "#ECECF1", fg = "#17171A", fg2 = "#62626B", acc = "#2B2B31", hi = "#474750", lo = "#18181C", on = "#FFFFFF" }),
  ocean = family("Ocean",
    { top = "#101C31", bot = "#060B16", fg = "#EBF2FF", fg2 = "#93A6C6", acc = "#5C9CFF", hi = "#8EBCFF", lo = "#3B78E2", on = "#06142E" },
    { top = "#F9FCFF", bot = "#E2EDFC", fg = "#0E1A33", fg2 = "#4A5E82", acc = "#2563D6", hi = "#4380F0", lo = "#1B4DB0", on = "#FFFFFF", ink = "#1D4FB8" }),
  violet = family("Violet",
    { top = "#1D1532", bot = "#0C0717", fg = "#F3EEFF", fg2 = "#A99DC9", acc = "#A27DFF", hi = "#C2A8FF", lo = "#7E56E8", on = "#190C38" },
    { top = "#FCF9FF", bot = "#EBE3FB", fg = "#1D1433", fg2 = "#5E5082", acc = "#6D45DB", hi = "#8761F0", lo = "#5632B8", on = "#FFFFFF", ink = "#5A34C4" }),
  emerald = family("Emerald",
    { top = "#0F2821", bot = "#050F0C", fg = "#E9FFF6", fg2 = "#8EB9A9", acc = "#2FD6A2", hi = "#6DEAC2", lo = "#14A87E", on = "#04201A" },
    { top = "#F7FFFC", bot = "#DBF3E9", fg = "#0A2A20", fg2 = "#46705F", acc = "#0B8F68", hi = "#18AF83", lo = "#06704F", on = "#FFFFFF", ink = "#077655" }),
  rose = family("Rose",
    { top = "#2B111B", bot = "#13050A", fg = "#FFEFF3", fg2 = "#C9A1AB", acc = "#FF7B94", hi = "#FFA5B7", lo = "#E65170", on = "#2E0612" },
    { top = "#FFFAFB", bot = "#FAE2E7", fg = "#2E0F17", fg2 = "#7A4C57", acc = "#D62F52", hi = "#EF4E70", lo = "#B31F3F", on = "#FFFFFF", ink = "#BF2548" }),

  -- ---- stili "funky": accento che sfuma tra 3-4 colori (g) ----
  sunset = family("Sunset",
    { top = "#2A1424", bot = "#12060F", fg = "#FFF0EA", fg2 = "#D2A5A8", acc = "#FF7A59", hi = "#FFB259", lo = "#E8466E", on = "#2B0A10",
      g = { "#FFB259", "#FF6A5A", "#E8466E", "#B45CFF" } },
    { top = "#FFF8F3", bot = "#FFE3D6", fg = "#3A1620", fg2 = "#865560", acc = "#E2552F", hi = "#F07A3C", lo = "#C8325E", on = "#FFFFFF", ink = "#B8381F",
      g = { "#E8691E", "#E04A38", "#D03A6E", "#8E44D8" } }),
  aurora = family("Aurora",
    { top = "#0E1F2B", bot = "#050E16", fg = "#E8FFF8", fg2 = "#8FB8B8", acc = "#3DF0B4", hi = "#7BFFD2", lo = "#22B8C8", on = "#031A18",
      g = { "#3DF0B4", "#38C8F0", "#7B6CFF", "#C65CFF" } },
    { top = "#F5FFFC", bot = "#D8F2EE", fg = "#0B2A2E", fg2 = "#43706F", acc = "#0B9E86", hi = "#14B8A0", lo = "#0A7C9A", on = "#FFFFFF", ink = "#077A68",
      g = { "#0EA07C", "#1688C8", "#5A50DC", "#A03CD0" } }),
  neon = family("Neon",
    { top = "#12102A", bot = "#07061A", fg = "#F2F0FF", fg2 = "#A09CD0", acc = "#00F0FF", hi = "#66F7FF", lo = "#00B8D8", on = "#04101A",
      g = { "#00F0FF", "#8A5CFF", "#FF2EA6" } },
    { top = "#FBFAFF", bot = "#E4E0FF", fg = "#15123A", fg2 = "#5A5690", acc = "#0AA0C8", hi = "#22BCE0", lo = "#087CA8", on = "#FFFFFF", ink = "#067DA0",
      g = { "#0A93BA", "#6240D8", "#D81C86" } }),
  candy = family("Candy",
    { top = "#2A1430", bot = "#140818", fg = "#FFEFFC", fg2 = "#D0A0CC", acc = "#FF8AD8", hi = "#FFB3E8", lo = "#E85CBF", on = "#35052F",
      g = { "#FF8AD8", "#B38CFF", "#7CD6FF", "#9CF2C8" } },
    { top = "#FFF8FD", bot = "#FFE4F4", fg = "#3A1038", fg2 = "#8A5688", acc = "#E040A8", hi = "#F268C4", lo = "#C0288E", on = "#FFFFFF", ink = "#C0288E",
      g = { "#E8429F", "#9A55F0", "#2E8FE0", "#17A673" } }),
  lava = family("Lava",
    { top = "#2A0F08", bot = "#120503", fg = "#FFF1E6", fg2 = "#CFA38C", acc = "#FF6A1F", hi = "#FFA040", lo = "#E03A12", on = "#2A0C02",
      g = { "#FFD23F", "#FF8A2A", "#FF5A2E", "#FF3D5A" } },
    { top = "#FFF9F4", bot = "#FFDDC8", fg = "#3A1408", fg2 = "#8A5438", acc = "#E04A0F", hi = "#F26A24", lo = "#C0300A", on = "#FFFFFF", ink = "#B63A08",
      g = { "#E56A0C", "#E0481A", "#C42814", "#8E1030" } }),
  ice = family("Ice",
    { top = "#0E2030", bot = "#050F18", fg = "#EAF8FF", fg2 = "#8FB4C8", acc = "#8FE8FF", hi = "#C0F4FF", lo = "#52C4F0", on = "#03121C",
      g = { "#E0FBFF", "#8FE8FF", "#6AA8FF" } },
    { top = "#FAFEFF", bot = "#DDF0FA", fg = "#0B2433", fg2 = "#476C84", acc = "#1E9CD0", hi = "#3BB4E8", lo = "#1678AA", on = "#FFFFFF", ink = "#127AA8",
      g = { "#1E96CE", "#2A82DA", "#5A66E2" } }),
  forest = family("Forest",
    { top = "#14231A", bot = "#070E09", fg = "#EEF8E8", fg2 = "#9AB596", acc = "#8BD35A", hi = "#B5EC84", lo = "#5AA83A", on = "#0B1C05",
      g = { "#D6E86A", "#8BD35A", "#3FB27A" } },
    { top = "#F9FDF5", bot = "#E0EFD6", fg = "#12260F", fg2 = "#4F6B49", acc = "#4C9A2A", hi = "#62B23A", lo = "#397A1E", on = "#FFFFFF", ink = "#3A7A1F",
      g = { "#5A9418", "#3E9A2A", "#1E8C6A" } }),
  synthwave = family("Synthwave",
    { top = "#1E0F3A", bot = "#0B0620", fg = "#FFEBFF", fg2 = "#B79AD8", acc = "#FF4FD8", hi = "#FF8AE8", lo = "#C426B8", on = "#200838",
      g = { "#FFD84D", "#FF4FA3", "#B04DFF", "#4D7DFF" } },
    { top = "#FFF8FF", bot = "#EBDDFB", fg = "#2A0F4A", fg2 = "#7048A0", acc = "#D81FB0", hi = "#EE44C6", lo = "#AE1590", on = "#FFFFFF", ink = "#B01590",
      g = { "#E07A06", "#DC2E88", "#8E3FE0", "#3F66E0" } }),
  contrast = family("Contrast",
    { top = "#101010", bot = "#000000", fg = "#FFFFFF", fg2 = "#D0D0D0", acc = "#FFE600", hi = "#FFF066", lo = "#E6C800", on = "#000000",
      g = { "#FFF066", "#FFE600", "#FF8A00" } },
    { top = "#FFFFFF", bot = "#F0F0F0", fg = "#000000", fg2 = "#303030", acc = "#1038E8", hi = "#3A5CF5", lo = "#0A28B8", on = "#FFFFFF", ink = "#0A28B8",
      g = { "#3A5CF5", "#1038E8", "#7A1FE0" } }),
  lagoon = family("Lagoon",
    { top = "#082A30", bot = "#031317", fg = "#E8FFFB", fg2 = "#86B8B4", acc = "#2EE6D0", hi = "#7CF5E6", lo = "#12B8A8", on = "#02201E",
      g = { "#2EE6D0", "#3CB8FF", "#FF8A7A" } },
    { top = "#F4FFFD", bot = "#D2F4EE", fg = "#08302E", fg2 = "#3F7470", acc = "#0A9C90", hi = "#14B8AA", lo = "#087C74", on = "#FFFFFF", ink = "#07786E",
      g = { "#0AA396", "#2A8FD6", "#EE5A4C" } }),
  citrus = family("Citrus",
    { top = "#262410", bot = "#101004", fg = "#FFFBE0", fg2 = "#C8C07A", acc = "#F5E626", hi = "#FAF068", lo = "#D8C400", on = "#1E1C00",
      g = { "#F5F02A", "#B8E82A", "#FFA826" } },
    { top = "#FFFEF2", bot = "#F5F0C8", fg = "#2A2800", fg2 = "#7A7220", acc = "#C9B400", hi = "#DCC81A", lo = "#A89500", on = "#1E1A00", ink = "#7A6E00",
      g = { "#D8C400", "#8CC020", "#E88A10" } }),
}

FAMILY_ORDER = { "gold", "mono", "ocean", "violet", "emerald", "rose",
  "sunset", "aurora", "neon", "candy", "lava", "ice", "forest", "synthwave", "contrast", "lagoon", "citrus" }
-- categorie degli stili storici
for c, ids in pairs({ cl = "gold mono violet rose contrast", fk = "sunset candy lava citrus", nt = "ocean emerald aurora ice forest lagoon",
  ne = "neon synthwave" }) do
  for id in ids:gmatch("%a+") do FAMILIES[id].cat = c end
end
-- Stili data-driven. Riga: { id, nome, categoria, dark, light, fx }
--   dark/light = "top bot accento g1 g2 [g3 g4]" (esadecimali): fg/fg2/hi/lo/on/ink si derivano (derive)
--   fx = { icon = id icona custom, bar = round|square|pixel|ghost, part = snow|bats|petals|stars|rain|bubbles|confetti }
--   (pack completi: in più shape/body/barCol/meter/proc/done/egg/font: vedi "PACK FX" sopra l'HUD)
-- Per aggiungere uno stile: una riga qui sotto (+ eventuale icona in ICON.c). Nient'altro.
local ROWS = {
  -- Pop-culture (nomi-nod, palette + motivi generici: nessun marchio/personaggio)
  { "bluerush", "Blue Rush", "pp", "0B1A52 050C2B 3D8BFF 3D8BFF 00C2FF FFC832", "F4F8FF DCE8FF 1458D6 1458D6 0A8ED8 D99A00",
    { icon = "ring", body = "speed", part = "rush", proc = "spin", done = "ring", egg = "rush" } },
  { "blocky", "Blocky", "pp", "23301A 11160C 7CBD3A 8FD14A 5B9A2E 8A5A33", "F3F7E8 DDE8C4 4C8A1F 4C8A1F 3E7A2A 8A5A33",
    { icon = "blockmic", bar = "pixel", shape = "block", body = "block", part = "chips", proc = "mine", done = "pixel", egg = "block",
      barCol = { dark = "F4F1D6", light = "2A1C0E" } } },
  { "turbo", "Turbo Ball", "pp", "1B1630 0A0716 FF8A1F FFB02E FF7A1A 1E8CFF", "FFF8F0 FFE6D2 E8650A E8650A D84A1A 1F6FE0",
    { icon = "ball", bar = "square", body = "sport", meter = "boost", part = "boost", proc = "wheel", done = "goal", egg = "turbo" } },
  { "quahog", "Quahog", "pp", "14284A 0A1428 4A9BFF 4A9BFF 4CC35F FF9A2E FFDD3C", "F6FBFF DDEBFA 2A6FD0 2A6FD0 2E9A3F E87A10 C9A200",
    { icon = "sofa", shape = "cartoon", body = "cartoon", part = "comic", proc = "hop", done = "pop", egg = "quahog", font = "rounded" } },
  { "quest", "Quest", "pp", "1B2A18 0B130A E8C14A 7BD35A E8C14A 3FA67A", "FBF7E6 EAE2BC 5E8F2E 4C9A2A B8901A 2F8F6F", { icon = "shield" } },
  { "zap", "Zap", "pp", "2A2208 120D02 FFD21F FFE14D FFC400 FF5A3C", "FFFCEB FFF0B8 D9A800 D9A800 E88A00 D0352A", { icon = "bolt" } },
  { "funghetto", "Funghetto", "pp", "14213F 070E22 FF4A3D FF4A3D FFD23F 3DA0FF", "F4F9FF D6E8FF D8271C D8271C E0A300 1E6FD8", { icon = "shroom", bar = "square" } },
  -- Stagioni
  { "spooky", "Spooky", "st", "1A0F26 08040E FF7A1A FF8A1F FF5A00 9B4DFF", "FFF6EC F1E0F4 D95F00 D95F00 C23B00 7E34C8", { icon = "pumpkin", bar = "ghost", part = "bats" } },
  { "noel", "Noel", "st", "2A0E14 0F0509 E8B84A D62F3A E8B84A 2E9E5A", "FFFDF8 F8E8E4 C42A36 C42A36 B08A1E 1F7A44", { icon = "tree", part = "snow" } },
  { "sakura", "Sakura", "st", "2A141F 13070D FFB7C5 FFB7C5 FF8FA8 FFD9E0", "FFF8FA FDE4EB D9456F E0577F C73A66 7DAF4E", { icon = "flower", part = "petals" } },
  { "autunno", "Autunno", "st", "2A180C 120A04 E8821E F2B134 E8821E B8412A", "FFF8EC F3DFC0 C2640A C98A12 C2640A A3351E", { part = "petals" } },
  { "estate", "Estate", "st", "0C2A3A 04121C FFD23F FFD23F FF8A5A 1FD1D1", "FFFDF0 D8F3F5 E0A800 E8A800 E86A3A 0A9AA8", { icon = "sun" } },
  { "primavera", "Primavera", "st", "14261A 07100A 8FE388 8FE388 FFB7D5 FFE27A", "F8FFF6 E0F3D8 3FA040 4AA848 D85A8A C8A020", { icon = "flower", part = "petals" } },
  { "inverno", "Inverno", "st", "0E1E33 050D18 A8D8FF E8F6FF A8D8FF 6F8CFF", "F8FCFF DCEBF8 2A7AC0 2A8AD0 3F6FE0 6A5FD0", { icon = "snow", part = "snow" } },
  { "cuori", "Cuori", "st", "2E0F1C 140509 FF5A7E FF8FA8 FF5A7E D9366A", "FFF7F9 FFE0E8 D81F4A E0345E C8173F A8123A", { icon = "heart", part = "petals" } },
  { "brindisi", "Brindisi", "st", "1A1608 0A0803 F2C94C F2C94C F7E7B0 E58AA8", "FFFCF0 F5EBC8 B8901A C09A20 A8741A C0507A", { part = "confetti" } },
  -- Retro
  { "arcade", "Arcade", "rt", "0A0A24 03030F FFE600 FFE600 FF4FA3 2D5BFF 00E5FF", "FFFEF0 F2EEC8 D4A800 C99A00 D81F7E 2038D8 0088A8", { icon = "stick", bar = "pixel" } },
  { "vapor", "Vapor", "rt", "261046 0F0620 FF71CE FF71CE B967FF 01CDFE", "FFF6FD F0E1FF D9399E D9399E 8A3FE0 0A9AC8", { icon = "sunset" } },
  { "pirata", "Pirata", "rt", "1E150B 0C0803 D4A23A D4A23A C23A2E 2E9AA6", "FBF4E2 EBDDB6 9A6A10 A87814 A82A20 1F7F8A", { icon = "skull" } },
  { "noir", "Noir", "rt", "1C1C1C 080808 E8E8E8 F2F2F2 B0B0B0 C8102E", "FAFAF8 E4E2DC 1A1A1A 2A2A2A 5A5A5A C8102E", { icon = "clap" } },
  { "miami", "Miami", "rt", "0F2630 05111A 2EE6D6 2EE6D6 FF6FB5 FFC857", "F4FFFD D8F6F2 0A9C94 0A9C94 DB3E8A D49000", {} },
  { "lcd", "LCD", "rt", "1C2A12 0B1206 9BBC0F C5DE5A 9BBC0F 6A8A0F", "EAF2C8 D3E0A0 306230 4A7A20 306230 0F380F", { icon = "pixmic", bar = "pixel" } },
  { "ambra", "Ambra", "rt", "1E1406 0B0702 FFB000 FFC94D FFB000 E87A00", "FFF8E6 F3E3B8 B87800 C48400 A86400 8A4A00", { bar = "square" } },
  { "steam", "Steam", "rt", "261A10 100A05 C99A4A E0B866 C99A4A 4F9A8A", "FBF4E4 E8DABB 8A6420 9A7226 7A5418 2F7A6C", { icon = "gear" } },
  -- Neon
  { "rain", "Digital Rain", "ne", "03150A 010802 00FF66 B6FFC8 00FF66 00A845", "F2FFF6 D2F2DC 00994A 00A24D 008A3E 00632B", { icon = "pixmic", bar = "square", part = "rain" } },
  { "cyber", "Cyber", "ne", "14120A 07060A FCEE0A FCEE0A FF2A6D 05D9E8", "FFFEE8 F4F0B8 C9B800 B8A800 D8184F 058FA0", { bar = "square" } },
  { "tokyo", "Tokyo", "ne", "150F2E 07051A FF3D9A FF3D9A 00E0FF F5FF5E", "FFF8FC F0E4FF D81C7A D81C7A 0A8FB0 B0A800", {} },
  { "acido", "Acido", "ne", "14240A 070D02 B6FF00 B6FF00 00FFA3 9B30FF", "F8FFE8 E2F2B8 6AA800 6AA800 00A870 7A1FC8", {} },
  { "uv", "UV", "ne", "150A2E 06021A 9D4DFF 9D4DFF 00E0FF FF4DDB", "FAF6FF E6DAFB 6A2FD8 6A2FD8 0A88C8 C0289A", {} },
  -- Natura
  { "deserto", "Deserto", "nt", "2B1A10 120A05 E8A55A F2C26B E8844A C8503C", "FFF8EC F5E0BC B8651E C8801E B8501E 8E3A2C", { icon = "cactus" } },
  { "abissi", "Abissi", "nt", "04182B 010A14 19E6D2 19E6D2 3A8BFF 9B5CFF", "F2FCFF CFEAF5 0A8FA8 0A9AA8 1F5FD8 6A3FD0", { part = "bubbles" } },
  { "matcha", "Matcha", "nt", "1C2616 0A0F07 A6D17A C5E3A0 A6D17A 6FA86A", "F8FBEF E1ECC9 5F8F3A 6C9A3E 4F8040 3A7050", {} },
  { "corallo", "Corallo", "nt", "2B1511 120806 FF7A66 FF9A7A FF6F61 1FC5B5", "FFF7F4 FFE0D8 D9503E E0654E CF4938 0A9A8E", {} },
  { "lavanda", "Lavanda", "nt", "211B33 0E0A1A B8A6F0 D0C2FF B8A6F0 9CC9B0", "FBF9FF E8E2F8 7A5FCF 8A6FD8 6A4FBF 4F9A78", {} },
  -- Funky
  { "cosmo", "Cosmo", "fk", "150C36 06031A 8C6CFF 8C6CFF FF5CA8 3DC8FF", "F8F5FF E2DAFA 5A3FD8 5A3FD8 D02A7E 0F8FC8", { icon = "planet", part = "stars" } },
  { "gelato", "Gelato", "fk", "2C1A24 140A10 FF9EB5 FF9EB5 B8F2C2 FFF1B8", "FFF9FB FDE6EE D9547A E0658A 3FA66A C89A1E", { icon = "cone" } },
  { "cioccolato", "Cioccolato", "fk", "2B1810 130A06 F0B8A0 F7D2BC E39A7E 8C5A3A", "FFF7F1 F0DACB A8503A B85F44 8F3E2C 6B3A1E", {} },
  { "bacche", "Bacche", "fk", "2A0F2E 12051A E040FB FF6FB0 E040FB 7C5CFF", "FFF7FD F5DDF5 B01FC4 C0267E B01FC4 5A3FD8", {} },
  { "memphis", "Memphis", "fk", "1F1A3A 0E0A20 FFD23F FFD23F FF5FA2 2FD6C8 6C63FF", "FFFDF3 F6EFC9 E0A800 E0A800 E0357E 0AA79B 5A4FE0", {} },
  -- Classici
  { "inchiostro", "Inchiostro", "cl", "15171E 090A0E E9DFC4 F2E8CC D8C9A0 8FA3D8", "FBF6E9 EBE1C8 1B2A49 1B2A49 33477A 8A5A2B", {} },
  { "caffe", "Caffè", "cl", "2A1D15 120B07 D2A06A E8C497 D2A06A A8703C", "FFF9F1 EBD9C3 8A5A2B 9A6630 7A4A22 5C3A1C", {} },
  { "nebbia", "Nebbia", "cl", "20252B 0D1013 A9BAC9 C4D2DE A9BAC9 7E92A8", "FAFBFC E3E8EC 506A82 5A7590 3F566C 2E4256", {} },
  { "ardesia", "Ardesia", "cl", "12262B 060F11 4FB8B0 7ADAD0 4FB8B0 3A8F9A", "F5FBFB D9ECEC 1F7F7A 238A84 186B70 124E54", {} },
  { "bordeaux", "Bordeaux", "cl", "2A0D16 12050A E0607E F08AA0 DC5A78 C73A5A", "FFF8F9 F3DCE1 A81D3C B8284A 8E1633 6B0F28", {} },
  { "platino", "Platino", "cl", "22242A 0E0F13 D8DCE6 F4F6FA D8DCE6 9AA3B8", "FCFCFE E6E8EE 5A6278 6A7390 4A526A 363E54", {} },
  { "rame", "Rame", "cl", "2A160F 120805 E0875A F2B48A E0875A B05A38", "FFF8F3 F2DCCB B0582A C0683A 9A4A22 7A361A", {} },
}
for _, r in ipairs(ROWS) do
  FAMILIES[r[1]] = family(r[2], r[4], r[5], r[6]); FAMILIES[r[1]].cat = r[3]
  FAMILY_ORDER[#FAMILY_ORDER + 1] = r[1]
end
-- ordine: raggruppato per categoria (a parità di categoria, l'ordine di definizione)
FAMILY_ORDER.cats = { { "all", "Tutti" }, { "cl", "Classici" }, { "fk", "Funky" }, { "nt", "Natura" }, { "ne", "Neon" },
  { "rt", "Retro" }, { "pp", "Pop" }, { "st", "Stagioni" } }
do
  local flat = {}
  for i = 2, #FAMILY_ORDER.cats do
    for _, id in ipairs(FAMILY_ORDER) do if FAMILIES[id].cat == FAMILY_ORDER.cats[i][1] then flat[#flat + 1] = id end end
  end
  for i = 1, #FAMILY_ORDER do FAMILY_ORDER[i] = flat[i] end
end
end
local COL = FAMILIES.gold.dark

local function scaleFor(preset)
  if preset == "minimal" then return 0.72
  elseif preset == "large" then return 1.2
  else return 1.0 end
end

local systemIsDark
do   -- cache 3s: "Auto" non deve lanciare un processo ad ogni disegno (scroll, hover...)
  local cache = { t = -100, v = false }
  systemIsDark = function()
    local t = hs.timer.secondsSinceEpoch()
    if t - cache.t > 3 then
      local out = hs.execute("defaults read -g AppleInterfaceStyle 2>/dev/null")
      cache.v = (out or ""):find("Dark") ~= nil; cache.t = t
    end
    return cache.v
  end
end

local function resolveMode()
  local m = config.themeMode
  if m == "auto" then m = systemIsDark() and "dark" or "light" end
  if m ~= "dark" and m ~= "light" then m = "dark" end
  return m
end

------------------------------------------------------------------------
-- LOOK: tutto ciò che è aspetto e non funzione (tab "Tema" delle impostazioni).
-- Ogni valore ha un default = comportamento originale; chiavi salvate in settings.lua.
------------------------------------------------------------------------
local RADIUS_MUL = { round = 1, medium = 0.55, square = 0.16 }
local SPEED_MUL  = { calm = 1.7, normal = 1, lively = 0.65 }
-- densità: larghezza extra pillola, passo onda, gap/passo verticali, scala degli spazi nei pannelli
local DENS = {
  compact = { w = -20, pitch = 5.2, vp = 4.8, vg = 17, vs = 29, gap = 0.72 },
  normal  = { w = 0,   pitch = 6.2, vp = 5.6, vg = 21, vs = 31, gap = 1 },
  wide    = { w = 26,  pitch = 8.2, vp = 6.6, vg = 25, vs = 34, gap = 1.22 },
}
local function R(v) return math.max(1.5, v * (RADIUS_MUL[config.cornerStyle] or 1)) end
local function dens() return DENS[config.density] or DENS.normal end
local function animOn() return config.animOn ~= false end
local function gapK() return dens().gap end

-- SANIFICAZIONE CENTRALE DEI VALORI DI LOOK (e delle chiavi che li accompagnano: posizione, misura, orientamento).
-- Ogni valore passa di qui in ingresso (loadSettings, setLook, Sorprendimi): tipo, intervallo, enum validi; invalido -> default
-- (mai errore). Un solo punto: i setter della UI e il file settings.lua non possono piu' portare nel codice stringhe al posto di
-- numeri/bool, valori fuori range o nomi sconosciuti. Tabella dentro config (niente nuovi local: limite 200 del chunk).
config.LOOK = { def = {
  style = "gold", themeMode = "dark", shadowOn = true, shadowIntensity = 0.5, glassOpacity = 0,
  cornerStyle = "round", animOn = true, animSpeed = "normal", waveStyle = "bars", waveColor = "auto",
  micPulse = 0.5, glowOn = false, uiFont = "sf", timerFont = "mono", density = "normal", idleOpacity = 1,
} }
do
  local K = config.LOOK
  local function asBool(v, d)
    if v == true or v == "true" or v == 1 or v == "1" then return true end
    if v == false or v == "false" or v == 0 or v == "0" then return false end
    return d
  end
  local function asNum(v)
    v = tonumber(v)
    if v == nil or v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
  end
  local function oneOf(v, list, d) for _, x in ipairs(list) do if v == x then return v end end return d end
  K.asBool, K.asNum = asBool, asNum
  -- valore valido per la chiave (nil/invalido -> default della chiave)
  function K.clean(key, v)
    local d = K.def[key]
    if key == "style" then return (type(v) == "string" and FAMILIES[v]) and v or d
    elseif key == "themeMode" then return oneOf(v, { "dark", "light", "auto" }, d)
    elseif key == "shadowOn" or key == "glowOn" or key == "animOn" then return asBool(v, d)
    elseif key == "shadowIntensity" then return clampN(asNum(v) or d, 0, 1)
    elseif key == "glassOpacity" then local n = asNum(v); if not n or n <= 0 then return 0 end return clampN(n, 0.5, 1)   -- 0 = default del tema
    elseif key == "cornerStyle" then return (type(v) == "string" and RADIUS_MUL[v]) and v or d
    elseif key == "animSpeed" then return (type(v) == "string" and SPEED_MUL[v]) and v or d
    elseif key == "waveStyle" then return oneOf(v, { "bars", "thin", "dots", "line" }, d)
    elseif key == "waveColor" then return oneOf(v, { "accent", "gradient", "auto" }, d)
    elseif key == "micPulse" then return clampN(asNum(v) or d, 0, 1)
    elseif key == "idleOpacity" then return clampN(asNum(v) or d, 0.3, 1)
    elseif key == "uiFont" then return oneOf(v, { "sf", "rounded", "mono" }, d)
    elseif key == "timerFont" then return oneOf(v, { "mono", "sf", "rounded" }, d)
    elseif key == "density" then return (type(v) == "string" and DENS[v]) and v or d
    end
    return v
  end
  -- porta tutta config in uno stato valido (chiavi assenti restano assenti: i default sono quelli di config)
  function K.fix(c)
    for key in pairs(K.def) do if c[key] ~= nil then c[key] = K.clean(key, c[key]) end end
    if c.layers ~= nil then c.layers = asBool(c.layers, true) end
    if c.micAutoFallback ~= nil then c.micAutoFallback = asBool(c.micAutoFallback, true) end
    c.sizePreset = oneOf(c.sizePreset, { "standard", "large", "minimal" }, "standard")
    c.orientation = oneOf(c.orientation, { "horizontal", "vertical" }, "horizontal")
    local px, py = asNum(c.posX), asNum(c.posY)
    if px and py and math.abs(px) < 1e5 and math.abs(py) < 1e5 then c.posX, c.posY = px, py else c.posX, c.posY = nil, nil end
  end
end

local function applyTheme()
  local fam = FAMILIES[config.style] or FAMILIES.gold
  local base = fam[resolveMode()]
  COL = base
  if type(config.glassOpacity) == "number" and finite(config.glassOpacity, 0) > 0 then   -- <= 0 / nil = default del tema
    -- opacità del vetro personalizzata: copia del tema con alpha dei due toni sovrascritto
    local c = {}
    for k, v in pairs(base) do c[k] = v end
    local g = clampN(config.glassOpacity, 0.5, 1)
    c.bg  = withA(base.bg, g)
    c.bg2 = withA(base.bg2, math.min(1, g + 0.02))
    COL = c
  end
end

------------------------------------------------------------------------
-- TASTI: bindings (qualsiasi tasto, anche multipli)
------------------------------------------------------------------------
local KEYCODE_MOD = { [61] = "alt", [58] = "alt", [62] = "ctrl", [59] = "ctrl", [54] = "cmd", [55] = "cmd", [60] = "shift", [56] = "shift", [63] = "fn" }
local MODSYM = { alt = "⌥", ctrl = "⌃", cmd = "⌘", shift = "⇧", fn = "fn" }
local SIDE = { [61] = " dx", [58] = " sx", [62] = " dx", [59] = " sx", [54] = " dx", [55] = " sx", [60] = " dx", [56] = " sx" }
local KC2NAME = {}
for name, code in pairs(hs.keycodes.map) do
  if type(code) == "number" and type(name) == "string" and not KC2NAME[code] then KC2NAME[code] = name end
end
local function bindLabel(b)
  if b.mod and MODSYM[b.mod] then return MODSYM[b.mod] .. (SIDE[b.kc] or "") end
  local n = KC2NAME[b.kc] or ("#" .. b.kc)
  if #n == 1 then n = n:upper() end
  return n
end
local function serializeBindings(list)
  local t = {}
  for _, b in ipairs(list) do t[#t + 1] = b.kc .. ":" .. (b.mod or "key") .. ":" .. (b.gesture or "double") end
  return table.concat(t, ";")
end
local function parseBindings(str, defGest)
  local list = {}
  for pair in tostring(str or ""):gmatch("[^;]+") do
    local kc, mod, g = pair:match("(%d+):(%a+):?(%a*)")
    if kc then list[#list + 1] = { kc = tonumber(kc), mod = mod, gesture = (g ~= "" and g) or defGest or "double" } end
  end
  return list
end

------------------------------------------------------------------------
-- SETTINGS
------------------------------------------------------------------------
local function loadSettings()
  local f = io.open(config.settingsPath, "r"); if not f then return end; f:close()
  local ok, s = pcall(dofile, config.settingsPath)
  if not ok or type(s) ~= "table" then gwAlert("⚠️ settings.lua non valido") return end
  if s.language ~= nil then config.language = (s.language == "auto") and nil or s.language end
  if s.micDevice then config.audioDevice = s.micDevice end
  if s.micName   then config.micName = s.micName end
  if s.model     then config.model = s.model end
  -- bindings: "kc:mod:gesture;..." (gesto per-tasto); back-compat coi vecchi formati
  if s.ssBindings then config.ssBindings = parseBindings(s.ssBindings, s.ssGesture or "double")
  elseif s.startStopKeycode then config.ssBindings = { { kc = s.startStopKeycode, mod = s.startStopFlag or KEYCODE_MOD[s.startStopKeycode] or "key", gesture = s.ssGesture or "double" } } end
  if s.pauseBindings then config.pauseBindings = parseBindings(s.pauseBindings, s.pauseGesture or "single")
  elseif s.pauseKeycode then config.pauseBindings = { { kc = s.pauseKeycode, mod = s.pauseFlag or KEYCODE_MOD[s.pauseKeycode] or "key", gesture = s.pauseGesture or "single" } } end
  if s.doubleTapSec     then config.doubleTapSec = s.doubleTapSec end
  if s.maxSegmentSec    then config.maxSegmentSec = s.maxSegmentSec end
  if s.restoreClipboard ~= nil then config.restoreClipboard = s.restoreClipboard end
  if s.autoUpdate ~= nil then config.autoUpdate = s.autoUpdate end
  if s.autoTranscribeRecovered ~= nil then config.autoTranscribeRecovered = s.autoTranscribeRecovered end
  if s.repoDir then config.repoDir = s.repoDir end
  if s.ffmpeg then config.ffmpeg = s.ffmpeg; config.ffmpegExplicit = true end
  if s.sizePreset  then config.sizePreset = s.sizePreset end
  if s.orientation then config.orientation = s.orientation end
  if s.style       then config.style = s.style end
  if s.themeMode   then config.themeMode = s.themeMode end
  -- bool salvati come stringa ("true"/"false", vecchio persist) → veri booleani
  local function bool(v) if v == "true" then return true elseif v == "false" then return false end return v end
  local function num(v) return tonumber(v) end
  if s.shadowOn ~= nil then config.shadowOn = bool(s.shadowOn) end
  if s.shadowIntensity then config.shadowIntensity = clampN(num(s.shadowIntensity) or 0.5, 0, 1) end
  -- look (tab Tema)
  if num(s.glassOpacity) then config.glassOpacity = num(s.glassOpacity) end
  if s.cornerStyle and RADIUS_MUL[s.cornerStyle] then config.cornerStyle = s.cornerStyle end
  if s.animOn ~= nil then config.animOn = bool(s.animOn) end
  if s.layers ~= nil then config.layers = bool(s.layers) end
  if s.micAutoFallback ~= nil then config.micAutoFallback = bool(s.micAutoFallback) end
  if s.animSpeed and SPEED_MUL[s.animSpeed] then config.animSpeed = s.animSpeed end
  if s.waveStyle then config.waveStyle = s.waveStyle end
  if s.waveColor then config.waveColor = s.waveColor end
  if num(s.micPulse) then config.micPulse = clampN(num(s.micPulse), 0, 1) end
  if s.glowOn ~= nil then config.glowOn = bool(s.glowOn) end
  if s.uiFont then config.uiFont = s.uiFont end
  if s.timerFont then config.timerFont = s.timerFont end
  if s.density and DENS[s.density] then config.density = s.density end
  if num(s.idleOpacity) then config.idleOpacity = clampN(num(s.idleOpacity), 0.3, 1) end
  -- migrazione dai vecchi stili/flag
  if config.style == "goldlight" then config.style = "gold"; if not s.themeMode then config.themeMode = "light" end
  elseif config.style == "monolight" then config.style = "mono"; if not s.themeMode then config.themeMode = "light" end end
  if s.themeAuto and not s.themeMode then config.themeMode = "auto" end
  if s.posX then config.posX = s.posX end
  if s.posY then config.posY = s.posY end
  config.LOOK.fix(config)                       -- tipi, intervalli ed enum validi per ogni chiave di look (invalido -> default)
  if #config.ssBindings == 0 then config.ssBindings = { { kc = 61, mod = "alt", gesture = "double" } } end
  if #config.pauseBindings == 0 then config.pauseBindings = { { kc = 60, mod = "shift", gesture = "single" } } end
  config.scale = scaleFor(config.sizePreset)
  applyTheme()
  local rf = io.open(os.getenv("HOME") .. "/.config/groq-dictation/repo_path", "r")
  if rf then local p = rf:read("*a"); rf:close(); p = (p or ""):gsub("%s+$", ""); if p ~= "" then config.repoDir = p end end
end

-- Scrive una chiave in settings.lua. Numeri e booleani restano tali (prima i bool finivano
-- tra virgolette: "false" era una stringa e contava come vero), il resto è stringa.
local function persist(key, value)
  local f = io.open(config.settingsPath, "r"); if not f then return end
  local txt = f:read("*a"); f:close()
  local rhs
  if type(value) == "number" then rhs = tostring(finite(value, 0))
  elseif type(value) == "boolean" then rhs = value and "true" or "false"
  else rhs = '"' .. (tostring(value):gsub('[\\"\n]', "")) .. '"' end
  local pat = "%f[%w_]" .. key .. "%s*=%s*[^,\n]+"
  if txt:find(pat) then txt = txt:gsub(pat, function() return key .. " = " .. rhs end, 1)
  else txt = txt:gsub("return%s*{", function() return "return {\n  " .. key .. " = " .. rhs .. "," end, 1) end
  local w = io.open(config.settingsPath, "w"); if w then w:write(txt); w:close() end
end

saveBindings = function()
  persist("ssBindings", serializeBindings(config.ssBindings))
  persist("pauseBindings", serializeBindings(config.pauseBindings))
end

------------------------------------------------------------------------
-- HELPERS
------------------------------------------------------------------------
local function readKey()
  local f = io.open(config.keyPath, "r"); if not f then return nil end
  local k = f:read("*a"); f:close()
  if not k then return nil end
  k = k:gsub("%s+", ""); if k == "" then return nil end
  return k
end
local function trim(s) if not s then return "" end return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function loadHistory()
  local f = io.open(config.historyPath, "r"); if not f then return {} end
  local raw = f:read("*a"); f:close()
  local ok, data = pcall(hs.json.decode, raw)
  if not ok or type(data) ~= "table" then return {} end
  return data
end
local function saveHistoryEntry(text)
  if not text or trim(text) == "" then return end
  local hist = loadHistory()
  table.insert(hist, 1, { ts = os.time(), text = text })
  while #hist > config.historyMax do table.remove(hist) end
  hs.execute("mkdir -p '" .. os.getenv("HOME") .. "/.config/groq-dictation'")
  local f = io.open(config.historyPath, "w")
  if f then f:write(hs.json.encode(hist)); f:close() end
end
local function fileSize(path)
  local f = io.open(path, "rb"); if not f then return 0 end
  local sz = f:seek("end"); f:close(); return sz or 0
end
local function segPath(i) return string.format("%s/groq_seg_%d.wav", config.workDir, i) end
local function now() return hs.timer.secondsSinceEpoch() end
local function fmtTime(t) local m = math.floor(t / 60); local s = math.floor(t % 60); return string.format("%d:%02d", m, s) end
local function currentElapsed()
  local e = elapsed
  if recording and not paused and segStart then e = e + (now() - segStart) end
  return e
end
local function mapLevel(db)
  if not db then return 0 end
  -- il parlato sta tra ~-45 dB (piano) e ~-15 dB (forte): finestra stretta così le barre
  -- distinguono piano/normale/forte; curva morbida per non saturare subito
  local v = (finite(db, -90) + 50) / 36
  if v < 0 then v = 0 elseif v > 1 then v = 1 end
  return spow(v, 1.15)   -- potenza DOPO il clamp: base negativa darebbe NaN e bloccherebbe il timer
end
local function nBars() return (config.orientation == "vertical") and 9 or 12 end
local function resetLevels() levels = {}; for _ = 1, nBars() do levels[#levels + 1] = 0 end end

local function recoverOrphans(deferred)
  local out = hs.execute("ls -1 '" .. config.workDir .. "'/groq_seg_*.wav 2>/dev/null")
  local files = {}
  for l in (out or ""):gmatch("[^\n]+") do files[#files + 1] = l end
  if #files == 0 then return {} end
  if deferred then
    -- nel percorso di avvio registrazione: niente ffmpeg sincrono. I file orfani vengono solo rinominati (fuori dal pattern dei segmenti
    -- correnti) e recuperati dopo, a registrazione partita.
    local stamp = os.date("%Y%m%d-%H%M%S")
    local moved = {}
    for i, p in ipairs(files) do
      local np = string.format("%s/groq_orph_%s_%d.wav", config.workDir, stamp, i)
      if os.rename(p, np) then moved[#moved + 1] = np end
    end
    hs.timer.doAfter(2.5, function()
      local rec = {}
      hs.execute("mkdir -p '" .. config.recDir .. "'")
      for i, p in ipairs(moved) do
        if fileSize(p) > 1000 then
          local dest = string.format("%s/recovered-%s-%d.wav", config.recDir, stamp, i)
          hs.execute(string.format("'%s' -y -i '%s' -c copy '%s' 2>/dev/null || cp '%s' '%s'", config.ffmpeg, p, dest, p, dest))
          rec[#rec + 1] = dest
        end
        os.remove(p)
      end
      if #rec > 0 then gwAlert("💾 Recuperato audio da una sessione interrotta:\n" .. config.recDir, 8) end
    end)
    return {}
  end
  hs.execute("mkdir -p '" .. config.recDir .. "'")
  local stamp = os.date("%Y%m%d-%H%M%S")
  local recovered = {}
  for i, p in ipairs(files) do
    if fileSize(p) > 1000 then
      local dest = string.format("%s/recovered-%s-%d.wav", config.recDir, stamp, i)
      hs.execute(string.format("'%s' -y -i '%s' -c copy '%s' 2>/dev/null || cp '%s' '%s'", config.ffmpeg, p, dest, p, dest))
      recovered[#recovered + 1] = dest
    end
    os.remove(p)
  end
  if #recovered > 0 then gwAlert("💾 Recuperato audio da una sessione interrotta:\n" .. config.recDir, 8) end
  return recovered
end

------------------------------------------------------------------------
-- DEVICE AUDIO
------------------------------------------------------------------------
local function getAudioDevices(cb)
  local t = hs.task.new(config.ffmpeg, function(_c, _o, err)
    local list, inAudio = {}, false
    for line in (err or ""):gmatch("[^\r\n]+") do
      if line:find("AVFoundation audio devices") then inAudio = true
      elseif line:find("AVFoundation video devices") then inAudio = false
      elseif inAudio then
        local n, name = line:match("%[(%d+)%]%s+(.+)$")
        if n then list[#list + 1] = { idx = ":" .. n, name = name } end
      end
    end
    cb(list)
  end, { "-f", "avfoundation", "-list_devices", "true", "-i", "" })
  t:start()
end
local deviceCache = {}
local function refreshDevices() getAudioDevices(function(list) deviceCache = list end) end
-- Fallback quando il mic scelto non c'è (es. AirPods spente): il mic integrato del Mac,
-- mai "il primo della lista" (che può essere il telefono).
local function builtinOrFirst()
  local builtin = {}
  for _, d in ipairs(hs.audiodevice.allInputDevices()) do
    if d:transportType() == "Built-in" then builtin[d:name()] = true end
  end
  for _, d in ipairs(deviceCache) do if builtin[d.name] then return d end end
  return deviceCache[1]
end
local function resolveMic()
  if config.micName and #deviceCache > 0 then
    for _, d in ipairs(deviceCache) do if d.name == config.micName then return d.idx, false, d.name end end
    return builtinOrFirst().idx, true, builtinOrFirst().name
  end
  if #deviceCache > 0 then return deviceCache[1].idx, false, deviceCache[1].name end
  return config.audioDevice or ":0", false, nil
end

------------------------------------------------------------------------
-- ANIMAZIONI
-- Un solo timer a 60fps, condiviso: nasce quando parte la prima animazione
-- e si ferma da solo quando la lista è vuota (nessun timer a HUD nascosto).
------------------------------------------------------------------------
local Anim = { list = {}, timer = nil }
local function clamp01(t) t = finite(t, 0); if t < 0 then return 0 elseif t > 1 then return 1 end return t end
local EASE = {
  linear = function(t) return t end,
  out    = function(t) return 1 - (1 - t) ^ 3 end,                  -- ease-out cubico
  inq    = function(t) return t * t * t end,                        -- ease-in (uscite)
  inout  = function(t) if t < 0.5 then return 4 * t * t * t end return 1 - ((-2 * t + 2) ^ 3) / 2 end,
  spring = function(t) local c1 = 1.45; local c3 = c1 + 1; return 1 + c3 * (t - 1) ^ 3 + c1 * (t - 1) ^ 2 end,  -- easeOutBack
}
local function nowT() return hs.timer.secondsSinceEpoch() end

function Anim.tick()
  local t = nowT()
  local finished = {}
  local snapshot = {}
  for k, a in pairs(Anim.list) do snapshot[#snapshot + 1] = { k, a } end     -- le animazioni possono crearne altre
  for _, ka in ipairs(snapshot) do
    local k, a = ka[1], ka[2]
    if Anim.list[k] == a then
      local p = clamp01(finite((t - a.t0) / a.dur, 1))
      local okE, ev = pcall(a.ease, p)
      pcall(a.fn, okE and finite(ev, p) or p, p)
      if p >= 1 then finished[#finished + 1] = ka end
    end
  end
  for _, ka in ipairs(finished) do
    local k, a = ka[1], ka[2]
    if Anim.list[k] == a then Anim.list[k] = nil end         -- se nel frattempo è stata rimpiazzata, non toccarla
    if a.done then pcall(a.done) end
  end
  if next(Anim.list) == nil and Anim.timer then Anim.timer:stop(); Anim.timer = nil end
end
-- group+key identificano l'animazione: una nuova con stessa chiave sostituisce la vecchia.
-- La durata segue velocità/animazioni on-off del tema (raw = true: tempi fissi, es. scrollbar).
function Anim.run(group, key, dur, ease, fn, done, raw)
  if not raw then
    if config.animOn == false then dur = 0.001
    else dur = dur * (SPEED_MUL[config.animSpeed] or 1) end
  end
  dur = math.max(0.001, finite(dur, 0.2))
  Anim.list[group .. "|" .. key] = { t0 = nowT(), dur = dur, group = group, fn = fn, done = done,
    ease = (type(ease) == "function") and ease or EASE[ease or "out"] or EASE.out }
  if not Anim.timer then Anim.timer = hs.timer.doEvery(1 / 60, Anim.tick) end
end
function Anim.cancel(group, key)
  for k, a in pairs(Anim.list) do
    if a.group == group and (key == nil or k == group .. "|" .. key) then Anim.list[k] = nil end
  end
  if next(Anim.list) == nil and Anim.timer then Anim.timer:stop(); Anim.timer = nil end
end
local function lerp(a, b, t) return a + (b - a) * t end
local function lerpC(a, b, t)
  local aa, ba = a.alpha or 1, b.alpha or 1
  return { red = lerp(a.red, b.red, t), green = lerp(a.green, b.green, t), blue = lerp(a.blue, b.blue, t), alpha = lerp(aa, ba, t) }
end

-- Hover animato: map[id] = {idx, fill, hoverFill, stroke, hoverStroke, p}
local function hoverTo(cv, map, group, id, entering)
  local h = map[id]; if not h or not cv then return end
  local from, to = h.p or 0, entering and 1 or 0
  if from == to then return end
  Anim.run(group, "hv:" .. id, 0.16, "out", function(e)
    local p = lerp(from, to, e); h.p = p
    if h.fill then cv:elementAttribute(h.idx, "fillColor", lerpC(h.fill, h.hoverFill or h.fill, p)) end
    if h.stroke then cv:elementAttribute(h.idx, "strokeColor", lerpC(h.stroke, h.hoverStroke or h.stroke, p)) end
  end)
end

local fonts, fontsOf
do
-- Font di sistema con fallback sicuri. Tre famiglie per il testo UI (sf / rounded / mono) e
-- tre per il timer; ogni set è risolto una volta sola e messo in cache.
local FONTCACHE = {}
-- prende il primo font che esiste E ha davvero il peso richiesto (se il nome di sistema
-- ricade silenziosamente sul regular, lo scarta e passa al fallback)
local function pickFont(c, want)
  for _, n in ipairs(c) do
    local ok, info = pcall(hs.styledtext.fontInfo, n)
    if ok and type(info) == "table" and info.fontName then
      if not want then return n end
      local fname = tostring(info.fontName):lower()
      for _, w in ipairs(want) do if fname:find(w, 1, true) then return n end end
    end
  end
  return c[#c]
end
local FONT_FAMILY = {
  sf = function() return {
    reg  = pickFont({ ".AppleSystemUIFont", "HelveticaNeue" }),
    semi = pickFont({ ".AppleSystemUIFontDemi", ".AppleSystemUIFontMedium", "HelveticaNeue-Medium" }, { "semibold", "demi", "medium" }),
    bold = pickFont({ ".AppleSystemUIFontBold", "HelveticaNeue-Bold" }, { "bold", "heavy", "black" }),
  } end,
  rounded = function() return {
    reg  = pickFont({ ".AppleSystemUIFontRounded", ".AppleSystemUIFont", "HelveticaNeue" }),
    semi = pickFont({ ".AppleSystemUIFontRounded-Semibold", ".AppleSystemUIFontRounded-Medium", "ArialRoundedMTBold", ".AppleSystemUIFontDemi", "HelveticaNeue-Medium" },
      { "semibold", "demi", "medium", "rounded" }),
    bold = pickFont({ ".AppleSystemUIFontRounded-Bold", "ArialRoundedMTBold", ".AppleSystemUIFontBold", "HelveticaNeue-Bold" }, { "bold", "heavy", "black", "rounded" }),
  } end,
  mono = function() return {
    reg  = pickFont({ ".AppleSystemUIFontMonospaced-Regular", "Menlo-Regular", "Courier" }, { "mono", "menlo", "courier" }),
    semi = pickFont({ ".AppleSystemUIFontMonospaced-Bold", "Menlo-Bold", "Courier-Bold" }, { "mono", "menlo", "courier" }),
    bold = pickFont({ ".AppleSystemUIFontMonospaced-Bold", "Menlo-Bold", "Courier-Bold" }, { "mono", "menlo", "courier" }),
  } end,
}
local function fontFamilyOf(kind)
  kind = FONT_FAMILY[kind] and kind or "sf"
  if not FONTCACHE[kind] then FONTCACHE[kind] = FONT_FAMILY[kind]() end
  return FONTCACHE[kind]
end
-- mono "vero" (etichette dei tasti, timer in modalità mono): invariato rispetto all'originale
local MONO_FIXED = nil
fontsOf = function(kind) return fontFamilyOf(kind) end        -- famiglia di font per nome (per i pack)
fonts = function()
  local ck = tostring(config.uiFont) .. "|" .. tostring(config.timerFont)
  if FONTCACHE[ck] then return FONTCACHE[ck] end
  if not MONO_FIXED then MONO_FIXED = pickFont({ "SFMono-Semibold", "Menlo-Bold" }, { "mono", "menlo" }) end
  local ui = fontFamilyOf(config.uiFont)
  local tkind = config.timerFont
  local tfont = MONO_FIXED
  if tkind == "sf" then tfont = fontFamilyOf("sf").bold
  elseif tkind == "rounded" then tfont = fontFamilyOf("rounded").bold end
  local F = { reg = ui.reg, semi = ui.semi, bold = ui.bold, mono = MONO_FIXED, timer = tfont }
  FONTCACHE[ck] = F
  return F
end
end

------------------------------------------------------------------------
-- ICONE (primitive canvas, tratto arrotondato coerente; sz = lato nominale)
------------------------------------------------------------------------
local ICON = {}
-- log che non lancia mai: con un'istanza `hs -c` morta (client ucciso) print() di Hammerspoon lancia "ipc port is no longer valid"
-- e, dentro un timer/callback, l'errore si propaga e puo' innescare tempeste di errori. Qui si ingoia.
function ICON.log(m) pcall(print, m) end
function ICON.layersOn() return config.layers ~= false end
-- La cache dei dispositivi si aggiorna SOLO a riposo (init, ~3 s dopo la registrazione, apertura impostazioni, evento del watcher audio con
-- debounce): `ffmpeg -list_devices` in parallelo a una registrazione che parte contende AVFoundation e ritarda il mic (visto fino a ~3 s).
function ICON.devSoon(delay)
  if ICON.devT then ICON.devT:stop(); ICON.devT = nil end
  ICON.devT = hs.timer.doAfter(delay or 1.5, function()
    ICON.devT = nil
    local mc = ICON.micS
    if recording or busy or (mc and mc.ph and mc.ph ~= "live") then ICON.devSoon(3); return end     -- occupato: riprova dopo
    refreshDevices()
  end)
end
local function arcPts(cx, cy, r, a0, a1, n)
  local t = {}
  for i = 0, n do
    local a = math.rad(a0 + (a1 - a0) * i / n)
    t[#t + 1] = { x = cx + r * math.cos(a), y = cy + r * math.sin(a) }
  end
  return t
end
local function seg(els, pts, col, sw, closed)
  els[#els + 1] = { type = "segments", action = "stroke", strokeColor = col, strokeWidth = sw, closed = closed or false,
    strokeCapStyle = "round", strokeJoinStyle = "round", coordinates = pts }
end
local function line(els, x1, y1, x2, y2, col, sw) seg(els, { { x = x1, y = y1 }, { x = x2, y = y2 } }, col, sw) end
local function rrect(els, x, y, w, h, r, o)   -- o: fill, stroke, sw
  els[#els + 1] = { type = "rectangle", action = (o.fill and o.stroke) and "strokeAndFill" or (o.fill and "fill" or "stroke"),
    fillColor = o.fill, strokeColor = o.stroke, strokeWidth = o.sw or 1, roundedRectRadii = { xRadius = r, yRadius = r },
    frame = { x = x, y = y, w = w, h = h } }
end

function ICON.mic(els, cx, cy, sz, col)
  local u = sz / 16
  rrect(els, cx - 2.7 * u, cy - 7.4 * u, 5.4 * u, 9.4 * u, 2.7 * u, { fill = col })
  seg(els, arcPts(cx, cy - 0.6 * u, 5.4 * u, 0, 180, 16), col, 1.5 * u)
  line(els, cx, cy + 4.8 * u, cx, cy + 7.2 * u, col, 1.5 * u)
  line(els, cx - 3 * u, cy + 7.2 * u, cx + 3 * u, cy + 7.2 * u, col, 1.5 * u)
end
function ICON.pause(els, cx, cy, sz, col)
  local u = sz / 16; local bw, bh, gap = 3.6 * u, 11 * u, 3.2 * u
  rrect(els, cx - gap / 2 - bw, cy - bh / 2, bw, bh, 1.3 * u, { fill = col })
  rrect(els, cx + gap / 2, cy - bh / 2, bw, bh, 1.3 * u, { fill = col })
end
function ICON.play(els, cx, cy, sz, col)
  local u = sz / 16
  els[#els + 1] = { type = "segments", action = "strokeAndFill", fillColor = col, strokeColor = col, strokeWidth = 1.8 * u,
    strokeJoinStyle = "round", closed = true,
    coordinates = { { x = cx - 3 * u, y = cy - 4.8 * u }, { x = cx - 3 * u, y = cy + 4.8 * u }, { x = cx + 4.8 * u, y = cy } } }
end
function ICON.stop(els, cx, cy, sz, col)
  local u = sz / 16
  rrect(els, cx - 4.4 * u, cy - 4.4 * u, 8.8 * u, 8.8 * u, 2.3 * u, { fill = col })
end
function ICON.gear(els, cx, cy, sz, col)
  local u = sz / 16; local pts = {}
  local R, rr = 7.5 * u, 5.7 * u
  for i = 0, 7 do
    local c = i * 45 - 90
    for _, d in ipairs({ { -15, rr }, { -9, R }, { 9, R }, { 15, rr } }) do
      local a = math.rad(c + d[1])
      pts[#pts + 1] = { x = cx + d[2] * math.cos(a), y = cy + d[2] * math.sin(a) }
    end
  end
  seg(els, pts, col, 1.35 * u, true)
  els[#els + 1] = { type = "circle", action = "stroke", strokeColor = col, strokeWidth = 1.4 * u, center = { x = cx, y = cy }, radius = 2.4 * u }
end
function ICON.clock(els, cx, cy, sz, col)
  local u = sz / 16
  els[#els + 1] = { type = "circle", action = "stroke", strokeColor = col, strokeWidth = 1.5 * u, center = { x = cx, y = cy }, radius = 6.6 * u }
  seg(els, { { x = cx, y = cy - 3.6 * u }, { x = cx, y = cy + 0.2 * u }, { x = cx + 2.8 * u, y = cy + 1.8 * u } }, col, 1.5 * u)
end
function ICON.copy(els, cx, cy, sz, col)
  local u = sz / 16
  rrect(els, cx - 2.2 * u, cy - 2.2 * u, 8.4 * u, 8.8 * u, 2 * u, { stroke = col, sw = 1.5 * u })
  seg(els, { { x = cx + 2 * u, y = cy - 3.4 * u }, { x = cx + 2 * u, y = cy - 6 * u }, { x = cx - 4.6 * u, y = cy - 6 * u },
    { x = cx - 6 * u, y = cy - 4.6 * u }, { x = cx - 6 * u, y = cy + 2.2 * u }, { x = cx - 3.4 * u, y = cy + 2.2 * u } }, col, 1.5 * u)
end
function ICON.check(els, cx, cy, sz, col, sw)
  local u = sz / 16
  seg(els, { { x = cx - 4.6 * u, y = cy + 0.4 * u }, { x = cx - 1.4 * u, y = cy + 3.6 * u }, { x = cx + 4.8 * u, y = cy - 3.6 * u } }, col, (sw or 1.9) * u)
end
function ICON.close(els, cx, cy, sz, col, sw)
  local u = sz / 16; local a = 3.6 * u
  line(els, cx - a, cy - a, cx + a, cy + a, col, (sw or 1.7) * u)
  line(els, cx - a, cy + a, cx + a, cy - a, col, (sw or 1.7) * u)
end
function ICON.plus(els, cx, cy, sz, col, sw)
  local u = sz / 16; local a = 4.6 * u
  line(els, cx - a, cy, cx + a, cy, col, (sw or 1.7) * u)
  line(els, cx, cy - a, cx, cy + a, col, (sw or 1.7) * u)
end
function ICON.sliders(els, cx, cy, sz, col)
  local u = sz / 16
  for i, kx in ipairs({ -2.6, 2.8, -1 }) do
    local y = cy + (i - 2) * 5 * u
    line(els, cx - 6.6 * u, y, cx + 6.6 * u, y, col, 1.4 * u)
    els[#els + 1] = { type = "circle", action = "fill", fillColor = col, center = { x = cx + kx * u, y = y }, radius = 2.1 * u }
  end
end
function ICON.keyboard(els, cx, cy, sz, col)
  local u = sz / 16
  rrect(els, cx - 7.2 * u, cy - 4.8 * u, 14.4 * u, 9.6 * u, 2.4 * u, { stroke = col, sw = 1.4 * u })
  for _, dx in ipairs({ -3.6, 0, 3.6 }) do
    els[#els + 1] = { type = "circle", action = "fill", fillColor = col, center = { x = cx + dx * u, y = cy - 1.6 * u }, radius = 0.85 * u }
  end
  line(els, cx - 3 * u, cy + 1.9 * u, cx + 3 * u, cy + 1.9 * u, col, 1.3 * u)
end
function ICON.orientH(els, cx, cy, sz, col)
  local u = sz / 16
  rrect(els, cx - 7 * u, cy - 3.4 * u, 14 * u, 6.8 * u, 3.4 * u, { stroke = col, sw = 1.4 * u })
  els[#els + 1] = { type = "circle", action = "fill", fillColor = col, center = { x = cx - 3.4 * u, y = cy }, radius = 1.4 * u }
end
function ICON.orientV(els, cx, cy, sz, col)
  local u = sz / 16
  rrect(els, cx - 3.4 * u, cy - 7 * u, 6.8 * u, 14 * u, 3.4 * u, { stroke = col, sw = 1.4 * u })
  els[#els + 1] = { type = "circle", action = "fill", fillColor = col, center = { x = cx, y = cy - 3.4 * u }, radius = 1.4 * u }
end

function ICON.palette(els, cx, cy, sz, col)
  local u = sz / 16
  els[#els + 1] = { type = "circle", action = "stroke", strokeColor = col, strokeWidth = 1.4 * u, center = { x = cx, y = cy }, radius = 6.9 * u }
  for _, p in ipairs({ { -3.1, -2.6 }, { 0.4, -3.9 }, { 3.5, -1.6 }, { -3.6, 1.6 } }) do
    els[#els + 1] = { type = "circle", action = "fill", fillColor = col, center = { x = cx + p[1] * u, y = cy + p[2] * u }, radius = 1.15 * u }
  end
  els[#els + 1] = { type = "circle", action = "fill", fillColor = col, center = { x = cx + 2.2 * u, y = cy + 4 * u }, radius = 1.7 * u }
end
function ICON.sparkle(els, cx, cy, sz, col)
  local u = sz / 16
  local pts, R0, r0 = {}, 7.2 * u, 2.1 * u
  for i = 0, 7 do
    local a = math.rad(i * 45 - 90)
    local rad = (i % 2 == 0) and R0 or r0
    pts[#pts + 1] = { x = cx + rad * math.cos(a), y = cy + rad * math.sin(a) }
  end
  els[#els + 1] = { type = "segments", action = "strokeAndFill", fillColor = col, strokeColor = col, strokeWidth = 1.1 * u,
    strokeJoinStyle = "round", closed = true, coordinates = pts }
end
function ICON.reset(els, cx, cy, sz, col)
  local u = sz / 16
  seg(els, arcPts(cx, cy, 5.6 * u, -40, 220, 22), col, 1.5 * u)
  local a = math.rad(220)
  local ex, ey = cx + 5.6 * u * math.cos(a), cy + 5.6 * u * math.sin(a)
  local dx, dy = -math.sin(a), math.cos(a)            -- tangente nel verso di percorrenza
  local px, py = -dy, dx
  local tx, ty = ex + dx * 1.2 * u, ey + dy * 1.2 * u
  seg(els, { { x = tx - dx * 3.2 * u + px * 2.6 * u, y = ty - dy * 3.2 * u + py * 2.6 * u }, { x = tx, y = ty },
    { x = tx - dx * 3.2 * u - px * 2.6 * u, y = ty - dy * 3.2 * u - py * 2.6 * u } }, col, 1.5 * u)
end

-- icone dei MODI (Dark / Light / Auto)
function ICON.sun(els, cx, cy, sz, col)
  local u = sz / 16
  els[#els + 1] = { type = "circle", action = "fill", fillColor = col, center = { x = cx, y = cy }, radius = 3.2 * u }
  for i = 0, 7 do
    local a = math.rad(i * 45)
    line(els, cx + 5.2 * u * math.cos(a), cy + 5.2 * u * math.sin(a), cx + 7.2 * u * math.cos(a), cy + 7.2 * u * math.sin(a), col, 1.5 * u)
  end
end
function ICON.moon(els, cx, cy, sz, col)
  local u = sz / 16
  local ox, oy = cx - 0.8 * u, cy + 0.8 * u
  local pts = arcPts(ox, oy, 6.4 * u, 9, 261, 22)                 -- arco esterno (lato lungo)
  for _, p in ipairs(arcPts(ox + 3 * u, oy - 3 * u, 5.2 * u, 219.7, 50.3, 16)) do pts[#pts + 1] = p end   -- morso interno
  els[#els + 1] = { type = "segments", action = "strokeAndFill", fillColor = col, strokeColor = col, strokeWidth = 1 * u,
    strokeJoinStyle = "round", closed = true, coordinates = pts }
end
function ICON.auto(els, cx, cy, sz, col)
  local u = sz / 16
  els[#els + 1] = { type = "circle", action = "stroke", strokeColor = col, strokeWidth = 1.5 * u, center = { x = cx, y = cy }, radius = 6.4 * u }
  els[#els + 1] = { type = "segments", action = "fill", fillColor = col, closed = true, coordinates = arcPts(cx, cy, 6.4 * u, 90, 270, 18) }
end

------------------------------------------------------------------------
-- ICONE CUSTOM DEGLI STILI + PARTICELLE
-- Solo primitive canvas, disegnate da zero (motivi generici, nessun marchio). Firma: (els, cx, cy, sz, col, T)
-- col = colore principale (inchiostro dell'accento), T = tema (per i colori del gradiente). Ogni stile sceglie
-- la propria con fx.icon; se manca si usa il microfono standard.
------------------------------------------------------------------------
ICON.c = {}
ICON.parts = {}
do
local C = ICON.c
local function poly(els, pts, fill, stroke, sw)
  els[#els + 1] = { type = "segments", action = (fill and stroke) and "strokeAndFill" or (fill and "fill" or "stroke"),
    fillColor = fill, strokeColor = stroke, strokeWidth = sw or 1, strokeJoinStyle = "round", strokeCapStyle = "round",
    closed = true, coordinates = pts }
end
local function disc(els, x, y, r, fill, stroke, sw)
  els[#els + 1] = { type = "circle", action = (fill and stroke) and "strokeAndFill" or (fill and "fill" or "stroke"),
    fillColor = fill, strokeColor = stroke, strokeWidth = sw or 1, center = { x = x, y = y }, radius = r }
end
local function P(u, cx, cy, list)       -- lista piatta {x1,y1,x2,y2,...} (in unità u) -> punti
  local t = {}
  for i = 1, #list, 2 do t[#t + 1] = { x = cx + list[i] * u, y = cy + list[i + 1] * u } end
  return t
end
local function g(T, i) return T.grad[math.min(i, #T.grad)] or T.accent end

function C.ring(els, cx, cy, sz, col, T)          -- anello dorato + scie di velocità
  local u = sz / 16; local rx = cx + 2.2 * u
  line(els, cx - 7.6 * u, cy - 3.4 * u, cx - 3.8 * u, cy - 3.4 * u, col, 1.4 * u)
  line(els, cx - 8 * u, cy, cx - 2.6 * u, cy, col, 1.4 * u)
  line(els, cx - 7.6 * u, cy + 3.4 * u, cx - 3.8 * u, cy + 3.4 * u, col, 1.4 * u)
  disc(els, rx, cy, 4.6 * u, nil, g(T, 3), 2.7 * u)
  seg(els, arcPts(rx, cy, 4.6 * u, 205, 285, 8), withA(T.fgWhite, 0.8), 1 * u)
end
function C.pixmic(els, cx, cy, sz, col, T)         -- microfono a pixel (7x8 blocchi)
  local u = sz / 16; local px = 1.9 * u
  local rows = { "..###..", "..###..", "..###..", "#.###.#", "#.....#", ".#...#.", "..###..", "...#...", ".#####." }
  local x0, y0 = cx - 3.5 * px, cy - 4.5 * px
  for r, row in ipairs(rows) do
    for c = 1, 7 do
      if row:sub(c, c) == "#" then
        els[#els + 1] = { type = "rectangle", action = "fill", fillColor = (r <= 3 and c == 3 and r == 1) and g(T, 2) or col,
          frame = { x = x0 + (c - 1) * px, y = y0 + (r - 1) * px, w = px + 0.35, h = px + 0.35 } }
      end
    end
  end
end
function C.ball(els, cx, cy, sz, col, T)           -- palla con scia di boost
  local u = sz / 16; local bx, by = cx + 1.6 * u, cy - 1 * u
  poly(els, P(u, cx, cy, { -3.2, 0.2, -8, 7.6, -0.6, 3.6 }), g(T, 2))
  poly(els, P(u, cx, cy, { -3.8, 1.2, -6, 5.2, -2.2, 3 }), withA(T.fgWhite, 0.55))
  disc(els, bx, by, 5.3 * u, nil, col, 1.7 * u)
  local hexa = {}
  for i = 0, 5 do local a = math.rad(i * 60 + 30); hexa[#hexa + 1] = { x = bx + 2.1 * u * math.cos(a), y = by + 2.1 * u * math.sin(a) } end
  poly(els, hexa, col)
end
function C.sofa(els, cx, cy, sz, col, T)           -- divano
  local u = sz / 16
  rrect(els, cx - 5.6 * u, cy - 5.8 * u, 11.2 * u, 6 * u, 2.3 * u, { stroke = col, sw = 1.5 * u })
  rrect(els, cx - 7.6 * u, cy - 1.4 * u, 15.2 * u, 5.8 * u, 2.2 * u, { fill = withA(col, 0.38), stroke = col, sw = 1.5 * u })
  line(els, cx - 5.4 * u, cy + 4.6 * u, cx - 5.4 * u, cy + 7 * u, col, 1.7 * u)
  line(els, cx + 5.4 * u, cy + 4.6 * u, cx + 5.4 * u, cy + 7 * u, col, 1.7 * u)
end
function C.pumpkin(els, cx, cy, sz, col, T)        -- zucca col sorriso
  local u = sz / 16
  rrect(els, cx - 7.4 * u, cy - 3.6 * u, 7.4 * u, 10 * u, 3.7 * u, { fill = col, stroke = T.solid, sw = 0.8 * u })
  rrect(els, cx, cy - 3.6 * u, 7.4 * u, 10 * u, 3.7 * u, { fill = col, stroke = T.solid, sw = 0.8 * u })
  rrect(els, cx - 3.4 * u, cy - 4.4 * u, 6.8 * u, 11 * u, 3.4 * u, { fill = col, stroke = T.solid, sw = 0.8 * u })
  rrect(els, cx - 1 * u, cy - 7.6 * u, 2.2 * u, 3.6 * u, 0.9 * u, { fill = g(T, 3) })
  poly(els, P(u, cx, cy, { -3.6, -0.6, -1.4, -0.6, -2.5, -2.8 }), T.solid)
  poly(els, P(u, cx, cy, { 1.4, -0.6, 3.6, -0.6, 2.5, -2.8 }), T.solid)
  poly(els, P(u, cx, cy, { -3.4, 2, -1.8, 3.6, -0.6, 2.4, 0.6, 3.6, 1.8, 2.4, 3.4, 2, 2.6, 4.6, -2.6, 4.6 }), T.solid)
end
function C.tree(els, cx, cy, sz, col, T)           -- albero di Natale
  local u = sz / 16; local gc = g(T, 3)
  rrect(els, cx - 1.2 * u, cy + 5 * u, 2.4 * u, 2.6 * u, 0.6 * u, { fill = col })
  poly(els, P(u, cx, cy, { 0, -1.2, -7, 5.2, 7, 5.2 }), gc, gc, 1 * u)
  poly(els, P(u, cx, cy, { 0, -4.2, -5.5, 2, 5.5, 2 }), gc, gc, 1 * u)
  poly(els, P(u, cx, cy, { 0, -7, -4, -2, 4, -2 }), gc, gc, 1 * u)
  disc(els, cx, cy - 7.6 * u, 1.3 * u, g(T, 2))
  disc(els, cx - 2.6 * u, cy + 3.4 * u, 0.9 * u, g(T, 1)); disc(els, cx + 2.8 * u, cy + 4 * u, 0.9 * u, g(T, 2))
  disc(els, cx + 0.4 * u, cy - 0.2 * u, 0.8 * u, g(T, 1))
end
function C.stick(els, cx, cy, sz, col, T)          -- joystick da sala giochi
  local u = sz / 16
  rrect(els, cx - 6.4 * u, cy + 2.6 * u, 12.8 * u, 4.6 * u, 1.6 * u, { fill = col })
  line(els, cx, cy + 2.6 * u, cx, cy - 2.6 * u, col, 1.9 * u)
  disc(els, cx, cy - 4.4 * u, 3.5 * u, g(T, 2))
  disc(els, cx - 1 * u, cy - 5.4 * u, 1 * u, withA(T.fgWhite, 0.6))
end
function C.shield(els, cx, cy, sz, col, T)         -- scudo con croce
  local u = sz / 16
  poly(els, P(u, cx, cy, { -5.6, -6, 5.6, -6, 5.6, -1, 4.6, 2.8, 2.4, 5.5, 0, 7, -2.4, 5.5, -4.6, 2.8, -5.6, -1 }),
    withA(col, 0.28), col, 1.5 * u)
  line(els, cx, cy - 3.4 * u, cx, cy + 3.8 * u, g(T, 2), 1.6 * u)
  line(els, cx - 3 * u, cy - 0.6 * u, cx + 3 * u, cy - 0.6 * u, g(T, 2), 1.6 * u)
end
function C.bolt(els, cx, cy, sz, col, T)           -- fulmine
  local u = sz / 16
  poly(els, P(u, cx, cy, { 1.6, -7.6, -4.2, 0.8, -0.4, 0.8, -1.8, 7.6, 4.6, -1.6, 0.6, -1.6 }), col, col, 1 * u)
end
function C.shroom(els, cx, cy, sz, col, T)         -- fungo
  local u = sz / 16
  rrect(els, cx - 2.6 * u, cy + 0.2 * u, 5.2 * u, 6 * u, 1.8 * u, { fill = g(T, 2) })
  poly(els, arcPts(cx, cy + 0.8 * u, 7.2 * u, 180, 360, 18), col, col, 1 * u)
  disc(els, cx - 3 * u, cy - 2.2 * u, 1.5 * u, withA(T.fgWhite, 0.9)); disc(els, cx + 2.9 * u, cy - 3 * u, 1.3 * u, withA(T.fgWhite, 0.9))
  disc(els, cx + 0.1 * u, cy - 4.4 * u, 1 * u, withA(T.fgWhite, 0.9))
end
function C.sunset(els, cx, cy, sz, col, T)         -- sole retro a strisce
  local u = sz / 16
  poly(els, arcPts(cx, cy + 0.6 * u, 6.4 * u, 180, 360, 20), col)
  for i, w in ipairs({ 11, 8.4, 5.6 }) do
    line(els, cx - w / 2 * u, cy + (1.8 + i * 1.9) * u, cx + w / 2 * u, cy + (1.8 + i * 1.9) * u, g(T, 2), 1.3 * u)
  end
end
function C.flower(els, cx, cy, sz, col, T)         -- fiore a 5 petali
  local u = sz / 16
  for i = 0, 4 do
    local a = math.rad(-90 + i * 72)
    disc(els, cx + 3.6 * u * math.cos(a), cy + 3.6 * u * math.sin(a), 2.8 * u, withA(col, 0.88))
  end
  disc(els, cx, cy, 1.7 * u, g(T, 2))
end
function C.cactus(els, cx, cy, sz, col, T)         -- cactus
  local u = sz / 16
  rrect(els, cx - 1.8 * u, cy - 6.4 * u, 3.6 * u, 13.2 * u, 1.8 * u, { fill = col })
  seg(els, P(u, cx, cy, { -1.8, 1.4, -4.8, 1.4, -4.8, -2.4 }), col, 2.6 * u)
  seg(els, P(u, cx, cy, { 1.8, -0.6, 4.8, -0.6, 4.8, -4.2 }), col, 2.6 * u)
  line(els, cx - 6.4 * u, cy + 7.4 * u, cx + 6.4 * u, cy + 7.4 * u, g(T, 2), 1.4 * u)
end
function C.planet(els, cx, cy, sz, col, T)         -- pianeta con anello
  local u = sz / 16
  disc(els, cx, cy, 4.4 * u, col)
  local ring, ca, sa = {}, math.cos(math.rad(-22)), math.sin(math.rad(-22))
  for i = 0, 23 do
    local a = i / 24 * 2 * math.pi
    local x, y = 8 * u * math.cos(a), 2.5 * u * math.sin(a)
    ring[#ring + 1] = { x = cx + x * ca - y * sa, y = cy + x * sa + y * ca }
  end
  poly(els, ring, nil, g(T, 2), 1.4 * u)
end
function C.skull(els, cx, cy, sz, col, T)          -- teschio con ossa incrociate
  local u = sz / 16
  line(els, cx - 7 * u, cy + 6.4 * u, cx + 7 * u, cy + 1 * u, g(T, 2), 1.6 * u)
  line(els, cx - 7 * u, cy + 1 * u, cx + 7 * u, cy + 6.4 * u, g(T, 2), 1.6 * u)
  disc(els, cx, cy - 1.8 * u, 5.2 * u, col)
  rrect(els, cx - 2.8 * u, cy + 1.6 * u, 5.6 * u, 4 * u, 1.2 * u, { fill = col })
  disc(els, cx - 2 * u, cy - 1.6 * u, 1.45 * u, T.solid); disc(els, cx + 2 * u, cy - 1.6 * u, 1.45 * u, T.solid)
  line(els, cx - 0.9 * u, cy + 3.6 * u, cx - 0.9 * u, cy + 5.4 * u, T.solid, 0.8 * u)
  line(els, cx + 0.9 * u, cy + 3.6 * u, cx + 0.9 * u, cy + 5.4 * u, T.solid, 0.8 * u)
end
function C.heart(els, cx, cy, sz, col, T)          -- cuore
  local u = sz / 16; local pts = {}
  for i = 0, 27 do
    local t = i / 28 * 2 * math.pi
    pts[#pts + 1] = { x = cx + 0.42 * u * 16 * math.sin(t) ^ 3,
      y = cy - 0.42 * u * (13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)) + 0.6 * u }
  end
  poly(els, pts, col, col, 1 * u)
end
function C.clap(els, cx, cy, sz, col, T)           -- ciak
  local u = sz / 16
  rrect(els, cx - 6.6 * u, cy - 1.8 * u, 13.2 * u, 8.6 * u, 1.5 * u, { stroke = col, sw = 1.5 * u })
  rrect(els, cx - 6.6 * u, cy - 6.2 * u, 13.2 * u, 3.8 * u, 1 * u, { fill = col })
  for i = 0, 2 do line(els, cx - 4.4 * u + i * 4 * u, cy - 6.1 * u, cx - 2.6 * u + i * 4 * u, cy - 2.5 * u, T.solid, 1.2 * u) end
end
function C.snow(els, cx, cy, sz, col, T)           -- fiocco di neve
  local u = sz / 16
  for i = 0, 5 do
    local a = math.rad(i * 60 - 90)
    local ca, sa = math.cos(a), math.sin(a)
    line(els, cx, cy, cx + 7.2 * u * ca, cy + 7.2 * u * sa, col, 1.5 * u)
    local bx, by = cx + 4.4 * u * ca, cy + 4.4 * u * sa
    for _, d in ipairs({ 55, -55 }) do
      local b = a + math.rad(d)
      line(els, bx, by, bx + 2.2 * u * math.cos(b), by + 2.2 * u * math.sin(b), col, 1.3 * u)
    end
  end
end
function C.cone(els, cx, cy, sz, col, T)           -- cono gelato
  local u = sz / 16
  poly(els, P(u, cx, cy, { -3.8, -0.4, 3.8, -0.4, 0, 7.6 }), g(T, 3), g(T, 3), 1 * u)
  disc(els, cx, cy - 2.6 * u, 4.4 * u, col)
  disc(els, cx + 0.4 * u, cy - 7 * u, 1.2 * u, g(T, 2))
end
function C.sun(els, cx, cy, sz, col, T) ICON.sun(els, cx, cy, sz, col) end
function C.gear(els, cx, cy, sz, col, T) ICON.gear(els, cx, cy, sz, col) end

-- disegna l'icona custom dello stile (id) o, se manca, il microfono standard
function ICON.drawFx(els, id, cx, cy, sz, col, T)
  local f = id and C[id]
  if f then f(els, cx, cy, sz, col, T) else ICON.mic(els, cx, cy, sz, col) end
end

------------------------------------------------------------------------
-- PARTICELLE leggere dentro la pillola (solo se lo stile ha fx.part e le animazioni sono attive).
-- Nessuno stato per particella: posizione = funzione del tempo → nessun accumulo, nessun NaN.
-- shape: c = punto, r = coriandolo/petalo, l = riga (pioggia), o = bolla (anello), b = pipistrello, s = stella
------------------------------------------------------------------------
local PT = ICON.parts
PT.snow    = { n = 12, shape = "c", cycle = 7.5, sway = 2, drift = 4, size = 1.5, a = 0.85, dir = 1 }
PT.petals  = { n = 9,  shape = "r", cycle = 6.5, sway = 1.5, drift = 7, size = 2.4, a = 0.8, dir = 1 }
PT.confetti = { n = 12, shape = "r", cycle = 4.2, sway = 3, drift = 3, size = 1.9, a = 0.85, dir = 1 }
PT.rain    = { n = 10, shape = "l", cycle = 1.9, sway = 0, drift = 0, size = 6, a = 0.75, dir = 1 }
PT.bubbles = { n = 8,  shape = "o", cycle = 5.5, sway = 2, drift = 3, size = 2.2, a = 0.7, dir = -1 }
PT.stars   = { n = 10, shape = "s", cycle = 1, sway = 0, drift = 0, size = 1.3, a = 0.9, dir = 0 }
PT.bats    = { n = 3,  shape = "b", cycle = 5.2, sway = 2, drift = 0, size = 3.4, a = 0.8, dir = 0 }

local function ptCol(kind, i, n)
  if kind == "snow" or kind == "stars" then return COL.dark and COL.fg or COL.accentInk end
  if kind == "bats" then return COL.dark and COL.accent2 or COL.accentInk end
  if kind == "rain" or kind == "bubbles" then return COL.accent end
  return gradAt(COL, (i - 1) / math.max(1, n - 1))
end
-- elementi (nell'ordine) da aggiungere a els; ritorna { kind, idx = {...}, ox, oy, w, h, s }
function ICON.partsBuild(els, ox, oy, w, h, s, lite)
  local kind = COL.fx and COL.fx.part
  local spec = kind and PT[kind]
  if not spec then return nil end
  if spec.build then return spec.build(els, ox, oy, w, h, s, lite, spec) end        -- particelle custom del pack
  local R = { kind = kind, idx = {}, ox = ox, oy = oy, w = w, h = h, s = s }
  for i = 1, (lite and math.ceil(spec.n * 0.5) or spec.n) do
    local col = withA(ptCol(kind, i, spec.n), 0)
    local el
    if spec.shape == "c" or spec.shape == "s" then
      el = { type = "circle", action = "fill", fillColor = col, center = { x = ox + w / 2, y = oy + h / 2 }, radius = spec.size * s }
    elseif spec.shape == "r" then
      el = { type = "rectangle", action = "fill", fillColor = col, roundedRectRadii = { xRadius = spec.size * s * 0.6, yRadius = spec.size * s * 0.6 },
        frame = { x = ox + w / 2, y = oy + h / 2, w = spec.size * 2 * s, h = spec.size * 1.3 * s } }
    elseif spec.shape == "o" then
      el = { type = "circle", action = "stroke", strokeColor = col, strokeWidth = 1 * s, center = { x = ox + w / 2, y = oy + h / 2 }, radius = spec.size * s }
    else
      el = { type = "segments", action = "stroke", strokeColor = col, strokeWidth = (spec.shape == "l" and 1.1 or 1.3) * s,
        strokeCapStyle = "round", strokeJoinStyle = "round", coordinates = { { x = ox + w / 2, y = oy + h / 2 }, { x = ox + w / 2 + 1, y = oy + h / 2 + 1 } } }
    end
    els[#els + 1] = el
    R.idx[i] = #els
  end
  return R
end
-- aggiorna le particelle al tempo t (visible = false: le nasconde una volta sola)
function ICON.partsTick(cv, R, t, visible)
  if not R then return end
  local spec = PT[R.kind]
  if not spec then return end
  if spec.tick then return spec.tick(cv, R, t, visible, spec) end
  if not visible then
    if not R.hidden then
      R.hidden = true
      for _, ix in ipairs(R.idx) do
        cv:elementAttribute(ix, spec.shape == "o" and "strokeColor" or "fillColor", withA(CLEAR, 0))
        if spec.shape == "l" or spec.shape == "b" then cv:elementAttribute(ix, "strokeColor", withA(CLEAR, 0)) end
      end
    end
    return
  end
  R.hidden = false
  local s, w, h = R.s, R.w, R.h
  local pad = 9 * s
  local n = spec.n
  for i, ix in ipairs(R.idx) do
    local seed = (i * 0.6180339887) % 1
    local x0 = pad + ((i * 0.7548776662 + 0.13) % 1) * math.max(1, w - 2 * pad)
    local life = spec.cycle * (0.8 + 0.4 * ((i * 0.31) % 1))
    local u = ((t / life) + seed) % 1
    local col = ptCol(R.kind, i, n)
    local a = spec.a
    local x, y
    if spec.shape == "s" then                                   -- stelle ferme che brillano
      x = x0; y = 6 * s + ((i * 0.4142 + 0.2) % 1) * math.max(1, h - 12 * s)
      a = a * (0.15 + 0.85 * spow(math.sin(finite(t * 1.3 + seed * 9, 0)) * 0.5 + 0.5, 2))
    elseif spec.shape == "b" then                               -- pipistrelli che attraversano la pillola
      x = 4 * s + u * (w - 8 * s)
      y = h * (0.25 + 0.5 * seed) + math.sin(finite(u * 12 + seed * 6, 0)) * h * 0.14
      a = a * math.sin(u * math.pi)
    else
      local span = math.max(1, h - 8 * s)
      y = (spec.dir >= 0) and (4 * s + u * span) or (h - 4 * s - u * span)
      x = x0 + math.sin(finite((u * spec.sway + seed) * 2 * math.pi, 0)) * spec.drift * s
      a = a * math.sin(u * math.pi)
    end
    a = clampN(a, 0, 1)
    x, y = finite(R.ox + x, R.ox), finite(R.oy + y, R.oy)
    local cc = withA(col, a)
    if spec.shape == "c" or spec.shape == "s" then
      cv:elementAttribute(ix, "center", { x = x, y = y }); cv:elementAttribute(ix, "fillColor", cc)
    elseif spec.shape == "r" then
      local wob = 0.75 + 0.25 * math.sin(finite(t * 3 + i, 0))
      cv:elementAttribute(ix, "frame", { x = x, y = y, w = spec.size * 2 * s * wob, h = spec.size * 1.3 * s })
      cv:elementAttribute(ix, "fillColor", cc)
    elseif spec.shape == "o" then
      cv:elementAttribute(ix, "center", { x = x, y = y }); cv:elementAttribute(ix, "strokeColor", cc)
    elseif spec.shape == "l" then
      cv:elementAttribute(ix, "coordinates", { { x = x, y = y }, { x = x, y = y + spec.size * s } }); cv:elementAttribute(ix, "strokeColor", cc)
    else                                                         -- pipistrello: due ali che sbattono
      local fl = math.sin(finite(t * 11 + seed * 5, 0)) * 0.8
      local k = spec.size * s
      cv:elementAttribute(ix, "coordinates", { { x = x - 2 * k, y = y + fl * k * 0.9 }, { x = x - 0.9 * k, y = y - 0.5 * k + fl * k * 0.2 },
        { x = x, y = y + 0.5 * k }, { x = x + 0.9 * k, y = y - 0.5 * k + fl * k * 0.2 }, { x = x + 2 * k, y = y + fl * k * 0.9 } })
      cv:elementAttribute(ix, "strokeColor", cc)
    end
  end
end
end

------------------------------------------------------------------------
-- VETRO: ombre multi-strato + corpo traslucido + riflesso + bordo luminoso
-- (hs.canvas non ha blur dello sfondo: la profondità è simulata)
-- Alone accento (glowOn): 8 strati tinti con l'accento (sfumano tra i colori del tema).
------------------------------------------------------------------------
local NCARD = 25          -- slot riservati: 8 alone + 8 ambient + 4 contatto + corpo/riflesso/highlight/filo gradiente/bordo

pushShadow = function(list, x, y, w, h, s, radius, mul, noGlow, lite)
  local glow = (config.glowOn == true) and not noGlow
  local shadow = (config.shadowOn ~= false)
  if not glow and not shadow then return end
  -- LIMITI: scala, intensita' ed estensioni sono clampate (px). Prima nessun tetto: scala/intensita' fuori range o un alone sommato
  -- all'ombra su una finestra grande (impostazioni 800x760) davano un'ombra "gigante"; ora ombra <= 24 px (+10 di offset),
  -- alone <= 14 px e alpha cumulata <= ~0.26 (il pannello grande non amplifica piu' l'alone: mul massimo 1).
  s = clampN(finite(s, 1), 0.3, 1.6)
  local k = clampN(tonumber(config.shadowIntensity) or 0.5, 0, 1)
  local m = clampN(finite(mul or 1, 1), 0, 2) * (COL.shadowK or 1)
  if glow then
    local gn = lite and 4 or 8
    local ga = (COL.dark and 0.036 or 0.032) * clampN(finite(mul or 1, 1), 0, 1) * (8 / gn)
    for i = 1, gn do
      local e = math.min(i * 1.8 * (8 / gn) * math.min(s, 1.4), 14)
      local c = COL.multi and gradAt(COL, (i - 1) / (gn - 1)) or COL.accent
      list[#list + 1] = { type = "rectangle", action = "fill", fillColor = withA(c, ga),
        roundedRectRadii = { xRadius = radius + e, yRadius = radius + e },
        frame = { x = x - e, y = y - e, w = w + 2 * e, h = h + 2 * e } }
    end
  end
  if not shadow then return end
  local an = lite and 3 or 8
  local off = math.min(8 * s * k, 10)
  for i = 1, an do                       -- ambient: ampia e morbida
    local e = math.min(i * 2.6 * (8 / an) * s * k, 24)
    list[#list + 1] = { type = "rectangle", action = "fill", fillColor = { red = 0, green = 0, blue = 0, alpha = 0.021 * (8 / an) * m },
      roundedRectRadii = { xRadius = radius + e, yRadius = radius + e },
      frame = { x = x - e, y = y - e + off, w = w + 2 * e, h = h + 2 * e } }
  end
  for i = 1, (lite and 1 or 4) do        -- contatto: stretta e più scura
    local e = math.min((lite and 2.4 or i * 0.9) * s * k, 6)
    list[#list + 1] = { type = "rectangle", action = "fill", fillColor = { red = 0, green = 0, blue = 0, alpha = (lite and 0.13 or 0.05) * m },
      roundedRectRadii = { xRadius = radius + e, yRadius = radius + e },
      frame = { x = x - e, y = y - e + math.min(2 * s * k, 3) + 1, w = w + 2 * e, h = h + 2 * e } }
  end
end

-- Corpo "clear glass". Ritorna (indice bordo, indice corpo).
-- o: { id = "drag", s = scala, shadow = false, shadowMul = n, border = colore, bw = spessore }
pushGlass = function(list, x, y, w, h, r, o)
  o = o or {}
  local s = o.s or 1
  r = math.max(1, math.min(r, h / 2, w / 2))
  if o.shadow ~= false then pushShadow(list, x, y, w, h, s, r, o.shadowMul, nil, o.lite) end
  local body = #list + 1
  list[body] = { type = "rectangle", action = "fill", fillColor = COL.bg,
    roundedRectRadii = { xRadius = r, yRadius = r }, frame = { x = x, y = y, w = w, h = h },
    fillGradient = "linear", fillGradientAngle = 90, fillGradientColors = { COL.bg, COL.bg2 },
    trackMouseDown = o.id and true or nil, id = o.id }
  -- riflesso: metà superiore, curva con gli angoli
  local sh = o.sheenH or h * 0.5
  local rr = math.max(1, math.min(r - 1, sh))
  local sp = { { x = x + 1, y = y + sh } }
  for _, p in ipairs(arcPts(x + 1 + rr, y + 1 + rr, rr, 180, 270, 10)) do sp[#sp + 1] = p end
  for _, p in ipairs(arcPts(x + w - 1 - rr, y + 1 + rr, rr, 270, 360, 10)) do sp[#sp + 1] = p end
  sp[#sp + 1] = { x = x + w - 1, y = y + sh }
  list[#list + 1] = { type = "segments", action = "fill", fillColor = withA(COL.sheen, (COL.sheen.alpha or 0.04) * (o.sheenA or 1)),
    closed = true, coordinates = sp }
  -- highlight 1px lungo il bordo alto (luce che entra dall'alto)
  local hl = {}
  for _, p in ipairs(arcPts(x + r, y + r, math.max(0.5, r - 0.8), 212, 270, 8)) do hl[#hl + 1] = p end
  for _, p in ipairs(arcPts(x + w - r, y + r, math.max(0.5, r - 0.8), 270, 328, 8)) do hl[#hl + 1] = p end
  seg(list, hl, COL.hi, 1)
  -- (filo gradiente sul bordo basso rimosso: si vedeva come striscia sotto la card.
  --  L'elemento resta, invisibile, per non spostare gli slot riservati NCARD.)
  list[#list + 1] = { type = "rectangle", action = "fill", fillColor = { red = 0, green = 0, blue = 0, alpha = 0 },
    frame = { x = x, y = y + h - 2, w = 1, h = 1 } }
  -- bordo
  local border = #list + 1
  list[border] = { type = "rectangle", action = "stroke", strokeColor = o.border or COL.border, strokeWidth = o.bw or 1,
    roundedRectRadii = { xRadius = r, yRadius = r }, frame = { x = x + 0.5, y = y + 0.5, w = w - 1, h = h - 1 } }
  return border, body
end

------------------------------------------------------------------------
-- COMPONENTI: hit-layer con hover animato, bottoni tondi, testo
------------------------------------------------------------------------
local function hitRect(els, map, id, x, y, w, h, r, o)
  local idx = #els + 1
  els[idx] = { type = "rectangle", action = o.stroke and "strokeAndFill" or "fill", fillColor = o.fill, strokeColor = o.stroke,
    strokeWidth = o.sw or 1, roundedRectRadii = { xRadius = r, yRadius = r }, frame = { x = x, y = y, w = w, h = h },
    trackMouseUp = true, trackMouseEnterExit = true, id = id }
  map[id] = { idx = idx, fill = o.fill, hoverFill = o.hoverFill, stroke = o.stroke, hoverStroke = o.hoverStroke }
  return idx
end
local function hitCircle(els, map, id, cx, cy, r, o)
  local idx = #els + 1
  els[idx] = { type = "circle", action = o.stroke and "strokeAndFill" or "fill", fillColor = o.fill, strokeColor = o.stroke,
    strokeWidth = o.sw or 1, center = { x = cx, y = cy }, radius = r,
    trackMouseUp = true, trackMouseEnterExit = true, id = id }
  map[id] = { idx = idx, fill = o.fill, hoverFill = o.hoverFill, stroke = o.stroke, hoverStroke = o.hoverStroke }
  return idx
end
-- forma "tonda" che segue l'angolo scelto: cerchio se tondo, quadrato arrotondato altrimenti
local function btnRadius(r)
  local sp = ICON.hudShape                       -- pack con forma propria (solo mentre si disegna l'HUD)
  if sp and sp.btn then return math.max(1, r * sp.btn) end
  return math.max(2, r * (RADIUS_MUL[config.cornerStyle] or 1))
end
local function isRoundStyle()
  local sp = ICON.hudShape
  if sp and sp.btn then return sp.btn >= 0.99 end
  return (RADIUS_MUL[config.cornerStyle] or 1) >= 0.99
end
-- hit-layer interattivo (map) oppure forma statica (map == nil: anteprima)
local function hitShape(els, map, id, cx, cy, r, o)
  if not map then
    local el
    if isRoundStyle() then
      el = { type = "circle", action = o.stroke and "strokeAndFill" or "fill", fillColor = o.fill, strokeColor = o.stroke,
        strokeWidth = o.sw or 1, center = { x = cx, y = cy }, radius = r }
    else
      el = { type = "rectangle", action = o.stroke and "strokeAndFill" or "fill", fillColor = o.fill, strokeColor = o.stroke,
        strokeWidth = o.sw or 1, roundedRectRadii = { xRadius = btnRadius(r), yRadius = btnRadius(r) },
        frame = { x = cx - r, y = cy - r, w = 2 * r, h = 2 * r } }
    end
    els[#els + 1] = el
    return #els
  end
  if isRoundStyle() then return hitCircle(els, map, id, cx, cy, r, o) end
  return hitRect(els, map, id, cx - r, cy - r, 2 * r, 2 * r, btnRadius(r), o)
end

-- bottone tondo. kind: "primary" (gradiente accento) | "ghost" (vetro con bordo)
-- icon(els, cx, cy) disegna il glifo sopra. map == nil → solo disegno (anteprima).
local function circleButton(els, map, id, cx, cy, r, kind, icon, s)
  s = s or 1
  if kind == "primary" then
    local el
    if isRoundStyle() then
      el = { type = "circle", action = "fill", fillColor = COL.accent, center = { x = cx, y = cy }, radius = r,
        fillGradient = "linear", fillGradientAngle = COL.multi and 45 or 90, fillGradientColors = COL.grad }
    else
      el = { type = "rectangle", action = "fill", fillColor = COL.accent, roundedRectRadii = { xRadius = btnRadius(r), yRadius = btnRadius(r) },
        frame = { x = cx - r, y = cy - r, w = 2 * r, h = 2 * r },
        fillGradient = "linear", fillGradientAngle = COL.multi and 45 or 90, fillGradientColors = COL.grad }
    end
    els[#els + 1] = el
    hitShape(els, map, id, cx, cy, r, { fill = withA(COL.fgWhite, 0), hoverFill = withA(COL.fgWhite, 0.22) })
  else
    hitShape(els, map, id, cx, cy, r, { fill = COL.rowBg, hoverFill = COL.accentSoft,
      stroke = COL.borderSoft, hoverStroke = COL.border, sw = 1 * s })
  end
  if icon then icon(els, cx, cy) end
end

local function txt(els, text, x, y, w, h, size, color, o)
  o = o or {}
  els[#els + 1] = { type = "text", text = text, textSize = size, textColor = color, textFont = fonts()[o.font or "reg"],
    textAlignment = o.align or "left", textLineBreak = o.lb or "truncateTail", frame = { x = x, y = y, w = w, h = h } }
  return #els
end

-- avvisi di sistema (hs.alert) nello stile del tema corrente
gwAlert = function(msg, dur)
  local ok = pcall(function()
    local style = { fillColor = withA(COL.solid, 0.94), strokeColor = COL.border, strokeWidth = 1, radius = 16,
      textColor = COL.fg, textFont = fonts().semi, textSize = 14, padding = 16,
      fadeInDuration = 0.14, fadeOutDuration = 0.35 }
    hs.alert.show(msg, style, hs.screen.mainScreen(), dur or 2)
  end)
  if not ok then hs.alert.show(msg, dur or 2) end
end

local function setAlphaAttr(cv, idx, attr, col, a) cv:elementAttribute(idx, attr, withA(col, a)) end

------------------------------------------------------------------------
-- HUD
------------------------------------------------------------------------
local animBusy = false      -- true mentre l'HUD sta entrando/uscendo (la guardia non lo riposiziona)
local PROC = nil            -- stato HUD "processing" (spinner / esito)

-- tooltip: pillola di vetro sopra il bottone, compare/scompare con dissolvenza
local function showTip(id, on)
  local I = RECIDX
  if not (overlay and mode == "rec" and I and I.tipBg and I.tips) then return end
  if on then
    local tip = I.tips[id]; if not tip then return end
    local s = I.s
    local w = (utf8.len(tip.label) or #tip.label) * 6.6 * s + 20 * s
    local h = 20 * s
    local fr = { x = tip.cx - w / 2, y = I.tipTop, w = w, h = h }
    overlay:elementAttribute(I.tipBg, "frame", fr)
    overlay:elementAttribute(I.tipText, "frame", { x = fr.x, y = fr.y + 3 * s, w = w, h = h })
    overlay:elementAttribute(I.tipText, "text", tip.label)
    I.tipOn = true
  else
    I.tipOn = false
  end
  local from = I.tipA or 0
  local to = on and 1 or 0
  Anim.run("hudtip", "a", on and 0.14 or 0.1, "out", function(e)
    local a = lerp(from, to, e); I.tipA = a
    overlay:elementAttribute(I.tipBg, "fillColor", withA(COL.solid, 0.96 * a))
    overlay:elementAttribute(I.tipBg, "strokeColor", withA(COL.border, a))
    overlay:elementAttribute(I.tipText, "textColor", withA(COL.fg, a))
  end)
end

mouseCb = function(_c, msg, id)
  if msg == "mouseEnter" then hoverTo(overlay, hoverMap, "hudhv", id, true); showTip(id, true); return
  elseif msg == "mouseExit" then hoverTo(overlay, hoverMap, "hudhv", id, false); showTip(id, false); return
  elseif msg == "mouseDown" then
    ICON.relayer(overlay, true)           -- il click porta la base sopra gli strati: li rimette sopra
    if id == "drag" then startDrag() end
    return
  elseif msg == "mouseUp" then
    ICON.relayer(overlay, true)
    -- l'azione parte DOPO il callback: ricostruire/cancellare canvas dentro il callback mouse della canvas stessa e' fragile
    hs.timer.doAfter(0.01, function()
      local ok, err = pcall(ICON.hudAction, id)
      if not ok then ICON.log("[GW] azione HUD " .. tostring(id) .. ": " .. tostring(err)) end
    end)
  end
end
function ICON.hudAction(id)
  if id == "pause" then M.togglePause()
  elseif id == "stop" then M.stop()
  elseif id == "settings" then openSettings()
  elseif id == "cancel" then M.cancel()
  elseif id == "egg" then ICON.eggClick(overlay, RECIDX)
  elseif id == "close" then hideOverlay() end
end

placeCanvas = function(w, h)
  -- sempre sullo schermo attivo (quello della finestra in primo piano)
  local main = hs.screen.mainScreen()
  local sf = main:frame()
  local cx, cy
  if config.posX and config.posY then
    cx, cy = config.posX, config.posY
    -- posizione salvata su un altro schermo → stessa posizione relativa su quello attivo
    local src = hs.geometry.point(cx, cy)
    local home
    for _, scr in ipairs(hs.screen.allScreens()) do if src:inside(scr:frame()) then home = scr; break end end
    if home and home:id() ~= main:id() then
      local hf = home:frame()
      cx = sf.x + (cx - hf.x) / hf.w * sf.w
      cy = sf.y + (cy - hf.y) / hf.h * sf.h
    end
  else cx = sf.x + sf.w / 2; cy = sf.y + sf.h - 24 - h / 2 end
  local fx = math.max(sf.x, math.min(cx - w / 2, sf.x + sf.w - w))
  local fy = math.max(sf.y, math.min(cy - h / 2, sf.y + sf.h - h))
  finalFrame = { x = math.floor(fx), y = math.floor(fy), w = w, h = h }
  if not overlay then
    overlay = ICON.wrap(hs.canvas.new(finalFrame))       -- proxy: base statica + canvas piccola animata (vedi STRATI)
    -- livello screenSaver: sopra qualsiasi finestra, anche fullscreen/presentazioni
    overlay:level(hs.canvas.windowLevels.screenSaver or hs.canvas.windowLevels.overlay)
    -- niente "stationary": lega la finestra al desktop → scorreva col background al cambio Space
    overlay:behavior(config.overlayBehavior or { "canJoinAllSpaces", "fullScreenAuxiliary", "ignoresCycle" })
    overlay:clickActivating(false)
    overlay:mouseCallback(mouseCb)
  else
    overlay:frame(finalFrame)
  end
end

dragCanvas = function(cv, persistPos, onDone)
  if not cv then return end
  if dragTap then dragTap:stop(); dragTap = nil end
  local m0 = hs.mouse.absolutePosition()
  local f0 = cv:frame()
  local off = { dx = m0.x - f0.x, dy = m0.y - f0.y }
  local moved = false
  dragTap = hs.eventtap.new({ hs.eventtap.event.types.leftMouseDragged, hs.eventtap.event.types.leftMouseUp }, function(e)
    if e:getType() == hs.eventtap.event.types.leftMouseUp then
      dragTap:stop(); dragTap = nil
      if moved and persistPos and cv then
        local f = cv:frame()
        config.posX = f.x + f.w / 2; config.posY = f.y + f.h / 2
        persist("posX", math.floor(config.posX)); persist("posY", math.floor(config.posY))
      end
      if moved and onDone and cv then onDone(cv:frame()) end
      return false
    end
    moved = true
    local m = hs.mouse.absolutePosition()
    local nx, ny = m.x - off.dx, m.y - off.dy
    cv:topLeft({ x = nx, y = ny })
    if cv == overlay and finalFrame then finalFrame.x = nx; finalFrame.y = ny end
    return false
  end)
  dragTap:start()
end
startDrag = function() dragCanvas(overlay, true) end


------------------------------------------------------------------------
-- PACK FX: estensioni opzionali di fx per stile (nessuna per gli stili normali = comportamento invariato).
--   fx.shape  = id in ICON.shapes  { r = moltiplicatore raggio card, btn = moltiplicatore raggio bottoni (<1 = squadrati) }
--   fx.body   = id in ICON.bodies  function(els,x,y,w,h,s,r,o,kind) -> bordo, corpo, colore bordo   (kind = "rec" | "proc")
--   fx.barCol = { dark = "hex", light = "hex" }  colore fisso delle barre onda
--   fx.meter  = id in ICON.meters  { build(els,I,ox,oy,s,vertical) -> m, tick(cv,I,m,lv,active,warn,t,dt) }
--   fx.part   = anche id custom in ICON.parts con build()/tick()  (<= 12 elementi, ~16Hz, solo se registra e animOn)
--   fx.proc   = id in ICON.proc    spinner  { build(els,cx,cy,s) -> st ; tick(cv,st,t) ; hide(cv,st) }
--   fx.done   = id in ICON.done    spunta   { build(els,cx,cy,s) -> st ; anim(cv,st,e) ; std = true tiene anche la spunta standard }
--   fx.egg    = id in ICON.eggs    easter egg { build, cond, pick, start, run, clear, dur, label, doneText }
--   fx.font   = "rounded" ...      carattere del timer/testo di stato nell'HUD
-- Un pack = una riga ROWS con queste chiavi + le funzioni nelle tabelle ICON.*. Niente altro.
------------------------------------------------------------------------
ICON.shapes, ICON.bodies, ICON.meters, ICON.proc, ICON.done, ICON.eggs = {}, {}, {}, {}, {}, {}
ICON.stat = { n = 0 }                      -- "anelli": registrazioni completate in questa sessione (solo memoria)
ICON.lv = 0                                -- livello audio liscio (0..1) per le particelle reattive
ICON.rng = function() return math.random() end
ICON.hudShape = nil                        -- forma attiva SOLO mentre si disegna l'HUD (non tocca i pannelli)

function ICON.shape() local f = COL.fx; return f and f.shape and ICON.shapes[f.shape] or nil end
function ICON.cardR(v) local sp = ICON.shape(); if sp and sp.r then return math.max(1.5, v * sp.r) end return R(v) end
-- corpo della card HUD: custom (fx.body) o vetro standard
function ICON.cardBody(els, x, y, w, h, s, o, kind)
  local f = COL.fx
  local B = f and f.body and ICON.bodies[f.body]
  local r = ICON.cardR(28 * s)
  if kind == "proc" then r = ICON.cardR(26 * s) end
  if B then return B(els, x, y, w, h, s, r, o, kind) end
  return pushGlass(els, x, y, w, h, r, o)
end
function ICON.barCol() local f = COL.fx; local b = f and f.barCol; if not b then return nil end return hex(COL.dark and b.dark or b.light) end
function ICON.packFont(slot)
  local f = COL.fx
  if not (f and f.font) then return nil end
  local ok, F = pcall(fontsOf, f.font)
  return ok and F and F[slot] or nil
end

-- icona che "salta": sposta in y gli elementi dell'icona (ref = tabelle originali degli elementi)
function ICON.hopIcon(cv, I, dy)
  local ref = I.iconRef
  if not ref then return end
  dy = finite(dy, 0)
  for k, el in ipairs(ref) do
    local ix = I.icon0 + k - 1
    if el.type == "rectangle" then local f = el.frame; cv:elementAttribute(ix, "frame", { x = f.x, y = f.y + dy, w = f.w, h = f.h })
    elseif el.type == "circle" then cv:elementAttribute(ix, "center", { x = el.center.x, y = el.center.y + dy })
    elseif el.type == "segments" then
      local c = {}; for j, p in ipairs(el.coordinates) do c[j] = { x = p.x, y = p.y + dy } end
      cv:elementAttribute(ix, "coordinates", c)
    end
  end
end

-- EASTER EGG: elementi riservati e nascosti (toast + sprite del pack); animazione = Anim "egg" (breve, si ferma da sola)
function ICON.eggBuild(els, I, ox, oy, w, h, s, map)
  local id = COL.fx and COL.fx.egg
  local sp = id and ICON.eggs[id]
  if not sp then return end
  local E = { spec = sp, last = -99, clicks = 0, lastClick = 0, cx = ox + w / 2, ty = oy - 26 * s, ox = ox, oy = oy, w = w, h = h, ta = 0, s = s }
  E.pill = #els + 1
  els[E.pill] = { type = "rectangle", action = "strokeAndFill", fillColor = withA(COL.solid, 0), strokeColor = withA(COL.accent, 0), strokeWidth = 1,
    roundedRectRadii = { xRadius = 9 * s, yRadius = 9 * s }, frame = { x = 0, y = 0, w = 1, h = 1 } }
  E.text = #els + 1
  els[E.text] = { type = "text", text = "", textSize = 11 * s, textColor = withA(COL.fg, 0), textFont = fonts().semi,
    textAlignment = "center", textLineBreak = "clip", frame = { x = 0, y = 0, w = 1, h = 1 } }
  if sp.build then sp.build(els, E, ox, oy, w, h, s) end
  I.egg = E
  I.eggKey = map and "hud" or "prev"
end
function ICON.toast(cv, I, label, a)
  local E = I.egg
  if not E then return end
  local s = E.s
  if label and label ~= E.label then
    E.label = label
    local tw = math.min(((utf8.len(label) or #label) * 6.6 + 22) * s, E.w + 70 * s)
    cv:elementAttribute(E.pill, "frame", { x = E.cx - tw / 2, y = E.ty, w = tw, h = 19 * s })
    cv:elementAttribute(E.text, "frame", { x = E.cx - tw / 2, y = E.ty + 3 * s, w = tw, h = 19 * s })
    cv:elementAttribute(E.text, "text", label)
  end
  a = clampN(a, 0, 1)
  if math.abs(a - E.ta) > 0.02 or (a == 0 and E.ta ~= 0) then
    E.ta = a
    cv:elementAttribute(E.pill, "fillColor", withA(COL.solid, 0.96 * a))
    cv:elementAttribute(E.pill, "strokeColor", withA(COL.accent, a))
    cv:elementAttribute(E.text, "textColor", withA(COL.fg, a))
  end
end
function ICON.eggFire(cv, I, why)
  local E = I and I.egg
  if not E or E.running or not cv or not animOn() then return end
  local t = now()
  if why ~= "click" and t - E.last < 4 then return end
  E.last = t; E.running = true
  local sp = E.spec
  local var = sp.pick and sp.pick(why) or 1
  if sp.start then sp.start(cv, I, E, var) end
  Anim.run("egg", I.eggKey, sp.dur or 1.6, "linear", function(_, p)
    sp.run(cv, I, E, p, var)
  end, function()
    E.running = false
    if sp.clear then sp.clear(cv, I, E) end
    ICON.toast(cv, I, nil, 0)
  end)
end
-- 5 clic ravvicinati (entro 3s) sul punto sensibile (timer dell'HUD in pausa / badge nell'anteprima del tab Tema)
function ICON.eggClick(cv, I)
  local E = I and I.egg
  if not E then return end
  local t = now()
  if t - E.lastClick > 3 then E.clicks = 0 end
  E.lastClick = t; E.clicks = E.clicks + 1
  if E.clicks >= 5 then E.clicks = 0; ICON.eggFire(cv, I, "click") end
end
function ICON.eggTick(cv, I, t, dt, active, warn)
  local E = I.egg
  if not E or I.preview or E.running or not active or warn then return end
  local sp = E.spec
  if sp.cond then
    local var = sp.cond(I, E, t, dt)
    if var then ICON.eggFire(cv, I, var) end
  end
end
-- testo di fine (✓ Fatto): il pack puo' variarlo
function ICON.doneText(text)
  local id = COL.fx and COL.fx.egg
  local sp = id and ICON.eggs[id]
  if sp and sp.doneText then return sp.doneText(text) end
  return text
end

-- indicatore (boost) sotto/accanto all'onda
function ICON.meterTick(cv, I, lv, active, warn, t, dt)
  local m = I.meter
  if not m then return 0 end
  local mt = ICON.meters[COL.fx and COL.fx.meter]
  if mt and mt.tick then mt.tick(cv, I, m, lv, active, warn, t, dt) end
  return m.v or 0
end

------------------------------------------------------------------------
-- PACK "Blocky" (blocchi): card squadrata erba sopra / terra sotto con texture a pixel e bevel da slot inventario,
-- schegge che cadono e rimbalzano, spinner "blocco che si scava", spunta a pixel, easter egg (faccina a blocchi / diamante).
-- Tutto disegnato da zero con rettangoli: nessun personaggio o logo.
------------------------------------------------------------------------
ICON.u = {}                 -- helper condivisi dai pack
function ICON.u.box(els, x, y, w, h, fill, rad, stroke, sw)
  local e = { type = "rectangle", action = stroke and (fill and "strokeAndFill" or "stroke") or "fill", frame = { x = x, y = y, w = w, h = h } }
  if fill then e.fillColor = fill end
  if stroke then e.strokeColor = stroke; e.strokeWidth = sw or 1 end
  if rad and rad > 0 then e.roundedRectRadii = { xRadius = rad, yRadius = rad } end
  els[#els + 1] = e
  return #els
end
function ICON.u.hz(i, k) local v = math.sin(i * 127.1 + k * 311.7) * 43758.5453; return v - math.floor(v) end     -- pseudo-casuale deterministico 0..1
function ICON.u.disc(els, x, y, r, fill, stroke, sw)
  els[#els + 1] = { type = "circle", action = stroke and (fill and "strokeAndFill" or "stroke") or "fill", fillColor = fill, strokeColor = stroke,
    strokeWidth = sw or 1, center = { x = x, y = y }, radius = r }
  return #els
end
function ICON.u.copy(o) local c = {}; for k, v in pairs(o or {}) do c[k] = v end return c end
function ICON.u.poly(els, pts, fill, stroke, sw)
  els[#els + 1] = { type = "segments", action = stroke and (fill and "strokeAndFill" or "stroke") or "fill", closed = true,
    fillColor = fill, strokeColor = stroke, strokeWidth = sw or 1, strokeJoinStyle = "round", coordinates = pts }
  return #els
end
do
local U = ICON.u
local BL = {
  dark  = { top = "3E7C23", bot = "5A3B22", edge = "10130A" },
  light = { top = "86C84A", bot = "B07C4C", edge = "3A2A18" },
}
local function pal() return BL[COL.dark and "dark" or "light"] end
local function g(T, i) return T.grad[math.min(i, #T.grad)] or T.accent end
ICON.shapes.block = { r = 0.1, btn = 0.14 }

ICON.bodies.block = function(els, x, y, w, h, s, r, o, kind)
  local P = pal()
  local o2 = U.copy(o); o2.sheenA = 0
  local _, body = pushGlass(els, x, y, w, h, r, o2)
  local q = 3.5 * s
  local seam = y + math.floor(h * 0.5 / q + 0.5) * q
  local top, bot, edge = hex(P.top), hex(P.bot), hex(P.edge)
  U.box(els, x, y, w, seam - y, top, 0)
  U.box(els, x, seam, w, y + h - seam, bot, 0)
  local lite = o.lite
  local cols = lite and 7 or 12
  local cw = w / cols
  for c = 0, cols - 1 do                                   -- frangia d'erba che pende sulla terra
    U.box(els, x + c * cw, seam, cw + 0.5, (1 + math.floor(U.hz(c, 1) * 2.99)) * q, top, 0)
  end
  local gx = math.max(1, math.floor(w / q) - 1)
  local rt = math.max(1, math.floor((seam - y) / q) - 1)
  local rb = math.max(1, math.floor((y + h - seam) / q) - 2)
  local hiT, loT, hiB, loB = mix(top, hex("FFFFFF"), 0.2), mix(top, hex("000000"), 0.22), mix(bot, hex("FFFFFF"), 0.16), mix(bot, hex("000000"), 0.28)
  for i = 1, (lite and 5 or 10) do                         -- rumore a pixel quantizzato (statico)
    U.box(els, x + math.floor(U.hz(i, 2) * gx) * q + q * 0.5, y + math.floor(U.hz(i, 3) * rt) * q + q * 0.5, q, q, (i % 2 == 0) and hiT or loT, 0)
    U.box(els, x + math.floor(U.hz(i, 4) * gx) * q + q * 0.5, seam + math.floor(U.hz(i, 5) * rb) * q + q, q, q, (i % 2 == 0) and hiB or loB, 0)
  end
  local bw, bv = 3 * s, 1.6 * s                            -- bevel stile slot: luce in alto/sinistra, ombra in basso/destra
  U.box(els, x + bw, y + bw, w - 2 * bw, bv, withA(hex("FFFFFF"), 0.38), 0)
  U.box(els, x + bw, y + bw, bv, h - 2 * bw, withA(hex("FFFFFF"), 0.26), 0)
  U.box(els, x + bw, y + h - bw - bv, w - 2 * bw, bv, withA(hex("000000"), 0.34), 0)
  U.box(els, x + w - bw - bv, y + bw, bv, h - 2 * bw, withA(hex("000000"), 0.3), 0)
  local border = U.box(els, x + bw / 2, y + bw / 2, w - bw, h - bw, nil, r, edge, bw)      -- bordo scuro spesso
  return border, body, edge
end

function ICON.c.blockmic(els, cx, cy, sz, col, T)         -- microfono a pixel: testa in accento, piede color terra
  local u = sz / 16; local px = 1.9 * u
  local rows = { "..###..", "..###..", "..###..", "#.###.#", "#.....#", ".#...#.", "..###..", "...#...", ".#####." }
  local x0, y0 = cx - 3.5 * px, cy - 4.5 * px
  for r, row in ipairs(rows) do
    for c = 1, 7 do
      if row:sub(c, c) == "#" then
        els[#els + 1] = { type = "rectangle", action = "fill", fillColor = (r == 1 and c == 3) and g(T, 2) or ((r <= 5) and col or g(T, 3)),
          frame = { x = x0 + (c - 1) * px, y = y0 + (r - 1) * px, w = px + 0.35, h = px + 0.35 } }
      end
    end
  end
end

-- schegge: quadratini che cadono, rimbalzano e svaniscono; piu' parlato = piu' schegge (max 9, solo se registra)
local CHIP = { "FFD25A", "6DBB3A", "9A6A3C", "C9CDBF" }
ICON.parts.chips = {
  build = function(els, ox, oy, w, h, s, lite)
    local R = { kind = "chips", idx = {}, ox = ox, oy = oy, w = w, h = h, s = s, c = {} }
    for i = 1, (lite and 5 or 9) do
      els[#els + 1] = { type = "rectangle", action = "fill", fillColor = withA(CLEAR, 0), frame = { x = ox, y = oy, w = 2.8 * s, h = 2.8 * s } }
      R.idx[i] = #els
    end
    return R
  end,
  tick = function(cv, R, t, visible)
    if not visible then
      if not R.hidden then
        R.hidden = true; R.c = {}
        for _, ix in ipairs(R.idx) do cv:elementAttribute(ix, "fillColor", withA(CLEAR, 0)) end
      end
      return
    end
    R.hidden = false
    local s, w, h, C = R.s, R.w, R.h, R.c
    local lv = clampN(ICON.lv or 0, 0, 1)
    local n = #R.idx
    local nAct = math.ceil(n * (0.5 + 0.5 * math.min(1, lv * 1.5)))
    local q = 1.4 * s
    for i, ix in ipairs(R.idx) do
      local X, Y, a = 0, 0, 0
      if i <= nAct then
        local seed = (i * 0.6180339887) % 1
        local u = (t / (2.4 + 1.6 * ((i * 0.37) % 1)) + seed) % 1
        local x0 = 8 * s + ((i * 0.7548776662 + 0.13) % 1) * math.max(1, w - 16 * s)
        local floorY, top = h - 6 * s, 3 * s
        local x, y
        if u < 0.6 then local v = u / 0.6; y = top + (floorY - top) * v * v; x = x0
        else local b = (u - 0.6) / 0.4; y = floorY - math.sin(b * math.pi) * h * 0.2 * (1 - b); x = x0 + b * 9 * s * ((i % 2 == 0) and 1 or -1) end
        a = math.min(1, u * 10) * ((u > 0.88) and (1 - u) / 0.12 or 1)
        if i % 4 == 0 then a = a * (0.55 + 0.45 * math.abs(math.sin(finite(t * 9 + i, 0)))) end       -- scintilla di torcia che sfarfalla
        X, Y = R.ox + math.floor(x / q + 0.5) * q, R.oy + math.floor(y / q + 0.5) * q
        a = clampN(a, 0, 1)
      end
      local L = C[i]
      if not L or math.abs(X - L.x) > 0.45 or math.abs(Y - L.y) > 0.45 or math.abs(a - L.a) > 0.04 then
        cv:elementAttribute(ix, "frame", { x = X, y = Y, w = 2.8 * s, h = 2.8 * s })
        cv:elementAttribute(ix, "fillColor", withA(hex(CHIP[(i - 1) % 4 + 1]), a))
        C[i] = { x = X, y = Y, a = a }
      end
    end
  end,
}

-- spinner: blocco di terra che si crepa a stadi e perde due schegge, poi ricomincia
ICON.proc.mine = {
  build = function(els, cx, cy, s)
    local P = pal()
    local st = { all = {}, cr = {}, last = -1 }
    local x, y, sz = cx - 8 * s, cy - 8 * s, 16 * s
    st.all[#st.all + 1] = { U.box(els, x, y, sz, sz, hex(P.bot), 0, hex(P.edge), 1.6 * s), "b" }
    st.all[#st.all + 1] = { U.box(els, x, y, sz, 4.5 * s, hex(P.top), 0), "f" }
    for i = 1, 3 do st.all[#st.all + 1] = { U.box(els, x + (2 + i * 3.3) * s, y + (6 + (i % 2) * 5) * s, 2.4 * s, 2.4 * s, withA(hex(P.edge), 0.55), 0), "f" } end
    local cr = { { -1, -6, 1, -1 }, { 1, -1, 5, 1.5 }, { 1, -1, -3, 3.5 }, { -3, 3.5, -4.5, 7 } }
    for k, c in ipairs(cr) do
      els[#els + 1] = { type = "segments", action = "stroke", strokeColor = withA(hex(P.edge), 0), strokeWidth = 1.5 * s, strokeCapStyle = "square",
        coordinates = { { x = cx + c[1] * s, y = cy + c[2] * s }, { x = cx + c[3] * s, y = cy + c[4] * s } } }
      st.cr[k] = #els; st.all[#st.all + 1] = { #els, "s" }
    end
    st.cx, st.cy, st.s, st.edge = cx, cy, s, hex(P.edge)
    st.ch = {}
    for i = 1, 2 do st.ch[i] = U.box(els, cx, cy, 2.4 * s, 2.4 * s, withA(hex(P.bot), 0), 0); st.all[#st.all + 1] = { st.ch[i], "f" } end
    return st
  end,
  tick = function(cv, st, t)
    local ph = (t * 0.75) % 1
    local stage = math.floor(ph * 5)
    local f = ph * 5 - stage
    if stage ~= st.last then
      st.last = stage
      for k, ix in ipairs(st.cr) do cv:elementAttribute(ix, "strokeColor", withA(st.edge, k <= stage and 0.9 or 0)) end
    end
    local s = st.s
    for i, ix in ipairs(st.ch) do
      local on = stage >= 2
      cv:elementAttribute(ix, "frame", { x = st.cx + (i == 1 and -3 or 2) * s + f * (i == 1 and -4 or 4) * s, y = st.cy + 7 * s + f * 9 * s, w = 2.4 * s, h = 2.4 * s })
      cv:elementAttribute(ix, "fillColor", withA(hex(pal().bot), on and (1 - f) or 0))
    end
  end,
  hide = function(cv, st)
    for _, e in ipairs(st.all) do
      if e[2] ~= "s" then cv:elementAttribute(e[1], "fillColor", withA(CLEAR, 0)) end
      if e[2] ~= "f" then cv:elementAttribute(e[1], "strokeColor", withA(CLEAR, 0)) end
    end
  end,
}

-- spunta finale: check a pixel che si compone cella per cella
ICON.done.pixel = {
  build = function(els, cx, cy, s)
    local st = { cells = {} }
    local px = 2.3 * s
    st.bg = U.box(els, cx - 12 * s, cy - 12 * s, 24 * s, 24 * s, withA(COL.ok, 0), 0)
    for k, c in ipairs({ { 0, 2 }, { 1, 3 }, { 2, 4 }, { 3, 3 }, { 4, 2 }, { 5, 1 }, { 6, 0 } }) do
      st.cells[k] = U.box(els, cx + (c[1] - 3) * px - px / 2, cy + (c[2] - 2) * px - px / 2, px + 0.3, px + 0.3, withA(COL.ok, 0), 0)
    end
    return st
  end,
  anim = function(cv, st, e)
    cv:elementAttribute(st.bg, "fillColor", withA(COL.ok, 0.2 * clamp01(e)))
    for k, ix in ipairs(st.cells) do cv:elementAttribute(ix, "fillColor", withA(COL.ok, clamp01(e * 8 - (k - 1)))) end
  end,
}

-- easter egg: faccina a blocchi che spunta dal bordo e lampeggia, oppure un diamante pixel con toast.
-- Scatta: 1 registrazione su 25 (dopo 3s) oppure ogni registrazione che supera 60s; 5 clic sul timer in pausa / badge nell'anteprima.
ICON.eggs.block = {
  dur = 1.8,
  build = function(els, E, ox, oy, w, h, s)
    E.sp = {}
    for k = 1, 6 do E.sp[k] = U.box(els, ox, oy, 1, 1, withA(CLEAR, 0), 0) end
    E.fx0 = ox + w * 0.64
  end,
  pick = function() return (ICON.rng() < 0.5) and 1 or 2 end,
  cond = function(I, E)
    local el = I.el or 0
    if E.luck == nil then E.luck = (ICON.rng() < 1 / 25) end
    if E.luck and el >= 3 and not E.f1 then E.f1 = true; return 1 end
    if el >= 60 and not E.f2 then E.f2 = true; return 2 end
  end,
  start = function(cv, I, E, var) E.sig = nil end,
  run = function(cv, I, E, p, var)
    local s = E.s
    local q = 2.8 * s * (var == 2 and 1.5 or 1)
    local rise = math.min(1, p * 6)
    local x, y = E.fx0, E.oy - 2 * s - 11.5 * s * rise
    local on = (p < 0.2) or (math.floor(p * 14) % 2 == 0)
    local sig = math.floor(rise * 10) * 2 + (on and 1 or 0)
    if sig ~= E.sig then
      E.sig = sig
      local A = on and 1 or 0.3
      local function Rr(k, rx, ry, rw, rh, col, a)
        cv:elementAttribute(E.sp[k], "frame", { x = x + rx * q, y = y + ry * q, w = rw * q, h = rh * q })
        cv:elementAttribute(E.sp[k], "fillColor", withA(hex(col), a))
      end
      if var == 1 then
        Rr(1, 0, 0, 5, 5, "56B02E", A); Rr(2, 1, 1, 1, 1, "10130A", A); Rr(3, 3, 1, 1, 1, "10130A", A)
        Rr(4, 2, 2.2, 1, 1.2, "10130A", A); Rr(5, 1, 3.2, 1, 1.4, "10130A", A); Rr(6, 3, 3.2, 1, 1.4, "10130A", A)
      else
        Rr(1, 0, 1, 3, 1, "4DF0E4", A); Rr(2, 1, 0, 1, 1, "4DF0E4", A); Rr(3, 1, 2, 1, 1, "4DF0E4", A)
        Rr(4, 1, 1, 1, 1, "FFFFFF", A); Rr(5, 0, 0, 0.01, 0.01, "000000", 0); Rr(6, 0, 0, 0.01, 0.01, "000000", 0)
      end
    end
    ICON.toast(cv, I, var == 2 and "Diamanti!" or nil, var == 2 and math.min(1, p * 8) * math.min(1, (1 - p) * 6) or 0)
  end,
  clear = function(cv, I, E)
    for _, ix in ipairs(E.sp) do cv:elementAttribute(ix, "fillColor", withA(CLEAR, 0)) end
  end,
}
end

------------------------------------------------------------------------
-- PACK "Blue Rush" (velocita'): card blu elettrico con bande oblique, scie di velocita' che scorrono, anelli dorati che
-- ruotano/rimbalzano e sciamano quando parli forte, spinner a palla che gira, spunta con scintilla d'anello,
-- easter egg "troppo veloce" (livello audio altissimo per 3s: scia extra + HUD che trema) con contatore di "anelli".
-- Tutto disegnato da zero con primitive: nessun personaggio o logo.
------------------------------------------------------------------------
do
local U = ICON.u
local function g(T, i) return T.grad[math.min(i, #T.grad)] or T.accent end
local function gold() return COL.grad[3] or COL.accent end

function ICON.c.ring(els, cx, cy, sz, col, T)          -- anello dorato con lucido, scintilla e scie di velocita'
  local u = sz / 16; local rx = cx + 2.2 * u
  line(els, cx - 7.6 * u, cy - 3.4 * u, cx - 3.8 * u, cy - 3.4 * u, col, 1.4 * u)
  line(els, cx - 8 * u, cy, cx - 2.6 * u, cy, col, 1.4 * u)
  line(els, cx - 7.6 * u, cy + 3.4 * u, cx - 3.8 * u, cy + 3.4 * u, col, 1.4 * u)
  U.disc(els, rx, cy, 4.6 * u, nil, g(T, 3), 2.7 * u)
  seg(els, arcPts(rx, cy, 4.6 * u, 205, 285, 8), withA(T.fgWhite, 0.8), 1 * u)
  local sx, sy = cx + 7.2 * u, cy - 6 * u
  U.poly(els, { { x = sx, y = sy - 2.4 * u }, { x = sx + 0.7 * u, y = sy - 0.7 * u }, { x = sx + 2.4 * u, y = sy }, { x = sx + 0.7 * u, y = sy + 0.7 * u },
    { x = sx, y = sy + 2.4 * u }, { x = sx - 0.7 * u, y = sy + 0.7 * u }, { x = sx - 2.4 * u, y = sy }, { x = sx - 0.7 * u, y = sy - 0.7 * u } }, withA(T.fgWhite, 0.95))
end

-- corpo: vetro blu + tre bande oblique "velocita'" (solo orizzontale: in verticale sarebbe rumore)
ICON.bodies.speed = function(els, x, y, w, h, s, r, o, kind)
  local border, body = pushGlass(els, x, y, w, h, r, o)
  if w > h then
    local r2 = math.max(1, math.min(r, h / 2, w / 2))
    local sk = h * 0.45
    local cols = { withA(hex("FFFFFF"), COL.dark and 0.05 or 0.35), withA(COL.grad[2] or COL.accent, 0.11), withA(gold(), 0.09) }
    for k = 1, 3 do
      local bx = x + r2 + w * (0.12 + 0.24 * (k - 1))
      U.poly(els, { { x = bx + sk, y = y + 1 }, { x = bx + sk + w * 0.07, y = y + 1 }, { x = bx + w * 0.07, y = y + h - 1 }, { x = bx, y = y + h - 1 } }, cols[k])
    end
  end
  return border, body
end

-- particelle: 8 anelli che ruotano e rimbalzano (piu' ne compaiono col volume) + 4 scie orizzontali, max 12, ~16Hz
ICON.parts.rush = {
  build = function(els, ox, oy, w, h, s, lite)
    local R = { kind = "rush", idx = {}, rings = {}, streaks = {}, ox = ox, oy = oy, w = w, h = h, s = s, c = {} }
    for i = 1, (lite and 4 or 8) do
      els[#els + 1] = { type = "segments", action = "stroke", closed = true, strokeColor = withA(gold(), 0), strokeWidth = 1.5 * s, strokeJoinStyle = "round",
        coordinates = { { x = ox, y = oy }, { x = ox + 1, y = oy }, { x = ox + 1, y = oy + 1 } } }
      R.rings[i] = #els; R.idx[#R.idx + 1] = #els
    end
    for i = 1, (lite and 2 or 4) do
      els[#els + 1] = { type = "segments", action = "stroke", strokeColor = withA(CLEAR, 0), strokeWidth = 1.3 * s, strokeCapStyle = "round",
        coordinates = { { x = ox, y = oy }, { x = ox + 1, y = oy } } }
      R.streaks[i] = #els; R.idx[#R.idx + 1] = #els
    end
    return R
  end,
  tick = function(cv, R, t, visible)
    if not visible then
      if not R.hidden then
        R.hidden = true; R.c = {}
        for _, ix in ipairs(R.idx) do cv:elementAttribute(ix, "strokeColor", withA(CLEAR, 0)) end
      end
      return
    end
    R.hidden = false
    local s, w, h, C = R.s, R.w, R.h, R.c
    local lv = clampN(ICON.lv or 0, 0, 1)
    local gc = gold()
    local nAct = math.ceil(#R.rings * (0.25 + 0.75 * math.min(1, lv * 1.6)))
    local rr = 3.1 * s
    for i, ix in ipairs(R.rings) do
      local x, y, a, rw = 0, 0, 0, 1
      if i <= nAct then
        local seed = (i * 0.6180339887) % 1
        local u = (t / (2.2 + 1.2 * ((i * 0.31) % 1)) + seed) % 1
        local x0 = 10 * s + ((i * 0.7548776662 + 0.13) % 1) * math.max(1, w - 20 * s)
        x = R.ox + x0 + (u - 0.5) * 22 * s * ((i % 2 == 0) and 1 or -1)
        y = R.oy + h - 7 * s - math.abs(math.sin(u * math.pi * 2.5)) * (1 - u) * (h - 14 * s)        -- rimbalza e si smorza
        a = clampN(math.min(u * 6, (1 - u) * 3, 1), 0, 1) * 0.9
        rw = 0.25 + 0.75 * math.abs(math.cos(finite(t * 6 + seed * 9, 0)))                          -- rotazione
      end
      local L = C[i]
      if not L or math.abs(x - L.x) > 0.5 or math.abs(y - L.y) > 0.5 or math.abs(a - L.a) > 0.04 or math.abs(rw - L.w) > 0.05 then
        local pts = {}
        for k = 0, 9 do local an = k / 10 * 2 * math.pi; pts[#pts + 1] = { x = x + rr * rw * math.cos(an), y = y + rr * math.sin(an) } end
        cv:elementAttribute(ix, "coordinates", pts)
        cv:elementAttribute(ix, "strokeColor", withA(gc, a))
        C[i] = { x = x, y = y, a = a, w = rw }
      end
    end
    local sc = COL.dark and hex("FFFFFF") or COL.accent
    for i, ix in ipairs(R.streaks) do
      local k = #R.rings + i
      local u = (t / (0.8 + 0.12 * i) + i * 0.27) % 1
      local len = (12 + 10 * lv) * s
      local xh = R.ox + w + len - u * (w + 2 * len)
      local yy = R.oy + h * (0.16 + 0.22 * (i - 1))
      local a = (0.12 + 0.3 * lv) * math.min(1, u * 5, (1 - u) * 5)
      local L = C[k]
      if not L or math.abs(xh - L.x) > 0.8 or math.abs(a - L.a) > 0.03 then
        cv:elementAttribute(ix, "coordinates", { { x = xh, y = yy }, { x = xh + len, y = yy } })
        cv:elementAttribute(ix, "strokeColor", withA(sc, a))
        C[k] = { x = xh, y = yy, a = a }
      end
    end
  end,
}

-- spinner: palla blu che rotola con spirale che gira (spin dash) e scie dietro
ICON.proc.spin = {
  build = function(els, cx, cy, s)
    local st = { arms = {}, cx = cx, cy = cy, s = s }
    st.disc = U.disc(els, cx, cy, 9.5 * s, COL.grad[1] or COL.accent, COL.grad[2] or COL.accent, 1.3 * s)
    for k = 1, 3 do
      els[#els + 1] = { type = "segments", action = "stroke", strokeColor = withA(hex("FFFFFF"), 0.85), strokeWidth = 1.5 * s, strokeCapStyle = "round",
        strokeJoinStyle = "round", coordinates = { { x = cx, y = cy }, { x = cx + 1, y = cy } } }
      st.arms[k] = #els
    end
    line(els, cx - 16 * s, cy - 3.5 * s, cx - 11.5 * s, cy - 3.5 * s, withA(gold(), 0.8), 1.5 * s); st.l1 = #els
    line(els, cx - 17 * s, cy + 1.5 * s, cx - 11.5 * s, cy + 1.5 * s, withA(gold(), 0.8), 1.5 * s); st.l2 = #els
    return st
  end,
  tick = function(cv, st, t)
    local s = st.s
    for k, ix in ipairs(st.arms) do
      local pts = {}
      for j = 0, 6 do
        local a = t * 9 + (k - 1) * 2.0944 + j * 0.5
        local rr = (1.2 + j * 1.15) * s
        pts[#pts + 1] = { x = st.cx + rr * math.cos(a), y = st.cy + rr * math.sin(a) }
      end
      cv:elementAttribute(ix, "coordinates", pts)
    end
    local pa = 0.45 + 0.4 * math.sin(finite(t * 14, 0))
    cv:elementAttribute(st.l1, "strokeColor", withA(gold(), pa)); cv:elementAttribute(st.l2, "strokeColor", withA(gold(), 0.85 - pa * 0.5))
  end,
  hide = function(cv, st)
    cv:elementAttribute(st.disc, "fillColor", withA(CLEAR, 0)); cv:elementAttribute(st.disc, "strokeColor", withA(CLEAR, 0))
    for _, ix in ipairs(st.arms) do cv:elementAttribute(ix, "strokeColor", withA(CLEAR, 0)) end
    cv:elementAttribute(st.l1, "strokeColor", withA(CLEAR, 0)); cv:elementAttribute(st.l2, "strokeColor", withA(CLEAR, 0))
  end,
}

-- spunta finale: anello d'oro che si espande con raggi di scintilla + check
ICON.done.ring = {
  build = function(els, cx, cy, s)
    local st = { cx = cx, cy = cy, s = s, rays = {} }
    els[#els + 1] = { type = "circle", action = "stroke", strokeColor = withA(gold(), 0), strokeWidth = 2.2 * s, center = { x = cx, y = cy }, radius = 4 * s }
    st.ring = #els
    for k = 1, 6 do
      els[#els + 1] = { type = "segments", action = "stroke", strokeColor = withA(gold(), 0), strokeWidth = 1.5 * s, strokeCapStyle = "round",
        coordinates = { { x = cx, y = cy }, { x = cx + 1, y = cy } } }
      st.rays[k] = #els
    end
    ICON.check(els, cx, cy, 17 * s, withA(COL.ok, 0), 2.1); st.chk = #els
    return st
  end,
  anim = function(cv, st, e)
    local a, s = clamp01(e), st.s
    local fade = 1 - clamp01((e - 0.55) / 0.45)
    cv:elementAttribute(st.ring, "radius", (4 + 8 * clampN(e, 0, 1.1)) * s)
    cv:elementAttribute(st.ring, "strokeColor", withA(gold(), a * (0.35 + 0.65 * fade)))
    for k, ix in ipairs(st.rays) do
      local an = math.rad(k * 60 - 90)
      local r0, r1 = (7 + 4 * e) * s, (10 + 8 * e) * s
      cv:elementAttribute(ix, "coordinates", { { x = st.cx + r0 * math.cos(an), y = st.cy + r0 * math.sin(an) }, { x = st.cx + r1 * math.cos(an), y = st.cy + r1 * math.sin(an) } })
      cv:elementAttribute(ix, "strokeColor", withA(gold(), a * fade))
    end
    cv:elementAttribute(st.chk, "strokeColor", withA(COL.ok, a))
  end,
}

-- easter egg "troppo veloce": livello audio alto (media barre > ~0.48) per 3s di fila -> 4 scie veloci + HUD che trema + toast
-- con il contatore di anelli (registrazioni completate in sessione). Cooldown 4s; 5 clic sul timer in pausa / badge anteprima.
ICON.eggs.rush = {
  dur = 1.6,
  build = function(els, E, ox, oy, w, h, s)
    E.sp = {}; E.hot = 0
    for k = 1, 4 do
      els[#els + 1] = { type = "segments", action = "stroke", strokeColor = withA(CLEAR, 0), strokeWidth = 1.6 * s, strokeCapStyle = "round",
        coordinates = { { x = ox, y = oy }, { x = ox + 1, y = oy } } }
      E.sp[k] = #els
    end
  end,
  cond = function(I, E, t, dt)
    if (I.lv or 0) > 0.72 then E.hot = E.hot + dt else E.hot = math.max(0, E.hot - dt * 2) end
    if E.hot >= 3 then E.hot = 0; return 1 end
  end,
  run = function(cv, I, E, p, var)
    local tk = math.floor(p * 30)
    if tk == E.tk then return end
    E.tk = tk
    local s = E.s
    local env = math.min(1, p * 8, (1 - p) * 5)
    local sc = COL.dark and hex("FFFFFF") or COL.accent
    for k, ix in ipairs(E.sp) do
      local u = (p * 3.2 + k * 0.23) % 1
      local len = 30 * s
      local xr = E.ox + E.w + len - u * (E.w + 2 * len)
      local yy = E.oy + E.h * (0.15 + 0.23 * (k - 1))
      cv:elementAttribute(ix, "coordinates", { { x = xr, y = yy }, { x = xr + len, y = yy } })
      cv:elementAttribute(ix, "strokeColor", withA(sc, 0.8 * env))
    end
    if cv == overlay and finalFrame and not dragTap and not animBusy then
      local f = finalFrame
      cv:frame({ x = f.x + math.sin(p * 70) * 1.6 * s * (1 - p), y = f.y, w = f.w, h = f.h })
    end
    ICON.toast(cv, I, (ICON.stat.n > 0) and ("Veloce! " .. ICON.stat.n .. " anelli") or "Troppo veloce!", env)
  end,
  clear = function(cv, I, E)
    E.tk = nil
    for _, ix in ipairs(E.sp) do cv:elementAttribute(ix, "strokeColor", withA(CLEAR, 0)) end
    if cv == overlay and finalFrame and not dragTap and not animBusy then cv:frame(finalFrame) end
  end,
}
end

------------------------------------------------------------------------
-- PACK "Turbo Ball" (arena): card scura con bordo a doppio colore arancio/blu e strisce livrea, onda con indicatore di BOOST
-- (barra che si riempie col volume + fiamma in testa), scintille di boost dal lato, spinner a ruota boost,
-- spunta con coriandoli blu/arancio, easter egg palla che rimbalza + "Che parata!" a fine registrazione lunga.
-- Tutto disegnato da zero con primitive: nessuna auto o logo.
------------------------------------------------------------------------
do
local U = ICON.u
local function orange() return COL.grad[2] or COL.accent end
local function blue() return COL.grad[3] or COL.accent2 or COL.accent end
local function yellow() return COL.grad[1] or COL.accent end
local function g2(T) return T.grad[2] or T.accent end

function ICON.c.ball(els, cx, cy, sz, col, T)           -- palla con pentagono, cuciture e scia di boost
  local u = sz / 16; local bx, by = cx + 1.6 * u, cy - 1 * u
  U.poly(els, { { x = cx - 3.2 * u, y = cy + 0.2 * u }, { x = cx - 8 * u, y = cy + 7.6 * u }, { x = cx - 0.6 * u, y = cy + 3.6 * u } }, g2(T))
  U.poly(els, { { x = cx - 3.8 * u, y = cy + 1.2 * u }, { x = cx - 6 * u, y = cy + 5.2 * u }, { x = cx - 2.2 * u, y = cy + 3 * u } }, withA(T.fgWhite, 0.55))
  U.disc(els, bx, by, 5.3 * u, nil, col, 1.7 * u)
  local pent = {}
  for i = 0, 4 do
    local a = math.rad(i * 72 - 90)
    pent[#pent + 1] = { x = bx + 2 * u * math.cos(a), y = by + 2 * u * math.sin(a) }
    line(els, bx + 2 * u * math.cos(a), by + 2 * u * math.sin(a), bx + 4.6 * u * math.cos(a), by + 4.6 * u * math.sin(a), col, 1 * u)
  end
  U.poly(els, pent, col)
end

ICON.bodies.sport = function(els, x, y, w, h, s, r, o, kind)
  local border, body = pushGlass(els, x, y, w, h, r, o)
  local r2 = math.max(1, math.min(r, h / 2, w / 2))
  if w > h then                                              -- strisce livrea alle estremita' (solo orizzontale)
    local sk = h * 0.3
    local x0 = x + w * 0.1
    U.poly(els, { { x = x0, y = y + h - 1 }, { x = x0 + sk, y = y + 1 }, { x = x0 + sk + w * 0.04, y = y + 1 }, { x = x0 + w * 0.04, y = y + h - 1 } }, withA(orange(), 0.16))
    local x1 = x + w * 0.9
    U.poly(els, { { x = x1, y = y + 1 }, { x = x1 - sk, y = y + h - 1 }, { x = x1 - sk - w * 0.04, y = y + h - 1 }, { x = x1 - w * 0.04, y = y + 1 } }, withA(blue(), 0.16))
  end
  local sw = 2.4 * s
  local L, Rr = {}, {}                                       -- bordo: meta' sinistra arancio, meta' destra blu
  Rr[1] = { x = x + w / 2, y = y + 0.5 }; L[1] = { x = x + w / 2, y = y + 0.5 }
  for _, p in ipairs(arcPts(x + r2, y + r2, r2 - 0.5, 270, 180, 10)) do L[#L + 1] = p end
  for _, p in ipairs(arcPts(x + r2, y + h - r2, r2 - 0.5, 180, 90, 10)) do L[#L + 1] = p end
  L[#L + 1] = { x = x + w / 2, y = y + h - 0.5 }
  for _, p in ipairs(arcPts(x + w - r2, y + r2, r2 - 0.5, 270, 360, 10)) do Rr[#Rr + 1] = p end
  for _, p in ipairs(arcPts(x + w - r2, y + h - r2, r2 - 0.5, 0, 90, 10)) do Rr[#Rr + 1] = p end
  Rr[#Rr + 1] = { x = x + w / 2, y = y + h - 0.5 }
  seg(els, L, orange(), sw); seg(els, Rr, blue(), sw)
  return border, body
end

-- indicatore di boost: pista sotto le barre (orizzontale) o a destra (verticale), si riempie col volume, fiamma in testa
ICON.meters.boost = {
  build = function(els, I, ox, oy, s, vertical)
    local D = dens()
    local m = { horiz = not vertical, s = s, v = 0, lastLen = -1, lastT = 0 }
    local th = 4 * s
    if vertical then m.x, m.y, m.len = ox + 47 * s, oy + 82 * s, (8 * D.vp + 3.2) * s; m.w, m.h = th, m.len
    else m.x, m.y, m.len = ox + 120 * s, oy + 46.5 * s, (11 * D.pitch + 3.2) * s; m.w, m.h = m.len, th end
    m.track = U.box(els, m.x, m.y, m.w, m.h, withA(COL.fg, 0.14), 2 * s)
    m.fill = U.box(els, m.x, m.y, 0.01, 0.01, orange(), 2 * s)
    els[m.fill].fillGradient = "linear"; els[m.fill].fillGradientAngle = vertical and 90 or 0; els[m.fill].fillGradientColors = { orange(), yellow() }
    m.flame = U.poly(els, { { x = m.x, y = m.y }, { x = m.x + 1, y = m.y }, { x = m.x, y = m.y + 1 } }, withA(yellow(), 0))
    return m
  end,
  tick = function(cv, I, m, lv, active, warn, t, dt)
    local target = (active and not warn) and clampN(lv * 1.15, 0, 1) or 0
    m.v = finite(m.v + (target - m.v) * (1 - math.exp(-9 * dt)), 0)
    if m.v < 0.004 then m.v = 0 end
    local L, s = m.len * m.v, m.s
    local boost = m.v > 0.82
    if math.abs(L - m.lastLen) > 0.45 or boost ~= m.lastBoost then
      m.lastLen = L
      if m.horiz then cv:elementAttribute(m.fill, "frame", { x = m.x, y = m.y, w = math.max(0.01, L), h = m.h })
      else cv:elementAttribute(m.fill, "frame", { x = m.x, y = m.y + m.len - L, w = m.w, h = math.max(0.01, L) }) end
      if boost ~= m.lastBoost then m.lastBoost = boost; cv:elementAttribute(m.fill, "fillGradientColors", boost and { yellow(), blue() } or { orange(), yellow() }) end
    end
    local on = m.v > 0.06
    if (on or m.flameOn) and (t - m.lastT > 0.05 or on ~= m.flameOn) then
      m.lastT = t; m.flameOn = on
      local fl = (3 + 9 * m.v) * s * (0.7 + 0.3 * math.sin(finite(t * 38, 0)))
      local pts
      if m.horiz then local xe, ym = m.x + L, m.y + m.h / 2; pts = { { x = xe, y = m.y - 0.8 * s }, { x = xe + fl, y = ym }, { x = xe, y = m.y + m.h + 0.8 * s } }
      else local ye, xm = m.y + m.len - L, m.x + m.w / 2; pts = { { x = m.x - 0.8 * s, y = ye }, { x = xm, y = ye - fl }, { x = m.x + m.w + 0.8 * s, y = ye } } end
      cv:elementAttribute(m.flame, "coordinates", pts)
      cv:elementAttribute(m.flame, "fillColor", withA(boost and blue() or yellow(), on and 0.9 or 0))
    end
  end,
}

-- scintille di boost: righe che escono dal lato sinistro della card, piu' lunghe e numerose col volume (max 9)
ICON.parts.boost = {
  build = function(els, ox, oy, w, h, s, lite)
    local R = { kind = "boost", idx = {}, ox = ox, oy = oy, w = w, h = h, s = s, c = {} }
    for i = 1, (lite and 4 or 9) do
      els[#els + 1] = { type = "segments", action = "stroke", strokeColor = withA(CLEAR, 0), strokeWidth = 1.5 * s, strokeCapStyle = "round",
        coordinates = { { x = ox, y = oy }, { x = ox + 1, y = oy } } }
      R.idx[i] = #els
    end
    return R
  end,
  tick = function(cv, R, t, visible)
    if not visible then
      if not R.hidden then R.hidden = true; R.c = {}; for _, ix in ipairs(R.idx) do cv:elementAttribute(ix, "strokeColor", withA(CLEAR, 0)) end end
      return
    end
    R.hidden = false
    local s, h, C = R.s, R.h, R.c
    local lv = clampN(ICON.lv or 0, 0, 1)
    local nAct = math.ceil(#R.idx * (0.4 + 0.6 * math.min(1, lv * 1.4)))
    for i, ix in ipairs(R.idx) do
      local x, y, x2, a = 0, 0, 0, 0
      if i <= nAct then
        local seed = (i * 0.6180339887) % 1
        local u = (t / (0.7 + 0.25 * ((i * 0.37) % 1)) + seed) % 1
        x = R.ox + 6 * s - u * 34 * s * (0.6 + 0.4 * ((i * 0.43) % 1))
        y = R.oy + h * (0.15 + 0.7 * ((i * 0.7548776662 + 0.13) % 1)) + (seed - 0.5) * u * 10 * s
        x2 = x + (4 + 7 * lv) * s * (1 - 0.5 * u)
        a = math.min(1, u * 6) * (1 - u) * (0.35 + 0.6 * lv)
      end
      local L = C[i]
      if not L or math.abs(x - L.x) > 0.6 or math.abs(y - L.y) > 0.6 or math.abs(a - L.a) > 0.04 then
        cv:elementAttribute(ix, "coordinates", { { x = x, y = y }, { x = x2, y = y } })
        cv:elementAttribute(ix, "strokeColor", withA((i % 2 == 0) and orange() or blue(), clampN(a, 0, 1)))
        C[i] = { x = x, y = y, a = a }
      end
    end
  end,
}

-- spinner: ruota boost a 8 raggi arancio/blu che si accendono in sequenza
ICON.proc.wheel = {
  build = function(els, cx, cy, s)
    local st = { sp = {} }
    for k = 1, 8 do
      local a = (k - 1) / 8 * 2 * math.pi - math.pi / 2
      els[#els + 1] = { type = "segments", action = "stroke", strokeColor = withA((k % 2 == 0) and blue() or orange(), 0.2), strokeWidth = 2.3 * s, strokeCapStyle = "round",
        coordinates = { { x = cx + 5.2 * s * math.cos(a), y = cy + 5.2 * s * math.sin(a) }, { x = cx + 10 * s * math.cos(a), y = cy + 10 * s * math.sin(a) } } }
      st.sp[k] = #els
    end
    st.disc = U.disc(els, cx, cy, 2.6 * s, withA(COL.fg, 0.85))
    return st
  end,
  tick = function(cv, st, t)
    local head = (t * 1.3) % 1
    for k, ix in ipairs(st.sp) do
      local d = (head - (k - 1) / 8) % 1
      cv:elementAttribute(ix, "strokeColor", withA((k % 2 == 0) and blue() or orange(), 0.14 + 0.86 * spow(1 - d, 2.2)))
    end
  end,
  hide = function(cv, st)
    for _, ix in ipairs(st.sp) do cv:elementAttribute(ix, "strokeColor", withA(CLEAR, 0)) end
    cv:elementAttribute(st.disc, "fillColor", withA(CLEAR, 0))
  end,
}

-- spunta finale "gol": check standard + 10 coriandoli blu/arancio/bianchi che esplodono (0.9s, 30fps)
ICON.done.goal = {
  std = true,
  build = function(els, cx, cy, s)
    local st = { cf = {}, cx = cx, cy = cy, s = s }
    for k = 1, 10 do st.cf[k] = U.box(els, cx, cy, 3 * s, 2 * s, withA(CLEAR, 0), 0.6 * s) end
    return st
  end,
  start = function(cv, st)
    local cols = { orange(), blue(), hex("FFFFFF") }
    Anim.run("egg", "burst", 0.9, "out", function(e, p)
      local tk = math.floor(p * 30)
      if tk == st.tk then return end
      st.tk = tk
      for k, ix in ipairs(st.cf) do
        local an = k / 10 * 2 * math.pi + 0.3
        local d = (7 + (18 + 6 * ((k * 0.37) % 1)) * e) * st.s
        cv:elementAttribute(ix, "frame", { x = st.cx + d * math.cos(an) - 1.5 * st.s, y = st.cy + d * math.sin(an) + 9 * st.s * p * p - st.s, w = 3 * st.s, h = 2 * st.s })
        cv:elementAttribute(ix, "fillColor", withA(cols[k % 3 + 1], clampN(1 - p * p, 0, 1)))
      end
    end, function() for _, ix in ipairs(st.cf) do cv:elementAttribute(ix, "fillColor", withA(CLEAR, 0)) end end)
  end,
  anim = function() end,
}

-- easter egg: palla che rimbalza nell'HUD. Scatta: a 90s di registrazione ("Che parata!"); 5 clic sul timer in pausa / badge anteprima ("Gol!").
-- A fine registrazione lunga (>= 45s) il testo di fine diventa "Che parata!" (doneText).
ICON.eggs.turbo = {
  dur = 1.7,
  build = function(els, E, ox, oy, w, h, s)
    E.ball = U.disc(els, ox, oy, 5 * s, withA(hex("FFFFFF"), 0), withA(orange(), 0), 1.6 * s)
  end,
  pick = function(why) return (why == "click") and 2 or 1 end,
  cond = function(I, E) if (I.el or 0) >= 90 and not E.f1 then E.f1 = true; return 1 end end,
  run = function(cv, I, E, p, var)
    local tk = math.floor(p * 30)
    if tk ~= E.tk then
      E.tk = tk
      local s = E.s
      local env = math.min(1, p * 10, (1 - p) * 6)
      local x = E.ox + E.w * (0.16 + 0.68 * p)
      local y = E.oy + E.h - 9 * s - math.abs(math.sin(p * math.pi * 3)) * (E.h - 18 * s) * (1 - 0.5 * p)
      cv:elementAttribute(E.ball, "center", { x = x, y = y })
      cv:elementAttribute(E.ball, "fillColor", withA(hex("FFFFFF"), 0.95 * env)); cv:elementAttribute(E.ball, "strokeColor", withA(orange(), env))
    end
    ICON.toast(cv, I, var == 2 and "Gol!" or "Che parata!", math.min(1, p * 8) * math.min(1, (1 - p) * 6))
  end,
  clear = function(cv, I, E)
    E.tk = nil
    cv:elementAttribute(E.ball, "fillColor", withA(CLEAR, 0)); cv:elementAttribute(E.ball, "strokeColor", withA(CLEAR, 0))
  end,
  doneText = function(text) if (ICON.lastDur or 0) >= 45 then return "✓  Che parata!" end return text end,
}
end

------------------------------------------------------------------------
-- PACK "Quahog" (sitcom): card a fumetto con contorno spesso + ombra piatta sfalsata (niente blur), banda tappezzeria nei colori
-- del tema, carattere rotondo, bolle fumetto e rombi che salgono, spinner a pallino che salta, spunta "pop" con stella,
-- easter egg: a volte la scritta di fine e' una battuta generica e il divano fa un salto.
-- Tutto disegnato da zero con primitive: nessun personaggio, nessuna citazione.
------------------------------------------------------------------------
do
local U = ICON.u
local function ink() return COL.dark and hex("03060E") or hex("0F1E3C") end
local function pick(g, i) return COL.grad[math.min(i, #COL.grad)] or COL.accent end
local DONE_JOKES = { "Fatto, ciccio!", "Ecco servito!", "Tutto a posto, capo!", "Missione compiuta!" }
local HOP_JOKES = { "Eh, ci sta!", "Salto di gioia!", "Che comodo!" }

function ICON.c.sofa(els, cx, cy, sz, col, T)           -- divano con cuscino e piedini
  local u = sz / 16
  rrect(els, cx - 5.6 * u, cy - 5.8 * u, 11.2 * u, 6 * u, 2.3 * u, { stroke = col, sw = 1.5 * u })
  rrect(els, cx - 7.6 * u, cy - 1.4 * u, 15.2 * u, 5.8 * u, 2.2 * u, { fill = withA(col, 0.38), stroke = col, sw = 1.5 * u })
  line(els, cx, cy - 1.2 * u, cx, cy + 3.6 * u, col, 1.1 * u)
  line(els, cx - 5.4 * u, cy + 4.6 * u, cx - 5.4 * u, cy + 7 * u, col, 1.7 * u)
  line(els, cx + 5.4 * u, cy + 4.6 * u, cx + 5.4 * u, cy + 7 * u, col, 1.7 * u)
end

ICON.shapes.cartoon = { r = 0.6 }
ICON.bodies.cartoon = function(els, x, y, w, h, s, r, o, kind)
  local k = ink()
  local o2 = U.copy(o); o2.shadow = false; o2.sheenA = 0.4; o2.border = k; o2.bw = 3 * s
  U.box(els, x + 3.5 * s, y + 4.5 * s, w, h, withA(k, 0.92), r)                   -- ombra piatta sfalsata
  local border, body = pushGlass(els, x, y, w, h, r, o2)                          -- contorno spesso
  local n = #COL.grad
  local bx0, bx1 = x + r * 0.8 + 3 * s, x + w - r * 0.8 - 3 * s
  local bw = (bx1 - bx0) / n
  for i = 1, n do U.box(els, bx0 + (i - 1) * bw, y + h - 8.5 * s, bw + 0.4, 3.6 * s, COL.grad[i], 1.2 * s) end     -- banda tappezzeria
  U.box(els, x + 4.6 * s, y + 4.6 * s, w - 9.2 * s, h - 9.2 * s, nil, math.max(1, r - 4 * s), withA(COL.accent, 0.38), 1 * s)   -- filo interno
  return border, body, k
end

-- bolle fumetto e rombi che salgono piano (max 9, solo se registra)
ICON.parts.comic = {
  build = function(els, ox, oy, w, h, s, lite)
    local R = { kind = "comic", idx = {}, ox = ox, oy = oy, w = w, h = h, s = s, c = {} }
    local n = lite and 4 or 9
    for i = 1, n do
      if i <= 4 then
        els[#els + 1] = { type = "rectangle", action = "strokeAndFill", fillColor = withA(CLEAR, 0), strokeColor = withA(CLEAR, 0), strokeWidth = 1.2 * s,
          roundedRectRadii = { xRadius = 3 * s, yRadius = 3 * s }, frame = { x = ox, y = oy, w = 10 * s, h = 7 * s } }
      elseif i <= 7 then
        els[#els + 1] = { type = "segments", action = "fill", closed = true, fillColor = withA(CLEAR, 0), coordinates = { { x = ox, y = oy }, { x = ox + 1, y = oy }, { x = ox, y = oy + 1 } } }
      else
        els[#els + 1] = { type = "circle", action = "fill", fillColor = withA(CLEAR, 0), center = { x = ox, y = oy }, radius = 1.4 * s }
      end
      R.idx[i] = #els
    end
    return R
  end,
  tick = function(cv, R, t, visible)
    if not visible then
      if not R.hidden then
        R.hidden = true; R.c = {}
        for i, ix in ipairs(R.idx) do
          cv:elementAttribute(ix, "fillColor", withA(CLEAR, 0))
          if i <= 4 then cv:elementAttribute(ix, "strokeColor", withA(CLEAR, 0)) end
        end
      end
      return
    end
    R.hidden = false
    local s, w, h, C = R.s, R.w, R.h, R.c
    for i, ix in ipairs(R.idx) do
      local seed = (i * 0.6180339887) % 1
      local u = (t / (5 + 2 * ((i * 0.31) % 1)) + seed) % 1
      local x = R.ox + 12 * s + ((i * 0.7548776662 + 0.13) % 1) * math.max(1, w - 24 * s) + math.sin(finite((u * 2 + seed) * 2 * math.pi, 0)) * 3 * s
      local y = R.oy + h - 5 * s - u * (h - 8 * s)
      local a = math.sin(u * math.pi) * 0.75
      local L = C[i]
      if not L or math.abs(x - L.x) > 0.6 or math.abs(y - L.y) > 0.6 or math.abs(a - L.a) > 0.04 then
        C[i] = { x = x, y = y, a = a }
        if i <= 4 then
          cv:elementAttribute(ix, "frame", { x = x - 5 * s, y = y - 3.5 * s, w = 10 * s, h = 7 * s })
          cv:elementAttribute(ix, "fillColor", withA(hex("FFFFFF"), 0.14 * a)); cv:elementAttribute(ix, "strokeColor", withA(COL.fg, a))
        elseif i <= 7 then
          local d = 2.6 * s
          cv:elementAttribute(ix, "coordinates", { { x = x, y = y - d }, { x = x + d * 0.8, y = y }, { x = x, y = y + d }, { x = x - d * 0.8, y = y } })
          cv:elementAttribute(ix, "fillColor", withA(pick(nil, i - 3), a))
        else
          cv:elementAttribute(ix, "center", { x = x, y = y }); cv:elementAttribute(ix, "fillColor", withA(COL.accent, a))
        end
      end
    end
  end,
}

-- spinner: pallino che salta con ombra
ICON.proc.hop = {
  build = function(els, cx, cy, s)
    local st = { cx = cx, cy = cy, s = s }
    st.gr = #els + 1
    line(els, cx - 9 * s, cy + 8.5 * s, cx + 9 * s, cy + 8.5 * s, withA(ink(), 0.5), 1.4 * s)
    st.sh = U.box(els, cx - 6 * s, cy + 7.3 * s, 12 * s, 2.4 * s, withA(hex("000000"), 0.25), 1.2 * s)
    st.ball = U.disc(els, cx, cy + 3 * s, 5 * s, pick(nil, 3), ink(), 1.5 * s)
    return st
  end,
  tick = function(cv, st, t)
    local s = st.s
    local ph = (t * 1.9) % 1
    local hgt = 4 * ph * (1 - ph)
    cv:elementAttribute(st.ball, "center", { x = st.cx, y = st.cy + 3 * s - hgt * 11 * s })
    local sw = 12 * s * (1 - 0.5 * hgt)
    cv:elementAttribute(st.sh, "frame", { x = st.cx - sw / 2, y = st.cy + 7.3 * s, w = sw, h = 2.4 * s })
  end,
  hide = function(cv, st)
    cv:elementAttribute(st.gr, "strokeColor", withA(CLEAR, 0)); cv:elementAttribute(st.sh, "fillColor", withA(CLEAR, 0))
    cv:elementAttribute(st.ball, "fillColor", withA(CLEAR, 0)); cv:elementAttribute(st.ball, "strokeColor", withA(CLEAR, 0))
  end,
}

-- spunta finale: stella-esplosione gialla con contorno + check scuro, con "pop"
ICON.done.pop = {
  build = function(els, cx, cy, s)
    local st = { cx = cx, cy = cy, s = s }
    local y0 = pick(nil, 4)
    st.y0 = y0
    st.star = U.poly(els, { { x = cx, y = cy }, { x = cx + 1, y = cy }, { x = cx, y = cy + 1 } }, withA(y0, 0), withA(ink(), 0), 1.8 * s)
    ICON.check(els, cx, cy, 15 * s, withA(ink(), 0), 2.6); st.chk = #els
    return st
  end,
  anim = function(cv, st, e)
    local a, s = clamp01(e * 1.5), st.s
    local sc = clampN(e, 0, 1.25)
    local pts = {}
    for k = 0, 11 do
      local an = k / 12 * 2 * math.pi - math.pi / 2
      local rr = ((k % 2 == 0) and 13 or 8.5) * s * sc
      pts[#pts + 1] = { x = st.cx + rr * math.cos(an), y = st.cy + rr * math.sin(an) }
    end
    cv:elementAttribute(st.star, "coordinates", pts)
    cv:elementAttribute(st.star, "fillColor", withA(st.y0, a)); cv:elementAttribute(st.star, "strokeColor", withA(ink(), a))
    cv:elementAttribute(st.chk, "strokeColor", withA(ink(), a))
  end,
}

-- easter egg: il divano fa un saltino con tre coriandoli attorno al badge + toast con una battuta generica.
-- Scatta: 1 registrazione su 20 (dopo 2s), ogni registrazione che supera 45s; 5 clic sul timer in pausa / badge anteprima.
-- Fine registrazione: nel 30% dei casi "Fatto" diventa una battuta breve.
ICON.eggs.quahog = {
  dur = 1.4,
  build = function(els, E, ox, oy, w, h, s)
    E.sp = {}
    for k = 1, 3 do E.sp[k] = U.disc(els, ox, oy, 1.8 * s, withA(CLEAR, 0)) end
  end,
  pick = function() return math.floor(ICON.rng() * 2.999) + 1 end,
  cond = function(I, E)
    local el = I.el or 0
    if E.luck == nil then E.luck = (ICON.rng() < 1 / 20) end
    if E.luck and el >= 2 and not E.f1 then E.f1 = true; return 1 end
    if el >= 45 and not E.f2 then E.f2 = true; return 2 end
  end,
  run = function(cv, I, E, p, var)
    local s = E.s
    local dy = -math.abs(math.sin(p * math.pi * 3)) * (1 - p) * 7 * s
    if not E.dy or math.abs(dy - E.dy) > 0.3 then E.dy = dy; ICON.hopIcon(cv, I, dy) end
    local tk = math.floor(p * 30)
    if tk ~= E.tk then
      E.tk = tk
      local bx, by = I.bcx or (E.ox + 31 * s), I.bcy or (E.oy + 28 * s)
      local env = math.min(1, p * 6) * (1 - p)
      for k, ix in ipairs(E.sp) do
        local an = math.rad(-90 + (k - 2) * 55)
        local d = (17 + 12 * p) * s
        cv:elementAttribute(ix, "center", { x = bx + d * math.cos(an), y = by + d * math.sin(an) })
        cv:elementAttribute(ix, "fillColor", withA(pick(nil, k + 1), clampN(env * 1.4, 0, 1)))
      end
    end
    ICON.toast(cv, I, HOP_JOKES[var] or HOP_JOKES[1], math.min(1, p * 8) * math.min(1, (1 - p) * 5))
  end,
  clear = function(cv, I, E)
    E.dy, E.tk = nil, nil
    ICON.hopIcon(cv, I, 0)
    for _, ix in ipairs(E.sp) do cv:elementAttribute(ix, "fillColor", withA(CLEAR, 0)) end
  end,
  doneText = function(text)
    if ICON.rng() < 0.3 then return "✓  " .. DONE_JOKES[math.floor(ICON.rng() * 3.999) + 1] end
    return text
  end,
}
end

-- avviso "NO MIC": scossa orizzontale smorzata della card
local function shakeHUD()
  if not overlay or not finalFrame or dragTap then return end
  local s = config.scale
  Anim.run("hud", "shake", 0.5, "linear", function(_, p)
    if not overlay or dragTap or animBusy then return end
    local f = finalFrame
    overlay:frame({ x = f.x + math.sin(p * math.pi * 7) * 5 * s * (1 - p), y = f.y, w = f.w, h = f.h })
  end, function()
    if overlay and finalFrame and not dragTap and not animBusy then overlay:frame(finalFrame) end
  end)
end

local function cleanStatus(t)
  t = tostring(t or "")
  local r = t:gsub("^[^%w]+", "")      -- toglie emoji/simboli iniziali (ora ci sono le icone)
  if r == "" then return t end
  return r
end

------------------------------------------------------------------------
-- HUD registrazione: pillola di vetro, badge mic con anelli pulsanti, timer, onda, pausa/stop
-- buildRecCard disegna la card in (ox, oy): la usano sia l'HUD vero sia l'anteprima viva
-- del tab Tema (map == nil → solo disegno, niente aree cliccabili).
------------------------------------------------------------------------
-- sfumatura del gradiente tema con alpha che scende da a0 ad a1
local function gradFade(T, a0, a1)
  local out, n = {}, #T.grad
  for i, c in ipairs(T.grad) do out[i] = withA(c, a0 + (a1 - a0) * ((n > 1) and (i - 1) / (n - 1) or 0)) end
  return out
end

-- dimensioni (non scalate) della pillola, in base a orientamento e densità
local function recDims(vertical)
  local D = dens()
  if vertical then return 56, 82 + 8 * D.vp + 3.2 + D.vg + D.vs + 22 end
  return 296 + D.w, 56
end

local function waveStyleOf()
  local w = config.waveStyle
  if w == "thin" or w == "dots" or w == "line" then return w end
  return "bars"
end
local function waveGradientOn()
  if config.waveColor == "gradient" then return true end
  if config.waveColor == "accent" then return false end
  return COL.multi == true          -- default: gradiente solo sugli stili multi-colore
end

local function buildRecCard(els, ox, oy, s, vertical, isPaused, map, withTips)
  local function sc(v) return v * s end
  local D = dens()
  local function add(el) els[#els + 1] = el; return #els end
  local idx = { bars = {}, disp = {}, last = nil, settled = false, warnPrev = false, vertical = vertical, s = s }
  local n = vertical and 9 or 12
  local pw, ph = recDims(vertical)
  idx.pw, idx.ph = pw, ph
  ICON.hudShape = ICON.shape()
  idx.border, idx.body, idx.borderCol = ICON.cardBody(els, ox, oy, sc(pw), sc(ph), s, { s = s, id = map and "drag" or nil, lite = (map == nil) }, "rec")
  if map then idx.parts = ICON.partsBuild(els, ox, oy, sc(pw), sc(ph), s, false) end      -- particelle dello stile (se ne ha); nell'anteprima del tab Tema (map nil) non ce ne sono

  -- badge mic (registrazione) oppure ingranaggio (in pausa: impostazioni/scelta mic)
  local bcx = ox + sc(vertical and 28 or 31)
  local bcy = oy + sc(vertical and 30 or 28)
  local br = sc(vertical and 16 or 17)
  idx.br = br
  idx.bcx, idx.bcy = bcx, bcy
  if isPaused then
    circleButton(els, map, "settings", bcx, bcy, br, "ghost", function(e, cx, cy)
      ICON.gear(e, cx, cy, sc(17), COL.accentInk)
    end, s)
  else
    if config.glowOn == true then       -- alone morbido attorno al badge
      add({ type = "circle", action = "fill", fillColor = withA(COL.accent, 0.09), center = { x = bcx, y = bcy }, radius = br * 1.8 })
      add({ type = "circle", action = "fill", fillColor = withA(COL.accent, 0.11), center = { x = bcx, y = bcy }, radius = br * 1.38 })
    end
    if ICON.hudShape and ICON.hudShape.btn and ICON.hudShape.btn < 0.99 then      -- pack squadrato: badge quadrato, niente anelli
      idx.badge = add({ type = "rectangle", action = "strokeAndFill", fillColor = COL.accentSoft,
        strokeColor = withA(COL.accent, 0.7), strokeWidth = sc(1.6),
        roundedRectRadii = { xRadius = btnRadius(br), yRadius = btnRadius(br) }, frame = { x = bcx - br, y = bcy - br, w = 2 * br, h = 2 * br },
        fillGradient = "linear", fillGradientAngle = 90, fillGradientColors = gradFade(COL, 0.34, 0.14) })
    else
    local ring = { type = "circle", action = "stroke", strokeColor = withA(COL.accent, 0), strokeWidth = sc(1.4),
      center = { x = bcx, y = bcy }, radius = br }
    idx.ring1 = add(ring)
    local ring2 = {}; for k, v in pairs(ring) do ring2[k] = v end
    idx.ring2 = add(ring2)
    idx.badge = add({ type = "circle", action = "strokeAndFill", fillColor = COL.accentSoft,
      strokeColor = withA(COL.accent, 0.55), strokeWidth = sc(1), center = { x = bcx, y = bcy }, radius = br,
      fillGradient = "linear", fillGradientAngle = COL.multi and 45 or 90,
      fillGradientColors = gradFade(COL, 0.34, 0.14) })
    end
    idx.icon0 = #els + 1
    ICON.drawFx(els, COL.fx and COL.fx.icon, bcx, bcy, sc(16), COL.accentInk, COL)     -- icona dello stile o microfono
    idx.icon1 = #els
    idx.iconRef = {}; for k = idx.icon0, #els do idx.iconRef[#idx.iconRef + 1] = els[k] end   -- (per l'icona che salta)
  end

  -- timer
  if vertical then
    idx.timerSize = sc(12)
    idx.timerFrames = { { x = ox, y = oy + sc(55), w = sc(56), h = sc(18) }, { x = ox, y = oy + sc(57), w = sc(56), h = sc(18) } }
    idx.timer = txt(els, "0:00", ox, oy + sc(55), sc(56), sc(18), sc(12), COL.fg, { font = "timer", align = "center", lb = "clip" })
  else
    idx.timerSize = sc(17)
    idx.timerFrames = { { x = ox + sc(57), y = oy + sc(17), w = sc(60), h = sc(24) }, { x = ox + sc(57), y = oy + sc(21), w = sc(60), h = sc(24) } }
    idx.timer = txt(els, "0:00", ox + sc(57), oy + sc(17), sc(60), sc(24), sc(17), COL.fg, { font = "timer", lb = "clip" })
  end
  do local pf = ICON.packFont("bold"); if pf then els[idx.timer].textFont = pf end end      -- carattere del pack

  -- ruota di connessione (al posto del timer finche' il mic non e' vivo): N puntini in cerchio, alpha 0 a riposo. Grande quanto il timer.
  if map then
    local N = 8
    local wcx, wcy = (vertical and (ox + sc(28)) or (ox + sc(57) + sc(22))), (vertical and (oy + sc(64)) or (oy + sc(29)))
    local R, dr = idx.timerSize * 0.42, idx.timerSize * 0.115
    local sq = (COL.fx and (COL.fx.bar == "pixel" or COL.fx.bar == "square")) and true or false
    idx.wheel = { n = N, idx = {}, last = {} }
    for i = 1, N do
      local a = (i - 1) / N * 2 * math.pi - math.pi / 2
      local px, py = wcx + math.cos(a) * R, wcy + math.sin(a) * R
      if sq then idx.wheel.idx[i] = add({ type = "rectangle", action = "fill", fillColor = withA(COL.accent, 0), frame = { x = px - dr, y = py - dr, w = 2 * dr, h = 2 * dr } })
      else idx.wheel.idx[i] = add({ type = "circle", action = "fill", fillColor = withA(COL.accent, 0), center = { x = px, y = py }, radius = dr }) end
    end
  end

  -- onda: barre / sottili / punti / linea
  local wstyle = waveStyleOf()
  local pitch = vertical and D.vp or D.pitch
  idx.wstyle, idx.wgrad = wstyle, waveGradientOn()
  local thick = (wstyle == "thin") and 1.7 or 3.2
  local shape = COL.fx and COL.fx.bar or "round"            -- round | square | pixel | ghost
  if shape == "pixel" or shape == "square" then thick = (wstyle == "thin") and 2.2 or 3.6 end
  local brad = (shape == "pixel") and 0 or (shape == "square" and 0.7 or thick / 2)
  local dotMax = pitch * 0.52
  for i = 1, n do
    local px, py
    if vertical then px = bcx; py = oy + sc(82 + (i - 1) * D.vp + 1.6)
    else px = ox + sc(120 + (i - 1) * D.pitch + 1.6); py = oy + sc(28) end
    local b = { px = px, py = py, col = gradAt(COL, (i - 1) / math.max(1, n - 1)) }
    if wstyle == "dots" then
      b.idx = add({ type = "circle", action = "fill", fillColor = withA(COL.accent, 0.5), center = { x = px, y = py }, radius = sc(dotMax * 0.38) })
    elseif wstyle ~= "line" then
      local fr
      if vertical then fr = { x = px - sc(2.5), y = py - sc(thick / 2), w = sc(5), h = sc(thick) }
      else fr = { x = px - sc(thick / 2), y = py - sc(2), w = sc(thick), h = sc(4) } end
      b.idx = add({ type = "rectangle", action = "fill", fillColor = withA(COL.accent, 0.5),
        roundedRectRadii = { xRadius = sc(brad), yRadius = sc(brad) }, frame = fr })
    end
    idx.bars[i] = b
  end
  if wstyle == "line" then
    idx.segs = {}
    for i = 1, n - 1 do
      local a, b = idx.bars[i], idx.bars[i + 1]
      idx.segs[i] = add({ type = "segments", action = "stroke", strokeColor = withA(COL.accent, 0.5), strokeWidth = sc(1.9),
        strokeCapStyle = "round", strokeJoinStyle = "round", coordinates = { { x = a.px, y = a.py }, { x = b.px, y = b.py } } })
    end
  end
  idx.barMeta = { horizontal = not vertical, s = s, thick = thick, maxLen = vertical and 30 or 28, dotMax = dotMax,
    q = (shape == "pixel") and thick or nil, ghost = (shape == "ghost") }
  idx.barCol = ICON.barCol()
  do local mt = COL.fx and COL.fx.meter and ICON.meters[COL.fx.meter]; if mt then idx.meter = mt.build(els, idx, ox, oy, s, vertical) end end

  -- pausa (primario) + stop (vetro)
  local pcx, pcy, scx, scy, brad
  if vertical then
    pcx = bcx; pcy = oy + sc(82 + 8 * D.vp + 3.2 + D.vg); scx = bcx; scy = pcy + sc(D.vs); brad = sc(13)
  else
    pcx, pcy, scx, scy, brad = ox + sc(pw - 72), oy + sc(28), ox + sc(pw - 36), oy + sc(28), sc(15)
  end
  circleButton(els, map, "pause", pcx, pcy, brad, "primary", function(e, cx, cy)
    (isPaused and ICON.play or ICON.pause)(e, cx, cy, brad * 1.1, COL.accentText)
  end, s)
  circleButton(els, map, "stop", scx, scy, brad, "ghost", function(e, cx, cy)
    ICON.stop(e, cx, cy, brad * 1.1, COL.accentInk)
  end, s)

  -- annulla: piccolo badge di vetro sul bordo alto-destro
  local kx, ky, kr = ox + sc(pw) - sc(8), oy + sc(8), sc(9.5)
  pushShadow(els, kx - kr, ky - kr, 2 * kr, 2 * kr, s, kr, 0.35, true)
  idx.pin0 = #els + 1                                    -- da qui: bottone annulla (cerchio + X). Sta in una canvas propria SOPRA tutti gli strati (vedi splitAnim)
  hitShape(els, map, "cancel", kx, ky, kr, { fill = withA(COL.solid, 1), hoverFill = withA(mix(COL.solid, COL.warn, 0.25), 1),
    stroke = COL.border, hoverStroke = COL.warn, sw = 1 })
  ICON.close(els, kx, ky, sc(11), COL.fg2, 1.8)
  idx.pin1 = #els

  -- easter egg: area sensibile sul timer (solo HUD in pausa; nell'anteprima del tab Tema è il badge)
  if map and isPaused and COL.fx and COL.fx.egg then
    hitRect(els, map, "egg", ox + sc(vertical and 0 or 57), oy + sc(vertical and 55 or 17), sc(vertical and 56 or 60), sc(vertical and 18 or 24), 2,
      { fill = withA(COL.fgWhite, 0), hoverFill = withA(COL.fgWhite, 0) })
  end

  -- tooltip sintetici sopra la card (solo orizzontale: in verticale non c'è spazio ai lati)
  if withTips and not vertical then
    idx.tipBg = add({ type = "rectangle", action = "strokeAndFill", fillColor = withA(COL.solid, 0), strokeColor = withA(COL.border, 0),
      strokeWidth = 1, roundedRectRadii = { xRadius = sc(8), yRadius = sc(8) }, frame = { x = 0, y = 0, w = 1, h = 1 } })
    idx.tipText = txt(els, "", 0, 0, 1, 1, sc(11), withA(COL.fg, 0), { font = "semi", align = "center", lb = "clip" })
    idx.tips = {
      pause = { cx = pcx, label = isPaused and "Riprendi" or "Pausa" },
      stop = { cx = scx, label = "Stop e trascrivi" },
      cancel = { cx = kx - sc(14), label = "Annulla" },
      settings = { cx = bcx, label = "Impostazioni" },
    }
    idx.tipTop = oy - sc(30)
  end
  ICON.eggBuild(els, idx, ox, oy, sc(pw), sc(ph), s, map)
  ICON.hudShape = nil
  return idx
end

setRecordingElements = function(isPaused)
  local s = config.scale
  local P = 40 * s   -- margine attorno alla card (ombra + badge)
  local els = {}
  hoverMap = {}
  Anim.cancel("hudhv"); Anim.cancel("hudtip"); Anim.cancel("egg")
  local vertical = (config.orientation == "vertical")
  local pw, ph = recDims(vertical)
  placeCanvas(pw * s + 2 * P, ph * s + 2 * P)
  local idx = buildRecCard(els, P, P, s, vertical, isPaused, hoverMap, true)
  -- strati: base = tutto cio' che non cambia; canvas A sopra = solo barre/anelli/badge/timer/particelle (ridisegno ~50x piu' economico)
  local spec = ICON.splitAnim(els, function()
    local e0 = {}
    local I0 = buildRecCard(e0, P, P, s, vertical, isPaused, {}, true)
    I0.probeConn = true                                   -- la scoperta degli elementi animati deve vedere anche la ruota di connessione
    return e0, I0
  end, { x = 0, y = 0, w = pw * s + 2 * P, h = ph * s + 2 * P }, 0, nil, ICON.recGroup)
  overlay:replaceElements(els)
  ICON.safeLayers(overlay, els, spec)
  ICON.relayer(overlay)                   -- strati riusati (stessa dimensione) restano dov'erano: sopra la base, sempre
  RECIDX = idx
  PROC = nil
  mode = "rec"
end

------------------------------------------------------------------------
-- HUD elaborazione: spinner a scia (poi check/croce con pop) + testo di stato
------------------------------------------------------------------------
-- tick dello spinner (una funzione sola: la usano il timer reale e la scoperta degli elementi animati)
local function procTick(cv, pr, t)
  if not pr or pr.state ~= "busy" then return end
  if pr.spin then pr.spinT.tick(cv, pr.spin, t); return end
  local head = (t * 1.15) % 1
  for i, d in ipairs(pr.dots) do
    local delta = (head - (i - 1) / 10) % 1
    cv:elementAttribute(d, "fillColor", withA(pr.cols[i] or COL.accent, 0.14 + 0.86 * spow(1 - delta, 2.2)))
  end
end

-- costruisce la card di elaborazione in els (pura: nessuno stato globale toccato, richiamabile come probe)
local function buildProc(els, text, s, P, pw, ph)
  local function sc(v) return v * s end
  local function add(el) els[#els + 1] = el; return #els end
  ICON.hudShape = ICON.shape()
  ICON.cardBody(els, P, P, sc(pw), sc(ph), s, { s = s, id = "drag" }, "proc")
  local cx, cy = P + sc(28), P + sc(26)
  local pr = { dots = {}, state = "busy", cols = {} }
  local PS = COL.fx and COL.fx.proc and ICON.proc[COL.fx.proc]        -- spinner / spunta custom del pack (se ci sono)
  local DN = COL.fx and COL.fx.done and ICON.done[COL.fx.done]
  if PS then pr.spin = PS.build(els, cx, cy, s); pr.spinT = PS end
  if DN then pr.dn = DN.build(els, cx, cy, s); pr.dnT = DN end
  for i = 1, (PS and 0 or 10) do
    local a = (i - 1) / 10 * 2 * math.pi - math.pi / 2
    pr.cols[i] = (COL.multi and waveGradientOn()) and gradAt(COL, (i - 1) / 9) or COL.accent
    pr.dots[i] = add({ type = "circle", action = "fill", fillColor = withA(pr.cols[i], 0.2),
      center = { x = cx + math.cos(a) * sc(9), y = cy + math.sin(a) * sc(9) }, radius = sc(1.9) })
  end
  if not DN or DN.std then
    pr.okC = add({ type = "circle", action = "fill", fillColor = withA(COL.ok, 0), center = { x = cx, y = cy }, radius = sc(12) })
    ICON.check(els, cx, cy, sc(17), withA(COL.ok, 0), 2.1); pr.okChk = #els
  end
  pr.errC = add({ type = "circle", action = "fill", fillColor = withA(COL.warn, 0), center = { x = cx, y = cy }, radius = sc(12) })
  ICON.close(els, cx, cy, sc(17), withA(COL.warn, 0), 2.1); pr.errX1 = #els - 1; pr.errX2 = #els
  pr.text = txt(els, cleanStatus(text or "…"), P + sc(54), P + sc(16), sc(pw) - sc(54) - sc(22), sc(22), sc(14), COL.fg, { font = "semi" })
  do local pf = ICON.packFont("bold"); if pf then els[pr.text].textFont = pf end end
  local kx, ky, kr = P + sc(pw) - sc(8), P + sc(8), sc(9.5)
  pushShadow(els, kx - kr, ky - kr, 2 * kr, 2 * kr, s, kr, 0.35, true)
  hitShape(els, hoverMap, "close", kx, ky, kr, { fill = COL.solid, hoverFill = mix(COL.solid, COL.accent, 0.22),
    stroke = COL.border, hoverStroke = COL.accent, sw = 1 })
  ICON.close(els, kx, ky, sc(11), COL.fg2, 1.8)
  ICON.hudShape = nil
  return pr
end

setProcessingElements = function(text)
  local s = config.scale
  local function sc(v) return v * s end
  local P = sc(40)
  hoverMap = {}
  Anim.cancel("hudhv"); Anim.cancel("hudtip"); Anim.cancel("egg")
  local pw, ph = 236, 52
  placeCanvas(sc(pw) + 2 * P, sc(ph) + 2 * P)
  local els = {}
  local pr = buildProc(els, text, s, P, pw, ph)
  -- strati: lo spinner (o i puntini) e' una canvas piccola sopra; la card resta statica
  local spec = ICON.splitAnim(els, function()
    local e0 = {}
    local hm = hoverMap; hoverMap = {}
    local p0 = buildProc(e0, text, s, P, pw, ph)
    hoverMap = hm
    return e0, p0
  end, { x = 0, y = 0, w = sc(pw) + 2 * P, h = sc(ph) + 2 * P }, 0, function(rec, p0)
    for k = 1, 8 do procTick(rec, p0, 500 + k * 0.07) end
  end)
  overlay:layerClear()
  overlay:replaceElements(els)
  ICON.safeLayers(overlay, els, spec)
  PROC = pr
  RECIDX = nil
  mode = "proc"
  -- lo spinner gira solo finché l'HUD è in "proc" (il timer si ferma con stopUITimer)
  if uiTimer then uiTimer:stop() end
  uiTimer = hs.timer.new(1 / 30, function()
    local ok, err = pcall(function()
      if not PROC or mode ~= "proc" or not overlay or PROC.state ~= "busy" then return end
      procTick(overlay, PROC, hs.timer.secondsSinceEpoch())
    end)
    if not ok then ICON.log("[GW] spinner: " .. tostring(err)) end
  end)
  uiTimer:start()
end

setStatus = function(text)
  if not (overlay and mode == "proc" and PROC) then return end
  local pr = PROC
  local kind = "busy"
  if text:find("^✓") then kind = "ok" elseif text:find("^✕") then kind = "err" end
  overlay:elementAttribute(pr.text, "text", cleanStatus(kind == "ok" and ICON.doneText(text) or text))
  overlay:elementAttribute(pr.text, "textColor", kind == "err" and COL.warn or COL.fg)
  if kind ~= pr.state then
    pr.state = kind
    if kind ~= "busy" then
      for _, d in ipairs(pr.dots) do overlay:elementAttribute(d, "fillColor", withA(COL.accent, 0)) end
      if pr.spin and pr.spinT.hide then pr.spinT.hide(overlay, pr.spin) end
      if kind == "ok" then ICON.stat.n = ICON.stat.n + 1 end
      if kind == "ok" and pr.dn and pr.dnT.start then pr.dnT.start(overlay, pr.dn) end
      Anim.run("hud", "result", 0.34, "spring", function(e)
        local a = clamp01(e)
        if kind == "ok" then
          if pr.dn then pr.dnT.anim(overlay, pr.dn, e) end
          if pr.okC then
            overlay:elementAttribute(pr.okC, "fillColor", withA(COL.ok, 0.20 * a))
            overlay:elementAttribute(pr.okChk, "strokeColor", withA(COL.ok, a))
          end
        else
          overlay:elementAttribute(pr.errC, "fillColor", withA(COL.warn, 0.20 * a))
          overlay:elementAttribute(pr.errX1, "strokeColor", withA(COL.warn, a))
          overlay:elementAttribute(pr.errX2, "strokeColor", withA(COL.warn, a))
        end
      end)
    end
  end
end

------------------------------------------------------------------------
-- Aggiornamento continuo (solo durante la registrazione): onda fluida, anelli, avviso
-- hudVisuals è condivisa con l'anteprima viva del tab Tema. Ogni blocco è in pcall:
-- un errore in un pezzo (es. anelli) non ferma timer e onda.
------------------------------------------------------------------------
local guarded
do
  local lastUIErr = nil
  guarded = function(tag, f)
    local ok, err = pcall(f)
    if not ok then
      local m = tag .. ": " .. tostring(err)
      if m ~= lastUIErr then lastUIErr = m; ICON.log("[GW] " .. m) end
    end
    return ok
  end
end

local function hudVisuals(cv, I, t, dt, active, warn, text, onWarn, src)
  -- timer + avviso
  guarded("timer", function()
    if text ~= I.lastText then cv:elementAttribute(I.timer, "text", text); I.lastText = text end
    if warn ~= I.warnPrev then
      I.warnPrev = warn
      cv:elementAttribute(I.timer, "textSize", warn and (I.timerSize * (I.vertical and 0.8 or 0.66)) or I.timerSize)
      cv:elementAttribute(I.timer, "frame", I.timerFrames[warn and 2 or 1])
      cv:elementAttribute(I.timer, "textColor", withA(warn and COL.warn or COL.fg, I.tA or 1))
      if I.badge then cv:elementAttribute(I.badge, "strokeColor", warn and withA(COL.warn, 0.75) or withA(COL.accent, 0.55)) end
      if warn then if onWarn then onWarn() end else cv:elementAttribute(I.border, "strokeColor", I.borderCol or COL.border) end
    end
    if warn then cv:elementAttribute(I.border, "strokeColor", mix(I.borderCol or COL.border, COL.warn, 0.55 + 0.45 * math.sin(finite(t * 7, 0)))) end
  end)

  -- ruota di connessione <-> timer: dissolvenza incrociata ~0.25 s, nessun cambio di colore. Spenta = anelli di puntini a alpha 0.
  guarded("wheel", function()
    local W = I.wheel
    local on = (W and (I.wheelOn or I.probeConn) and not warn) and true or false
    local tgt = on and 1 or 0
    local wa = I.wA or 0
    local base = active and 1 or 0.7                       -- in pausa il timer e' attenuato ma leggibile
    if wa == tgt and not on and I.tA == base then return end
    if animOn() then wa = wa + (tgt - wa) * (1 - math.exp(-14 * clampN(dt, 0.001, 0.1))); if math.abs(wa - tgt) < 0.02 then wa = tgt end else wa = tgt end
    I.wA = wa
    local ta = clampN((1 - wa) * base, 0, 1)
    if I.tA == nil or math.abs(ta - I.tA) > 0.015 or (ta == base and I.tA ~= base) or (ta == 0 and I.tA ~= 0) then
      I.tA = ta; cv:elementAttribute(I.timer, "textColor", withA(warn and COL.warn or COL.fg, ta))
    end
    if not W then return end
    local head = animOn() and ((t * (I.wheelSpd or 1.1)) % 1) or 0.3
    local N = W.n
    for i = 1, N do
      local delta = (head - (i - 1) / N) % 1
      local a = (0.16 + 0.84 * spow(clampN(1 - delta, 0, 1), 2.0)) * wa
      local last = W.last[i]
      if not last or math.abs(a - last) > 0.02 or (a == 0 and last ~= 0) then
        W.last[i] = a
        cv:elementAttribute(W.idx[i], "fillColor", withA(COL.accent, a))
      end
    end
  end)

  -- anelli pulsanti dietro al mic (intensità regolabile; spenti se le animazioni sono off)
  guarded("rings", function()
    if not I.ring1 then return end
    local pk = clampN(config.micPulse == nil and 0.5 or config.micPulse, 0, 1) * 2
    if not animOn() then pk = 0 end
    if warn then pk = math.max(pk, 1) end
    local grow = math.min(0.75, 0.55 * pk)
    local cols = { warn and COL.warn or COL.accent, warn and COL.warn or (COL.multi and COL.accent2 or COL.accent) }
    local speed = warn and 1.9 or 0.85
    local RL = I.ringLast
    if not RL then RL = {}; I.ringLast = RL end
    for k, ri in ipairs({ I.ring1, I.ring2 }) do
      local ph = (t * speed + (k - 1) * 0.5) % 1
      local e = 1 - (1 - ph) * (1 - ph)
      local rad = finite(I.br * (1 + grow * e), I.br)
      local al = active and 0.55 * math.min(1, pk) * spow(1 - ph, 1.6) or 0
      local L = RL[k]
      -- scrive solo ciò che cambia oltre soglia (a riposo / pulsazione 0 niente da aggiornare)
      if not L or math.abs(rad - L.r) > 0.12 or math.abs(al - L.a) > 0.012 or warn ~= L.w then
        cv:elementAttribute(ri, "radius", rad)
        cv:elementAttribute(ri, "strokeColor", withA(cols[k], al))
        RL[k] = { r = rad, a = al, w = warn }
      end
    end
    local brd = finite(I.br * (1 + (active and 0.035 * pk * math.sin(t * 2 * math.pi * 0.85) or 0)), I.br)
    if not RL.b or math.abs(brd - RL.b) > 0.06 then cv:elementAttribute(I.badge, "radius", brd); RL.b = brd end
  end)

  -- particelle dello stile (neve, pipistrelli, ...): ~22 aggiornamenti/s, ferme se le animazioni sono spente o a riposo
  guarded("particles", function()
    if not I.parts then return end
    if t - (I.partT or 0) < (I.preview and 0.1 or 0.06) and not I.partDirty then return end
    I.partT = t
    ICON.lv = I.lv or 0
    ICON.partsTick(cv, I.parts, t, animOn() and active and not warn)
  end)

  -- onda: i livelli arrivano a 10Hz, qui sono lisciati (attacco rapido, rilascio lento)
  local maxDelta = 0
  guarded("wave", function()
    local lvSum = 0
    local bm = I.barMeta
    local n = #I.bars
    local styleDots, styleLine = (I.wstyle == "dots"), (I.wstyle == "line")
    local pts = {}
    local cols = {}
    local ckey = (active and 1 or 0) + (warn and 2 or 0)
    if I.cacheKey ~= ckey or not I.bh then I.cacheKey = ckey; I.bh = {}; I.ba = {} end      -- cambio stato: riscrivi tutto
    local BH, BA = I.bh, I.ba
    for i, b in ipairs(I.bars) do
      local target = 0
      if active and not warn then
        if I.conn then target = clampN(0.16 + 0.12 * math.sin(finite(t * 3.2 - i * 0.7, 0)), 0, 1)    -- in attesa del mic: onda che respira
        else target = finite((src and src[i]) or 0, 0) end
      end
      local cur = finite(I.disp[i], 0)
      local rate = (target > cur) and 22 or 6
      cur = finite(cur + (target - cur) * (1 - math.exp(-rate * dt)), 0)
      I.disp[i] = cur
      maxDelta = math.max(maxDelta, math.abs(target - cur))
      local lv = clampN(cur, 0, 1)
      lvSum = lvSum + lv
      if active and not warn then lv = math.max(lv, 0.06 + 0.05 * math.sin(finite(t * 2.4 + i * 0.8, 0))) end   -- respiro a riposo
      -- colore: accento oppure gradiente del tema lungo l'onda
      local c
      if warn then c = COL.warn
      elseif I.barCol then c = active and I.barCol or mix(I.barCol, COL.solid, 0.3)       -- colore fisso del pack
      elseif I.wgrad then c = active and b.col or mix(b.col, COL.solid, 0.3)
      else c = active and COL.accent or COL.accentDim end
      local fade = 0.5 + 0.5 * i / n
      local a = active and ((0.42 + 0.58 * math.min(1, lv * 1.4)) * fade) or 0.9
      if bm.ghost then a = a * clampN(0.62 + 0.38 * math.sin(finite(t * 1.9 + i * 0.9, 0)), 0, 1) end     -- barre "spettrali": sfarfallio
      local col = withA(c, a)
      if styleLine then
        local off = ((i % 2 == 0) and 1 or -1) * lv * bm.maxLen * 0.5 * bm.s
        pts[i] = bm.horizontal and { x = b.px, y = b.py + off } or { x = b.px + off, y = b.py }
        cols[i] = col
      elseif styleDots then
        local r = finite((bm.dotMax * 0.38 + lv * bm.dotMax * 0.62) * bm.s, 1)
        if not BH[i] or math.abs(r - BH[i]) > 0.08 or not BA[i] or math.abs(a - BA[i]) > 0.012 then
          cv:elementAttribute(b.idx, "radius", r)
          cv:elementAttribute(b.idx, "fillColor", col)
          BH[i], BA[i] = r, a
        end
      else
        local ext
        if bm.horizontal then
          ext = (4 + lv * bm.maxLen) * bm.s
          if bm.q then ext = math.max(bm.q, math.floor(ext / (bm.q * bm.s) + 0.5) * bm.q * bm.s) end          -- a blocchi
        else
          ext = (5 + lv * bm.maxLen) * bm.s
          if bm.q then ext = math.max(bm.q, math.floor(ext / (bm.q * bm.s) + 0.5) * bm.q * bm.s) end
        end
        ext = finite(ext, 4)
        -- scrive solo se la barra è cambiata oltre una soglia (mezzo pixel / ~1% di opacità)
        if not BH[i] or math.abs(ext - BH[i]) > 0.4 or not BA[i] or math.abs(a - BA[i]) > 0.012 then
          if bm.horizontal then
            cv:elementAttribute(b.idx, "frame", { x = b.px - bm.thick * bm.s / 2, y = b.py - ext / 2, w = bm.thick * bm.s, h = ext })
          else
            cv:elementAttribute(b.idx, "frame", { x = b.px - ext / 2, y = b.py - bm.thick * bm.s / 2, w = ext, h = bm.thick * bm.s })
          end
          cv:elementAttribute(b.idx, "fillColor", col)
          BH[i], BA[i] = ext, a
        end
      end
    end
    if styleLine and I.segs then
      for i = 1, n - 1 do
        local p1, p2 = pts[i], pts[i + 1]
        if p1 and p2 then
          cv:elementAttribute(I.segs[i], "coordinates", { { x = finite(p1.x, 0), y = finite(p1.y, 0) }, { x = finite(p2.x, 0), y = finite(p2.y, 0) } })
          cv:elementAttribute(I.segs[i], "strokeColor", cols[i])
        end
      end
    end
    I.lv = clampN(lvSum / math.max(1, n) * 1.5, 0, 1)
  end)
  -- indicatore del pack (boost) + easter egg: niente se lo stile non li ha
  if I.meter then guarded("meter", function() maxDelta = math.max(maxDelta, ICON.meterTick(cv, I, I.lv or 0, active, warn, t, dt)) end) end
  if I.egg then guarded("egg", function() ICON.eggTick(cv, I, t, dt, active, warn) end) end
  return maxDelta
end

------------------------------------------------------------------------
-- STRATI: ogni ridisegno di hs.canvas ripassa TUTTA la canvas (costo ~ elementi x area). La card animata (HUD / anteprima)
-- sta quindi su DUE canvas: la base (statica: ombra, vetro, bordo, bottoni; si ridisegna solo quando cambia davvero) e una
-- canvas piccola "A" sopra, senza mouse, con SOLO gli elementi che l'animazione scrive (barre, anelli, badge+icona, timer, particelle).
-- ICON.wrap(base) restituisce un proxy con la stessa API della canvas: finestra (frame/alpha/show/hide/...) propagata ad A,
-- elementAttribute instradato per indice (con traslazione delle coordinate). Gli indici della base non cambiano mai
-- (gli elementi passati ad A restano come segnaposto trasparente).
------------------------------------------------------------------------
do
  local function shiftEl(e, dx, dy)
    local c = {}; for k, v in pairs(e) do c[k] = v end
    if e.frame then c.frame = { x = e.frame.x - dx, y = e.frame.y - dy, w = e.frame.w, h = e.frame.h } end
    if e.center then c.center = { x = e.center.x - dx, y = e.center.y - dy } end
    if e.coordinates then
      local p = {}; for i, q in ipairs(e.coordinates) do p[i] = { x = q.x - dx, y = q.y - dy } end
      c.coordinates = p
    end
    return c
  end
  local function shiftVal(k, v, dx, dy)
    if type(v) ~= "table" then return v end
    if k == "frame" then return { x = v.x - dx, y = v.y - dy, w = v.w, h = v.h } end
    if k == "center" then return { x = v.x - dx, y = v.y - dy } end
    if k == "coordinates" then
      local p = {}; for i, q in ipairs(v) do p[i] = { x = q.x - dx, y = q.y - dy } end
      return p
    end
    return v
  end

  -- placeholder invisibile (action "skip": non costa nulla in disegno) che tiene stabili gli indici della base
  -- uguaglianza profonda (numeri a meno di 1e-6): serve a non rifotografare una colonna il cui contenuto non e' cambiato
  function ICON.sameVal(a, b, depth)
    depth = (depth or 0) + 1
    if depth > 8 then return false end
    local ta = type(a)
    if ta ~= type(b) then return false end
    if ta == "number" then return a == b or math.abs(a - b) < 1e-6 end
    if ta ~= "table" then return a == b end
    for k, v in pairs(a) do if not ICON.sameVal(v, b[k], depth) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
  end
  -- ruolo di ogni elemento "caldo" del HUD: w = barre/segmenti dell'onda, t = timer, p = particelle, r = anelli/badge/icona/meter
  function ICON.recGroup(I0)
    local m = {}
    if I0.timer then m[I0.timer] = "t" end
    for _, b in ipairs(I0.bars or {}) do if b.idx then m[b.idx] = "w" end end
    for _, si in ipairs(I0.segs or {}) do m[si] = "w" end
    if I0.parts and I0.parts.idx then for _, i in ipairs(I0.parts.idx) do m[i] = "p" end end
    if I0.wheel then for _, i in ipairs(I0.wheel.idx) do m[i] = "c" end end
    if I0.pin0 then for i = I0.pin0, I0.pin1 do m[i] = "k" end end
    return function(i) return m[i] or "r" end
  end
  -- frequenza massima di ridisegno (Hz) delle canvas del HUD di registrazione: onda 18, anelli/badge 12, timer 8 (cambia 1/s), particelle 16, avviso 15
  ICON.GROUP_HZ = { w = 18, r = 12, t = 8, p = 16, x = 15, c = 15 }
  function ICON.skipEl() return { type = "rectangle", action = "skip", frame = { x = 0, y = 0, w = 1, h = 1 } } end
  -- livello di finestra = quello di cv + n (numerico): gli strati stanno SOPRA la base per livello, non solo per ordine (un click sulla base
  -- porta la base in primo piano nel suo livello, ma non oltre il livello degli strati); hover/fantasma + 2 stanno sopra gli strati
  function ICON.lvlUp(cv, n)
    local ok, l = pcall(function() return cv:level() end)
    if ok and type(l) == "number" then return l + n end
    return ok and l or nil
  end
  -- cv = proxy ICON.wrap; later = anche una volta differita (se la finestra viene portata avanti dopo il callback)
  function ICON.relayer(cv, later)
    if not cv then return end
    local okS, sh = pcall(function() return cv:isShowing() end)
    if okS and not sh then return end                        -- finestra nascosta: niente (orderAbove la mostrerebbe)
    pcall(function() if cv.layerCount and cv:layerCount() > 0 then cv:relayer() end end)
    if later then
      hs.timer.doAfter(0.04, function() pcall(function() if cv.layerCount and cv:layerCount() > 0 then cv:relayer() end end) end)
    end
  end
  -- applica gli strati; se QUALCOSA fallisce torna a canvas singola (ripristina gli elementi spostati) invece di lasciare l'HUD a meta'
  function ICON.safeLayers(cv, els, spec)
    if not spec then pcall(function() cv:layerClear() end); return end
    local ok, err = pcall(function()
      if spec.groups then
        local keep = {}
        for _, k in ipairs(spec.order) do keep["g" .. k] = true end
        cv:layerPrune(keep)
        for _, k in ipairs(spec.order) do
          local g = spec.groups[k]
          g.hz = ICON.GROUP_HZ[k]
          if k == "k" then g.cb = mouseCb end                -- bottone annulla: unico strato col mouse (il resto e' click-through)
          cv:layerApply(g, "g" .. k)
        end
      else
        cv:layerPrune({ a = true })
        cv:layerApply(spec)
      end
    end)
    if not ok then
      ICON.log("[GW] strati: " .. tostring(err))
      pcall(function() cv:layerClear() end)
      for i, e in pairs(spec.orig or {}) do els[i] = e end
      pcall(function() cv:replaceElements(els) end)
    end
  end

  -- proxy multi-strato: layers[key] = { cv, dx, dy, w, h, route }. Un indice della base instradato in uno strato viene scritto li'
  -- (coordinate traslate); gli altri vanno alla base. Finestra (frame/alpha/show/...) propagata a tutti gli strati.
  ICON.shiftEl = shiftEl
  function ICON.wrap(base)
    local P = {}
    local layers = {}               -- upvalue: niente campi sul proxy (il suo __index inoltra alla canvas vera)
    local seqN = 0
    local function each(fn, ordered)
      if ordered then       -- dall'alto: l'ultimo creato sta sotto (ognuno si mette subito sopra la base)
        local ks = {}
        for k in pairs(layers) do ks[#ks + 1] = k end
        table.sort(ks, function(p, q) return (layers[p].seq or 0) > (layers[q].seq or 0) end)
        for _, k in ipairs(ks) do local L = layers[k]; local w = L.win or L.cv; if w then pcall(fn, w, L, k) end end
      else
        for k, L in pairs(layers) do local w = L.win or L.cv; if w then pcall(fn, w, L, k) end end
      end
    end
    local function kill(L)
      L.dead = true
      if L.ft then pcall(function() L.ft:stop() end); L.ft = nil end
      if L.cv then pcall(function() L.cv:delete() end) end
      if L.vc then pcall(function() L.vc:delete() end) end
    end
    -- un click (down/up) su una canvas del gruppo la porta davanti alle altre: dopo ogni click gli strati tornano sopra
    local function wrapCb(f)
      if not f then return nil end
      return function(c, msg, ...)
        if msg == "mouseDown" or msg == "mouseUp" then ICON.relayer(P, true) end
        return f(c, msg, ...)
      end
    end
    function P:layerClear(key)
      if key == nil then
        for k, L in pairs(layers) do kill(L); layers[k] = nil end
      else
        local L = layers[key]; layers[key] = nil
        if L then kill(L) end
      end
    end
    -- STRATO RASTER (colonne scorrevoli): il contenuto lungo vive in una canvas mai mostrata (L.cv, coordinate di contenuto) che
    -- viene fotografata (imageFromCanvas, risoluzione nativa) in una canvas viewport (L.vc = la finestra vera) con 3 elementi:
    -- [1] immagine (scorre cambiando solo il suo frame), [2] superficie mouse trasparente (hit-test fatto in Lua), [3] scrollbar.
    -- Le scritture instradate (animazioni, slider) vanno su L.cv e segnano "sporco": una nuova istantanea, al massimo ogni 30 ms.
    local gcPend = false
    local function gcSoon()               -- le istantanee pesano nel nativo, non nell'heap Lua: il GC non se ne accorge da solo
      if gcPend then return end
      gcPend = true
      hs.timer.doAfter(0.35, function() gcPend = false; pcall(collectgarbage) end)
    end
    -- L.tiles = { {y, h}, ... }: l'immagine e' tagliata in strisce (TILE pt): ogni ridisegno della viewport costa quanto le strisce che
    -- intersecano la finestra, non quanto l'intera immagine (misurato: 1772 pt interi 25-40% CPU a 30 agg/s; strisce da 512 pt ~8%).
    local TILE = 512
    local function tileFrames(L)
      local y0 = math.floor((L.yOff - L.scroll) * 2 + 0.5) / 2              -- passo di mezzo punto: nitido anche su retina
      local out = {}
      for i, t in ipairs(L.tiles) do out[i] = { x = 0, y = y0 + t.y, w = L.fw, h = t.h } end
      return out
    end
    local function rasterNow(L)
      L.dirty = false
      local ok, img = pcall(function() return L.cv:imageFromCanvas() end)
      if not (ok and img and L.vc) then return end
      local tiles, els = {}, { L.surf, L.sbEl or ICON.skipEl() }
      local y = 0
      while y < L.fh do
        local h = math.min(TILE, L.fh - y)
        local ti = img
        if h < L.fh then
          local okc, c = pcall(function() return img:croppedCopy({ x = 0, y = y, w = L.fw, h = h }) end)
          if okc and c then ti = c else tiles = nil; break end
        end
        tiles[#tiles + 1] = { y = y, h = h }
        els[#els + 1] = { type = "image", image = ti, imageScaling = "scaleToFit", frame = { x = 0, y = y, w = L.fw, h = h } }
        y = y + h
      end
      if not tiles then                                                       -- ritaglio non disponibile: immagine intera
        tiles = { { y = 0, h = L.fh } }
        els = { L.surf, L.sbEl or ICON.skipEl(), { type = "image", image = img, imageScaling = "scaleToFit", frame = { x = 0, y = 0, w = L.fw, h = L.fh } } }
      end
      L.tiles = tiles
      L.vc:replaceElements(els)
      local fr = tileFrames(L)
      for i = 1, #tiles do L.vc:elementAttribute(2 + i, "frame", fr[i]) end
      L.rasters = (L.rasters or 0) + 1; gcSoon()
    end
    local function markDirty(L)
      L.dirty = true
      if L.pend then return end
      L.pend = true
      hs.timer.doAfter(0.03, function()
        L.pend = false
        if L.dirty and not L.dead then pcall(rasterNow, L) end
      end)
    end
    -- spec = { els (coordinate di contenuto), route, box = viewport {x,y,w,h} in coordinate base, fc = {w,h,dx,dy}, yOff, scroll,
    --          cb = callback mouse, sbIdx (indice base della scrollbar), sbEl (elemento in coordinate viewport) }
    function P:layerRaster(spec, key)
      key = key or "r"
      local b, fc = spec.box, spec.fc
      local f = base:frame()
      local L = layers[key]
      if L and not L.raster then P:layerClear(key); L = nil end
      local surf = { type = "rectangle", action = "fill", fillColor = { red = 0, green = 0, blue = 0, alpha = 0 }, frame = { x = 0, y = 0, w = b.w, h = b.h },
        trackMouseDown = true, trackMouseUp = true, trackMouseEnterExit = true, trackMouseMove = true, id = "rv" }
      local same = false
      if L and L.cv and L.vc and L.fw == fc.w and L.fh == fc.h then
        same = (not L.touched) and L.last ~= nil and ICON.sameVal(L.last, spec.els)
        if not same then L.cv:replaceElements(spec.els) end
      else
        P:layerClear(key)
        local fcv = hs.canvas.new({ x = -30000, y = 0, w = fc.w, h = fc.h })     -- mai mostrata
        fcv:replaceElements(spec.els)
        local vc = hs.canvas.new({ x = f.x + b.x, y = f.y + b.y, w = b.w, h = b.h })
        pcall(function() vc:level(ICON.lvlUp(base, 1)); vc:behavior(base:behavior()) end)
        vc:replaceElements({ surf, spec.sbEl or ICON.skipEl() })
        vc:alpha(base:alpha())
        L = { raster = true, cv = fcv, vc = vc, win = vc, fw = fc.w, fh = fc.h, w = b.w, h = b.h, tiles = {} }
        layers[key] = L
        local ok, sh = pcall(function() return base:isShowing() end)
        if ok and sh then vc:show(); pcall(function() vc:orderAbove(base) end) end
      end
      L.dx, L.dy, L.wx, L.wy, L.route, L.sbIdx = fc.dx, fc.dy, b.x, b.y, spec.route, spec.sbIdx
      L.yOff, L.scroll = spec.yOff or 0, spec.scroll or 0
      L.vc:mouseCallback(wrapCb(spec.cb))
      L.vc:topLeft({ x = f.x + b.x, y = f.y + b.y })
      if L.w ~= b.w or L.h ~= b.h then L.w, L.h = b.w, b.h; L.vc:size({ w = b.w, h = b.h }) end
      surf.frame = { x = 0, y = 0, w = b.w, h = b.h }
      L.surf, L.sbEl = surf, spec.sbEl
      L.last, L.touched = spec.els, false
      if same then              -- contenuto identico: niente nuova istantanea, solo scroll / scrollbar / superficie
        L.vc:elementAttribute(1, "frame", surf.frame)
        if spec.sbEl then L.vc:elementAttribute(2, "frame", spec.sbEl.frame); L.vc:elementAttribute(2, "fillColor", spec.sbEl.fillColor) end
        local fr = tileFrames(L)
        for i = 1, #L.tiles do L.vc:elementAttribute(2 + i, "frame", fr[i]) end
      else
        rasterNow(L)
      end
    end
    function P:layerRasterScroll(key, sc)    -- scorre l'immagine; false se lo strato non e' raster
      local L = layers[key]
      if not L or not L.raster or not L.vc then return false end
      L.scroll = sc
      local fr = tileFrames(L)
      for i = 1, #L.tiles do L.vc:elementAttribute(2 + i, "frame", fr[i]) end
      return true
    end
    function P:layerIsRaster(key) local L = layers[key]; return L ~= nil and L.raster == true end
    function P:layerStats()                  -- diagnostica: { {key, rasters, fw, fh} }
      local out = {}
      for k, L in pairs(layers) do if L.raster then out[#out + 1] = { key = k, rasters = L.rasters or 0, fw = L.fw, fh = L.fh } end end
      return out
    end
    -- spec = { els = {...}, route = { [indiceBase] = indiceStrato }, box = {x,y,w,h} in coordinate della base, cb = mouseCallback | nil }
    function P:layerApply(spec, key)
      key = key or "a"
      if not spec or not spec.els or #spec.els == 0 or not spec.box then P:layerClear(key); return end
      local b = spec.box
      local f = base:frame()
      local L = layers[key]
      if L and L.raster then P:layerClear(key); L = nil end
      if L and L.cv and L.w == b.w and L.h == b.h then
        L.cv:replaceElements(spec.els)
        L.pq, L.pord = nil, nil                       -- scritture in coda riferite al contenuto vecchio: scartate
      else
        P:layerClear(key)
        local cv = hs.canvas.new({ x = f.x + b.x, y = f.y + b.y, w = b.w, h = b.h })
        pcall(function() cv:level(ICON.lvlUp(base, 1)); cv:behavior(base:behavior()) end)
        cv:replaceElements(spec.els)
        cv:alpha(base:alpha())
        seqN = seqN + 1
        L = { cv = cv, w = b.w, h = b.h, seq = seqN }
        layers[key] = L
        local ok, sh = pcall(function() return base:isShowing() end)
        if ok and sh then cv:show(); pcall(function() cv:orderAbove(base) end) end
      end
      L.cv:mouseCallback(wrapCb(spec.cb))          -- nil = trasparente al mouse (click-through)
      if spec.cb then pcall(function() L.cv:clickActivating(false) end) end     -- come la base: il click non porta in primo piano Hammerspoon
      L.dx, L.dy, L.route, L.hz = b.x, b.y, spec.route, spec.hz
      L.cv:topLeft({ x = f.x + b.x, y = f.y + b.y })
    end
    function P:layerPrune(keep)             -- elimina gli strati con chiave non in keep (set)
      for k in pairs(layers) do if not keep[k] then P:layerClear(k) end end
    end
    function P:layerSize(key, w, h)         -- ritaglio dinamico (altezza della finestra in animazione)
      local L = layers[key]
      if not L or not L.cv then return end
      w, h = math.max(1, w), math.max(1, h)
      if L.w == w and L.h == h then return end
      L.w, L.h = w, h
      if L.raster then
        L.vc:size({ w = w, h = h }); L.vc:elementAttribute(1, "frame", { x = 0, y = 0, w = w, h = h })
        if L.surf then L.surf.frame = { x = 0, y = 0, w = w, h = h } end
      else
        L.cv:size({ w = w, h = h })
      end
    end
    function P:layerImages()                -- istantanee degli strati (per il fantasma del cambio pagina): { {img, x, y, w, h}, ... }
      local out = {}
      for k, L in pairs(layers) do
        local win = L.win or L.cv
        if win then
          local ok, img = pcall(function() return win:imageFromCanvas() end)
          if ok and img then out[#out + 1] = { img = img, x = L.wx or L.dx, y = L.wy or L.dy, w = L.w, h = L.h } end
        end
      end
      return out
    end
    function P:layerCount() local n = 0; for _, L in pairs(layers) do if L.cv then n = n + 1 end end return n end
    function P:frame(fr)
      if fr == nil then return base:frame() end
      base:frame(fr)
      each(function(cv, L) cv:topLeft({ x = fr.x + (L.wx or L.dx), y = fr.y + (L.wy or L.dy) }) end)
      return P
    end
    function P:topLeft(p)
      if p == nil then return base:topLeft() end
      base:topLeft(p)
      each(function(cv, L) cv:topLeft({ x = p.x + (L.wx or L.dx), y = p.y + (L.wy or L.dy) }) end)
      return P
    end
    function P:alpha(a)
      if a == nil then return base:alpha() end
      base:alpha(a); each(function(cv) cv:alpha(a) end)
      return P
    end
    function P:show()
      base:show()
      each(function(cv) cv:show(); cv:orderAbove(base) end, true)
      return P
    end
    function P:hide() base:hide(); each(function(cv) cv:hide() end); return P end
    function P:orderAbove(c2)
      base:orderAbove(c2)
      each(function(cv) cv:orderAbove(base) end, true)
      return P
    end
    function P:relayer()                    -- rimette gli strati sopra la base (un click sulla base la porta in primo piano nel suo livello)
      local a = base:alpha()
      each(function(cv) cv:alpha(a); cv:orderAbove(base) end, true)    -- (e li riallinea alla trasparenza della base: mai strati a mezza alpha)
      return P
    end
    function P:mouseCallback(f)
      base:mouseCallback(wrapCb(f))
      return P
    end
    function P:level(l)
      if l == nil then return base:level() end
      base:level(l); local lv = ICON.lvlUp(base, 1); each(function(cv) cv:level(lv) end)
      return P
    end
    function P:behavior(bh)
      if bh == nil then return base:behavior() end
      base:behavior(bh); each(function(cv) cv:behavior(bh) end)
      return P
    end
    function P:delete() P:layerClear(); base:delete() end
    function P:elementAttribute(i, k, v)
      for _, L in pairs(layers) do
        local j = L.route and L.route[i]
        if j and L.hz then
          -- strato a frequenza limitata: le scritture si accodano (l'ultimo valore vince) e partono in blocco, al massimo hz volte/s
          local key = j .. ":" .. k
          L.pq = L.pq or {}; L.pord = L.pord or {}
          if not L.pq[key] then L.pord[#L.pord + 1] = key end
          L.pq[key] = { j, k, shiftVal(k, v, L.dx, L.dy) }
          if not L.ft then
            local gap = 1 / L.hz
            L.ft = hs.timer.doAfter(math.max(0.001, gap - (hs.timer.secondsSinceEpoch() - (L.fl or 0))), function()
              L.ft = nil
              if L.dead or not L.pq then return end
              local q, ord = L.pq, L.pord
              L.pq, L.pord = nil, nil
              L.fl = hs.timer.secondsSinceEpoch()
              for _, kk in ipairs(ord) do local w = q[kk]; pcall(function() L.cv:elementAttribute(w[1], w[2], w[3]) end) end
            end)
          end
          return P
        end
        if j then
          L.cv:elementAttribute(j, k, shiftVal(k, v, L.dx, L.dy))
          if L.raster then L.touched = true; markDirty(L) end
          return P
        end
        if L.raster and L.sbIdx == i then          -- scrollbar: sta nella viewport, non nell'immagine
          local sv = shiftVal(k, v, L.wx, L.wy)
          if L.sbEl then L.sbEl[k] = sv end                -- lo stato resta valido anche dopo una nuova istantanea (replaceElements)
          L.vc:elementAttribute(2, k, sv)
          return P
        end
      end
      base:elementAttribute(i, k, v)
      return P
    end
    setmetatable(P, { __index = function(_, k)
      local f = base[k]
      if type(f) == "function" then
        return function(self, ...) local r = f(base, ...); if r == base then return P end return r end
      end
      return f
    end })
    return P
  end

  local function extent(e)             -- ingombro (x0,y0,x1,y1) di un elemento, tratto incluso
    local sw = (e.strokeWidth or 0) * 0.5 + 1.5
    if e.frame then local f = e.frame; return f.x - sw, f.y - sw, f.x + f.w + sw, f.y + f.h + sw end
    if e.center then local c, r = e.center, (e.radius or 0) + sw; return c.x - r, c.y - r, c.x + r, c.y + r end
    if e.coordinates then
      local x0, y0, x1, y1 = 1e9, 1e9, -1e9, -1e9
      for _, p in ipairs(e.coordinates) do x0 = math.min(x0, p.x); y0 = math.min(y0, p.y); x1 = math.max(x1, p.x); y1 = math.max(y1, p.y) end
      if x0 > x1 then return nil end
      return x0 - sw, y0 - sw, x1 + sw, y1 + sw
    end
  end

  -- Scopre QUALI elementi dell'HUD cambiano durante l'animazione (probe su una copia: nessuno stato reale toccato) e li sposta
  -- in canvas piccole sopra la base. probe() -> els0, I0 (stessa card ricostruita a parte). Ritorna spec per layerApply, oppure nil.
  -- els: lista reale (i passati agli strati diventano segnaposto). bounds = {x,y,w,h} della base (gli strati sono tagliati li').
  -- grp (opzionale) = function(I0) -> function(i) -> chiave gruppo: gli elementi "caldi" (scritti durante la registrazione normale) si
  -- dividono in piu' canvas, ognuna con la sua frequenza di ridisegno (hz); quelli scritti solo in avviso/riposo vanno in un gruppo "x" a
  -- parte (a riposo non costa nulla). Senza grp: una sola canvas "a" (comportamento precedente).
  function ICON.splitAnim(els, probe, bounds, off, drive, grp)
    off = off or 0
    if not ICON.layersOn() then return nil end
    local ok, spec = pcall(function()
      local els0, I0 = probe()
      if not I0 or (not drive and not I0.bars) then return nil end
      local seen, seenHot, W = {}, {}, {}
      local phase = 1
      local function ext(w, x0, y0, x1, y1)
        w.x0 = math.min(w.x0 or x0, x0); w.y0 = math.min(w.y0 or y0, y0); w.x1 = math.max(w.x1 or x1, x1); w.y1 = math.max(w.y1 or y1, y1)
      end
      local rec = setmetatable({}, { __index = function() return function() end end })
      rec.elementAttribute = function(_, i, k, v)
        seen[i] = true
        if phase == 1 then seenHot[i] = true end
        local w = W[i]; if not w then w = {}; W[i] = w end
        if k == "frame" and type(v) == "table" then ext(w, v.x, v.y, v.x + v.w, v.y + v.h)
        elseif k == "center" and type(v) == "table" then ext(w, v.x, v.y, v.x, v.y)
        elseif k == "radius" and type(v) == "number" then w.r = math.max(w.r or 0, v)
        elseif k == "coordinates" and type(v) == "table" then for _, p in ipairs(v) do ext(w, p.x, p.y, p.x, p.y) end end
      end
      rec.frame = function() return { x = 0, y = 0, w = 1, h = 1 } end
      if drive then drive(rec, I0)
      else
        local lv = {}; for i = 1, #I0.bars do lv[i] = 0.2 + 0.7 * ((i * 0.37) % 1) end
        local t0 = 500
        for k = 1, 8 do hudVisuals(rec, I0, t0 + k * 0.09, 0.05, true, false, "0:0" .. k, nil, lv) end      -- registra
        phase = 2
        for k = 1, 4 do hudVisuals(rec, I0, t0 + 1 + k * 0.09, 0.05, true, true, "NO MIC", nil, lv) end      -- avviso
        for k = 1, 4 do hudVisuals(rec, I0, t0 + 2 + k * 0.09, 0.05, false, false, "0:00", nil, lv) end     -- riposo
      end
      if I0.badge and seen[I0.badge] and I0.icon0 and I0.icon1 then
        for i = I0.icon0, I0.icon1 do seen[i] = true; if seenHot[I0.badge] then seenHot[i] = true end end   -- l'icona sta SOPRA il badge
      end
      if I0.pin0 and grp then for i = I0.pin0, I0.pin1 do seen[i] = true; seenHot[i] = true end end        -- elementi "fissati in cima" (annulla): sempre in canvas propria
      local classify = grp and grp(I0) or nil
      local G = {}                                   -- chiave -> { ids = {}, x0.. }
      local function grow(g, i, e)
        local a, b, c, d = extent(e)
        if not a then return false end
        local w = W[i]
        if w and w.x0 then
          local r = e.center and math.max(e.radius or 0, w.r or 0) + (e.strokeWidth or 0) * 0.5 + 1.5 or 0
          if e.center then a, b, c, d = math.min(a, w.x0 - r), math.min(b, w.y0 - r), math.max(c, w.x1 + r), math.max(d, w.y1 + r)
          else a, b, c, d = math.min(a, w.x0 - 2), math.min(b, w.y0 - 2), math.max(c, w.x1 + 2), math.max(d, w.y1 + 2) end
        elseif w and w.r and e.center then
          local r = w.r + (e.strokeWidth or 0) * 0.5 + 1.5
          a, b, c, d = math.min(a, e.center.x - r), math.min(b, e.center.y - r), math.max(c, e.center.x + r), math.max(d, e.center.y + r)
        end
        g.x0 = math.min(g.x0 or a, a); g.y0 = math.min(g.y0 or b, b); g.x1 = math.max(g.x1 or c, c); g.y1 = math.max(g.y1 or d, d)
        return true
      end
      local n = 0
      local idxs = {}; for i in pairs(seen) do idxs[#idxs + 1] = i end
      table.sort(idxs)
      for _, i in ipairs(idxs) do
        local e = els0[i]
        local pinned = I0.pin0 and grp and i >= I0.pin0 and i <= I0.pin1
        if e and (pinned or not (e.trackMouseUp or e.trackMouseDown or e.trackMouseEnterExit or e.trackMouseMove or e.id)) and e.type ~= "image" and e.action ~= "clip" then
          local key = "a"
          if classify then key = seenHot[i] and classify(i) or "x" end
          local g = G[key]; if not g then g = { ids = {} }; G[key] = g end
          if grow(g, i, e) then g.ids[#g.ids + 1] = i; n = n + 1 end
        end
      end
      if n == 0 then return nil end
      -- ritaglio ai bordi della base, margine intero (pixel pieni)
      local bx, by, bw, bh = bounds.x, bounds.y, bounds.w, bounds.h
      local orig, groups, order = {}, {}, {}
      for key, g in pairs(G) do
        local x0 = math.max(bx, math.floor(g.x0 - 2)); local y0 = math.max(by, math.floor(g.y0 - 2))
        local x1 = math.min(bx + bw, math.ceil(g.x1 + 2)); local y1 = math.min(by + bh, math.ceil(g.y1 + 2))
        if x1 - x0 >= 4 and y1 - y0 >= 4 then
          local A, route = {}, {}
          for _, i in ipairs(g.ids) do
            local e = els[i + off]
            if e then A[#A + 1] = shiftEl(e, x0, y0); route[i + off] = #A end
          end
          for i in pairs(route) do orig[i] = els[i]; els[i] = ICON.skipEl() end
          if #A > 0 then
            groups[key] = { els = A, route = route, box = { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }, minIdx = (key == "k") and 1e9 or g.ids[1] }     -- "k" (annulla) sempre in cima
            order[#order + 1] = key
          end
        end
      end
      if #order == 0 then return nil end
      if not classify then local g = groups.a; g.orig = orig; return g end
      table.sort(order, function(p, q) return groups[p].minIdx > groups[q].minIdx end)     -- creazione dall'alto: l'indice piu' basso resta sotto
      return { groups = groups, order = order, orig = orig }
    end)
    if not ok then ICON.log("[GW] strati: " .. tostring(spec)); return nil end
    return spec
  end
end

-- opacità dell'HUD a riposo: attenuato quando il mouse non è sopra la card (1 = sempre pieno)
local HUDA = 1
local function hudRestAlpha(dt)
  if animBusy or not overlay then return end
  local rest = clampN(config.idleOpacity == nil and 1 or config.idleOpacity, 0.3, 1)
  if rest >= 0.999 and HUDA >= 0.999 then return end
  local target = 1
  if rest < 0.999 and not micWarned and not dragTap then
    local f = overlay:frame(); local m = hs.mouse.absolutePosition()
    local P = 40 * config.scale
    local over = m.x >= f.x + P and m.x <= f.x + f.w - P and m.y >= f.y + P and m.y <= f.y + f.h - P
    target = over and 1 or rest
  end
  local cur = HUDA + (target - HUDA) * (1 - math.exp(-9 * clampN(dt, 0.001, 0.1)))
  if math.abs(cur - target) < 0.004 then cur = target end
  cur = clampN(cur, 0.3, 1)
  if cur ~= HUDA then overlay:alpha(cur); HUDA = cur end
end

updateUI = function()
  local I = RECIDX
  if not overlay or mode ~= "rec" or not I then return end
  local t = now()
  local dt = clampN(I.last and (t - I.last) or 0.016, 0.001, 0.1)
  I.last = t
  guarded("alpha", function() hudRestAlpha(dt) end)
  local active = ((not paused) and (recording or I.preview)) and true or false
  local warn = (micWarned and recording and not paused) and true or false
  if I.settled and not active then return end
  local mc = ICON.micS
  local lbl = (active and not warn) and ICON.micLabel(t) or nil        -- non nil finche' il mic non manda un livello vero: al posto del timer c'e' la ruota
  local text = warn and "NO MIC" or fmtTime(currentElapsed())
  I.conn = (active and not warn and recording and mc and mc.ph and mc.ph ~= "live") and true or false
  I.wheelOn = (lbl ~= nil) and true or false
  I.wheelSpd = (mc and (mc.ph == "retry" or mc.ph == "fallback")) and 2.0 or 1.1       -- ritentativo / fallback: giro piu' veloce
  I.okFlash = false                                                        -- (nessun cenno verde: la ruota si dissolve nel timer)
  I.el = active and currentElapsed() or 0
  local md = hudVisuals(overlay, I, t, dt, active, warn, text, shakeHUD, I.demo or levels)
  I.settled = (not active) and (md < 0.004)
end

------------------------------------------------------------------------
-- Entrata/uscita HUD: molla in entrata, ease-in in uscita
------------------------------------------------------------------------
showAnimated = function()
  if not overlay or not finalFrame then return end
  local f = finalFrame
  animBusy = true
  overlay:alpha(0); overlay:frame({ x = f.x, y = f.y + 20, w = f.w, h = f.h }); overlay:show(); pinOverlay()
  Anim.run("hud", "vis", 0.36, "spring", function(e, p)
    local ff = finalFrame or f
    overlay:alpha(clamp01(p * 2.4))
    overlay:frame({ x = ff.x, y = ff.y + 20 * (1 - e), w = ff.w, h = ff.h })
  end, function()
    animBusy = false
    HUDA = 1
    if overlay and finalFrame then overlay:alpha(1); overlay:frame(finalFrame); pinOverlay() end
  end)
end

hideAnimated = function()
  if not overlay or not finalFrame then if overlay then overlay:hide() end return end
  animBusy = true
  Anim.cancel("hud", "shake")
  Anim.run("hud", "vis", 0.2, "inq", function(e)
    local ff = finalFrame
    if not ff then return end
    overlay:alpha((1 - e) * HUDA)
    overlay:frame({ x = ff.x, y = ff.y + 12 * e, w = ff.w, h = ff.h })
  end, function()
    animBusy = false
    HUDA = 1
    if overlay then overlay:hide(); overlay:alpha(1); if finalFrame then overlay:frame(finalFrame) end end
  end)
end

showRecordingHUD = function()
  setRecordingElements(false)
  showAnimated()
  if uiTimer then uiTimer:stop() end
  HUDA = 1
  -- tick protetto: un errore non ferma timer/onda/pulsazione (lezione del bug NaN)
  uiTimer = hs.timer.new(1 / 30, function() guarded("updateUI", updateUI) end); uiTimer:start()
end
stopUITimer = function() if uiTimer then uiTimer:stop(); uiTimer = nil end end
function hideOverlay() stopUITimer(); mode = nil; RECIDX = nil; PROC = nil; hideAnimated() end
rebuildHUD = function() if mode == "rec" then setRecordingElements(paused) end end


------------------------------------------------------------------------
-- PANNELLI (impostazioni + storico): stesso linguaggio vetro dell'HUD
------------------------------------------------------------------------
local SPANEL_W = 360
local HPANEL_W = 380
local PSP = 36                 -- margine attorno al pannello (ombra + bordo non tagliati)
local segPrev, togglePrev = {}, {}   -- memoria per le animazioni (pillola che scivola, interruttori)
local settingsPos = nil        -- posizione scelta trascinando (nil = centrato)
-- stato delle impostazioni: finestra a dimensione FISSA, contenuto scorrevole
-- H = altezza TARGET (a misura del tab, tetto = cap); hCur = altezza visibile durante l'animazione
local SET = { scroll = 0, maxScroll = 0, sliders = {}, sbA = 0, W = nil, H = nil, cap = nil, minH = 300, hCur = nil,
  frame = nil, pending = false, ghost = nil, botIdx = nil, pill = {}, tog = {}, trial = false,
  sc = { 0, 0 }, reg = nil, dy = {}, wCur = nil, themeW = 800, cxHome = nil, lastScroll = 0 }
local scrollTap, previewTimer, PREV = nil, nil, nil
local resetArmAt = 0

local function placeholder() return { type = "rectangle", action = "fill", fillColor = CLEAR, frame = { x = 0, y = 0, w = 1, h = 1 } } end
local function shallow(t) local c = {}; for k, v in pairs(t) do c[k] = v end return c end
local function pct(v) return string.format("%d%%", math.floor(finite(v, 0) * 100 + 0.5)) end

-- riempie gli slot riservati in testa (ombra + vetro) una volta nota l'altezza
local function fillShell(els, W, H, dragId, n, lite)
  local head = {}
  pushGlass(head, PSP, PSP, W - 2 * PSP, H - 2 * PSP, R(20), { s = 1, id = dragId, sheenH = 58, sheenA = 0.6, shadowMul = 1.25, lite = lite })
  for i = 1, n or NCARD do els[i] = head[i] or placeholder() end
end
-- quanti elementi occupano ombra + vetro (versione "lite"): alone 4 + ombra 4 + corpo/riflesso/highlight/filo/bordo 5
function SET.shellN() return ((config.glowOn == true) and 4 or 0) + ((config.shadowOn ~= false) and 4 or 0) + 5 end

-- entrata a molla / cambio pagina (alpha + salita) e uscita ease-in
local function panelIn(group, cv, fx, fy, W, H, dy, a0)
  a0 = a0 or 0
  Anim.run(group, "vis", 0.3, "spring", function(e, p)
    cv:alpha(a0 + (1 - a0) * clamp01(p * 2.2))
    cv:frame({ x = fx, y = fy + dy * (1 - e), w = W, h = H })
  end, function() cv:alpha(1); cv:frame({ x = fx, y = fy, w = W, h = H }) end)
end
local function panelOut(cv)
  local f = cv:frame()
  Anim.run("panelout", tostring(cv), 0.16, "inq", function(e)
    cv:alpha(1 - e); cv:frame({ x = f.x, y = f.y + 10 * e, w = f.w, h = f.h })
  end, function() cv:delete() end)
end

-- intestazione comune: badge con icona, titolo, bottone chiudi, filo divisore
local function panelHeader(els, map, pad, IW, y, title, iconFn, closeId)
  els[#els + 1] = { type = "circle", action = "strokeAndFill", fillColor = COL.accentSoft, strokeColor = COL.borderSoft, strokeWidth = 1,
    center = { x = pad + 14, y = y + 15 }, radius = 14,
    fillGradient = "linear", fillGradientAngle = COL.multi and 45 or 90, fillGradientColors = gradFade(COL, 0.30, 0.12) }
  iconFn(els, pad + 14, y + 15, 16, COL.accentInk)
  txt(els, title, pad + 38, y + 5, IW - 38 - 34, 20, 16, COL.fg, { font = "bold" })
  circleButton(els, map, closeId, pad + IW - 12, y + 15, 12, "ghost", function(e, cx, cy) ICON.close(e, cx, cy, 13, COL.fg2, 1.8) end)
  els[#els + 1] = { type = "rectangle", action = "fill", fillColor = COL.divider, frame = { x = pad, y = y + 40, w = IW, h = 1 } }
end

do   -- (blocco: tiene sotto il limite di 200 variabili locali del chunk)
------------------------------------------------------------------------
-- LOOK: valori di default, reset e "Sorprendimi"
------------------------------------------------------------------------
local LOOK_DEFAULTS = config.LOOK.def
local LOOK_ORDER = { "style", "themeMode", "shadowOn", "shadowIntensity", "glassOpacity", "cornerStyle", "animOn", "animSpeed",
  "waveStyle", "waveColor", "micPulse", "glowOn", "uiFont", "timerFont", "density", "idleOpacity" }
local function setLook(key, val) val = config.LOOK.clean(key, val); config[key] = val; persist(key, val) end
local function resetLook()
  for _, k in ipairs(LOOK_ORDER) do setLook(k, LOOK_DEFAULTS[k]) end
  segPrev = {}; togglePrev = {}
  applyTheme(); rebuildHUD()
end
local function randomLook()
  math.randomseed(os.time() + math.floor((hs.timer.secondsSinceEpoch() * 1000) % 100000))
  local function pick(t) return t[math.random(#t)] end
  local function r2(v) return tonumber(string.format("%.2f", v)) end
  local choices = {}
  for _, k in ipairs(FAMILY_ORDER) do if k ~= config.style then choices[#choices + 1] = k end end
  setLook("style", pick(choices))
  setLook("waveStyle", pick({ "bars", "thin", "dots", "line" }))
  setLook("waveColor", math.random() < 0.65 and "gradient" or "accent")
  setLook("cornerStyle", pick({ "round", "round", "medium", "square" }))
  setLook("glowOn", math.random() < 0.4)
  setLook("micPulse", r2(0.25 + math.random() * 0.6))
  setLook("glassOpacity", r2(0.78 + math.random() * 0.22))
  setLook("timerFont", pick({ "mono", "sf", "rounded" }))
  setLook("uiFont", pick({ "sf", "sf", "rounded" }))
  applyTheme(); rebuildHUD()
end

-- slider del tab Tema: key in config, intervallo, default (se la chiave non c'è)
local SLIDER_DEFS = {
  shadow = { key = "shadowIntensity", lo = 0,   hi = 1, def = 0.5,  rebuild = true },
  glass  = { key = "glassOpacity",    lo = 0.5, hi = 1, def = 0.95, rebuild = true, live = function() applyTheme() end },
  pulse  = { key = "micPulse",        lo = 0,   hi = 1, def = 0.5 },
  idle   = { key = "idleOpacity",     lo = 0.3, hi = 1, def = 1 },
}
local function sliderValue(def)
  local v = config[def.key]
  if type(v) ~= "number" or v < def.lo - 1e-6 then v = def.def end    -- glassOpacity 0 = "default del tema"
  return clampN(v, def.lo, def.hi)
end

------------------------------------------------------------------------
-- IMPOSTAZIONI  (3 tab: Generale · Tasti · Tema). Finestra a dimensione fissa, ancorata in
-- alto a sinistra; il contenuto che eccede scorre con rotella/trackpad (clip + scrollbar).
------------------------------------------------------------------------
-- larghezza (canvas, ombra inclusa) e altezza massima per pagina: Tema si allarga (simmetrico), tetto = schermo-48
local function widthFor(page)
  local sf = hs.screen.mainScreen():frame()
  local base = SPANEL_W + 2 * PSP
  if page == "theme" then return math.max(base, math.min(SET.themeW, sf.w - 48)) end
  return base
end
local function capFor(page)
  local sf = hs.screen.mainScreen():frame()
  if page == "theme" then return math.max(480, math.min(760, sf.h - 24)) end
  return math.max(420, math.min(680, sf.h - 24))
end
local function settingsGeometry() return widthFor(settingsPage), capFor(settingsPage) end

local function killGhost()
  local G = SET.ghost; SET.ghost = nil
  if G and G.cv then pcall(function() G.cv:delete() end) end
end
local function stopPreview() if previewTimer then previewTimer:stop(); previewTimer = nil end; PREV = nil end
local function stopScrollTap() if scrollTap then scrollTap:stop(); scrollTap = nil end end

closeSettings = function()
  local cv = settingsCanvas
  if not cv then return end
  settingsCanvas = nil; settingsPos = nil
  stopPreview(); stopScrollTap(); killGhost(); SET.hvKill()
  SET.K.msg = nil; SET.K.armAt = 0; SET.K.tipReset(); SET.K.exp = false; SET.K.q = 0; Anim.cancel("setvis", "kx")
  SET.frame = nil; SET.W = nil; SET.H = nil; SET.cap = nil; SET.hCur = nil; SET.wCur = nil; SET.sc = { 0, 0 }; SET.reg = nil; SET.dy = {}
  SET.pill = {}; SET.tog = {}; SET.cxHome = nil; SET.shellLast = nil; SET.hero = nil
  Anim.cancel("sethv"); Anim.cancel("setui"); Anim.cancel("setvis"); Anim.cancel("setsb")
  panelOut(cv)
end

-- scrollbar sottile: compare mentre si scorre, poi svanisce (una per regione)
local function pokeScrollbar(changed)
  local any = false
  SET.sbReg = SET.sbReg or {}
  for _, r in ipairs(changed or {}) do SET.sbReg[r.i] = true end        -- si dissolve solo la scrollbar della colonna che scorre
  for _, r in pairs(SET.reg or {}) do if r.sbIdx then any = true end end
  if not any then return end
  Anim.run("setsb", "fade", 1.5, "linear", function(t)
    local a = (t < 0.55) and 1 or (1 - (t - 0.55) / 0.45)
    SET.sbA = clampN(a, 0, 1) * 0.36
    local cv = settingsCanvas; if not cv then return end
    for _, r in pairs(SET.reg or {}) do
      if r.sbIdx and (not SET.sbReg or SET.sbReg[r.i]) then cv:elementAttribute(r.sbIdx, "fillColor", withA(COL.fg, SET.sbA)) end
    end
  end, function()
    SET.sbA = 0
    local cv = settingsCanvas
    for _, r in pairs(SET.reg or {}) do
      if cv and r.sbIdx and SET.sbReg and not SET.sbReg[r.i] then cv:elementAttribute(r.sbIdx, "fillColor", withA(COL.fg, 0)) end
    end
    SET.sbReg = nil
  end, true)
end

-- animazioni che scrivono posizioni ASSOLUTE dentro le regioni (non compatibili con lo scroll per spostamento)
local function tweensBusy()
  for k, a in pairs(Anim.list) do
    if (a.group == "setui" and k ~= "setui|pill:tab") or k == "setvis|kx" then return true end
  end
  return false
end

-- sposta gli elementi di una regione al nuovo scroll: niente replaceElements, solo gli elementi in vista (+60px)
local function regionShift(cv, r)
  local d = r.scroll - r.base
  SET.dy[r.i] = d
  r.hot = nil                                          -- il contenuto si e' mosso sotto il mouse: l'hover riparte al prossimo movimento
  local lo, hi = r.top - 60, r.bot + 60
  local rast = cv:layerRasterScroll("r" .. r.i, r.scroll)      -- colonna raster: basta spostare l'immagine (1 attributo)
  for _, rec in ipairs(rast and {} or r.shift) do
    if rec[4] ~= d then
      local k, kind, g = rec[1], rec[2], rec[3]
      local y1, y2
      if kind == "frame" then y1, y2 = g.y - d, g.y + g.h - d
      elseif kind == "center" then y1, y2 = g.y - d - 20, g.y - d + 20
      else y1 = (g[1] and g[1].y or 0) - d - 30; y2 = y1 + 60 end
      if y2 >= lo and y1 <= hi then
        rec[4] = d
        if kind == "frame" then cv:elementAttribute(k, "frame", { x = g.x, y = g.y - d, w = g.w, h = g.h })
        elseif kind == "center" then cv:elementAttribute(k, "center", { x = g.x, y = g.y - d })
        else
          local pts = {}
          for i, pt in ipairs(g) do pts[i] = { x = pt.x, y = pt.y - d } end
          cv:elementAttribute(k, "coordinates", pts)
        end
      end
    end
  end
  if r.sbIdx and r.max > 0 then
    local barY = r.contentTop + 4 + (r.trackH - r.barH) * clampN(r.scroll / r.max, 0, 1)
    cv:elementAttribute(r.sbIdx, "frame", { x = r.cx1 - 5, y = barY, w = 3, h = r.barH })
  end
end

function SET.applyScroll()
  local cv = settingsCanvas
  if not cv or not SET.reg then return end
  SET.hvHide()
  local need, changed, busyOk = false, {}, true
  for _, r in pairs(SET.reg) do
    if r.scroll ~= r.shown then
      changed[#changed + 1] = r
      if math.abs(r.scroll - r.base) > r.margin - 12 then need = true end     -- uscito dalla fascia costruita: ricostruisci
      if not cv:layerIsRaster("r" .. r.i) then busyOk = false end
    end
  end
  if #changed == 0 then return end
  if need or (tweensBusy() and not busyOk) then renderSettings({ scroll = true }); return end   -- colonne raster: nessun conflitto con le animazioni
  local anySc = false
  for _, r in ipairs(changed) do regionShift(cv, r); r.shown = r.scroll end
  for _, r in pairs(SET.reg) do if r.scroll > 0.5 then anySc = true end end
  if SET.divIdx then cv:elementAttribute(SET.divIdx, "fillColor", anySc and COL.divider or withA(COL.divider, 0)) end
  pokeScrollbar(changed)
end

local function scrollBy(d, i)
  local r = SET.reg and SET.reg[i]
  if not settingsCanvas or not r or r.max <= 0 then return end
  local ns = clampN(r.scroll + finite(d, 0), 0, r.max)
  if ns == r.scroll then return end
  r.scroll = ns; SET.sc[i] = ns
  SET.lastScroll = now()
  if not SET.pending then            -- coalescing: ~30 aggiornamenti/s al massimo, qualunque sia la frequenza degli eventi
    SET.pending = true
    hs.timer.doAfter(0.033, function()
      SET.pending = false
      if settingsCanvas then
        local ok, err = pcall(SET.applyScroll)
        if not ok then ICON.log("[GW] scroll: " .. tostring(err)) end
      end
    end)
  end
end

-- macOS disabilita un event tap se il callback tarda (UI che laggava) e Hammerspoon non lo riaccende da solo: la rotella smetteva di
-- funzionare "a caso". Controllo di salute: tap spento -> start() (chiamato ogni secondo dal guard e a ogni apertura/render).
function SET.tapAlive(t)
  if not t then return false end
  local ok, en = pcall(function() return t:isEnabled() end)
  if ok and en == false then pcall(function() t:start() end); return true end
  return false
end
local function startScrollTap()
  if scrollTap then SET.tapAlive(scrollTap); return end
  local ev = hs.eventtap.event
  scrollTap = hs.eventtap.new({ ev.types.scrollWheel }, function(e)
    local cv = settingsCanvas
    if not cv then return false end
    local f = cv:frame(); local m = hs.mouse.absolutePosition()
    if m.x < f.x + PSP or m.x > f.x + f.w - PSP or m.y < f.y + PSP or m.y > f.y + f.h - PSP then return false end
    local dy = e:getProperty(ev.properties.scrollWheelEventPointDeltaAxis1)
    if not dy or dy == 0 then dy = (e:getProperty(ev.properties.scrollWheelEventDeltaAxis1) or 0) * 8 end
    -- regione sotto il mouse (colonna); fuori da ogni colonna: la più vicina
    local rx, pick, best = m.x - f.x, 1, 1e9
    for i, r in pairs(SET.reg or {}) do
      local dist = (rx < r.cx0) and (r.cx0 - rx) or ((rx > r.cx1) and (rx - r.cx1) or 0)
      if dist < best then best = dist; pick = i end
    end
    scrollBy(-finite(dy, 0), pick)
    return true
  end)
  scrollTap:start()
end

local function startSlider(id)
  local sl, def = SET.sliders[id], SLIDER_DEFS[id]
  if not sl or not def or not settingsCanvas or not sl.tw or sl.tw <= 0 then return end
  if dragTap then dragTap:stop(); dragTap = nil end
  local lastT = 0
  local function apply(commit)
    local cv = settingsCanvas; if not cv then return end
    local tn = now()
    if not commit and tn - lastT < 0.016 then return end          -- max ~60 aggiornamenti/s mentre si trascina
    lastT = tn
    local f = cv:frame()
    local rel = clampN((hs.mouse.absolutePosition().x - f.x - sl.tx) / sl.tw, 0, 1)
    local sty = sl.ty - (SET.rastOn and 0 or (SET.dy[sl.reg or 1] or 0))   -- raster: coordinate di contenuto (scroll = immagine)
    local v = tonumber(string.format("%.2f", def.lo + rel * (def.hi - def.lo)))
    config[def.key] = v
    cv:elementAttribute(sl.knob, "center", { x = sl.tx + rel * sl.tw, y = sty })
    cv:elementAttribute(sl.fill, "frame", { x = sl.tx, y = sty - 2.5, w = math.max(0.1, rel * sl.tw), h = 5 })
    cv:elementAttribute(sl.val, "text", pct(v))
    if def.live then def.live() end
    if commit then
      persist(def.key, v)
      if def.rebuild then rebuildHUD(); renderSettings() end
    end
  end
  dragTap = hs.eventtap.new({ hs.eventtap.event.types.leftMouseDragged, hs.eventtap.event.types.leftMouseUp }, function(e)
    local ok = pcall(function()
      if e:getType() == hs.eventtap.event.types.leftMouseUp then dragTap:stop(); dragTap = nil; apply(true) else apply(false) end
    end)
    return false
  end)
  apply(false)
  dragTap:start()
end

settingsMouse = function(_c, msg, id)
  if msg == "mouseEnter" then
    SET.hover(id, true)
    if id == "key_info" then SET.K.tipHover = true; SET.K.tipFade() end
    local sk = tostring(id):match("^style:(.+)$")
    if sk then SET.heroSet(sk) end
    return
  elseif msg == "mouseExit" then
    SET.hover(id, false)
    if id == "key_info" then SET.K.tipHover = false; SET.K.tipFade() end
    if tostring(id):match("^style:") then SET.heroSet(nil) end
    return
  elseif msg == "mouseDown" then
    if id == "s_drag" then
      SET.hvHide()
      dragCanvas(settingsCanvas, false, function(f) settingsPos = { x = f.x, y = f.y }; SET.frame = { x = f.x, y = f.y, w = f.w, h = f.h }; SET.cxHome = nil end)
    else
      local sid = tostring(id):match("^sl_(.+)$")
      if sid then startSlider(sid) end
    end
    return
  elseif msg ~= "mouseUp" then return end
  if not settingsCanvas then return end
  if id == "pv_badge" then if PREV then ICON.eggClick(settingsCanvas, PREV.I) end return end      -- easter egg: 5 clic sul badge dell'anteprima

  if id == "s_close" then closeSettings(); return end
  if id == "key_paste" then SET.K.paste(); return end
  if id == "key_open" then SET.K.open(); return end
  if id == "key_remove" then SET.K.remove(); return end
  if id == "key_info" then SET.K.tipPin = not SET.K.tipPin; SET.K.tipFade(); return end
  if id == "key_toggle" then
    SET.K.exp = not SET.K.exp; SET.K.tipReset(); SET.K.armAt = 0
    renderSettings({ keyToggle = true }); return
  end
  if id == "tg_shadow" then setLook("shadowOn", not (config.shadowOn ~= false)); rebuildHUD(); renderSettings(); return end
  if id == "tg_glow" then setLook("glowOn", not (config.glowOn == true)); rebuildHUD(); renderSettings(); return end
  if id == "tg_anim" then setLook("animOn", not animOn()); renderSettings(); return end
  if id == "btn_random" then randomLook(); resetArmAt = 0; renderSettings(); return end
  if id == "btn_reset" then
    if resetArmAt > 0 and (now() - resetArmAt) < 3 then
      resetArmAt = 0; resetLook()
    else
      resetArmAt = now()
      hs.timer.doAfter(3.1, function()
        if resetArmAt > 0 and (now() - resetArmAt) >= 3 then resetArmAt = 0; if settingsCanvas then pcall(renderSettings) end end
      end)
    end
    renderSettings(); return
  end
  local kind, val = tostring(id):match("^(%a+):(.+)$")
  if not kind then return end
  local pageChange = false
  if kind == "tab" then
    if settingsPage ~= val then settingsPage = val; SET.sc = { 0, 0 }; pageChange = true; SET.K.tipReset() end
  elseif kind == "mic" then
    local d = settingsDevices[tonumber(val)]
    if d then config.audioDevice = d.idx; config.micName = d.name; persist("micDevice", d.idx); persist("micName", d.name) end
  elseif kind == "size" then config.sizePreset = val; config.scale = scaleFor(val); persist("sizePreset", val); rebuildHUD()
  elseif kind == "orient" then config.orientation = val; persist("orientation", val); resetLevels(); rebuildHUD()
  elseif kind == "cat" then SET.cat = val; SET.sc[1] = 0
  elseif kind == "style" then setLook("style", val); applyTheme(); rebuildHUD(); SET.pvBoost = now() + 1.2
  elseif kind == "theme" then setLook("themeMode", val); applyTheme(); rebuildHUD(); SET.pvBoost = now() + 1.2
  elseif kind == "corner" then setLook("cornerStyle", val); rebuildHUD()
  elseif kind == "wave" then setLook("waveStyle", val); rebuildHUD()
  elseif kind == "wcol" then setLook("waveColor", val); rebuildHUD()
  elseif kind == "aspeed" then setLook("animSpeed", val)
  elseif kind == "uifont" then setLook("uiFont", val); rebuildHUD()
  elseif kind == "tfont" then setLook("timerFont", val); rebuildHUD()
  elseif kind == "dens" then setLook("density", val); rebuildHUD()
  elseif kind == "gest" then
    local which, i, g = val:match("(%a+):(%d+):(%a+)"); i = tonumber(i)
    local list = (which == "ss") and config.ssBindings or config.pauseBindings
    if list and list[i] then list[i].gesture = g; saveBindings() end
  elseif kind == "add" then startCapture(val); return
  elseif kind == "del" then
    local which, i = val:match("(%a+):(%d+)"); i = tonumber(i)
    local list = (which == "ss") and config.ssBindings or config.pauseBindings
    if list and list[i] then table.remove(list, i); saveBindings() end
  end
  renderSettings({ page = pageChange })
end

-- anteprima viva: anima SOLO se il mouse e' sopra l'anteprima (o per ~1,2 s dopo un cambio di stile/tema), a ~10 agg/s, senza particelle;
-- altrimenti resta un fotogramma fermo (CPU ~0). Mai insieme a scroll, ridimensionamento, dissolvenza o aggiornamento dell'hero.
local function previewTick()
  local cv, P = settingsCanvas, PREV
  if not cv or not P or settingsPage ~= "theme" then return end
  local t = now()
  if t - (SET.lastScroll or 0) < 0.25 then return end
  if SET.heroAt and t - SET.heroAt < 0.2 then return end
  local boost = SET.pvBoost and t < SET.pvBoost
  if not boost then
    local m = hs.mouse.absolutePosition()
    local f = cv:frame()
    local mx, my = m.x - f.x, m.y - f.y
    if mx < (P.x0 or 0) or mx > (P.x1 or 0) or my < (P.top or 0) or my > (P.bot or 0) then return end
  end
  if Anim.list["setvis|h"] or Anim.list["setvis|xfade"] or Anim.list["setvis|vis"] then return end
  local I = P.I
  local dt = clampN(I.last and (t - I.last) or 0.08, 0.001, 0.12)
  I.last = t
  if I.body and P.bgA ~= COL.bg.alpha then       -- trasparenza del vetro cambiata (slider in corso)
    P.bgA = COL.bg.alpha
    cv:elementAttribute(I.body, "fillGradientColors", { COL.bg, COL.bg2 })
  end
  local demo = {}
  local env = 0.55 + 0.45 * math.sin(finite(t * 0.9, 0))
  for i = 1, #I.bars do
    demo[i] = clampN(0.12 + 0.85 * math.abs(math.sin(finite(t * 2.3 + i * 0.7, 0))) * env, 0, 1)
  end
  hudVisuals(cv, I, t, dt, true, false, fmtTime(12 + (t - P.t0)), nil, demo)
end
local function startPreview()
  if previewTimer then return end
  previewTimer = hs.timer.doEvery(1 / 10, function() guarded("preview", previewTick) end)
end

-- hero degli stili: mostra lo stile sotto il mouse (o quello attuale); aggiornamento a pochi attributi
function SET.heroSet(key)
  SET.heroWant = key
  if SET.heroPending then return end
  SET.heroPending = true
  hs.timer.doAfter(0.04, function()
    SET.heroPending = false
    SET.heroAt = now()
    local cv, Hh = settingsCanvas, SET.hero
    if not cv or not Hh then return end
    local want = SET.heroWant
    local k2 = want or config.style
    local F = FAMILIES[k2]
    if not F or (Hh.shown == k2 and Hh.hover == (want ~= nil)) then return end
    local T = F[Hh.mode]
    Hh.shown = k2; Hh.hover = (want ~= nil)
    local catNm = ""
    for _, c in ipairs(FAMILY_ORDER.cats) do if c[1] == F.cat then catNm = c[2] end end
    cv:elementAttribute(Hh.bg, "fillColor", T.accent)
    cv:elementAttribute(Hh.bg, "fillGradientColors", T.grad)
    cv:elementAttribute(Hh.name, "text", F.name)
    cv:elementAttribute(Hh.name, "textColor", T.accentText)
    cv:elementAttribute(Hh.sub, "text", ((want ~= nil) and "Anteprima · clicca per usarlo · " or "Stile attuale · ") .. catNm)
    cv:elementAttribute(Hh.sub, "textColor", withA(T.accentText, 0.82))
  end)
end

------------------------------------------------------------------------
-- CHIAVE GROQ (tab Generale). Mai in console/log/alert/history: l'unica copia è il file keyPath (permessi 600).
-- Flusso: incolla dal clipboard -> controllo formato -> prova a costo zero (GET /openai/v1/models) ->
-- salva SOLO se Groq risponde 200. readKey() rilegge il file ogni volta: nessun riavvio.
------------------------------------------------------------------------
local K = { has = false, mask = nil, msg = nil, msgId = 0, armAt = 0, busy = false, tipA = 0, tipPin = false, tipHover = false, tipEls = {},
  exp = false, q = 0, flip = false }
SET.K = K
local KEY_STEPS = { "1) Premi «Prendi / crea la chiave»: si apre il sito Groq.",
  "2) Registrati (è gratis: bastano Google o email, nessuna carta).",
  "3) Premi «Create API Key», dai un nome qualsiasi e conferma.",
  "4) Copia la chiave (inizia con gsk_).",
  "5) Torna qui e premi «Incolla chiave»." }
function K.refresh()
  local k = readKey()
  if k then
    K.has = true
    K.mask = (#k >= 12) and (k:sub(1, 4) .. "…" .. k:sub(-4)) or "chiave salvata"
  else K.has = false; K.mask = nil end
  k = nil
end
function K.setMsg(kind, text)
  K.msgId = K.msgId + 1
  local id = K.msgId
  K.msg = { kind = kind, text = text }
  if kind ~= "busy" then
    hs.timer.doAfter(9, function()
      if K.msgId == id and K.msg and settingsCanvas then K.msg = nil; pcall(renderSettings, { scroll = true }) end
    end)
  end
  if settingsCanvas then
    local flip = K.flip; K.flip = false
    pcall(renderSettings, flip and { page = true } or { scroll = true })     -- flip: la sezione cambia posto (alto <-> in fondo)
  end
end
function K.paste()
  if K.busy then return end
  local raw = hs.pasteboard.getContents()
  local clip = trim(type(raw) == "string" and raw or "")
  raw = nil
  if clip == "" then K.setMsg("err", "Negli appunti non c'è niente da incollare"); return end
  if not (clip:match("^gsk_[%w_%-]+$") and #clip >= 30 and #clip <= 120) then
    K.setMsg("err", "Non è una chiave Groq (inizia con gsk_)"); return
  end
  K.busy = true
  K.setMsg("busy", "Controllo la chiave con Groq…")
  local key = clip
  local function done(kind, text) K.busy = false; key = nil; K.setMsg(kind, text) end
  local t = hs.task.new(config.curl, function(code, out)
    local st = tonumber(trim(out or "")) or 0
    if code ~= 0 or st == 0 then done("err", "Nessuna rete: riprova tra poco"); return end
    if st == 200 then
      local dir = config.keyPath:match("^(.*)/[^/]+$") or "."
      hs.execute("umask 077; mkdir -p '" .. dir .. "'; : > '" .. config.keyPath .. "'")
      local f = io.open(config.keyPath, "w")
      local okw = false
      if f then okw = f:write(key) and true or false; f:close() end
      hs.execute("chmod 600 '" .. config.keyPath .. "'")
      if okw and readKey() == key then K.refresh(); K.exp = false; K.q = 0; K.flip = true; done("ok", "Chiave valida: salvata")
      else done("err", "Non riesco a salvare la chiave") end
    elseif st == 401 then done("err", "Chiave non valida: Groq l'ha rifiutata")
    elseif st == 403 then done("err", "Groq ha rifiutato la richiesta (403): riprova")
    else done("err", "Groq non risponde (codice " .. tostring(st) .. "): riprova") end
  end, { "-s", "-S", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "12",
         "-H", "Authorization: Bearer " .. key, "https://api.groq.com/openai/v1/models" })
  if not (t and t:start()) then done("err", "Nessuna rete: riprova tra poco") end
end
function K.remove()
  if K.armAt > 0 and (now() - K.armAt) < 3 then
    K.armAt = 0
    os.remove(config.keyPath)
    K.refresh(); K.exp = false; K.q = 0; K.flip = true; K.setMsg("info", "Chiave rimossa")
  else
    K.armAt = now()
    hs.timer.doAfter(3.1, function()
      if K.armAt > 0 and (now() - K.armAt) >= 3 then K.armAt = 0; if settingsCanvas then pcall(renderSettings, { scroll = true }) end end
    end)
    if settingsCanvas then pcall(renderSettings, { scroll = true }) end
  end
end
function K.open()
  local ok = pcall(hs.urlevent.openURL, "https://console.groq.com/keys")
  if not ok then hs.execute("open 'https://console.groq.com/keys'") end
  K.setMsg("info", "Ho aperto il sito di Groq nel browser")
end
-- popover (i): elementi già nel canvas, a trasparenza animata (nessun ridisegno al passaggio del mouse)
function K.tipApply()
  local cv = settingsCanvas; if not cv then return end
  for _, e in ipairs(K.tipEls) do cv:elementAttribute(e[1], e[2], withA(e[3], (e[3].alpha or 1) * K.tipA)) end
end
function K.tipFade()
  local target = (K.tipPin or K.tipHover) and 1 or 0
  local from = K.tipA
  if from == target then return end
  Anim.run("settip", "fade", 0.16, "out", function(e) K.tipA = clamp01(lerp(from, target, e)); K.tipApply() end)
end
function K.tipReset() K.tipPin = false; K.tipHover = false; K.tipA = 0; Anim.cancel("settip") end

-- sezione chiave RIDUCIBILE (chiave già impostata): scheda che si apre/chiude, corpo a dissolvenza
function K.fade(q) return clamp01((q - 0.5) / 0.5) end
function K.chev(cx, cy, q)
  local d = 3 * (1 - 2 * clamp01(q))
  return { { x = cx - 5, y = cy - d }, { x = cx, y = cy + d }, { x = cx + 5, y = cy - d } }
end
function K.apply(cv, a, q)
  cv:elementAttribute(a.box, "frame", { x = a.x, y = a.y, w = a.w, h = 44 + a.bodyH * q })
  cv:elementAttribute(a.chevIdx, "coordinates", K.chev(a.cx, a.cy, q))
  local f = K.fade(q)
  for _, r in ipairs(a.body) do
    local base = r[3]
    if r[2] == "fillGradientColors" then
      local list = {}
      for i, c in ipairs(base) do list[i] = withA(c, (c.alpha or 1) * f) end
      cv:elementAttribute(r[1], r[2], list)
    else
      cv:elementAttribute(r[1], r[2], withA(base, (base.alpha or 1) * f))
    end
  end
end
function K.anim(a)
  Anim.run("setvis", "kx", 0.28, "out", function(e)
    local cv = settingsCanvas; if not cv then return end
    local q = lerp(a.from, a.to, clamp01(e)); K.q = q
    K.apply(cv, a, q)
  end, function()
    K.q = a.to
    local cv = settingsCanvas; if cv then K.apply(cv, a, a.to) end
    if a.to == 0 and cv and not K.exp then pcall(renderSettings, { scroll = true }) end     -- chiusa: toglie il corpo (e i suoi bottoni) dal canvas
  end)
end

-- costruisce tutti gli elementi per un dato offset di scroll. Ritorna (els, info)
local function layoutSettings()
  local W, H = SET.W, SET.H
  local pad0 = PSP + 20
  local pad = pad0
  local IW0 = W - 2 * pad0
  local IW = IW0
  local top = PSP + 20
  local tabsY = top + 56
  local bodyTop = tabsY + 36 + 16
  local clipTop = tabsY + 36 + 8
  local clipBot = H - PSP - 8
  SET.clipTop, SET.clipBot = clipTop, clipBot
  local GAP = 18 * gapK()
  local trial = SET.trial                 -- prova a secco (targetHeight): niente elementi per le sezioni, niente effetti
  local els = {}
  sHoverMap = {}
  SET.sliders = {}; SET.keyTip = nil; SET.kAnim = nil; SET.hero = nil
  PREV = nil; SET.pvSpec = nil
  SET.reg = {}; SET.dy = {}
  local regs = SET.reg
  local nShell = SET.shellN()
  SET.nShell = nShell
  for i = 1, nShell do els[i] = placeholder() end     -- slot per ombra + vetro (riempiti a fine layout)
  local function add(el) els[#els + 1] = el; return #els end
  local y = 0
  -- SCROLL A IMMAGINE (SET.RASTER): le regioni scorrevoli costruiscono TUTTO il contenuto a scroll 0 (coordinate di contenuto);
  -- buildLayers lo rasterizza una volta e lo scroll sposta solo l'immagine. Senza raster: fascia visibile + MARGIN, scroll baked.
  local RAST = (SET.RASTER ~= false) and ICON.layersOn()
  SET.rastOn = RAST
  local MARGIN = RAST and 1e6 or 140                   -- elementi creati oltre il bordo visibile
  local R0                                             -- regione di scroll aperta

  -- REGIONI DI SCROLL: ogni regione ha un ritaglio, un proprio scroll (SET.sc[i]) e crea solo gli elementi
  -- visibili + MARGIN. Lo scroll "normale" sposta gli elementi esistenti (elementAttribute), senza ridisegnare.
  local function openRegion(i, cx0, cx1, ctop, cbot, contentTop)
    local sc = SET.sc[i] or 0
    local r = { i = i, cx0 = cx0, cx1 = cx1, top = ctop, bot = cbot, contentTop = contentTop, scroll = sc, base = RAST and 0 or sc, shown = sc,
      visLo = ctop - MARGIN, visHi = cbot + MARGIN, margin = MARGIN }
    r.clipIdx = add({ type = "rectangle", action = "clip", frame = { x = cx0, y = ctop, w = cx1 - cx0, h = math.max(1, cbot - ctop) } })
    r.i0 = #els + 1
    regs[i] = r; R0 = r
    y = contentTop - r.base
  end
  local function closeRegion(trail)
    local r = R0
    r.i1 = #els
    add({ type = "resetClip" })
    r.len = math.max(0, (y - trail) - (r.contentTop - r.base)) + 16     -- altezza reale del contenuto (r.base = parte di scroll gia' "cotta" nelle coordinate: 0 nelle colonne raster)
    r.view = r.bot - r.contentTop
    r.max = math.max(0, r.len - r.view)
    if RAST then
      r.scroll = clampN(r.scroll, 0, r.max); r.shown = r.scroll; SET.sc[r.i] = r.scroll
      SET.dy[r.i] = r.scroll - r.base                  -- spostamento a schermo (hover, hit-test)
    end
    local sh = {}
    for k = r.i0, r.i1 do
      local el = els[k]
      if el.frame then sh[#sh + 1] = { k, "frame", el.frame }
      elseif el.center then sh[#sh + 1] = { k, "center", el.center }
      elseif el.coordinates then sh[#sh + 1] = { k, "coordinates", el.coordinates } end
    end
    r.shift = sh
    R0 = nil
  end
  -- sezione di altezza nota h: costruita solo se interseca la fascia visibile (+margine)
  local function S(h, fn)
    local y0 = y
    if not trial and R0 and (y0 + h >= R0.visLo) and (y0 <= R0.visHi) then fn() end
    y = y0 + h
  end

  local function box(x, by, w, h)
    add({ type = "rectangle", action = "strokeAndFill", fillColor = COL.rowBg, strokeColor = COL.divider, strokeWidth = 1,
      roundedRectRadii = { xRadius = R(12), yRadius = R(12) }, frame = { x = x, y = by, w = w, h = h } })
  end
  local function sec(title)
    txt(els, title, pad + 2, y, IW, 14, 10.5, COL.fg3, { font = "bold" })
    y = y + 20
  end

  -- controllo segmentato con pillola che scivola. o: x,y,w,h,size,inset
  local function segmented(prefix, options, current, o)
    local x0, y0, w, h = o.x or pad, o.y, o.w or IW, o.h or 32
    local inset, size = o.inset or 3, o.size or 12
    local n = #options
    local ow = (w - 2 * inset) / n
    local ph = h - 2 * inset
    local function pillX(i) return x0 + inset + (i - 1) * ow end
    local sel = 1
    for i, opt in ipairs(options) do if opt.val == current then sel = i end end
    add({ type = "rectangle", action = "fill", fillColor = COL.track, roundedRectRadii = { xRadius = R(h / 2 - 3), yRadius = R(h / 2 - 3) },
      frame = { x = x0, y = y0, w = w, h = h } })
    local pillIdx = add({ type = "rectangle", action = "fill", fillColor = COL.accent, roundedRectRadii = { xRadius = R(ph / 2 - 2), yRadius = R(ph / 2 - 2) },
      frame = { x = pillX(sel), y = y0 + inset, w = ow, h = ph },
      fillGradient = "linear", fillGradientAngle = COL.multi and 0 or 90, fillGradientColors = COL.grad })
    -- posizione VISIBILE della pillola (frazionaria, 1..n): ogni render riparte da lì, mai dal punto "finale"
    -- del click precedente → click ravvicinati = movimento continuo, zero scatti
    local st = SET.pill
    local cur = (not SET.trial) and st[prefix] or nil
    local pos0, doAnim = sel, false
    if cur and cur.n == n and math.abs(cur.pos - sel) > 0.004 and animOn() then pos0 = cur.pos; doAnim = true end
    local selCol, unCol = COL.accentText, COL.fg2
    local function onness(pos, i) return clamp01(1 - math.abs(pos - i)) end
    local function pxAt(p) return x0 + inset + (p - 1) * ow end
    els[pillIdx].frame.x = pxAt(pos0)
    local labels, icons = {}, {}
    for i, opt in ipairs(options) do
      local ox = pillX(i)
      local on = (i == sel)
      local col = lerpC(unCol, selCol, onness(pos0, i))
      hitRect(els, sHoverMap, prefix .. ":" .. opt.val, ox, y0 + inset, ow, ph, R(ph / 2 - 2),
        { fill = withA(COL.rowHover, 0), hoverFill = on and withA(COL.rowHover, 0) or COL.rowHover })
      local tx, tw = ox, ow
      if opt.icon then
        local from = #els + 1
        opt.icon(els, ox + 15, y0 + h / 2, 15, col)
        icons[i] = { from, #els }
        tx, tw = ox + 20, ow - 20
      end
      labels[i] = txt(els, opt.label, tx, y0 + (h - size * 1.25) / 2, tw, size * 1.4, size, col,
        { font = "semi", align = "center", lb = "clip" })
    end
    segPrev[prefix] = sel
    if not SET.trial then
      st[prefix] = { pos = sel, n = n }
      if doAnim then
        -- molla critica con velocità persistente: ogni nuovo click continua dal punto e dalla velocità correnti
        local rec = st[prefix]; rec.pos = pos0; rec.v = cur.v or 0
        local key = "pill:" .. prefix
        local tl = nowT()
        local function paint(p)
          local cv = settingsCanvas; if not cv then return end
          cv:elementAttribute(pillIdx, "frame", { x = pxAt(p), y = y0 + inset, w = ow, h = ph })
          for i = 1, n do
            local o1 = onness(p, i)
            if rec.last == nil or o1 ~= onness(rec.last, i) then
              local c2 = lerpC(unCol, selCol, o1)
              cv:elementAttribute(labels[i], "textColor", c2)
              local r = icons[i]
              if r then
                for k = r[1], r[2] do
                  if els[k].strokeColor then cv:elementAttribute(k, "strokeColor", c2) end
                  if els[k].fillColor then cv:elementAttribute(k, "fillColor", c2) end
                end
              end
            end
          end
          rec.last = p
        end
        Anim.run("setui", key, 1.5, "linear", function()
          local t = nowT()
          local dt = clampN(t - tl, 0.001, 0.05); tl = t
          local w = 24 / (SPEED_MUL[config.animSpeed] or 1)
          local x, v = rec.pos - sel, rec.v or 0
          local ex = math.exp(-w * dt)
          local nx = (x + (v + w * x) * dt) * ex
          local nv = (v - (v + w * x) * w * dt) * ex
          rec.pos, rec.v = finite(sel + nx, sel), finite(nv, 0)
          if math.abs(nx) < 0.004 and math.abs(nv) < 0.03 then
            rec.pos, rec.v = sel, 0
            paint(sel)
            Anim.cancel("setui", key)
          else
            paint(rec.pos)
          end
        end, nil, true)
      end
    end
  end

  -- interruttore animato dentro una riga alta 40 che parte da ry
  local function switchRow(id, label, on, ry, dim)
    hitRect(els, sHoverMap, id, pad + 4, ry + 2, IW - 8, 40, R(9), { fill = withA(COL.rowHover, 0), hoverFill = COL.rowHover })
    txt(els, label, pad + 16, ry + 13, IW - 90, 18, 13, COL.fg, { font = "semi" })
    local tw, th = 42, 24
    local tx0, ty0 = pad + IW - 16 - tw, ry + 10
    -- progresso VISIBILE 0..1 dell'interruttore: ogni render riparte da lì (click ravvicinati = nessuno scatto)
    local target = on and 1 or 0
    local cur = (not SET.trial) and SET.tog[id] or nil
    local q0, doAnim = target, false
    if cur and math.abs(cur.q - target) > 0.004 and animOn() then q0 = cur.q; doAnim = true end
    local kxOn, kxOff = tx0 + tw - th / 2, tx0 + th / 2
    add({ type = "rectangle", action = "fill", fillColor = COL.track, roundedRectRadii = { xRadius = R(th / 2), yRadius = R(th / 2) },
      frame = { x = tx0, y = ty0, w = tw, h = th } })
    local onIdx = add({ type = "rectangle", action = "fill", fillColor = withA(COL.accent, clamp01(q0)),
      roundedRectRadii = { xRadius = R(th / 2), yRadius = R(th / 2) }, frame = { x = tx0, y = ty0, w = tw, h = th },
      fillGradient = "linear", fillGradientAngle = 0, fillGradientColors = gradA(COL, clamp01(q0)) })
    local knobIdx = add({ type = "circle", action = "strokeAndFill", fillColor = COL.fgWhite, strokeColor = { red = 0, green = 0, blue = 0, alpha = 0.16 },
      strokeWidth = 1, center = { x = lerp(kxOff, kxOn, q0), y = ty0 + th / 2 }, radius = th / 2 - 2.5 })
    togglePrev[id] = on
    if not SET.trial then
      local rec = { q = target }
      SET.tog[id] = rec
      if doAnim then
        rec.q = q0
        Anim.run("setui", "toggle:" .. id, 0.26, "spring", function(e, p)
          local cv = settingsCanvas; if not cv then return end
          local q = lerp(q0, target, e); rec.q = q
          cv:elementAttribute(knobIdx, "center", { x = lerp(kxOff, kxOn, q), y = ty0 + th / 2 })
          cv:elementAttribute(onIdx, "fillGradientColors", gradA(COL, clamp01(lerp(q0, target, clamp01(p * 1.4)))))
        end, function() rec.q = target end)
      end
    end
  end

  -- slider con etichetta e valore, riga che parte da sy
  local function sliderRow(id, label, sy)
    local def = SLIDER_DEFS[id]
    local v = sliderValue(def)
    local rel = (v - def.lo) / (def.hi - def.lo)
    txt(els, label, pad + 16, sy + 14, 86, 16, 12, COL.fg2, {})
    local tx, tw2 = pad + 16 + 90, IW - 32 - 90 - 40
    local ty = sy + 22
    add({ type = "rectangle", action = "fill", fillColor = COL.track, roundedRectRadii = { xRadius = 2.5, yRadius = 2.5 },
      frame = { x = tx, y = ty - 2.5, w = tw2, h = 5 } })
    local fillIdx = add({ type = "rectangle", action = "fill", fillColor = COL.accent, roundedRectRadii = { xRadius = 2.5, yRadius = 2.5 },
      frame = { x = tx, y = ty - 2.5, w = math.max(0.1, rel * tw2), h = 5 },
      fillGradient = "linear", fillGradientAngle = 0, fillGradientColors = COL.grad })
    local knobIdx = add({ type = "circle", action = "strokeAndFill", fillColor = COL.fgWhite, strokeColor = { red = 0, green = 0, blue = 0, alpha = 0.2 },
      strokeWidth = 1, center = { x = tx + rel * tw2, y = ty }, radius = 8.5 })
    local valIdx = txt(els, pct(v), tx + tw2 + 6, sy + 14, 34, 16, 12, COL.fg3, { align = "right", lb = "clip" })
    add({ type = "rectangle", action = "fill", fillColor = CLEAR, frame = { x = tx - 10, y = sy + 6, w = tw2 + 20, h = 32 },
      trackMouseDown = true, id = "sl_" .. id })
    SET.sliders[id] = { tx = tx, tw = tw2, ty = ty, knob = knobIdx, fill = fillIdx, val = valIdx, reg = R0 and R0.i or 1 }
  end

  ----------------------------------------------------------------------
  -- CORPO (scorrevole, ritagliato)
  ----------------------------------------------------------------------
  if settingsPage == "general" then
    openRegion(1, PSP + 1, W - PSP - 1, clipTop, clipBot, bodyTop)
    local trail = GAP          -- spazio vuoto in coda al contenuto (tolto dal calcolo dell'altezza naturale)
    -- CHIAVE GROQ: non impostata = in evidenza in cima; già impostata = scheda riducibile in fondo (dopo l'orientamento)
    if not K.has then
      txt(els, "CHIAVE GROQ", pad + 2, y, IW, 14, 10.5, COL.fg3, { font = "bold" })
      local bx, by = pad + 92, y + 7
      hitCircle(els, sHoverMap, "key_info", bx, by, 8.5, { fill = COL.rowBg, hoverFill = COL.accentSoft, stroke = COL.fg3, hoverStroke = COL.accent, sw = 1.2 })
      add({ type = "circle", action = "fill", fillColor = COL.fg2, center = { x = bx, y = by - 3.1 }, radius = 1 })
      line(els, bx, by - 0.7, bx, by + 3.4, COL.fg2, 1.5)
      y = y + 20
      local bh = 148
      box(pad, y, IW, bh)
      local sy = y + 12
      add({ type = "circle", action = "fill", fillColor = withA(K.has and COL.ok or COL.warn, 0.22), center = { x = pad + 22, y = sy + 9 }, radius = 8 })
      add({ type = "circle", action = "fill", fillColor = K.has and COL.ok or COL.warn, center = { x = pad + 22, y = sy + 9 }, radius = 4.4 })
      txt(els, K.has and K.mask or "Nessuna chiave", pad + 38, sy, IW - 38 - 140, 18, 13, COL.fg, { font = K.has and "mono" or "semi" })
      local m = K.msg
      local l2, l2c = nil, COL.fg3
      if m then
        l2 = m.text
        l2c = (m.kind == "ok") and COL.ok or ((m.kind == "err") and COL.warn or COL.fg2)
      else
        l2 = K.has and "Salvata su questo Mac · incolla per sostituirla" or "Serve per trascrivere · gratis su Groq"
      end
      txt(els, l2, pad + 38, sy + 20, IW - 38 - 12, 15, 11, l2c, { lb = "clip" })
      if K.has then
        local armed = K.armAt > 0 and (now() - K.armAt) < 3
        local rw = armed and 132 or 64
        hitRect(els, sHoverMap, "key_remove", pad + IW - 12 - rw, sy - 1, rw, 20, R(10), { fill = armed and withA(COL.warn, 0.14) or withA(COL.rowBg, 0),
          hoverFill = armed and withA(COL.warn, 0.22) or COL.accentSoft, stroke = armed and COL.warn or COL.divider, hoverStroke = armed and COL.warn or COL.borderSoft })
        txt(els, armed and "Sicuro? Tocca ancora" or "Rimuovi", pad + IW - 12 - rw, sy + 2, rw, 15, 10.5, armed and COL.warn or COL.fg2,
          { font = "semi", align = "center", lb = "clip" })
      end
      local py = y + 54
      add({ type = "rectangle", action = "fill", fillColor = COL.accent, roundedRectRadii = { xRadius = R(12), yRadius = R(12) },
        frame = { x = pad + 12, y = py, w = IW - 24, h = 38 }, fillGradient = "linear", fillGradientAngle = COL.multi and 0 or 90, fillGradientColors = COL.grad })
      hitRect(els, sHoverMap, "key_paste", pad + 12, py, IW - 24, 38, R(12), { fill = withA(COL.fgWhite, K.busy and 0.3 or 0), hoverFill = withA(COL.fgWhite, 0.2) })
      ICON.copy(els, pad + IW / 2 - 78, py + 19, 14, COL.accentText)
      txt(els, K.busy and "Controllo…" or "Incolla chiave dal clipboard", pad + IW / 2 - 64, py + 11, 180, 16, 12.5, COL.accentText, { font = "semi", lb = "clip" })
      local oy = py + 46
      hitRect(els, sHoverMap, "key_open", pad + 12, oy, IW - 24, 36, R(12), { fill = COL.rowBg, hoverFill = COL.accentSoft, stroke = COL.borderSoft, hoverStroke = COL.border })
      local ax, ay = pad + IW / 2 - 92, oy + 18          -- freccia "apri nel browser" (↗)
      line(els, ax - 3.5, ay + 3.5, ax + 3.5, ay - 3.5, COL.accentInk, 1.6)
      seg(els, { { x = ax - 0.5, y = ay - 3.5 }, { x = ax + 3.5, y = ay - 3.5 }, { x = ax + 3.5, y = ay + 0.5 } }, COL.accentInk, 1.6)
      txt(els, "Prendi / crea la chiave su Groq", pad + IW / 2 - 80, oy + 10, 200, 16, 12.5, COL.accentInk, { font = "semi", lb = "clip" })
      SET.keyTip = { y = y + 2 }
      y = y + bh + GAP
    end

    -- MICROFONO
    sec("MICROFONO")
    local nDev = math.max(1, #settingsDevices)
    local bh = nDev * 34 + 8
    box(pad, y, IW, bh)
    local ry = y + 4
    if #settingsDevices == 0 then
      txt(els, "Nessun microfono trovato", pad + 16, ry + 9, IW - 32, 18, 12.5, COL.fg2, {})
    end
    for i, d in ipairs(settingsDevices) do
      local cur = (d.name == config.micName)
      hitRect(els, sHoverMap, "mic:" .. i, pad + 4, ry, IW - 8, 34, R(9), { fill = withA(COL.rowHover, 0), hoverFill = COL.rowHover })
      local rx, rcy = pad + 24, ry + 17
      if cur then
        add({ type = "circle", action = "fill", fillColor = COL.accent, center = { x = rx, y = rcy }, radius = 8.5,
          fillGradient = "linear", fillGradientAngle = COL.multi and 45 or 90, fillGradientColors = COL.grad })
        ICON.check(els, rx, rcy, 13, COL.accentText, 2.3)
      else
        add({ type = "circle", action = "stroke", strokeColor = COL.fg3, strokeWidth = 1.4, center = { x = rx, y = rcy }, radius = 7.5 })
      end
      txt(els, d.name, pad + 42, ry + 9, IW - 42 - 16, 18, 12.5, cur and COL.fg or COL.fg2, { font = cur and "semi" or "reg" })
      if i < #settingsDevices then
        add({ type = "rectangle", action = "fill", fillColor = COL.divider, frame = { x = pad + 42, y = ry + 33, w = IW - 42 - 12, h = 1 } })
      end
      ry = ry + 34
    end
    y = y + bh + GAP

    sec("DIMENSIONE")
    segmented("size", { { label = "Minimal", val = "minimal" }, { label = "Standard", val = "standard" }, { label = "Grande", val = "large" } },
      config.sizePreset, { y = y })
    y = y + 32 + GAP

    sec("ORIENTAMENTO")
    segmented("orient", { { label = "Orizzontale", val = "horizontal", icon = ICON.orientH }, { label = "Verticale", val = "vertical", icon = ICON.orientV } },
      config.orientation, { y = y })
    y = y + 32 + GAP

    if K.has then
      local ry0 = y
      local bodyH = 162
      local showBody = K.exp or K.q > 0.001
      local boxIdx = add({ type = "rectangle", action = "strokeAndFill", fillColor = COL.rowBg, strokeColor = COL.divider, strokeWidth = 1,
        roundedRectRadii = { xRadius = R(12), yRadius = R(12) }, frame = { x = pad, y = ry0, w = IW, h = 44 + bodyH * K.q } })
      local b0 = #els + 1
      local bodyRecs = {}
      if showBody then
        local y0 = ry0 + 44
        local m = K.msg
        local l2, l2c
        if m then l2 = m.text; l2c = (m.kind == "ok") and COL.ok or ((m.kind == "err") and COL.warn or COL.fg2)
        else l2 = "Salvata su questo Mac · incolla per sostituirla"; l2c = COL.fg3 end
        txt(els, l2, pad + 16, y0 + 8, IW - 16 - 44, 15, 11, l2c, { lb = "clip" })
        local bx, by = pad + IW - 24, y0 + 15
        hitCircle(els, sHoverMap, "key_info", bx, by, 8.5, { fill = COL.rowBg, hoverFill = COL.accentSoft, stroke = COL.fg3, hoverStroke = COL.accent, sw = 1.2 })
        add({ type = "circle", action = "fill", fillColor = COL.fg2, center = { x = bx, y = by - 3.1 }, radius = 1 })
        line(els, bx, by - 0.7, bx, by + 3.4, COL.fg2, 1.5)
        local py = y0 + 32
        add({ type = "rectangle", action = "fill", fillColor = COL.accent, roundedRectRadii = { xRadius = R(12), yRadius = R(12) },
          frame = { x = pad + 12, y = py, w = IW - 24, h = 38 }, fillGradient = "linear", fillGradientAngle = COL.multi and 0 or 90, fillGradientColors = COL.grad })
        hitRect(els, sHoverMap, "key_paste", pad + 12, py, IW - 24, 38, R(12), { fill = withA(COL.fgWhite, K.busy and 0.3 or 0), hoverFill = withA(COL.fgWhite, 0.2) })
        ICON.copy(els, pad + IW / 2 - 84, py + 19, 14, COL.accentText)
        txt(els, K.busy and "Controllo…" or "Incolla nuova chiave", pad + IW / 2 - 70, py + 11, 180, 16, 12.5, COL.accentText, { font = "semi", lb = "clip" })
        local oy = py + 46
        hitRect(els, sHoverMap, "key_open", pad + 12, oy, IW - 24, 36, R(12), { fill = COL.rowBg, hoverFill = COL.accentSoft, stroke = COL.borderSoft, hoverStroke = COL.border })
        local ax, ay = pad + IW / 2 - 92, oy + 18
        line(els, ax - 3.5, ay + 3.5, ax + 3.5, ay - 3.5, COL.accentInk, 1.6)
        seg(els, { { x = ax - 0.5, y = ay - 3.5 }, { x = ax + 3.5, y = ay - 3.5 }, { x = ax + 3.5, y = ay + 0.5 } }, COL.accentInk, 1.6)
        txt(els, "Prendi / crea la chiave su Groq", pad + IW / 2 - 80, oy + 10, 200, 16, 12.5, COL.accentInk, { font = "semi", lb = "clip" })
        local rmy = oy + 44
        local armed = K.armAt > 0 and (now() - K.armAt) < 3
        hitRect(els, sHoverMap, "key_remove", pad + 12, rmy, IW - 24, 30, R(10), { fill = armed and withA(COL.warn, 0.14) or withA(COL.rowBg, 0),
          hoverFill = armed and withA(COL.warn, 0.22) or COL.accentSoft, stroke = armed and COL.warn or COL.divider, hoverStroke = armed and COL.warn or COL.borderSoft })
        txt(els, armed and "Sicuro? Tocca ancora" or "Rimuovi chiave", pad + 12, rmy + 8, IW - 24, 15, 11.5, armed and COL.warn or COL.fg2,
          { font = "semi", align = "center", lb = "clip" })
        SET.keyTip = { y = by + 22 - 212 }
        -- dissolvenza del corpo: registra i colori e applica l'opacità di partenza
        local f0 = K.fade(K.q)
        for k = b0, #els do
          local el = els[k]
          for _, at in ipairs({ "fillColor", "strokeColor", "textColor", "fillGradientColors" }) do
            local base = el[at]
            if base then
              bodyRecs[#bodyRecs + 1] = { k, at, base }
              if at == "fillGradientColors" then
                local list = {}
                for i, c in ipairs(base) do list[i] = withA(c, (c.alpha or 1) * f0) end
                el[at] = list
              else
                el[at] = withA(base, (base.alpha or 1) * f0)
              end
            end
          end
        end
      end
      hitRect(els, sHoverMap, "key_toggle", pad + 4, ry0 + 2, IW - 8, 40, R(9), { fill = withA(COL.rowHover, 0), hoverFill = COL.rowHover })
      add({ type = "circle", action = "fill", fillColor = withA(COL.ok, 0.22), center = { x = pad + 22, y = ry0 + 22 }, radius = 8 })
      add({ type = "circle", action = "fill", fillColor = COL.ok, center = { x = pad + 22, y = ry0 + 22 }, radius = 4.4 })
      txt(els, "Chiave Groq", pad + 38, ry0 + 13, 100, 18, 13, COL.fg, { font = "semi", lb = "clip" })
      local mm = K.msg
      local mtxt, mcol, mfont = K.mask or "chiave salvata", COL.fg3, "mono"
      if mm and not K.exp then mtxt = mm.text; mcol = (mm.kind == "ok") and COL.ok or ((mm.kind == "err") and COL.warn or COL.fg2); mfont = "semi" end
      txt(els, mtxt, pad + 138, ry0 + 14, IW - 138 - 40, 16, 12, mcol, { font = mfont, align = "right", lb = "clip" })
      local chevIdx = add({ type = "segments", action = "stroke", strokeColor = COL.fg2, strokeWidth = 1.8, strokeCapStyle = "round",
        strokeJoinStyle = "round", coordinates = K.chev(pad + IW - 22, ry0 + 22, K.q) })
      local target = K.exp and 1 or 0
      if not SET.trial and math.abs(K.q - target) > 0.001 then
        SET.kAnim = { from = K.q, to = target, box = boxIdx, chevIdx = chevIdx, x = pad, y = ry0, w = IW, bodyH = bodyH,
          cx = pad + IW - 22, cy = ry0 + 22, body = bodyRecs }
      end
      y = y + 44 + (K.exp and bodyH or 0) + GAP
    end
  -- popover (i) della chiave Groq: sopra tutto il corpo, trasparenza animata da K.tipA
  K.tipEls = {}
  if settingsPage == "general" and SET.keyTip then
    local tx, ty, tw, th = pad, SET.keyTip.y, IW, 212
    local function reg(ix, attr) K.tipEls[#K.tipEls + 1] = { ix, attr, els[ix][attr] }; els[ix][attr] = withA(els[ix][attr], (els[ix][attr].alpha or 1) * K.tipA) end
    local bg = add({ type = "rectangle", action = "strokeAndFill", fillColor = withA(mix(COL.solid, COL.accent, 0.07), 0.99), strokeColor = COL.border,
      strokeWidth = 1, roundedRectRadii = { xRadius = R(14), yRadius = R(14) }, frame = { x = tx, y = ty, w = tw, h = th } })
    reg(bg, "fillColor"); reg(bg, "strokeColor")
    local tt = txt(els, "Come ottenere la chiave", tx + 14, ty + 12, tw - 28, 18, 12.5, COL.fg, { font = "bold", lb = "clip" })
    reg(tt, "textColor")
    local st = txt(els, table.concat(KEY_STEPS, "\n"), tx + 14, ty + 36, tw - 28, th - 44, 11.5, COL.fg2, { lb = "wordWrap" })
    reg(st, "textColor")
  end
    closeRegion(trail)
  elseif settingsPage == "theme" then
    local mode = resolveMode()
    local Lw = math.floor(IW0 * 0.58)                   -- colonna sinistra: stili · destra: anteprima + controlli
    local colBx = pad0 + Lw + 16
    local colBw = IW0 - Lw - 16
    local cats = FAMILY_ORDER.cats
    local curCat = SET.cat or "all"
    do
      local found = false
      for _, c in ipairs(cats) do if c[1] == curCat then found = true end end
      if not found then curCat = "all"; SET.cat = "all" end
    end
    local list, counts = {}, { all = #FAMILY_ORDER }
    for _, key in ipairs(FAMILY_ORDER) do
      local ct = FAMILIES[key].cat
      counts[ct] = (counts[ct] or 0) + 1
      if curCat == "all" or ct == curCat then list[#list + 1] = key end
    end
    local heroH, catW = 60, 104
    local leftTop = bodyTop + heroH + 12               -- inizio di categorie e carte

    ---- COLONNA SINISTRA ---------------------------------------------------
    if not trial then
      -- hero: gradiente a più stop + onda finta + nome; segue lo stile sotto il mouse (altrimenti quello attuale)
      local FH = FAMILIES[config.style] or FAMILIES.gold
      local TH = FH[mode]
      local hbg = add({ type = "rectangle", action = "fill", fillColor = TH.accent, roundedRectRadii = { xRadius = R(14), yRadius = R(14) },
        frame = { x = pad0, y = bodyTop, w = Lw, h = heroH }, fillGradient = "linear", fillGradientAngle = 0, fillGradientColors = TH.grad })
      for i = 0, 10 do
        local bh = 8 + 24 * math.abs(math.sin(i * 0.83 + 0.55))
        add({ type = "rectangle", action = "fill", fillColor = { red = 1, green = 1, blue = 1, alpha = 0.40 },
          roundedRectRadii = { xRadius = 1.6, yRadius = 1.6 },
          frame = { x = pad0 + Lw - 18 - (11 - i) * 8.5, y = bodyTop + (heroH - bh) / 2, w = 3.2, h = bh } })
      end
      local hn = txt(els, FH.name, pad0 + 16, bodyTop + 11, Lw - 150, 22, 15, TH.accentText, { font = "bold", lb = "clip" })
      local catNm = ""
      for _, c in ipairs(cats) do if c[1] == FH.cat then catNm = c[2] end end
      local hs = txt(els, "Stile attuale · " .. catNm, pad0 + 16, bodyTop + 35, Lw - 150, 16, 10.5, withA(TH.accentText, 0.82), { lb = "clip" })
      SET.hero = { bg = hbg, name = hn, sub = hs, mode = mode, shown = config.style, hover = false,
        i0 = hbg, i1 = hs, box = { x = pad0, y = bodyTop, w = Lw, h = heroH } }

      -- categorie (con conteggio)
      local cpitch = clampN(math.floor((clipBot - leftTop) / #cats), 24, 36)      -- finestre basse: righe più fitte
      local crh = cpitch - 4
      for i, c in ipairs(cats) do
        local ry = leftTop + (i - 1) * cpitch
        local on = (c[1] == curCat)
        if on then
          add({ type = "rectangle", action = "fill", fillColor = COL.accent, roundedRectRadii = { xRadius = R(10), yRadius = R(10) },
            frame = { x = pad0, y = ry, w = catW, h = crh }, fillGradient = "linear", fillGradientAngle = 0, fillGradientColors = COL.grad })
        end
        hitRect(els, sHoverMap, "cat:" .. c[1], pad0, ry, catW, crh, R(10),
          { fill = on and withA(COL.fgWhite, 0) or withA(COL.rowBg, 0), hoverFill = on and withA(COL.fgWhite, 0.16) or COL.rowHover })
        txt(els, c[2], pad0 + 12, ry + (crh - 16) / 2, catW - 44, 16, 12, on and COL.accentText or COL.fg2, { font = "semi", lb = "clip" })
        txt(els, tostring(counts[c[1]] or 0), pad0 + catW - 34, ry + (crh - 14) / 2 + 1, 24, 14, 10.5, on and withA(COL.accentText, 0.75) or COL.fg3, { align = "right", lb = "clip" })
      end
    end

    -- carte stile (regione 1: scorrono, solo quelle visibili hanno elementi)
    do
      local cardsX = pad0 + catW + 10
      local cardsW = Lw - catW - 10
      local ncol = clampN(math.floor((cardsW + 8) / 94), 2, 4)
      local cw = (cardsW - (ncol - 1) * 8) / ncol
      local ch, pitch = 76, 84
      openRegion(1, cardsX - 3, cardsX + cardsW + 3, leftTop - 4, clipBot, leftTop)
      pad, IW = cardsX, cardsW
      local rows = math.ceil(#list / ncol)
      local y0 = y
      if not trial then
        for r = 0, rows - 1 do
          local ry = y0 + r * pitch
          if ry + ch >= R0.visLo and ry <= R0.visHi then
            for c = 0, ncol - 1 do
              local key = list[r * ncol + c + 1]
              if key then
                local F = FAMILIES[key]; local T = F[mode]
                local cx = cardsX + c * (cw + 8)
                local cur = (config.style == key)
                hitRect(els, sHoverMap, "style:" .. key, cx, ry, cw, ch, R(12), {
                  fill = cur and T.accentSoft or COL.rowBg, hoverFill = cur and withA(T.accent, 0.3) or COL.rowHover,
                  stroke = cur and T.accent or COL.divider, hoverStroke = cur and T.accent or withA(T.accent, 0.75), sw = cur and 2 or 1 })
                add({ type = "rectangle", action = "fill", fillColor = T.accent, roundedRectRadii = { xRadius = R(8), yRadius = R(8) },
                  frame = { x = cx + 5, y = ry + 5, w = cw - 10, h = 42 }, fillGradient = "linear", fillGradientAngle = 0, fillGradientColors = T.grad })
                -- mini onda dello stile (rotonda / a blocchi / a punta)
                local kind = F.fx and F.fx.bar or "round"
                local pts = {}
                for i = 0, 12 do
                  local u = i / 12
                  local v = math.sin(u * math.pi * 3.4 + 0.6) * math.sin(u * math.pi)
                  if kind == "pixel" then v = math.floor(v * 3 + 0.5) / 3
                  elseif kind == "square" then v = ((i % 2 == 0) and 1 or -1) * math.abs(v) end
                  pts[#pts + 1] = { x = cx + 5 + 12 + u * (cw - 34), y = ry + 26 + v * 11 }
                end
                add({ type = "segments", action = "stroke", strokeColor = withA(T.accentText, kind == "ghost" and 0.6 or 0.92), strokeWidth = 2,
                  strokeCapStyle = "round", strokeJoinStyle = "round", coordinates = pts })
                txt(els, F.name, cx + 3, ry + 52, cw - 6, 16, 10.5, cur and COL.fg or COL.fg2, { font = cur and "semi" or "reg", align = "center", lb = "clip" })
                if cur then
                  add({ type = "circle", action = "fill", fillColor = T.accentText, center = { x = cx + cw - 15, y = ry + 15 }, radius = 7.5 })
                  ICON.check(els, cx + cw - 15, ry + 15, 11, T.accent, 2.2)
                end
              end
            end
          end
        end
      end
      y = y0 + rows * pitch
      closeRegion(8)
    end

    ---- COLONNA DESTRA -------------------------------------------------------
    pad, IW = colBx, colBw
    y = bodyTop
    sec("ANTEPRIMA")
    do
      local bh = 104
      if not trial then
        add({ type = "rectangle", action = "fill", fillColor = COL.rowBg, roundedRectRadii = { xRadius = R(14), yRadius = R(14) },
          frame = { x = pad, y = y, w = IW, h = bh }, fillGradient = "linear", fillGradientAngle = 25, fillGradientColors = gradFade(COL, 0.55, 0.20) })
        add({ type = "rectangle", action = "stroke", strokeColor = COL.divider, strokeWidth = 1, roundedRectRadii = { xRadius = R(14), yRadius = R(14) },
          frame = { x = pad + 0.5, y = y + 0.5, w = IW - 1, h = bh - 1 } })
        local pw, ph = recDims(false)
        local s = clampN((IW - 20) / pw, 0.5, 0.92)
        local ox, oy = pad + (IW - pw * s) / 2, y + (bh - ph * s) / 2
        local off = #els
        local I = buildRecCard(els, ox, oy, s, false, false, nil, false)
        -- strati: le parti animate dell'anteprima vanno in una canvas piccola sopra (la base resta statica)
        SET.pvSpec = ICON.splitAnim(els, function()
          local e0 = {}
          return e0, buildRecCard(e0, ox, oy, s, false, false, nil, false)
        end, { x = 0, y = 0, w = SET.W, h = SET.H }, off)
        I.preview = true
        PREV = { I = I, top = y, bot = y + bh, x0 = pad, x1 = pad + IW, t0 = now(), bgA = COL.bg.alpha, mt = now() }
        Anim.cancel("egg", "prev")
        if I.egg then
          hitRect(els, sHoverMap, "pv_badge", ox + 14 * s, oy + 11 * s, 34 * s, 34 * s, 4, { fill = withA(COL.fgWhite, 0), hoverFill = withA(COL.fgWhite, 0) })
        end
      end
      y = y + bh + 12
    end
    local ctB = y                                         -- = bodyTop + 136
    openRegion(2, colBx - 4, colBx + colBw + 6, ctB - 6, clipBot, ctB)
    pad, IW = colBx, colBw

    S(20 + 32 + GAP, function()
      sec("MODO")
      segmented("theme", { { label = "Dark", val = "dark", icon = ICON.moon }, { label = "Light", val = "light", icon = ICON.sun },
        { label = "Auto", val = "auto", icon = ICON.auto } }, config.themeMode, { y = y })
    end)

    local on = config.shadowOn ~= false
    local bh2 = on and 88 or 44
    S(20 + bh2 + 44 + GAP, function()
      sec("OMBRA E ALONE")
      local glowOn = config.glowOn == true
      box(pad, y, IW, bh2 + 44)
      switchRow("tg_shadow", on and "Ombra attiva" or "Ombra disattivata", on, y)
      local ry = y + 44
      if on then
        add({ type = "rectangle", action = "fill", fillColor = COL.divider, frame = { x = pad + 16, y = ry, w = IW - 32, h = 1 } })
        sliderRow("shadow", "Intensità", ry)
        ry = ry + 44
      end
      add({ type = "rectangle", action = "fill", fillColor = COL.divider, frame = { x = pad + 16, y = ry, w = IW - 32, h = 1 } })
      switchRow("tg_glow", glowOn and "Alone accento attivo" or "Alone accento", glowOn, ry)
    end)

    S(20 + 44 + GAP, function()
      sec("VETRO")
      box(pad, y, IW, 44)
      sliderRow("glass", "Opacità", y)
    end)

    S(20 + 32 + GAP, function()
      sec("ANGOLI")
      segmented("corner", { { label = "Squadrati", val = "square" }, { label = "Medi", val = "medium" }, { label = "Tondi", val = "round" } },
        config.cornerStyle or "round", { y = y })
    end)

    S(20 + 32 + 10 + 32 + GAP, function()
      sec("ONDA")
      segmented("wave", { { label = "Barre", val = "bars" }, { label = "Sottili", val = "thin" }, { label = "Punti", val = "dots" }, { label = "Linea", val = "line" } },
        waveStyleOf(), { y = y, size = 11.5 })
      y = y + 32 + 10
      segmented("wcol", { { label = "Accento", val = "accent" }, { label = "Gradiente", val = "gradient" } },
        waveGradientOn() and "gradient" or "accent", { y = y })
    end)

    S(20 + 44 + GAP, function()
      sec("PULSAZIONE MIC")
      box(pad, y, IW, 44)
      sliderRow("pulse", "Intensità", y)
    end)

    local an = animOn()
    S(20 + (an and 94 or 44) + GAP, function()
      sec("ANIMAZIONI")
      box(pad, y, IW, an and 44 + 50 or 44)
      switchRow("tg_anim", an and "Animazioni attive" or "Animazioni disattivate", an, y)
      if an then
        add({ type = "rectangle", action = "fill", fillColor = COL.divider, frame = { x = pad + 16, y = y + 44, w = IW - 32, h = 1 } })
        segmented("aspeed", { { label = "Calme", val = "calm" }, { label = "Normali", val = "normal" }, { label = "Vivaci", val = "lively" } },
          SPEED_MUL[config.animSpeed] and config.animSpeed or "normal", { x = pad + 10, w = IW - 20, y = y + 52, h = 30, size = 11.5 })
      end
    end)

    S(20 + 32 + GAP, function()
      sec("TESTO")
      segmented("uifont", { { label = "SF", val = "sf" }, { label = "Arrotondato", val = "rounded" }, { label = "Mono", val = "mono" } },
        (config.uiFont == "rounded" or config.uiFont == "mono") and config.uiFont or "sf", { y = y })
    end)

    S(20 + 32 + GAP, function()
      sec("TIMER")
      segmented("tfont", { { label = "Mono", val = "mono" }, { label = "SF", val = "sf" }, { label = "Arrotondato", val = "rounded" } },
        (config.timerFont == "sf" or config.timerFont == "rounded") and config.timerFont or "mono", { y = y })
    end)

    S(20 + 32 + GAP, function()
      sec("DENSITÀ")
      segmented("dens", { { label = "Compatta", val = "compact" }, { label = "Normale", val = "normal" }, { label = "Ampia", val = "wide" } },
        DENS[config.density] and config.density or "normal", { y = y })
    end)

    S(20 + 44 + GAP, function()
      sec("HUD A RIPOSO")
      box(pad, y, IW, 44)
      sliderRow("idle", "Opacità", y)
    end)

    -- azioni: Sorprendimi / Reset look
    S(38 + 10, function()
      local bw = (IW - 10) / 2
      local armed = resetArmAt > 0 and (now() - resetArmAt) < 3
      add({ type = "rectangle", action = "fill", fillColor = COL.accent, roundedRectRadii = { xRadius = R(12), yRadius = R(12) },
        frame = { x = pad, y = y, w = bw, h = 38 }, fillGradient = "linear", fillGradientAngle = COL.multi and 0 or 90, fillGradientColors = COL.grad })
      hitRect(els, sHoverMap, "btn_random", pad, y, bw, 38, R(12), { fill = withA(COL.fgWhite, 0), hoverFill = withA(COL.fgWhite, 0.2) })
      ICON.sparkle(els, pad + bw / 2 - 42, y + 19, 14, COL.accentText)
      txt(els, "Sorprendimi", pad + bw / 2 - 30, y + 11, 90, 16, 12.5, COL.accentText, { font = "semi", lb = "clip" })
      local rx = pad + bw + 10
      hitRect(els, sHoverMap, "btn_reset", rx, y, bw, 38, R(12), { fill = armed and withA(COL.warn, 0.14) or COL.rowBg,
        hoverFill = armed and withA(COL.warn, 0.22) or COL.accentSoft, stroke = armed and COL.warn or COL.borderSoft,
        hoverStroke = armed and COL.warn or COL.border })
      ICON.reset(els, rx + 20, y + 19, 14, armed and COL.warn or COL.accentInk)
      txt(els, armed and "Confermi?" or "Reset look", rx + 34, y + 11, bw - 40, 16, 12.5,
        armed and COL.warn or COL.accentInk, { font = "semi", lb = "clip" })
    end)
    closeRegion(10)
    pad, IW = pad0, IW0
  else
    openRegion(1, PSP + 1, W - PSP - 1, clipTop, clipBot, bodyTop)
    local trail = GAP
    -- TASTI: una card per tasto [tasto] [gesto] [elimina]
    local function bindings(actionKey, list, gestures)
      for i, b in ipairs(list) do
        local rh = 46
        box(pad, y, IW, rh)
        local label = bindLabel(b)
        local cw = math.max(46, (utf8.len(label) or #label) * 8.5 + 22)
        add({ type = "rectangle", action = "strokeAndFill", fillColor = COL.track, strokeColor = COL.divider, strokeWidth = 1,
          roundedRectRadii = { xRadius = R(8), yRadius = R(8) }, frame = { x = pad + 10, y = y + 9, w = cw, h = 28 } })
        txt(els, label, pad + 10, y + 14, cw, 18, 13, COL.accentInk, { font = "mono", align = "center", lb = "clip" })
        local dcx = pad + IW - 10 - 10
        local gx = pad + 10 + cw + 10
        local gw = dcx - 10 - 8 - gx
        segmented("gest:" .. actionKey .. ":" .. i, gestures, b.gesture, { x = gx, y = y + 10, w = gw, h = 26, size = 10.5, inset = 2 })
        circleButton(els, sHoverMap, "del:" .. actionKey .. ":" .. i, dcx, y + rh / 2, 10, "ghost",
          function(e, cx, cy) ICON.close(e, cx, cy, 12, COL.fg2, 1.8) end)
        y = y + rh + 8
      end
      local ai = hitRect(els, sHoverMap, "add:" .. actionKey, pad, y, IW, 36, R(12),
        { fill = withA(COL.accent, 0), hoverFill = COL.accentFaint, stroke = COL.borderSoft, hoverStroke = COL.border })
      els[ai].strokeDashPattern = { 5, 4 }
      ICON.plus(els, pad + IW / 2 - 58, y + 18, 14, COL.accentInk, 1.9)
      txt(els, "Aggiungi tasto", pad + IW / 2 - 44, y + 10, 110, 16, 12.5, COL.accentInk, { font = "semi", lb = "clip" })
      y = y + 36 + GAP
    end
    sec("AVVIO / STOP")
    bindings("ss", config.ssBindings, { { label = "2 tap", val = "double" }, { label = "1 tap", val = "single" }, { label = "hold", val = "hold" } })
    sec("PAUSA")
    bindings("pause", config.pauseBindings, { { label = "1 tap", val = "single" }, { label = "2 tap", val = "double" } })
    y = y - 12
    trail = GAP - 12
    closeRegion(trail)
  end

  ----------------------------------------------------------------------
  -- Sopra il corpo: schermi che bloccano i click sul contenuto scrollato fuori vista
  -- (e fanno da maniglia di trascinamento), scrollbar, intestazione e tab (fissi).
  ----------------------------------------------------------------------
  pad, IW = pad0, IW0
  local function cover(x, cy, w, h) add({ type = "rectangle", action = "fill", fillColor = CLEAR, frame = { x = x, y = cy, w = w, h = h },
    trackMouseDown = true, trackMouseUp = true, trackMouseEnterExit = true, id = "s_drag" }) end
  cover(PSP, PSP, W - 2 * PSP, clipTop - PSP)
  SET.botIdx = add({ type = "rectangle", action = "fill", fillColor = CLEAR, frame = { x = PSP, y = clipBot, w = W - 2 * PSP, h = H - PSP - clipBot },
    trackMouseDown = true, trackMouseUp = true, trackMouseEnterExit = true, id = "s_drag" })
  if settingsPage == "theme" then            -- zone fisse sopra le regioni (hero / anteprima): niente click "fantasma" dal contenuto scorso
    for _, r in pairs(regs) do cover(r.cx0 - 6, clipTop, r.cx1 - r.cx0 + 12, math.max(1, r.top - clipTop)) end
  end
  local anySc = false
  for _, r in pairs(regs) do if r.scroll > 0.5 then anySc = true end end
  -- filo sotto i tab quando il contenuto è scorso (sempre presente, opacità 0 a scroll zero)
  SET.divIdx = add({ type = "rectangle", action = "fill", fillColor = anySc and COL.divider or withA(COL.divider, 0),
    frame = { x = pad, y = clipTop, w = IW, h = 1 } })
  for _, r in pairs(regs) do
    r.sbIdx = nil
    if r.max > 0 then
      local trackH = r.view - 8
      local barH = clampN(trackH * r.view / math.max(1, r.len), 28, trackH)
      local barY = r.contentTop + 4 + (trackH - barH) * clampN(r.scroll / r.max, 0, 1)
      r.trackH, r.barH = trackH, barH
      r.sbIdx = add({ type = "rectangle", action = "fill", fillColor = withA(COL.fg, SET.sbA or 0),
        roundedRectRadii = { xRadius = 1.5, yRadius = 1.5 }, frame = { x = r.cx1 - 5, y = barY, w = 3, h = barH } })
    end
  end

  y = top
  panelHeader(els, sHoverMap, pad, IW, y, "Impostazioni", ICON.gear, "s_close")
  y = y + 56
  segmented("tab", { { label = "Generale", val = "general", icon = ICON.sliders }, { label = "Tasti", val = "keys", icon = ICON.keyboard },
    { label = "Tema", val = "theme", icon = ICON.palette } }, settingsPage, { y = y, h = 36, size = 12.5, w = math.min(IW0, SPANEL_W - 40) })

  fillShell(els, W, H, "s_drag", nShell, true)
  local natural = 0
  for _, r in pairs(regs) do natural = math.max(natural, r.contentTop + r.len + PSP + 8) end
  return els, { natural = natural, bodyTop = bodyTop }
end

-- Altezza naturale del tab corrente: layout di prova al tetto (a secco: nessuna animazione, nessuno stato toccato),
-- poi H = intestazione+tab + contenuto + margini. Mai sotto minH, mai sopra il tetto (cap).
local function targetHeight()
  local oldH = SET.H
  local sS, sT = shallow(segPrev), shallow(togglePrev)
  SET.H = SET.cap
  SET.trial = true
  local ok, _, info = pcall(layoutSettings)
  SET.trial = false
  segPrev, togglePrev = sS, sT
  SET.H = oldH
  if not ok or type(info) ~= "table" then return SET.cap end
  return clampN(finite(info.natural, 0), SET.minH, SET.cap)
end

-- schermo che contiene la finestra (per il clamp verso l'alto del bordo basso)
local function screenFrameFor(f)
  local ok, sf = pcall(function()
    local cx, cy = f.x + f.w / 2, f.y + f.h / 2
    for _, s in ipairs(hs.screen.allScreens()) do
      local r = s:frame()
      if cx >= r.x and cx <= r.x + r.w and cy >= r.y and cy <= r.y + r.h then return r end
    end
  end)
  if ok and sf then return sf end
  return hs.screen.mainScreen():frame()
end

-- STRATI DELLE IMPOSTAZIONI: le colonne scorrevoli e l'hero sono canvas separate sopra la base (che resta statica: ridisegnata solo
-- a cambio pagina / stile / misura). Scroll e aggiornamenti dell'hero toccano solo la canvas piccola; la logica esistente
-- continua a scrivere sugli stessi indici: il proxy li instrada. Le colonne hanno il mouse (stessa callback), l'hero e'
-- trasparente al mouse. Elementi spostati = segnaposto "skip" nella base (indici invariati).
-- Hit-test delle colonne raster: la viewport ha UNA superficie mouse; qui si risolve a mano quale elemento (id) sta sotto il puntatore
-- usando la mappa dei rettangoli/cerchi interattivi del contenuto (coordinate di contenuto) + lo scroll corrente. Ordine = topmost per ultimo.
function SET.rasterHits(els, idxs, ox, oy)
  local hits = {}
  for _, i in ipairs(idxs) do
    local e = els[i]
    if e and e.id and (e.trackMouseDown or e.trackMouseUp or e.trackMouseEnterExit) then
      local h = { id = e.id, down = e.trackMouseDown, up = e.trackMouseUp, ee = e.trackMouseEnterExit }
      if e.frame then h.x0, h.y0, h.x1, h.y1 = e.frame.x - ox, e.frame.y - oy, e.frame.x + e.frame.w - ox, e.frame.y + e.frame.h - oy
      elseif e.center and e.radius then h.c = true; h.cx, h.cy, h.rad = e.center.x - ox, e.center.y - oy, e.radius
      else h = nil end
      if h then hits[#hits + 1] = h end
    end
  end
  return hits
end
function SET.rasterMouse(hits, r)
  local function find(flag, x, y)
    for k = #hits, 1, -1 do
      local h = hits[k]
      if h[flag] then
        if h.c then
          local dx, dy = x - h.cx, y - h.cy
          if dx * dx + dy * dy <= h.rad * h.rad then return h.id end
        elseif x >= h.x0 and x <= h.x1 and y >= h.y0 and y <= h.y1 then return h.id end
      end
    end
    return nil
  end
  return function(c, msg, _id, x, y)
    if msg == "mouseExit" then
      local o = r.hot; r.hot = nil
      if o then settingsMouse(c, "mouseExit", o) end
      return
    end
    if type(x) ~= "number" or type(y) ~= "number" or x ~= x or y ~= y then return end
    local cy = y + r.scroll - (r.contentTop - r.top)            -- punto nel contenuto
    if msg == "mouseEnter" or msg == "mouseMove" then
      local n = find("ee", x, cy)
      if n ~= r.hot then
        local o = r.hot; r.hot = n
        if o then settingsMouse(c, "mouseExit", o) end
        if n then settingsMouse(c, "mouseEnter", n) end
      end
    elseif msg == "mouseDown" then
      settingsMouse(c, "mouseDown", find("down", x, cy) or "s_drag")      -- fondo = maniglia di trascinamento (come lo schermo sotto)
    elseif msg == "mouseUp" then
      local n = find("up", x, cy)
      if n then settingsMouse(c, "mouseUp", n) end
    end
  end
end

function SET.buildLayers(els)
  local specs = {}
  SET.elsO = {}
  for i = 1, #els do SET.elsO[i] = els[i] end              -- riferimenti originali (geometria per l'overlay hover)
  if not ICON.layersOn() then SET.pvSpec = nil; specs.orig = {}; return specs end   -- kill-switch: tutto nella base
  local clipBot = SET.clipBot or ((SET.H or 300) - PSP - 8)
  local function take(key, box, idxs, cb, dragHit)
    local list, route = {}, {}
    if dragHit then
      list[1] = { type = "rectangle", action = "fill", fillColor = CLEAR, frame = { x = 0, y = 0, w = box.w, h = box.h }, trackMouseDown = true, id = "s_drag" }
    end
    for _, i in ipairs(idxs) do
      local e = els[i]
      if e then list[#list + 1] = ICON.shiftEl(e, box.x, box.y); route[i] = #list end
    end
    for i in pairs(route) do els[i] = ICON.skipEl() end
    specs[key] = { els = list, route = route, box = box, cb = cb }
  end
  for i, r in pairs(SET.reg or {}) do
    local idxs = {}
    for k = r.i0, r.i1 do idxs[#idxs + 1] = k end
    local box = { x = r.cx0, y = r.top, w = r.cx1 - r.cx0, h = math.max(1, clipBot - r.top) }
    if SET.RASTER ~= false and r.max > 0 and r.len > 0 then
      -- colonna raster: contenuto intero (coordinate di contenuto) -> immagine; la viewport ha immagine + superficie mouse + scrollbar
      local list, route = {}, {}
      local hits = SET.rasterHits(els, idxs, r.cx0, r.contentTop)
      for _, k in ipairs(idxs) do
        local e = els[k]
        if e then list[#list + 1] = ICON.shiftEl(e, r.cx0, r.contentTop); route[k] = #list end
      end
      local sbEl
      if r.sbIdx and els[r.sbIdx] then sbEl = ICON.shiftEl(els[r.sbIdx], box.x, box.y) end
      local orig = {}
      for k in pairs(route) do orig[k] = els[k]; els[k] = ICON.skipEl() end
      if r.sbIdx and sbEl then orig[r.sbIdx] = els[r.sbIdx]; els[r.sbIdx] = ICON.skipEl() end
      specs["r" .. i] = { raster = true, els = list, route = route, box = box, cb = SET.rasterMouse(hits, r), sbIdx = sbEl and r.sbIdx or nil, sbEl = sbEl,
        fc = { w = box.w, h = math.max(1, math.ceil(r.len)), dx = r.cx0, dy = r.contentTop }, yOff = r.contentTop - r.top, scroll = r.scroll,
        alt = function()          -- ripiego (se la canvas raster non si crea): colonna normale a spostamento di elementi
          for k, e in pairs(orig) do els[k] = e end
          local keep = specs
          take("r" .. i, box, (function() local t = {}; for k = r.i0, r.i1 do t[#t + 1] = k end; if r.sbIdx then t[#t + 1] = r.sbIdx end; return t end)(), settingsMouse, true)
          return keep["r" .. i]
        end }
    else
      if r.sbIdx then idxs[#idxs + 1] = r.sbIdx end            -- anche la scrollbar (la sua dissolvenza non deve ridisegnare la base)
      take("r" .. i, box, idxs, settingsMouse, true)
    end
  end
  local Hh = SET.hero
  if Hh and Hh.box and Hh.i0 and Hh.i1 then
    local idxs = {}
    for k = Hh.i0, Hh.i1 do idxs[#idxs + 1] = k end
    take("hero", Hh.box, idxs, nil, false)
  end
  if SET.pvSpec then specs.pv = SET.pvSpec end
  -- elementi spostati negli strati (per tornare a canvas singola se uno strato non si crea)
  local orig = {}
  for i in pairs(SET.reg or {}) do for k = SET.reg[i].i0, SET.reg[i].i1 do orig[k] = SET.elsO[k] end; if SET.reg[i].sbIdx then orig[SET.reg[i].sbIdx] = SET.elsO[SET.reg[i].sbIdx] end end
  if SET.hero and SET.hero.i0 then for k = SET.hero.i0, SET.hero.i1 do orig[k] = SET.elsO[k] end end
  if SET.pvSpec and SET.pvSpec.orig then for k, e in pairs(SET.pvSpec.orig) do orig[k] = e end end
  specs.orig = orig
  return specs
end
function SET.applyLayers(cv, specs, els)
  local failed = false
  for _, key in ipairs({ "r1", "r2", "hero", "pv" }) do
    local sp = specs and specs[key] or nil
    local ok, err = pcall(function()
      if sp and sp.raster then cv:layerRaster(sp, key) else cv:layerApply(sp, key) end
    end)
    if not ok then ICON.log("[GW] strati: " .. tostring(err)); failed = true; break end
  end
  if failed then
    -- qualcosa non si e' creato: torna a canvas singola (base completa, scroll a spostamento di elementi), niente a meta'
    pcall(function() cv:layerClear() end)
    if els and specs and specs.orig then
      for k, e in pairs(specs.orig) do els[k] = e end
      pcall(function() cv:replaceElements(els) end)
    end
    SET.rastOn = false
    for _, r in pairs(SET.reg or {}) do r.base = 0; r.shown = 0 end
    for i, r in pairs(SET.reg or {}) do SET.dy[i] = r.scroll end
    SET.applyScroll()
  end
  ICON.relayer(cv)                       -- strati riusati: restano sopra la base e alla sua stessa alpha dopo ogni render
end

-- HOVER: un solo rettangolo su una canvas piccola (pool di 2) che si sposta sull'elemento sotto il mouse. Niente attributi sulla base
-- (ogni scrittura ridisegnerebbe tutta la canvas). Dissolvenza = alpha della finestra (gratis). Colore compensato: l'alpha
-- dell'overlay e' scelta in modo che base + overlay ~ colore di hover originale.
SET.hv = { pool = {} }
function SET.hvGeom(h)
  local el = SET.elsO and SET.elsO[h.idx]
  if not el then return nil end
  local x, y, w, ht, r
  if el.frame then
    x, y, w, ht = el.frame.x, el.frame.y, el.frame.w, el.frame.h
    r = el.roundedRectRadii and el.roundedRectRadii.xRadius or 0
  elseif el.center and el.radius then
    x, y, w, ht, r = el.center.x - el.radius, el.center.y - el.radius, 2 * el.radius, 2 * el.radius, el.radius
  else return nil end
  local rg
  for _, g in pairs(SET.reg or {}) do
    if h.idx >= g.i0 and h.idx <= g.i1 then y = y - (SET.dy[g.i] or 0); rg = g end
  end
  local x0, y0, x1, y1 = x, y, x + w, y + ht
  if rg then x0 = math.max(x0, rg.cx0); x1 = math.min(x1, rg.cx1); y0 = math.max(y0, rg.top); y1 = math.min(y1, SET.clipBot or y1) end
  if x1 - x0 < 1 or y1 - y0 < 1 then return nil end
  return { x = x0, y = y0, w = x1 - x0, h = y1 - y0, ex = x - x0, ey = y - y0, ew = w, eh = ht, r = r, circle = (el.center ~= nil), sw = el.strokeWidth or 1 }
end
function SET.hvHide()
  Anim.cancel("sethv")
  for _, p in ipairs(SET.hv.pool) do
    if p.cv then pcall(function() p.cv:hide() end) end
    p.id = nil
  end
end
function SET.hvKill()
  Anim.cancel("sethv")
  for _, p in ipairs(SET.hv.pool) do if p.cv then pcall(function() p.cv:delete() end) end end
  SET.hv.pool = {}
end
function SET.hover(id, entering)
  local cv = settingsCanvas
  local h = sHoverMap[id]
  if not cv or not h then return end
  if not ICON.layersOn() then hoverTo(cv, sHoverMap, "sethv", id, entering); return end      -- kill-switch: hover sulla base come prima degli strati
  local pool = SET.hv.pool
  if not entering then
    for n, p in ipairs(pool) do
      if p.id == id and p.cv then
        p.id = nil
        local a0 = p.a or 1
        Anim.run("sethv", "ov" .. n, 0.16, "out", function(e) p.a = a0 * (1 - e); p.cv:alpha(p.a) end, function() p.a = 0; p.cv:hide() end)
      end
    end
    return
  end
  for _, p in ipairs(pool) do if p.id == id then return end end
  if not h.hoverFill and not h.hoverStroke then return end
  local g = SET.hvGeom(h)
  if not g then return end
  local p
  for _, q in ipairs(pool) do if not q.id and (not p or (q.a or 0) < (p.a or 0)) then p = q end end
  if not p then
    if #pool >= 2 then return end
    p = { n = #pool + 1 }
    pool[#pool + 1] = p
  end
  p.id = id
  local f = cv:frame()
  local base, hov = h.fill, h.hoverFill
  local fill = nil
  if hov then
    local aF, aH = (base and base.alpha) or 0, hov.alpha or 1
    local ao = clampN(1 - (1 - aH) / math.max(0.001, 1 - aF), 0, 1)
    fill = { red = hov.red, green = hov.green, blue = hov.blue, alpha = ao }
  end
  local stroke = h.hoverStroke
  local el
  if g.circle then
    el = { type = "circle", action = stroke and (fill and "strokeAndFill" or "stroke") or "fill", fillColor = fill, strokeColor = stroke, strokeWidth = g.sw,
      center = { x = g.ex + g.ew / 2, y = g.ey + g.eh / 2 }, radius = g.ew / 2 }
  else
    el = { type = "rectangle", action = stroke and (fill and "strokeAndFill" or "stroke") or "fill", fillColor = fill, strokeColor = stroke, strokeWidth = g.sw,
      roundedRectRadii = { xRadius = g.r, yRadius = g.r }, frame = { x = g.ex, y = g.ey, w = g.ew, h = g.eh } }
  end
  local fr = { x = f.x + g.x, y = f.y + g.y, w = g.w, h = g.h }
  if not p.cv then
    p.cv = hs.canvas.new(fr)
    pcall(function() p.cv:level(ICON.lvlUp(cv, 2)); p.cv:behavior(cv:behavior()) end)
  else
    p.cv:frame(fr)
  end
  p.cv:replaceElements({ el })
  p.a = 0; p.cv:alpha(0); p.cv:show()
  Anim.cancel("sethv", "ov" .. p.n)
  Anim.run("sethv", "ov" .. p.n, 0.16, "out", function(e) if p.id == id then p.a = clamp01(e); p.cv:alpha(p.a) end end, function() if p.id == id then p.a = 1; p.cv:alpha(1) end end)
end

-- Porta alla nuova misura (w, h) TUTTO ciò che ne dipende, in un colpo solo (stessa passata del run loop):
-- finestra (nx/ny se dati), ombra/vetro/bordo (aggiornati solo se la misura è cambiata), ritagli delle regioni
-- e schermo-maniglia in basso. Il contenuto resta lo stesso: nessun ridisegno.
local function applyShell(cv, w, h, nx, ny)
  if not cv or not SET.W then return end
  w = clampN(finite(w, SET.W), 120, 6000)
  h = clampN(finite(h, SET.H or 300), 40, 4000)
  local last = SET.shellLast
  if not last or math.abs(last.w - w) > 0.05 or math.abs(last.h - h) > 0.05 then
    local head = {}
    pushGlass(head, PSP, PSP, w - 2 * PSP, h - 2 * PSP, R(20), { s = 1, sheenH = 58, sheenA = 0.6, shadowMul = 1.25, lite = true })
    local coords = (not last) or math.abs(last.w - w) > 0.05
    for i = 1, math.min(#head, SET.nShell or NCARD) do
      local e = head[i]
      if e.frame then cv:elementAttribute(i, "frame", e.frame) end
      if coords and e.coordinates then cv:elementAttribute(i, "coordinates", e.coordinates) end
    end
    local clipBot = h - PSP - 8
    for _, r in pairs(SET.reg or {}) do
      cv:elementAttribute(r.clipIdx, "frame", { x = r.cx0, y = r.top, w = r.cx1 - r.cx0, h = math.max(1, clipBot - r.top) })
      cv:layerSize("r" .. r.i, r.cx1 - r.cx0, math.max(1, clipBot - r.top))        -- il ritaglio della colonna segue l'altezza animata
    end
    if SET.botIdx then
      cv:elementAttribute(SET.botIdx, "frame", { x = PSP, y = clipBot, w = SET.W - 2 * PSP, h = math.max(1, h - PSP - clipBot) })
    end
    SET.shellLast = { w = w, h = h }
  end
  local f = cv:frame()
  local fx, fy = (nx ~= nil) and finite(nx, f.x) or f.x, (ny ~= nil) and finite(ny, f.y) or f.y
  if math.abs(f.x - fx) > 0.02 or math.abs(f.y - fy) > 0.02 or math.abs(f.w - w) > 0.02 or math.abs(f.h - h) > 0.02 then
    cv:frame({ x = fx, y = fy, w = w, h = h })
  end
end

-- fantasma del corpo uscente: istantanea della canvas, in una finestra sottile sopra (ritagliata al corpo)
local function makeGhost(cv, hFrom, ct, wFrom)
  killGhost()
  local ok, g = pcall(function()
    local img = cv:imageFromCanvas()
    if not img then return nil end
    local f = cv:frame()
    local gh = clampN(hFrom - PSP - 8 - ct, 1, 4000)
    local gw = clampN(wFrom - 2 * PSP - 2, 1, 6000)
    local gc = hs.canvas.new({ x = f.x + PSP + 1, y = f.y + ct, w = gw, h = gh })
    gc:level(ICON.lvlUp(cv, 2) or hs.canvas.windowLevels.overlay)
    gc:behavior({ "canJoinAllSpaces", "fullScreenAuxiliary" })
    gc:appendElements({ type = "image", image = img, imageScaling = "scaleToFit", frame = { x = -(PSP + 1), y = -ct, w = wFrom, h = hFrom } })
    -- gli strati (colonne scorrevoli, hero, anteprima) sono finestre a parte: le loro istantanee vanno nel fantasma
    local ga = {}
    for _, L in ipairs(cv:layerImages()) do
      local fr = { x = L.x - (PSP + 1), y = L.y - ct, w = L.w, h = L.h }
      gc:appendElements({ type = "image", image = L.img, imageScaling = "scaleToFit", frame = fr })
      ga[#ga + 1] = fr
    end
    gc:alpha(1)
    gc:show()
    return { cv = gc, ct = ct, gh = gh, gw = gw, ih = hFrom, iw = wFrom, a = ga }
  end)
  if ok and g then
    SET.ghost = g
    hs.timer.doAfter(0.7, function() if SET.ghost == g then killGhost() end end)      -- rete di sicurezza: il fantasma non sopravvive mai alla dissolvenza (0,24 s)
    return g
  end
  return nil
end
local function syncGhost()
  local G, cv = SET.ghost, settingsCanvas
  if not G or not cv or not SET.W then return end
  local f = cv:frame()
  local vis = clampN(finite(SET.hCur, G.gh + G.ct + PSP + 8) - PSP - 8 - G.ct, 1, G.gh)
  local gw = clampN(finite(SET.wCur, G.gw + 2 * PSP + 2) - 2 * PSP - 2, 1, G.gw)
  G.cv:frame({ x = f.x + PSP + 1, y = f.y + G.ct, w = gw, h = vis })
end
local function fadeGhost(g)
  Anim.run("setvis", "xfade", 0.24, "inout", function(e)
    local G = SET.ghost
    if not G or G ~= g then return end
    e = clamp01(e)
    G.cv:alpha(1 - e)
    G.cv:elementAttribute(1, "frame", { x = -(PSP + 1), y = -G.ct - 6 * e, w = G.iw, h = G.ih })
    for k, fr in ipairs(G.a or {}) do G.cv:elementAttribute(k + 1, "frame", { x = fr.x, y = fr.y - 6 * e, w = fr.w, h = fr.h }) end
    syncGhost()
  end, function() if SET.ghost == g then killGhost() end end)
end

renderSettings = function(opts)
  opts = opts or {}
  if not SET.W then SET.W, SET.cap = settingsGeometry(); SET.H = SET.cap end
  SET.hvHide(); Anim.cancel("setui")
  local snapSeg, snapTog = shallow(segPrev), shallow(togglePrev)
  local cvOld = settingsCanvas
  local hFrom = cvOld and clampN(finite(SET.hCur, SET.H), 40, 4000) or nil
  local wFrom = cvOld and clampN(finite(SET.wCur, SET.W), 120, 6000) or nil
  local oldClipTop = SET.clipTop
  if not opts.scroll then
    SET.W, SET.cap = settingsGeometry()                       -- larghezza e tetto del tab corrente
    SET.H = targetHeight()                                    -- altezza a misura del contenuto di questo tab
  end
  local els, info = layoutSettings()
  local fix = false
  for i, r in pairs(SET.reg) do                               -- il contenuto si è accorciato: riallinea lo scroll
    if r.scroll > r.max + 0.5 then SET.sc[i] = r.max; fix = true end
  end
  if fix then
    segPrev, togglePrev = snapSeg, snapTog
    els, info = layoutSettings()
  end
  SET.shellLast = nil
  local W, tH = SET.W, SET.H
  local layerSpecs = SET.buildLayers(els)                     -- colonne scorrevoli + hero -> canvas separate (base statica)

  local heightAnimating = false
  if not cvOld then
    local sf = hs.screen.mainScreen():frame()
    local fx, fy
    if settingsPos then fx, fy = settingsPos.x, settingsPos.y
    else fx = sf.x + (sf.w - W) / 2; fy = sf.y + (sf.h - tH) / 2 end
    fx = math.max(sf.x, math.min(fx, sf.x + sf.w - W))
    fy = math.max(sf.y, math.min(fy, sf.y + sf.h - tH))
    SET.frame = { x = fx, y = fy, w = W, h = tH }
    SET.hCur = tH; SET.wCur = W
    settingsCanvas = ICON.wrap(hs.canvas.new({ x = fx, y = fy, w = W, h = tH }))
    settingsCanvas:level(hs.canvas.windowLevels.overlay)
    settingsCanvas:behavior({ "canJoinAllSpaces", "fullScreenAuxiliary" })
    settingsCanvas:mouseCallback(settingsMouse)
    settingsCanvas:replaceElements(els)
    settingsCanvas:alpha(0)
    SET.applyLayers(settingsCanvas, layerSpecs, els)
    settingsCanvas:show()
    panelIn("setvis", settingsCanvas, fx, fy, W, tH, 18)
    startScrollTap()
  else
    startScrollTap()
    -- stessa finestra: header, tab e card restano dove sono; cambia solo il corpo (e la misura, con il centro
    -- orizzontale e il bordo alto fermi). Mai alpha < 1: niente lampeggio.
    local cv = cvOld
    local f = cv:frame()
    local sizeChange = math.abs(tH - hFrom) > 0.5 or math.abs(W - wFrom) > 0.5
    local moveOrGrow = (not opts.scroll) and (opts.page or sizeChange)
    if moveOrGrow and Anim.list["setvis|vis"] then      -- entrata ancora in corso: chiudila di netto
      Anim.cancel("setvis", "vis")
      cv:alpha(1)
      if SET.frame then cv:frame({ x = SET.frame.x, y = SET.frame.y, w = wFrom, h = hFrom }); f = cv:frame() end
    end
    local ghost = nil
    if opts.page and animOn() then ghost = makeGhost(cv, hFrom, oldClipTop or SET.clipTop, wFrom) else killGhost() end
    cv:replaceElements(els)                -- atomico: contenuto nuovo sotto il fantasma del vecchio
    SET.applyLayers(cv, layerSpecs, els)
    -- posizione di arrivo: allargamento SIMMETRICO attorno al centro (clamp ai bordi con minima correzione;
    -- se corretto, si ricorda il centro voluto per tornare lì quando la finestra si restringe); alto fermo
    local sf = screenFrameFor(f)
    local x0, y0, xT, yT = f.x, f.y, f.x, f.y
    if math.abs(W - wFrom) > 0.5 then
      local cx = SET.cxHome or (f.x + wFrom / 2)
      xT = cx - W / 2
      local xC = math.max(sf.x, math.min(xT, sf.x + sf.w - W))
      if math.abs(xC - xT) > 0.5 then SET.cxHome = cx else SET.cxHome = nil end
      xT = xC
    end
    if tH > hFrom + 0.5 and f.y + tH > sf.y + sf.h then yT = math.max(sf.y, sf.y + sf.h - tH) end    -- solo se uscirebbe dal bordo basso
    if opts.scroll or not sizeChange then
      SET.hCur = (math.abs(tH - hFrom) <= 0.5) and tH or hFrom
      SET.wCur = (math.abs(W - wFrom) <= 0.5) and W or wFrom
      applyShell(cv, SET.wCur, SET.hCur)
      if Anim.list["setvis|h"] and opts.scroll then heightAnimating = true end
    elseif not animOn() then                -- animazioni spente: cambio istantaneo e atomico (misura + posizione insieme)
      SET.hCur, SET.wCur = tH, W
      applyShell(cv, W, tH, xT, yT)
      local ff = cv:frame(); SET.frame = { x = ff.x, y = ff.y, w = ff.w, h = ff.h }
    else
      applyShell(cv, wFrom, hFrom)
      heightAnimating = true
      Anim.run("setvis", "h", 0.28, "out", function(e)
        local c2 = settingsCanvas; if not c2 then return end
        e = clamp01(e)
        SET.hCur = lerp(hFrom, tH, e); SET.wCur = lerp(wFrom, W, e)
        applyShell(c2, SET.wCur, SET.hCur, lerp(x0, xT, e), lerp(y0, yT, e))
        syncGhost()
      end, function()
        local c2 = settingsCanvas; if not c2 then return end
        SET.hCur, SET.wCur = tH, W
        applyShell(c2, W, tH, xT, yT)
        local ff = c2:frame()
        SET.frame = { x = ff.x, y = ff.y, w = ff.w, h = ff.h }
        syncGhost()
        pokeScrollbar()
      end)
    end
    if ghost then syncGhost(); fadeGhost(ghost) end
  end
  if (opts.scroll or opts.page or not cvOld) and not heightAnimating then pokeScrollbar() end
  if SET.kAnim then SET.K.anim(SET.kAnim); SET.kAnim = nil end
  if settingsPage == "theme" then
    if opts.page or not cvOld then SET.pvBoost = now() + 1.2 end        -- appena arrivati sul tab: qualche istante di movimento, poi fermo
    startPreview()
  else stopPreview() end
end

openSettings = function()
  segPrev = {}; togglePrev = {}; resetArmAt = 0; SET.pill = {}; SET.tog = {}
  SET.K.refresh(); SET.K.armAt = 0; SET.K.tipReset(); SET.K.exp = false; SET.K.q = 0
  getAudioDevices(function(list)
    deviceCache = list; settingsDevices = list
    if not settingsCanvas then SET.sc = { 0, 0 }; SET.W, SET.cap = settingsGeometry(); SET.H = SET.cap end
    renderSettings()
  end)
end
end

------------------------------------------------------------------------
-- PANNELLO TRANSCRIPT RECENTI (mini clipboard manager)
------------------------------------------------------------------------
local hCards = {}

closeHistory = function()
  local cv = historyCanvas
  if not cv then return end
  historyCanvas = nil
  Anim.cancel("hishv"); Anim.cancel("hisvis")
  panelOut(cv)
end

historyMouse = function(_c, msg, id)
  if msg == "mouseEnter" then hoverTo(historyCanvas, hHoverMap, "hishv", id, true); return
  elseif msg == "mouseExit" then hoverTo(historyCanvas, hHoverMap, "hishv", id, false); return
  elseif msg == "mouseDown" then
    if id == "h_drag" then dragCanvas(historyCanvas, false) end
    return
  elseif msg ~= "mouseUp" then return end
  if not historyCanvas then return end

  if id == "h_close" then closeHistory(); return end
  local i = id:match("^copy:(%d+)$")
  if i then
    i = tonumber(i)
    local hist = loadHistory()
    local e = hist[i]
    if not e then return end
    hs.pasteboard.setContents(e.text)
    -- feedback sul chip: "Copia" -> "Copiato" con check
    local cv, c = historyCanvas, hCards[i]
    if cv and c then
      cv:elementAttribute(c.chipBg, "fillColor", withA(COL.ok, 0.20))
      cv:elementAttribute(c.chipText, "text", "Copiato")
      cv:elementAttribute(c.chipText, "textColor", COL.ok)
      for _, ix in ipairs(c.copyIcon) do cv:elementAttribute(ix, "strokeColor", withA(COL.accentInk, 0)) end
      cv:elementAttribute(c.check, "strokeColor", COL.ok)
      hs.timer.doAfter(1.5, function()
        if historyCanvas ~= cv then return end
        pcall(function()
          cv:elementAttribute(c.chipBg, "fillColor", COL.accentSoft)
          cv:elementAttribute(c.chipText, "text", "Copia")
          cv:elementAttribute(c.chipText, "textColor", COL.accentInk)
          for _, ix in ipairs(c.copyIcon) do cv:elementAttribute(ix, "strokeColor", COL.accentInk) end
          cv:elementAttribute(c.check, "strokeColor", withA(COL.ok, 0))
        end)
      end)
    end
  end
end

renderHistoryPanel = function()
  Anim.cancel("hishv")
  local W = HPANEL_W + 2 * PSP
  local pad = PSP + 20
  local IW = W - 2 * pad
  local els, y = {}, PSP + 20
  hHoverMap = {}
  hCards = {}
  for i = 1, NCARD do els[i] = placeholder() end
  local function add(el) els[#els + 1] = el; return #els end

  panelHeader(els, hHoverMap, pad, IW, y, "Transcript recenti", ICON.clock, "h_close")
  y = y + 56

  local hist = loadHistory()
  if #hist == 0 then
    ICON.clock(els, pad + IW / 2, y + 28, 30, COL.fg3)
    txt(els, "Nessun transcript salvato ancora.", pad, y + 56, IW, 18, 12.5, COL.fg2, { align = "center" })
    txt(els, "Appena detti qualcosa, compare qui.", pad, y + 76, IW, 16, 11, COL.fg3, { align = "center" })
    y = y + 108
  else
    local function wordTruncate(s, n)
      s = s:gsub("%s+", " ")
      if #s <= n then return s end
      local cut = s:sub(1, n):gsub("%s+%S*$", "")
      return cut .. " …"
    end
    for i = 1, math.min(3, #hist) do
      local e = hist[i]
      local preview = wordTruncate(tostring(e.text or ""), 170)
      local ch = 108
      hitRect(els, hHoverMap, "copy:" .. i, pad, y, IW, ch, R(14),
        { fill = COL.rowBg, hoverFill = COL.rowHover, stroke = COL.divider, hoverStroke = COL.borderSoft })
      -- barra d'accento (la più recente è piena, le altre sfumano)
      add({ type = "rectangle", action = "fill", fillColor = i == 1 and COL.accent or withA(COL.accent, 0.4),
        roundedRectRadii = { xRadius = 1.5, yRadius = 1.5 }, frame = { x = pad + 9, y = y + 14, w = 3, h = ch - 28 } })
      txt(els, os.date("%d/%m · %H:%M", e.ts), pad + 24, y + 14, 140, 14, 11, COL.fg3, { font = "semi", lb = "clip" })
      -- chip "Copia"
      local cwid, cx0, cy0 = 74, pad + IW - 12 - 74, y + 10
      local c = {}
      c.chipBg = add({ type = "rectangle", action = "fill", fillColor = COL.accentSoft, roundedRectRadii = { xRadius = R(11), yRadius = R(11) },
        frame = { x = cx0, y = cy0, w = cwid, h = 22 } })
      local from = #els + 1
      ICON.copy(els, cx0 + 14, cy0 + 11, 13, COL.accentInk)
      c.copyIcon = {}
      for k = from, #els do c.copyIcon[#c.copyIcon + 1] = k end
      ICON.check(els, cx0 + 14, cy0 + 11, 13, withA(COL.ok, 0), 2.1); c.check = #els
      c.chipText = txt(els, "Copia", cx0 + 26, cy0 + 4, cwid - 30, 15, 11.5, COL.accentInk, { font = "semi", lb = "clip" })
      hCards[i] = c
      txt(els, preview, pad + 24, y + 38, IW - 24 - 16, ch - 46, 12.5, COL.fg, { lb = "wordWrap" })
      y = y + ch + 12
    end
    txt(els, "Clicca un transcript per copiarlo", pad, y + 2, IW, 14, 10.5, COL.fg3, { align = "center" })
    y = y + 20
  end

  local H = y + PSP + 6
  fillShell(els, W, H, "h_drag")

  local sf = hs.screen.mainScreen():frame()
  local fx = sf.x + (sf.w - W) / 2
  local fy = math.max(sf.y, math.min(sf.y + (sf.h - H) / 2, sf.y + sf.h - H))
  local isNew = (historyCanvas == nil)
  if isNew then
    historyCanvas = hs.canvas.new({ x = fx, y = fy, w = W, h = H })
    historyCanvas:level(hs.canvas.windowLevels.overlay)
    historyCanvas:behavior({ "canJoinAllSpaces", "fullScreenAuxiliary" })
    historyCanvas:mouseCallback(historyMouse)
    historyCanvas:replaceElements(els)
    historyCanvas:alpha(0)
    historyCanvas:show()
    panelIn("hisvis", historyCanvas, fx, fy, W, H, 18)
  else
    historyCanvas:frame({ x = fx, y = fy, w = W, h = H })
    historyCanvas:replaceElements(els)
  end
end

openHistory = function() renderHistoryPanel() end

------------------------------------------------------------------------
-- INCOLLA
------------------------------------------------------------------------
local function pasteText(text)
  local prev = config.restoreClipboard and hs.pasteboard.getContents() or nil
  hs.pasteboard.setContents(text)
  hs.eventtap.keyStroke({ "cmd" }, "v", 0)
  if config.restoreClipboard then
    hs.timer.doAfter(0.6, function() if prev ~= nil then hs.pasteboard.setContents(prev) end end)
  end
end

------------------------------------------------------------------------
-- TRASCRIZIONE
------------------------------------------------------------------------
local function cleanupSegments() for _, p in ipairs(segments) do os.remove(p) end; segments = {}; segIndex = 0 end
local transcribeBackup  -- forward: ritrascrive audio salvato di riserva (definita dopo transcribeOne)
local function backupSegments()
  hs.execute("mkdir -p '" .. config.recDir .. "'")
  local stamp = os.date("%Y%m%d-%H%M%S"); local saved = {}
  for i, p in ipairs(segments) do
    if fileSize(p) > 1000 then
      local dest = string.format("%s/rec-%s-%d.wav", config.recDir, stamp, i)
      hs.execute(string.format("cp '%s' '%s'", p, dest)); saved[#saved + 1] = dest
    end
  end
  return saved
end
local function failSaving(msg)
  busy = false
  local saved = backupSegments(); cleanupSegments()
  setStatus("✕ " .. msg)
  if #saved > 0 then
    gwAlert("💾 Audio salvato in\n" .. config.recDir, 6)
    -- la trascrizione è fallita (spesso un intoppo di rete): ritenta in automatico sull'audio salvato
    if config.autoTranscribeRecovered ~= false then
      hs.timer.doAfter(2.0, function() transcribeBackup(saved, "salvato") end)
    end
  end
  hs.timer.doAfter(2.6, hideOverlay)
end
local function transcribeOne(wavPath, cb)
  local key = readKey()
  if not key then cb(false, nil, "Nessuna chiave Groq") return end
  local args = { "-s", "-S", "https://api.groq.com/openai/v1/audio/transcriptions",
    "-H", "Authorization: Bearer " .. key, "-F", "model=" .. config.model,
    "-F", "file=@" .. wavPath, "-F", "response_format=text", "-F", "temperature=0" }
  if config.language then table.insert(args, "-F"); table.insert(args, "language=" .. config.language) end
  local t = hs.task.new(config.curl, function(code, out, err)
    if code ~= 0 then cb(false, nil, "Groq errore " .. tostring(code) .. " " .. trim(err)) else cb(true, trim(out)) end
  end, args)
  t:start()
end
local function transcribeAll(paths, i, acc)
  if i > #paths then
    local text = trim(table.concat(acc, " "))
    if text == "" then failSaving("Nessun testo") return end
    saveHistoryEntry(text)
    busy = false; setStatus("✓  Fatto")
    hs.timer.doAfter(0.30, function() pasteText(text) end)
    hs.timer.doAfter(0.85, hideOverlay); cleanupSegments()
    return
  end
  if #paths > 1 then setStatus(string.format("✍️  Trascrivo… (%d/%d)", i, #paths)) else setStatus("✍️  Trascrivo…") end
  transcribeOne(paths[i], function(ok, text, err)
    if not ok then failSaving(err or "Errore trascrizione") return end
    acc[i] = text; transcribeAll(paths, i + 1, acc)
  end)
end
-- Ritrascrive in background un batch di audio salvato/recuperato (no HUD, no auto-paste).
-- Esito: testo in clipboard + salvato accanto all'audio (.txt) + avviso. Idempotente per batch.
transcribeBackup = function(paths, label)
  if not paths or #paths == 0 then return end
  local key = paths[1] .. "|" .. #paths
  if config.recoveredRetryDone[key] then return end   -- niente loop sugli stessi file
  config.recoveredRetryDone[key] = true
  -- non disturbare una registrazione in corso: rimanda
  if recording or busy then hs.timer.doAfter(20, function() config.recoveredRetryDone[key] = nil; transcribeBackup(paths, label) end); return end
  local acc = {}
  local function step(i)
    if i > #paths then
      local text = trim(table.concat(acc, " "))
      if text == "" then gwAlert("⚠️ Audio " .. (label or "recuperato") .. ": trascrizione non riuscita (resta il file audio)", 6); return end
      saveHistoryEntry(text)
      hs.pasteboard.setContents(text)
      local sidecar = paths[1]:gsub("%-%d+%.wav$", ".txt"):gsub("%.wav$", ".txt")
      local f = io.open(sidecar, "w"); if f then f:write(text); f:close() end
      gwAlert("📝 Audio " .. (label or "recuperato") .. " trascritto → copiato in clipboard\n(salvato anche in " .. config.recDir .. ")", 8)
      return
    end
    transcribeOne(paths[i], function(ok, t)
      acc[i] = ok and t or ""
      step(i + 1)
    end)
  end
  step(1)
end

-- Carica un audio esterno (non registrato dal mic) e lo trascrive con Groq.
-- Flusso indipendente da recording/busy: nessun HUD, esito in clipboard + storico + sidecar .txt.
local uploadBusy = false
function M.transcribeUploaded()
  if uploadBusy then gwAlert("⏳ Trascrizione upload già in corso…", 2); return end
  local ok, path = hs.osascript.applescript(
    'POSIX path of (choose file with prompt "Scegli un audio da trascrivere" of type ' ..
    '{"public.audio", "public.mp3", "mp3", "wav", "m4a", "mp4", "aac", "aiff", "flac", "ogg"})'
  )
  if not ok or not path or trim(path) == "" then return end
  path = trim(path)
  uploadBusy = true
  gwAlert("📤 Carico e trascrivo…\n" .. path:match("([^/]+)$"), 3)
  transcribeOne(path, function(tok, text, err)
    uploadBusy = false
    if not tok or not text or trim(text) == "" then
      gwAlert("✕ Trascrizione fallita: " .. tostring(err or "nessun testo"), 5)
      return
    end
    text = trim(text)
    saveHistoryEntry(text)
    hs.pasteboard.setContents(text)
    hs.execute("mkdir -p '" .. config.recDir .. "'")
    local base = path:match("([^/]+)%.[^./]+$") or path:match("([^/]+)$") or ("upload-" .. os.date("%Y%m%d-%H%M%S"))
    local sidecar = string.format("%s/%s.txt", config.recDir, base)
    local f = io.open(sidecar, "w"); if f then f:write(text); f:close() end
    gwAlert("📝 Trascritto → copiato in clipboard\n(salvato anche in " .. config.recDir .. ")", 6)
  end)
end

local function finalizeAndTranscribe()
  busy = true; stopUITimer()
  ICON.lastDur = elapsed
  Anim.cancel("hud"); animBusy = false
  setProcessingElements("🎙️  Ricevuto")
  if overlay then overlay:alpha(1); overlay:show(); pinOverlay() end
  hs.timer.doAfter(0.25, function()
    local valid = {}
    for _, p in ipairs(segments) do if fileSize(p) > 1000 then valid[#valid + 1] = p end end
    if #valid == 0 then failSaving("Audio vuoto") return end
    setStatus("☁️  Inviato"); transcribeAll(valid, 1, {})
  end)
end

------------------------------------------------------------------------
-- REGISTRAZIONE
------------------------------------------------------------------------
local function onStream(_t, _out, err)
  if err and recording and not paused then
    for m in err:gmatch("RMS_level=(%S+)") do
      local db = tonumber(m)   -- "-inf" (silenzio digitale) → nil
      lastRmsAt = now()
      if db and db == db and ICON.micS and ICON.micS.ph and ICON.micS.ph ~= "live" then ICON.micLive() end    -- primo livello NON -inf: mic vivo
      if db and db > config.silenceDb then
        lastSoundAt = lastRmsAt
        if micWarned then micWarned = false; gwAlert("🎙️ Audio di nuovo ricevuto", 1.5) end
      end
      table.remove(levels, 1); levels[#levels + 1] = mapLevel(db)
    end
  end
  return true
end

-- STATO CONNESSIONE MIC. ICON.micS = { ph = "connect"|"retry"|"fallback"|"live", t0, retried, fb, liveAt, shown }
-- Con AirPods/Bluetooth il mic manda silenzio digitale (-inf) ~1-1,3 s (cambio profilo), poi livelli veri. Fino al primo livello non -inf l'HUD mostra
-- "Mic…" con l'onda che respira; dopo ~2,5 s senza livelli si riavvia UNA volta ffmpeg sullo stesso device; se resta muto e il device e' Bluetooth
-- (e micAutoFallback non e' false) si passa al mic integrato solo per questa registrazione.
function ICON.micLive()
  local mc = ICON.micS
  if not mc or mc.ph == "live" then return end
  mc.ph = "live"; mc.liveAt = now()
  if ICON.micTimer then ICON.micTimer:stop(); ICON.micTimer = nil end
end
function ICON.micLabel(t)             -- testo del timer mentre il mic si connette (nil = mostra il tempo)
  local mc = ICON.micS
  if not mc or not mc.ph or mc.ph == "live" or (t - mc.t0) < 0.35 then return nil end
  mc.shown = true
  return (mc.ph == "retry") and "Mic ↻" or ((mc.ph == "fallback") and "Mac…" or "Mic…")
end
function ICON.micIsBluetooth(name)
  if not name then return false end
  local ok, res = pcall(function()
    for _, d in ipairs(hs.audiodevice.allInputDevices()) do
      if d:name() == name then return d:transportType() == "Bluetooth" end
    end
    return false
  end)
  return ok and res or false
end
local startSegment, stopCurrentSegment
function ICON.micTick()
  local mc = ICON.micS
  if not recording or paused or not mc or not mc.ph or mc.ph == "live" or not segStart then
    if ICON.micTimer then ICON.micTimer:stop(); ICON.micTimer = nil end
    return
  end
  local t = now()
  if mc.restarting then return end
  if mc.ph == "connect" and not mc.retried and t - mc.t0 >= 2.5 then
    mc.retried = true; mc.ph = "retry"; mc.tRetry = t
    ICON.micRestart(nil)
  elseif mc.ph == "retry" and t - mc.tRetry >= 2.5 and not mc.fb and config.micAutoFallback ~= false and ICON.micIsBluetooth(micName) then
    local b = builtinOrFirst()
    if b and b.idx and b.idx ~= config.audioDevice then
      mc.fb = true; mc.ph = "fallback"
      micName = b.name or micName
      gwAlert("🎙️ Il mic Bluetooth non risponde → uso il mic del Mac per questa registrazione", 3.5)
      ICON.micRestart(b.idx)
    end
  end
end
-- riavvia ffmpeg sullo stesso segmento (o su un altro device) senza perdere i segmenti gia' registrati: l'orologio del timer e dell'avviso
-- silenzio NON ripartono da zero
function ICON.micRestart(newDev)
  local mc = ICON.micS
  if not mc or not recTask then return end
  mc.nRestart = (mc.nRestart or 0) + 1
  if mc.nRestart > 3 then return end                        -- tetto: al massimo 3 riavvii di ffmpeg per registrazione
  mc.restarting = true; mc.newDev = newDev
  stopCurrentSegment("restart")
end

-- Avviso "non sto registrando": suono + alert + HUD rosso (resta finché l'audio non torna)
local function warnNoMic(msg)
  micWarned = true
  local snd = hs.sound.getByName("Basso"); if snd then snd:play() end
  gwAlert(msg, 4)
end

-- Guardia (1s): HUD sempre visibile/in cima sullo schermo attivo + controllo silenzio mic
local lastScreenId = nil
local function reassertOverlay(force)
  if not overlay or not mode or dragTap then return end
  local sid = hs.screen.mainScreen():id()
  if (force or sid ~= lastScreenId) and finalFrame and not animBusy then
    lastScreenId = sid
    placeCanvas(finalFrame.w, finalFrame.h)
  end
  if not overlay:isShowing() then overlay:alpha(1); overlay:show(); pinOverlay() end
  if force then overlay:orderAbove(); pinOverlay() end
end
M._reassertOverlay = reassertOverlay
-- prova varianti al volo: M._setBehavior({"canJoinAllSpaces", ...})
function M._setBehavior(list) config.overlayBehavior = list; if overlay then overlay:behavior(list) end end
local function guardTick()
  reassertOverlay(false)
  if settingsCanvas then SET.tapAlive(scrollTap) end
  SET.tapAlive(dragTap)
  if recording and not paused and not micWarned and segStart then
    if now() - math.max(lastSoundAt, segStart) >= config.silenceWarnSec then
      local noData = now() - math.max(lastRmsAt, segStart) >= config.silenceWarnSec
      warnNoMic(string.format("⚠️ Nessun audio dal microfono da %ds\n%s%s",
        config.silenceWarnSec,
        noData and "Il microfono non manda nulla — non sto registrando" or "Solo silenzio — mic mutato o sbagliato?",
        micName and ("\nMic: " .. micName) or ""))
    end
  end
end
local function stopRotTimer() if rotTimer then rotTimer:stop(); rotTimer = nil end end
local rotate
startSegment = function(mode_)
  local mc = ICON.micS
  local p = segPath(segIndex); os.remove(p)
  if mode_ ~= "restart" then segments[#segments + 1] = p end        -- il riavvio riusa lo stesso segmento
  if mode_ == "restart" and mc then lastSoundAt, lastRmsAt, micWarned = mc.t0, mc.t0, false     -- l'avviso "nessun audio" resta ancorato all'avvio
  else lastSoundAt, lastRmsAt, micWarned = now(), now(), false end
  if mode_ == "fresh" then                                          -- partenza / ripresa da pausa: stato di connessione da capo
    ICON.micS = { ph = "connect", t0 = now(), retried = false, fb = false }
    if ICON.micTimer then ICON.micTimer:stop() end
    ICON.micTimer = hs.timer.doEvery(0.25, function() guarded("mic", ICON.micTick) end)
  end
  local args = { "-y", "-f", "avfoundation", "-i", config.audioDevice, "-ac", "1", "-ar", "16000",
    "-af", "asetnsamples=1600:p=0,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level", p }
  -- il callback di uscita puo' scattare DENTRO start() (ffmpeg che muore subito): in quel caso lo si rimanda a dopo, cosi' _onSegmentFinished
  -- non rientra mai in startSegment/start/togglePause (niente ricorsione sincrona)
  local mine
  ICON.starting = true
  mine = hs.task.new(config.ffmpeg, function()
    if ICON.starting then ICON.deadAtStart = true; return end
    M._onSegmentFinished()
  end, onStream, args)
  recTask = mine
  local okS = mine:start()
  ICON.starting = false
  if not okS then gwAlert("❌ ffmpeg non parte"); recTask = nil; ICON.deadAtStart = false; return false end
  if ICON.deadAtStart then
    ICON.deadAtStart = false
    hs.timer.doAfter(0, function() if recTask == mine then M._onSegmentFinished() end end)
  end
  if mode_ ~= "restart" or not segStart then segStart = now() end
  stopRotTimer()
  if config.maxSegmentSec and config.maxSegmentSec > 0 then rotTimer = hs.timer.doAfter(config.maxSegmentSec, function() rotate() end) end
  return true
end
function M._onSegmentFinished()
  recTask = nil
  if intent == "pause" then intent = nil
  elseif intent == "stop" then intent = nil; finalizeAndTranscribe()
  elseif intent == "cancel" then intent = nil; cleanupSegments()
  elseif intent == "rotate" then intent = nil; segIndex = segIndex + 1; startSegment()
  elseif intent == "restart" then
    intent = nil
    local mc = ICON.micS
    if mc then mc.restarting = false; if mc.newDev then config.audioDevice = mc.newDev; mc.newDev = nil end end
    if recording and not paused then startSegment("restart") end
  elseif recording and not paused then
    -- ffmpeg uscito da solo: il microfono non c'è / si è staccato
    warnNoMic("❌ Registrazione interrotta: microfono non disponibile" .. (micName and ("\nMic: " .. micName) or "") ..
      "\nFerma per trascrivere quello che c'è")
  end
end
stopCurrentSegment = function(newIntent)
  stopRotTimer(); intent = newIntent
  if recTask then
    local pid = recTask:pid()
    if pid and pid > 0 then hs.execute(config.kill .. " -INT " .. pid) else recTask:terminate() end
  else
    M._onSegmentFinished()   -- ffmpeg già morto: esegui subito l'intento (stop/cancel/…)
  end
end
rotate = function()
  if not recording or paused then return end
  elapsed = elapsed + (now() - (segStart or now())); segStart = nil; stopCurrentSegment("rotate")
end
local function start()
  recoverOrphans(true); cleanupSegments()
  local dev, fellBack, name = resolveMic()
  config.audioDevice = dev; micName = name
  elapsed = 0; segStart = nil; paused = false; segIndex = 0
  if fellBack then gwAlert("🎙️ Mic salvato non disponibile → uso “" .. (name or dev) .. "”", 3) end
  resetLevels()
  if not startSegment("fresh") then return end
  recording = true; showRecordingHUD()
end
function M.stop()
  if not recording then return end
  recording = false; stopRotTimer()
  ICON.micS = nil; ICON.devSoon(3)
  if paused then finalizeAndTranscribe()
  else elapsed = elapsed + (now() - (segStart or now())); stopCurrentSegment("stop") end
end
function M.cancel()
  if not recording then hideOverlay(); cleanupSegments(); return end
  recording = false; paused = false; busy = false; stopRotTimer(); hideOverlay()
  ICON.micS = nil; ICON.devSoon(3)
  if recTask then stopCurrentSegment("cancel") else cleanupSegments() end
end
function M.togglePause()
  if not recording then return end
  local tp = now()
  if tp - (ICON.pauseAt or -9) < 0.25 then return end      -- antirimbalzo: pausa/riprendi non si ripetono piu' di ~4 volte/s (doppio click, tasto che rimbalza)
  ICON.pauseAt = tp
  if paused then
    paused = false; segIndex = segIndex + 1; startSegment("fresh")
    if mode == "rec" then setRecordingElements(false) end
  else
    paused = true; elapsed = elapsed + (now() - (segStart or now())); segStart = nil
    stopCurrentSegment("pause")
    if mode == "rec" then setRecordingElements(true) end
  end
end

------------------------------------------------------------------------
-- HOTKEY (gesti configurabili)
------------------------------------------------------------------------
local watcher = nil
local function handleDouble(kc, action)
  local t = now(); local last = taps[kc] or 0
  if (t - last) < config.doubleTapSec then taps[kc] = 0; action() else taps[kc] = t end
end

local function matchAction(kc)
  for _, b in ipairs(config.ssBindings) do if b.kc == kc then return "ss", b end end
  for _, b in ipairs(config.pauseBindings) do if b.kc == kc then return "pause", b end end
  return nil
end

startCapture = function(actionKey)
  gwAlert("Premi il tasto per « " .. (actionKey == "ss" and "Avvio / Stop" or "Pausa") .. " »…", 2)
  local tap
  tap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged, hs.eventtap.event.types.keyDown }, function(e)
    local kc, et = e:getKeyCode(), e:getType()
    local mod
    if et == hs.eventtap.event.types.flagsChanged then
      local fn = KEYCODE_MOD[kc]
      if not fn or not e:getFlags()[fn] then return false end   -- aspetta la pressione di un modificatore
      mod = fn
    else
      mod = "key"
    end
    tap:stop()
    local list = (actionKey == "ss") and config.ssBindings or config.pauseBindings
    local dup = false; for _, b in ipairs(list) do if b.kc == kc then dup = true end end
    if not dup then list[#list + 1] = { kc = kc, mod = mod, gesture = (actionKey == "ss" and "double" or "single") } end
    saveBindings(); renderSettings()
    return (mod == "key")
  end)
  tap:start()
end

local function initHotkeys()
  local T = hs.eventtap.event.types
  watcher = hs.eventtap.new({ T.flagsChanged, T.keyDown, T.keyUp }, function(e)
    local kc = e:getKeyCode()
    local act, b = matchAction(kc)
    if not act then return false end
    local et = e:getType()
    local down
    if et == T.flagsChanged then
      local fn = KEYCODE_MOD[kc]; if not fn then return false end
      down = e:getFlags()[fn] == true
    elseif et == T.keyDown then
      if e:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat) == 1 then return b.mod == "key" end
      down = true
    elseif et == T.keyUp then
      down = false
    else return false end
    local g = b.gesture or (act == "ss" and "double" or "single")
    if act == "ss" then
      if g == "hold" then
        if down then if not recording and not busy then start() end elseif recording then M.stop() end
      elseif g == "single" then
        if down and not busy then if recording then M.stop() else start() end end
      else
        if down then
          if recording then if not busy then M.stop() end
          else handleDouble(kc, function() if not busy then start() end end) end
        end
      end
    else
      if down then
        if g == "double" then handleDouble(kc, function() if recording and not busy then M.togglePause() end end)
        elseif recording and not busy then M.togglePause() end
      end
    end
    return (b.mod == "key")
  end)
  watcher:start()
end

------------------------------------------------------------------------
-- AUTO-UPDATE
------------------------------------------------------------------------
local checkUpdate
do   -- (blocco: limite di 200 variabili locali del chunk)
local deferReload
deferReload = function()
  if recording or busy then hs.timer.doAfter(30, deferReload); return end
  hs.reload()
end
-- Auto-update SENZA git: scarica direttamente da GitHub (raw). Funziona anche
-- sui Mac del team che hanno solo il DMG installato (nessun clone, nessun git).
local RAW_BASE     = "https://raw.githubusercontent.com/sasholone/golden-whisper/main"
local VERSION_FILE = os.getenv("HOME") .. "/.config/groq-dictation/version"

local function localVersion()
  local f = io.open(VERSION_FILE, "r"); if not f then return "" end
  local v = f:read("*a") or ""; f:close(); return trim(v)
end
local function writeLocalVersion(v)
  local f = io.open(VERSION_FILE, "w"); if f then f:write(v); f:close() end
end

local function applyUpdate(newVer)
  local dest = os.getenv("HOME") .. "/.hammerspoon/groq_dictation.lua"
  local tmp  = dest .. ".new"
  local t = hs.task.new(config.curl, function(code)
    -- scarica su file temporaneo, poi sostituisci solo se il download è valido
    if code ~= 0 or fileSize(tmp) < 1000 then
      os.remove(tmp); gwAlert("Golden Whisper: download update fallito"); return
    end
    os.rename(tmp, dest)
    writeLocalVersion(newVer)
    gwAlert("⬆️ Golden Whisper aggiornato (" .. newVer .. ") — riavvio appena sei fermo", 4)
    deferReload()
  end, { "-fsSL", RAW_BASE .. "/src/groq_dictation.lua", "-o", tmp })
  t:start()
end
checkUpdate = function(silent)
  local t = hs.task.new(config.curl, function(code, out)
    if code ~= 0 then if not silent then gwAlert("Update: controllo fallito (rete?)") end return end
    local rem = trim(out or "")
    if rem == "" then if not silent then gwAlert("Update: versione remota vuota") end return end
    local loc = localVersion()
    if loc ~= rem then
      if config.autoUpdate then applyUpdate(rem)
      else gwAlert("⬆️ Golden Whisper: update disponibile (" .. rem .. ")", 5) end
    elseif not silent then gwAlert("Golden Whisper è aggiornato ✓ (" .. loc .. ")", 2) end
  end, { "-fsSL", RAW_BASE .. "/VERSION" })
  t:start()
end
end

function M.update() checkUpdate(false) end
-- Ritrascrive a mano l'audio salvato/recuperato che non ha ancora un testo (.txt) accanto.
function M.transcribeRecovered()
  local out = hs.execute("ls -1t '" .. config.recDir .. "'/*.wav 2>/dev/null")
  local groups, order = {}, {}
  for l in (out or ""):gmatch("[^\n]+") do
    local base = l:gsub("%-%d+%.wav$", ""):gsub("%.wav$", "")
    if not groups[base] then groups[base] = {}; order[#order + 1] = base end
    table.insert(groups[base], l)
  end
  local n = 0
  for _, base in ipairs(order) do
    if not hs.fs.attributes(base .. ".txt") then
      table.sort(groups[base])                                   -- seg -1, -2… in ordine
      config.recoveredRetryDone[groups[base][1] .. "|" .. #groups[base]] = nil
      transcribeBackup(groups[base], "recuperato"); n = n + 1
    end
  end
  gwAlert(n == 0 and "Nessun audio da ritrascrivere (già fatti)" or ("📝 Ritrascrivo " .. n .. " audio salvati…"), 3)
end
function M.settings(page)
  if page then
    if page ~= settingsPage then SET.sc = { 0, 0 } end
    settingsPage = page
  end
  openSettings()
end
function M.toggle() if not busy then if recording then M.stop() else start() end end end

-- PREVIEW per verifica estetica (M._preview(orient, isPaused) mostra l'HUD con onda finta, senza registrare)
function M._preview(orient, isPaused)
  config.orientation = orient or "vertical"; paused = isPaused and true or false
  stopUITimer()
  setRecordingElements(paused)
  local I = RECIDX
  I.preview = true
  I.demo = { 0.25, 0.55, 0.85, 0.4, 0.95, 0.3, 0.7, 0.5, 0.65, 0.45, 0.8, 0.35 }
  for i = 1, #I.bars do I.disp[i] = I.demo[i] or 0.5 end
  updateUI()
  overlay:elementAttribute(I.timer, "text", "0:03"); I.lastText = "0:03"
  overlay:alpha(1); overlay:show()
  local f = overlay:frame()
  return string.format("%d,%d,%d,%d", math.floor(f.x), math.floor(f.y), math.floor(f.w), math.floor(f.h))
end
function M._previewEnd() paused = false; recording = false; if overlay then overlay:hide() end; mode = nil; RECIDX = nil end
function M._snap(path)
  local cv = settingsCanvas or overlay
  if not cv then return "no canvas" end
  local f = cv:frame(); local pad = 24
  local img = hs.screen.mainScreen():snapshot(hs.geometry.rect(f.x - pad, f.y - pad, f.w + pad * 2, f.h + pad * 2))
  if not img then return "snapshot nil" end
  img:saveToFile(path); return "saved"
end

function M.init()
  loadSettings()
  -- risolvi il path di ffmpeg: prima quello impacchettato dall'installer (DMG), poi Homebrew/PATH
  if not config.ffmpegExplicit then
    local cands = {
      os.getenv("HOME") .. "/.config/groq-dictation/bin/ffmpeg",
      "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg",
    }
    for _, p in ipairs(cands) do
      if hs.fs.attributes(p, "mode") then config.ffmpeg = p; break end
    end
  end
  hs.execute("mkdir -p '" .. config.workDir .. "' '" .. config.recDir .. "'")
  local recovered = recoverOrphans()
  -- audio di una sessione interrotta → ritrascrivi in automatico (clipboard + .txt), senza disturbare
  if config.autoTranscribeRecovered ~= false and recovered and #recovered > 0 then
    hs.timer.doAfter(2.0, function() transcribeBackup(recovered, "recuperato") end)
  end
  refreshDevices()
  hs.audiodevice.watcher.setCallback(function() ICON.devSoon(1.5) end)
  hs.audiodevice.watcher.start()
  -- segui il tema di sistema quando themeAuto è attivo
  M._appearanceWatcher = hs.distributednotifications.new(function()
    if config.themeMode == "auto" or config.themeAuto then applyTheme(); rebuildHUD() end
  end, "AppleInterfaceThemeChangedNotification")
  M._appearanceWatcher:start()
  initHotkeys()
  -- HUD sempre in cima: guardia periodica + riposizionamento al cambio app/desktop
  if M._guardTimer then M._guardTimer:stop() end
  M._guardTimer = hs.timer.doEvery(1, function() guarded("guard", guardTick) end)
  local function bump() hs.timer.doAfter(0.2, function() reassertOverlay(true) end) end
  if M._appWatcher then M._appWatcher:stop() end
  M._appWatcher = hs.application.watcher.new(function(_n, ev)
    if ev == hs.application.watcher.activated then bump() end
  end)
  M._appWatcher:start()
  if M._spaceWatcher then M._spaceWatcher:stop() end
  M._spaceWatcher = hs.spaces.watcher.new(bump); M._spaceWatcher:start()
  if M._screenWatcher then M._screenWatcher:stop() end
  M._screenWatcher = hs.screen.watcher.new(bump); M._screenWatcher:start()
  -- icona menu bar: apri impostazioni / avvia-ferma senza passare dalla pausa
  if not M._menu then M._menu = hs.menubar.new() end
  if M._menu then
    M._menu:setTitle("🎙️")
    M._menu:setTooltip("Golden Whisper")
    M._menu:setMenu({
      { title = "🎙️  Avvia / Ferma dettatura", fn = function() M.toggle() end },
      { title = "📤  Carica audio…", fn = function() M.transcribeUploaded() end },
      { title = "📝  Trascrivi audio recuperato", fn = function() M.transcribeRecovered() end },
      { title = "📜  Transcript recenti…", fn = function() openHistory() end },
      { title = "📂  Apri cartella recordings/transcript", fn = function() hs.execute("open '" .. config.recDir .. "'") end },
      { title = "⚙️  Impostazioni…", fn = function() openSettings() end },
      { title = "-" },
      { title = "🔄  Ricarica", fn = function() hs.reload() end },
    })
  end
  if config.autoUpdate ~= false then
    hs.timer.doAfter(45, function() checkUpdate(true) end)
    hs.timer.doEvery(config.updateCheckHours * 3600, function() checkUpdate(true) end)
  end
  return M
end

M.config = config
return M
