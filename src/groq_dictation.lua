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
local settingsPage = "general"   -- general | keys
local openHistory, closeHistory, renderHistoryPanel, historyMouse
local historyCanvas
local hHoverMap = {}
local startShadowSlider
local sliderTrackX, sliderTrackW, sliderTrackY, sliderH, sliderKnobIdx, sliderFillIdx, sliderKnobY

------------------------------------------------------------------------
-- PALETTE / STILI  ("clear glass": rampe tonali per famiglia, dark + light)
-- Ogni tema ha: sfondo a due toni (top/bot), testo a 3 livelli, accento a 3 toni
-- (hi/base/lo per i gradienti), bordo + hairline, superfici (riga/hover/track),
-- stati (warn/ok). Tutto derivato da ~9 esadecimali per tema.
------------------------------------------------------------------------
local function hex(h, a)
  h = h:gsub("#", "")
  return { red = tonumber(h:sub(1, 2), 16) / 255, green = tonumber(h:sub(3, 4), 16) / 255,
           blue = tonumber(h:sub(5, 6), 16) / 255, alpha = a or 1 }
end
local function withA(c, a) return { red = c.red, green = c.green, blue = c.blue, alpha = a } end
local function mix(a, b, t)
  local aa, ba = a.alpha or 1, b.alpha or 1
  return { red = a.red + (b.red - a.red) * t, green = a.green + (b.green - a.green) * t,
           blue = a.blue + (b.blue - a.blue) * t, alpha = aa + (ba - aa) * t }
end
local function lighten(c, t) return mix(c, { red = 1, green = 1, blue = 1, alpha = c.alpha or 1 }, t) end
local CLEAR = { red = 0, green = 0, blue = 0, alpha = 0 }

-- d = { top, bot, fg, fg2, acc, hi, lo, on, ink }  (esadecimali)
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
  return T
end

local function family(name, dark, light) return { name = name, dark = theme(dark, true), light = theme(light, false) } end

-- Famiglie. Dark gold = carattere originale (nero caldo + oro); light gold = champagne + oro caldo.
local FAMILIES = {
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
}
local FAMILY_ORDER = { "gold", "mono", "ocean", "violet", "emerald", "rose" }
local COL = FAMILIES.gold.dark

local function scaleFor(preset)
  if preset == "minimal" then return 0.72
  elseif preset == "large" then return 1.2
  else return 1.0 end
end

local function systemIsDark()
  local out = hs.execute("defaults read -g AppleInterfaceStyle 2>/dev/null")
  return (out or ""):find("Dark") ~= nil
end

local function resolveMode()
  local m = config.themeMode
  if m == "auto" then m = systemIsDark() and "dark" or "light" end
  if m ~= "dark" and m ~= "light" then m = "dark" end
  return m
end

local function applyTheme()
  local fam = FAMILIES[config.style] or FAMILIES.gold
  COL = fam[resolveMode()]
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
  if s.shadowOn ~= nil then config.shadowOn = s.shadowOn end
  if s.shadowIntensity then config.shadowIntensity = s.shadowIntensity end
  -- migrazione dai vecchi stili/flag
  if config.style == "goldlight" then config.style = "gold"; if not s.themeMode then config.themeMode = "light" end
  elseif config.style == "monolight" then config.style = "mono"; if not s.themeMode then config.themeMode = "light" end end
  if s.themeAuto and not s.themeMode then config.themeMode = "auto" end
  if s.posX then config.posX = s.posX end
  if s.posY then config.posY = s.posY end
  if #config.ssBindings == 0 then config.ssBindings = { { kc = 61, mod = "alt", gesture = "double" } } end
  if #config.pauseBindings == 0 then config.pauseBindings = { { kc = 60, mod = "shift", gesture = "single" } } end
  config.scale = scaleFor(config.sizePreset)
  applyTheme()
  local rf = io.open(os.getenv("HOME") .. "/.config/groq-dictation/repo_path", "r")
  if rf then local p = rf:read("*a"); rf:close(); p = (p or ""):gsub("%s+$", ""); if p ~= "" then config.repoDir = p end end
end

local function persist(key, value)
  local f = io.open(config.settingsPath, "r"); if not f then return end
  local txt = f:read("*a"); f:close()
  local rhs = (type(value) == "number") and tostring(value) or ('"' .. tostring(value) .. '"')
  local pat = key .. "%s*=%s*[^,\n]+"
  if txt:find(pat) then txt = txt:gsub(pat, key .. " = " .. rhs, 1)
  else txt = txt:gsub("return%s*{", "return {\n  " .. key .. " = " .. rhs .. ",", 1) end
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
  local v = ((db + 50) / 36) ^ 1.15
  if v < 0 then v = 0 elseif v > 1 then v = 1 end
  return v
end
local function nBars() return (config.orientation == "vertical") and 9 or 12 end
local function resetLevels() levels = {}; for _ = 1, nBars() do levels[#levels + 1] = 0 end end

local function recoverOrphans()
  local out = hs.execute("ls -1 '" .. config.workDir .. "'/groq_seg_*.wav 2>/dev/null")
  local files = {}
  for l in (out or ""):gmatch("[^\n]+") do files[#files + 1] = l end
  if #files == 0 then return {} end
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
local function clamp01(t) if t < 0 then return 0 elseif t > 1 then return 1 end return t end
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
  for k, a in pairs(Anim.list) do
    local p = clamp01((t - a.t0) / a.dur)
    pcall(a.fn, a.ease(p), p)
    if p >= 1 then finished[#finished + 1] = k end
  end
  for _, k in ipairs(finished) do
    local a = Anim.list[k]; Anim.list[k] = nil
    if a and a.done then pcall(a.done) end
  end
  if next(Anim.list) == nil and Anim.timer then Anim.timer:stop(); Anim.timer = nil end
end
-- group+key identificano l'animazione: una nuova con stessa chiave sostituisce la vecchia
function Anim.run(group, key, dur, ease, fn, done)
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

-- Font di sistema (SF) con fallback sicuri. Risolti una volta sola.
local FONT = nil
local function fonts()
  if FONT then return FONT end
  -- prende il primo font che esiste E ha davvero il peso richiesto (se il nome di sistema
  -- ricade silenziosamente sul regular, lo scarta e passa al fallback)
  local function pick(c, want)
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
  FONT = {
    reg  = pick({ ".AppleSystemUIFont", "HelveticaNeue" }),
    semi = pick({ ".AppleSystemUIFontDemi", ".AppleSystemUIFontMedium", "HelveticaNeue-Medium" }, { "semibold", "demi", "medium" }),
    bold = pick({ ".AppleSystemUIFontBold", "HelveticaNeue-Bold" }, { "bold", "heavy", "black" }),
    mono = pick({ "SFMono-Semibold", "Menlo-Bold" }, { "mono", "menlo" }),
  }
  return FONT
end

------------------------------------------------------------------------
-- ICONE (primitive canvas, tratto arrotondato coerente; sz = lato nominale)
------------------------------------------------------------------------
local ICON = {}
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

------------------------------------------------------------------------
-- VETRO: ombre multi-strato + corpo traslucido + riflesso + bordo luminoso
-- (hs.canvas non ha blur dello sfondo: la profondità è simulata)
------------------------------------------------------------------------
local NSH = 12       -- elementi d'ombra riservati (8 ambient + 4 contatto)
local NCARD = NSH + 4 -- ombre + corpo + riflesso + highlight + bordo

pushShadow = function(list, x, y, w, h, s, radius, mul)
  if config.shadowOn == false then return end
  local k = config.shadowIntensity or 0.5
  local m = (mul or 1) * (COL.shadowK or 1)
  for i = 1, 8 do                       -- ambient: ampia e morbida
    local e = i * 2.6 * s * k
    list[#list + 1] = { type = "rectangle", action = "fill", fillColor = { red = 0, green = 0, blue = 0, alpha = 0.021 * m },
      roundedRectRadii = { xRadius = radius + e, yRadius = radius + e },
      frame = { x = x - e, y = y - e + 8 * s * k, w = w + 2 * e, h = h + 2 * e } }
  end
  for i = 1, 4 do                       -- contatto: stretta e più scura
    local e = i * 0.9 * s * k
    list[#list + 1] = { type = "rectangle", action = "fill", fillColor = { red = 0, green = 0, blue = 0, alpha = 0.05 * m },
      roundedRectRadii = { xRadius = radius + e, yRadius = radius + e },
      frame = { x = x - e, y = y - e + 2 * s * k + 1, w = w + 2 * e, h = h + 2 * e } }
  end
end

-- Corpo "clear glass". Ritorna (indice bordo, indice corpo).
-- o: { id = "drag", s = scala, shadow = false, shadowMul = n, border = colore, bw = spessore }
pushGlass = function(list, x, y, w, h, r, o)
  o = o or {}
  local s = o.s or 1
  if o.shadow ~= false then pushShadow(list, x, y, w, h, s, r, o.shadowMul) end
  local body = #list + 1
  list[body] = { type = "rectangle", action = "fill", fillColor = COL.bg,
    roundedRectRadii = { xRadius = r, yRadius = r }, frame = { x = x, y = y, w = w, h = h },
    fillGradient = "linear", fillGradientAngle = 90, fillGradientColors = { COL.bg, COL.bg2 },
    trackMouseDown = o.id and true or nil, id = o.id }
  -- riflesso: metà superiore, curva con gli angoli
  local sh = o.sheenH or h * 0.5
  local rr = math.min(r - 1, sh)
  local sp = { { x = x + 1, y = y + sh } }
  for _, p in ipairs(arcPts(x + 1 + rr, y + 1 + rr, rr, 180, 270, 10)) do sp[#sp + 1] = p end
  for _, p in ipairs(arcPts(x + w - 1 - rr, y + 1 + rr, rr, 270, 360, 10)) do sp[#sp + 1] = p end
  sp[#sp + 1] = { x = x + w - 1, y = y + sh }
  list[#list + 1] = { type = "segments", action = "fill", fillColor = withA(COL.sheen, (COL.sheen.alpha or 0.04) * (o.sheenA or 1)),
    closed = true, coordinates = sp }
  -- highlight 1px lungo il bordo alto (luce che entra dall'alto)
  local hl = {}
  for _, p in ipairs(arcPts(x + r, y + r, r - 0.8, 212, 270, 8)) do hl[#hl + 1] = p end
  for _, p in ipairs(arcPts(x + w - r, y + r, r - 0.8, 270, 328, 8)) do hl[#hl + 1] = p end
  seg(list, hl, COL.hi, 1)
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

-- bottone tondo. kind: "primary" (gradiente accento) | "ghost" (vetro con bordo)
-- icon(els, cx, cy) disegna il glifo sopra.
local function circleButton(els, map, id, cx, cy, r, kind, icon, s)
  s = s or 1
  if kind == "primary" then
    els[#els + 1] = { type = "circle", action = "fill", fillColor = COL.accent, center = { x = cx, y = cy }, radius = r,
      fillGradient = "linear", fillGradientAngle = 90, fillGradientColors = { COL.accentHi, COL.accentLo } }
    hitCircle(els, map, id, cx, cy, r, { fill = withA(COL.fgWhite, 0), hoverFill = withA(COL.fgWhite, 0.22) })
  else
    hitCircle(els, map, id, cx, cy, r, { fill = COL.rowBg, hoverFill = COL.accentSoft,
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
    if id == "drag" then startDrag() end
    return
  elseif msg == "mouseUp" then
    if id == "pause" then M.togglePause()
    elseif id == "stop" then M.stop()
    elseif id == "settings" then openSettings()
    elseif id == "cancel" then M.cancel()
    elseif id == "close" then hideOverlay() end
  end
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
    overlay = hs.canvas.new(finalFrame)
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
------------------------------------------------------------------------
setRecordingElements = function(isPaused)
  local s = config.scale
  local function sc(v) return v * s end
  local P = sc(40)   -- margine attorno alla card (ombra + badge)
  local els = {}
  local idx = { bars = {}, disp = {}, last = nil, settled = false, warnPrev = false }
  local function add(el) els[#els + 1] = el; return #els end
  hoverMap = {}
  Anim.cancel("hudhv"); Anim.cancel("hudtip")
  local vertical = (config.orientation == "vertical")
  local pw, ph = vertical and 56 or 296, vertical and 204 or 56
  placeCanvas(sc(pw) + 2 * P, sc(ph) + 2 * P)
  idx.border = pushGlass(els, P, P, sc(pw), sc(ph), sc(28), { s = s, id = "drag" })

  -- badge mic (registrazione) oppure ingranaggio (in pausa: impostazioni/scelta mic)
  local bcx = P + sc(vertical and 28 or 31)
  local bcy = P + sc(vertical and 30 or 28)
  local br = sc(vertical and 16 or 17)
  idx.br = br
  idx.vertical = vertical
  if isPaused then
    circleButton(els, hoverMap, "settings", bcx, bcy, br, "ghost", function(e, cx, cy)
      ICON.gear(e, cx, cy, sc(17), COL.accentInk)
    end, s)
  else
    local ring = { type = "circle", action = "stroke", strokeColor = withA(COL.accent, 0), strokeWidth = sc(1.4),
      center = { x = bcx, y = bcy }, radius = br }
    idx.ring1 = add(ring)
    local ring2 = {}; for k, v in pairs(ring) do ring2[k] = v end
    idx.ring2 = add(ring2)
    idx.badge = add({ type = "circle", action = "strokeAndFill", fillColor = COL.accentSoft,
      strokeColor = withA(COL.accent, 0.55), strokeWidth = sc(1), center = { x = bcx, y = bcy }, radius = br,
      fillGradient = "linear", fillGradientAngle = 90,
      fillGradientColors = { withA(COL.accentHi, 0.34), withA(COL.accentLo, 0.12) } })
    ICON.mic(els, bcx, bcy, sc(16), COL.accentInk)
  end

  -- timer + onda
  local bm
  if vertical then
    idx.timerSize = sc(12)
    idx.timerFrames = { { x = P, y = P + sc(55), w = sc(56), h = sc(18) }, { x = P, y = P + sc(57), w = sc(56), h = sc(18) } }
    idx.timer = txt(els, "0:00", P, P + sc(55), sc(56), sc(18), sc(12), COL.fg, { font = "mono", align = "center", lb = "clip" })
    for i = 1, 9 do
      local yb = P + sc(82 + (i - 1) * 5.6)
      local ei = add({ type = "rectangle", action = "fill", fillColor = withA(COL.accent, 0.5),
        roundedRectRadii = { xRadius = sc(1.6), yRadius = sc(1.6) }, frame = { x = bcx - sc(2.5), y = yb, w = sc(5), h = sc(3.2) } })
      idx.bars[i] = { idx = ei, cx = bcx, y = yb }
    end
    bm = { horizontal = false, s = s, barH = sc(3.2), maxLen = 30 }
  else
    idx.timerSize = sc(17)
    idx.timerFrames = { { x = P + sc(57), y = P + sc(17), w = sc(60), h = sc(24) }, { x = P + sc(57), y = P + sc(21), w = sc(60), h = sc(24) } }
    idx.timer = txt(els, "0:00", P + sc(57), P + sc(17), sc(60), sc(24), sc(17), COL.fg, { font = "mono", lb = "clip" })
    for i = 1, 12 do
      local xb = P + sc(120 + (i - 1) * 6.2)
      local ei = add({ type = "rectangle", action = "fill", fillColor = withA(COL.accent, 0.5),
        roundedRectRadii = { xRadius = sc(1.6), yRadius = sc(1.6) }, frame = { x = xb, y = P + sc(26), w = sc(3.2), h = sc(4) } })
      idx.bars[i] = { idx = ei, x = xb }
    end
    bm = { horizontal = true, s = s, barW = sc(3.2), maxLen = 28, cy = P + sc(28) }
  end
  idx.barMeta = bm

  -- pausa (primario) + stop (vetro)
  local pcx, pcy, scx, scy, brad
  if vertical then pcx, pcy, scx, scy, brad = bcx, P + sc(151), bcx, P + sc(182), sc(13)
  else pcx, pcy, scx, scy, brad = P + sc(224), P + sc(28), P + sc(260), P + sc(28), sc(15) end
  circleButton(els, hoverMap, "pause", pcx, pcy, brad, "primary", function(e, cx, cy)
    (isPaused and ICON.play or ICON.pause)(e, cx, cy, brad * 1.1, COL.accentText)
  end, s)
  circleButton(els, hoverMap, "stop", scx, scy, brad, "ghost", function(e, cx, cy)
    ICON.stop(e, cx, cy, brad * 1.1, COL.accentInk)
  end, s)

  -- annulla: piccolo badge di vetro sul bordo alto-destro
  local kx, ky, kr = P + sc(pw) - sc(8), P + sc(8), sc(9.5)
  pushShadow(els, kx - kr, ky - kr, 2 * kr, 2 * kr, s, kr, 0.35)
  hitCircle(els, hoverMap, "cancel", kx, ky, kr, { fill = COL.solid, hoverFill = mix(COL.solid, COL.warn, 0.25),
    stroke = COL.border, hoverStroke = COL.warn, sw = 1 })
  ICON.close(els, kx, ky, sc(11), COL.fg2, 1.8)

  -- tooltip sintetici sopra la card (solo orizzontale: in verticale non c'è spazio ai lati)
  if not vertical then
    idx.tipBg = add({ type = "rectangle", action = "strokeAndFill", fillColor = withA(COL.solid, 0), strokeColor = withA(COL.border, 0),
      strokeWidth = 1, roundedRectRadii = { xRadius = sc(8), yRadius = sc(8) }, frame = { x = 0, y = 0, w = 1, h = 1 } })
    idx.tipText = txt(els, "", 0, 0, 1, 1, sc(11), withA(COL.fg, 0), { font = "semi", align = "center", lb = "clip" })
    idx.tips = {
      pause = { cx = pcx, label = isPaused and "Riprendi" or "Pausa" },
      stop = { cx = scx, label = "Stop e trascrivi" },
      cancel = { cx = kx - sc(14), label = "Annulla" },
      settings = { cx = bcx, label = "Impostazioni" },
    }
    idx.tipTop = P - sc(30)
    idx.s = s
  end

  overlay:replaceElements(els)
  RECIDX = idx
  PROC = nil
  mode = "rec"
end

------------------------------------------------------------------------
-- HUD elaborazione: spinner a scia (poi check/croce con pop) + testo di stato
------------------------------------------------------------------------
setProcessingElements = function(text)
  local s = config.scale
  local function sc(v) return v * s end
  local P = sc(40)
  hoverMap = {}
  Anim.cancel("hudhv")
  local pw, ph = 236, 52
  placeCanvas(sc(pw) + 2 * P, sc(ph) + 2 * P)
  local els = {}
  local function add(el) els[#els + 1] = el; return #els end
  pushGlass(els, P, P, sc(pw), sc(ph), sc(26), { s = s, id = "drag" })
  local cx, cy = P + sc(28), P + sc(26)
  local pr = { dots = {}, state = "busy" }
  for i = 1, 10 do
    local a = (i - 1) / 10 * 2 * math.pi - math.pi / 2
    pr.dots[i] = add({ type = "circle", action = "fill", fillColor = withA(COL.accent, 0.2),
      center = { x = cx + math.cos(a) * sc(9), y = cy + math.sin(a) * sc(9) }, radius = sc(1.9) })
  end
  pr.okC = add({ type = "circle", action = "fill", fillColor = withA(COL.ok, 0), center = { x = cx, y = cy }, radius = sc(12) })
  ICON.check(els, cx, cy, sc(17), withA(COL.ok, 0), 2.1); pr.okChk = #els
  pr.errC = add({ type = "circle", action = "fill", fillColor = withA(COL.warn, 0), center = { x = cx, y = cy }, radius = sc(12) })
  ICON.close(els, cx, cy, sc(17), withA(COL.warn, 0), 2.1); pr.errX1 = #els - 1; pr.errX2 = #els
  pr.text = txt(els, cleanStatus(text or "…"), P + sc(54), P + sc(16), sc(pw) - sc(54) - sc(22), sc(22), sc(14), COL.fg, { font = "semi" })
  local kx, ky, kr = P + sc(pw) - sc(8), P + sc(8), sc(9.5)
  pushShadow(els, kx - kr, ky - kr, 2 * kr, 2 * kr, s, kr, 0.35)
  hitCircle(els, hoverMap, "close", kx, ky, kr, { fill = COL.solid, hoverFill = mix(COL.solid, COL.accent, 0.22),
    stroke = COL.border, hoverStroke = COL.accent, sw = 1 })
  ICON.close(els, kx, ky, sc(11), COL.fg2, 1.8)
  overlay:replaceElements(els)
  PROC = pr
  RECIDX = nil
  mode = "proc"
  -- lo spinner gira solo finché l'HUD è in "proc" (il timer si ferma con stopUITimer)
  if uiTimer then uiTimer:stop() end
  uiTimer = hs.timer.new(1 / 30, function()
    if not PROC or mode ~= "proc" or not overlay or PROC.state ~= "busy" then return end
    local head = (hs.timer.secondsSinceEpoch() * 1.15) % 1
    for i, d in ipairs(PROC.dots) do
      local delta = (head - (i - 1) / 10) % 1
      overlay:elementAttribute(d, "fillColor", withA(COL.accent, 0.14 + 0.86 * (1 - delta) ^ 2.2))
    end
  end)
  uiTimer:start()
end

setStatus = function(text)
  if not (overlay and mode == "proc" and PROC) then return end
  local pr = PROC
  local kind = "busy"
  if text:find("^✓") then kind = "ok" elseif text:find("^✕") then kind = "err" end
  overlay:elementAttribute(pr.text, "text", cleanStatus(text))
  overlay:elementAttribute(pr.text, "textColor", kind == "err" and COL.warn or COL.fg)
  if kind ~= pr.state then
    pr.state = kind
    if kind ~= "busy" then
      for _, d in ipairs(pr.dots) do overlay:elementAttribute(d, "fillColor", withA(COL.accent, 0)) end
      Anim.run("hud", "result", 0.34, "spring", function(e)
        local a = clamp01(e)
        if kind == "ok" then
          overlay:elementAttribute(pr.okC, "fillColor", withA(COL.ok, 0.20 * a))
          overlay:elementAttribute(pr.okChk, "strokeColor", withA(COL.ok, a))
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
------------------------------------------------------------------------
updateUI = function()
  local I = RECIDX
  if not overlay or mode ~= "rec" or not I then return end
  local t = now()
  local dt = I.last and math.min(0.1, t - I.last) or 0.016
  I.last = t
  local active = ((not paused) and (recording or I.preview)) and true or false
  local warn = (micWarned and recording and not paused) and true or false
  if I.settled and not active then return end

  local text = warn and "NO MIC" or fmtTime(currentElapsed())
  if text ~= I.lastText then overlay:elementAttribute(I.timer, "text", text); I.lastText = text end
  if warn ~= I.warnPrev then
    I.warnPrev = warn
    overlay:elementAttribute(I.timer, "textSize", warn and (I.timerSize * (I.vertical and 0.8 or 0.66)) or I.timerSize)
    overlay:elementAttribute(I.timer, "frame", I.timerFrames[warn and 2 or 1])
    overlay:elementAttribute(I.timer, "textColor", warn and COL.warn or COL.fg)
    if I.badge then overlay:elementAttribute(I.badge, "strokeColor", warn and withA(COL.warn, 0.75) or withA(COL.accent, 0.55)) end
    if warn then shakeHUD() else overlay:elementAttribute(I.border, "strokeColor", COL.border) end
  end
  if warn then overlay:elementAttribute(I.border, "strokeColor", mix(COL.border, COL.warn, 0.55 + 0.45 * math.sin(t * 7))) end

  -- anelli pulsanti dietro al mic
  if I.ring1 then
    local col = warn and COL.warn or COL.accent
    local speed = warn and 1.9 or 0.85
    for k, ri in ipairs({ I.ring1, I.ring2 }) do
      local ph = (t * speed + (k - 1) * 0.5) % 1
      local e = 1 - (1 - ph) ^ 2
      overlay:elementAttribute(ri, "radius", I.br * (1 + 0.55 * e))
      overlay:elementAttribute(ri, "strokeColor", withA(col, active and 0.55 * (1 - ph) ^ 1.6 or 0))
    end
    overlay:elementAttribute(I.badge, "radius", I.br * (1 + (active and 0.035 * math.sin(t * 2 * math.pi * 0.85) or 0)))
  end

  -- onda: i livelli arrivano a 10Hz, qui sono lisciati (attacco rapido, rilascio lento)
  local bm = I.barMeta
  local base = warn and COL.warn or (active and COL.accent or COL.accentDim)
  local n, maxDelta = #I.bars, 0
  for i, b in ipairs(I.bars) do
    local target = 0
    if active and not warn then target = (I.demo and I.demo[i]) or levels[i] or 0 end
    local cur = I.disp[i] or 0
    local rate = (target > cur) and 22 or 6
    cur = cur + (target - cur) * (1 - math.exp(-rate * dt))
    I.disp[i] = cur
    maxDelta = math.max(maxDelta, math.abs(target - cur))
    local lv = cur
    if active and not warn then lv = math.max(lv, 0.06 + 0.05 * math.sin(t * 2.4 + i * 0.8)) end   -- respiro a riposo
    if bm.horizontal then
      local h = (4 + lv * bm.maxLen) * bm.s
      overlay:elementAttribute(b.idx, "frame", { x = b.x, y = bm.cy - h / 2, w = bm.barW, h = h })
    else
      local w = (5 + lv * bm.maxLen) * bm.s
      overlay:elementAttribute(b.idx, "frame", { x = b.cx - w / 2, y = b.y, w = w, h = bm.barH })
    end
    local fade = 0.5 + 0.5 * i / n
    local a = active and ((0.42 + 0.58 * math.min(1, lv * 1.4)) * fade) or 0.8
    overlay:elementAttribute(b.idx, "fillColor", withA(base, a))
  end
  I.settled = (not active) and (maxDelta < 0.004)
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
    overlay:alpha(1 - e)
    overlay:frame({ x = ff.x, y = ff.y + 12 * e, w = ff.w, h = ff.h })
  end, function()
    animBusy = false
    if overlay then overlay:hide(); overlay:alpha(1); if finalFrame then overlay:frame(finalFrame) end end
  end)
end

showRecordingHUD = function()
  setRecordingElements(false)
  showAnimated()
  if uiTimer then uiTimer:stop() end
  uiTimer = hs.timer.new(1 / 45, updateUI); uiTimer:start()
end
stopUITimer = function() if uiTimer then uiTimer:stop(); uiTimer = nil end end
function hideOverlay() stopUITimer(); mode = nil; RECIDX = nil; PROC = nil; hideAnimated() end
rebuildHUD = function() if mode == "rec" then setRecordingElements(paused) end end


------------------------------------------------------------------------
-- PANNELLI (impostazioni + storico): stesso linguaggio vetro dell'HUD
------------------------------------------------------------------------
local SPANEL_W = 340
local HPANEL_W = 380
local PSP = 36                 -- margine attorno al pannello (ombra + bordo non tagliati)
local segPrev, togglePrev = {}, nil   -- memoria per le animazioni (pillola che scivola, interruttore)
local settingsPos = nil        -- posizione scelta trascinando (nil = centrato)
local sliderValIdx

local function placeholder() return { type = "rectangle", action = "fill", fillColor = CLEAR, frame = { x = 0, y = 0, w = 1, h = 1 } } end

-- riempie gli slot riservati in testa (ombra + vetro) una volta nota l'altezza
local function fillShell(els, W, H, dragId)
  local head = {}
  pushGlass(head, PSP, PSP, W - 2 * PSP, H - 2 * PSP, 20, { s = 1, id = dragId, sheenH = 58, sheenA = 0.6, shadowMul = 1.25 })
  for i = 1, NCARD do els[i] = head[i] or placeholder() end
end

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
    fillGradient = "linear", fillGradientAngle = 90, fillGradientColors = { withA(COL.accentHi, 0.30), withA(COL.accentLo, 0.12) } }
  iconFn(els, pad + 14, y + 15, 16, COL.accentInk)
  txt(els, title, pad + 38, y + 5, IW - 38 - 34, 20, 16, COL.fg, { font = "bold" })
  circleButton(els, map, closeId, pad + IW - 12, y + 15, 12, "ghost", function(e, cx, cy) ICON.close(e, cx, cy, 13, COL.fg2, 1.8) end)
  els[#els + 1] = { type = "rectangle", action = "fill", fillColor = COL.divider, frame = { x = pad, y = y + 40, w = IW, h = 1 } }
end

------------------------------------------------------------------------
-- IMPOSTAZIONI
------------------------------------------------------------------------
closeSettings = function()
  local cv = settingsCanvas
  if not cv then return end
  settingsCanvas = nil; settingsPos = nil
  Anim.cancel("sethv"); Anim.cancel("setui"); Anim.cancel("setvis")
  panelOut(cv)
end

startShadowSlider = function()
  if not settingsCanvas or not sliderTrackW then return end
  if dragTap then dragTap:stop(); dragTap = nil end
  local function apply(commit)
    local cv = settingsCanvas; if not cv then return end
    local f = cv:frame()
    local rel = (hs.mouse.absolutePosition().x - f.x - sliderTrackX) / sliderTrackW
    if rel < 0 then rel = 0 elseif rel > 1 then rel = 1 end
    config.shadowIntensity = rel
    cv:elementAttribute(sliderKnobIdx, "center", { x = sliderTrackX + rel * sliderTrackW, y = sliderKnobY })
    cv:elementAttribute(sliderFillIdx, "frame", { x = sliderTrackX, y = sliderTrackY, w = math.max(0.1, rel * sliderTrackW), h = sliderH })
    cv:elementAttribute(sliderValIdx, "text", string.format("%d%%", math.floor(rel * 100 + 0.5)))
    if commit then persist("shadowIntensity", tonumber(string.format("%.2f", rel))); rebuildHUD() end
  end
  dragTap = hs.eventtap.new({ hs.eventtap.event.types.leftMouseDragged, hs.eventtap.event.types.leftMouseUp }, function(e)
    if e:getType() == hs.eventtap.event.types.leftMouseUp then dragTap:stop(); dragTap = nil; apply(true); return false end
    apply(false); return false
  end)
  apply(false)
  dragTap:start()
end

settingsMouse = function(_c, msg, id)
  if msg == "mouseEnter" then hoverTo(settingsCanvas, sHoverMap, "sethv", id, true); return
  elseif msg == "mouseExit" then hoverTo(settingsCanvas, sHoverMap, "sethv", id, false); return
  elseif msg == "mouseDown" then
    if id == "s_drag" then dragCanvas(settingsCanvas, false, function(f) settingsPos = { x = f.x, y = f.y } end)
    elseif id == "shadowslider" then startShadowSlider() end
    return
  elseif msg ~= "mouseUp" then return end
  if not settingsCanvas then return end

  if id == "s_close" then closeSettings(); return end
  if id == "shadowtoggle" then config.shadowOn = not config.shadowOn; persist("shadowOn", config.shadowOn); rebuildHUD(); renderSettings(); return end
  local kind, val = id:match("^(%a+):(.+)$")
  if not kind then return end
  local pageChange = false
  if kind == "tab" then settingsPage = val; pageChange = true
  elseif kind == "mic" then
    local d = settingsDevices[tonumber(val)]
    if d then config.audioDevice = d.idx; config.micName = d.name; persist("micDevice", d.idx); persist("micName", d.name) end
  elseif kind == "size" then config.sizePreset = val; config.scale = scaleFor(val); persist("sizePreset", val); rebuildHUD()
  elseif kind == "orient" then config.orientation = val; persist("orientation", val); resetLevels(); rebuildHUD()
  elseif kind == "style" then config.style = val; persist("style", val); applyTheme(); rebuildHUD()
  elseif kind == "theme" then config.themeMode = val; persist("themeMode", val); applyTheme(); rebuildHUD()
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

renderSettings = function(opts)
  opts = opts or {}
  Anim.cancel("sethv"); Anim.cancel("setui")
  local W = SPANEL_W + 2 * PSP
  local pad = PSP + 20
  local IW = W - 2 * pad
  local els, y = {}, PSP + 20
  sHoverMap = {}
  for i = 1, NCARD do els[i] = placeholder() end     -- slot per ombra + vetro (riempiti a fine layout)
  local function add(el) els[#els + 1] = el; return #els end
  local function box(x, by, w, h)
    add({ type = "rectangle", action = "strokeAndFill", fillColor = COL.rowBg, strokeColor = COL.divider, strokeWidth = 1,
      roundedRectRadii = { xRadius = 12, yRadius = 12 }, frame = { x = x, y = by, w = w, h = h } })
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
    add({ type = "rectangle", action = "fill", fillColor = COL.track, roundedRectRadii = { xRadius = h / 2 - 3, yRadius = h / 2 - 3 },
      frame = { x = x0, y = y0, w = w, h = h } })
    local pillIdx = add({ type = "rectangle", action = "fill", fillColor = COL.accent, roundedRectRadii = { xRadius = ph / 2 - 2, yRadius = ph / 2 - 2 },
      frame = { x = pillX(sel), y = y0 + inset, w = ow, h = ph },
      fillGradient = "linear", fillGradientAngle = 90, fillGradientColors = { COL.accentHi, COL.accentLo } })
    local labels = {}
    for i, opt in ipairs(options) do
      local ox = pillX(i)
      local on = (i == sel)
      hitRect(els, sHoverMap, prefix .. ":" .. opt.val, ox, y0 + inset, ow, ph, ph / 2 - 2,
        { fill = withA(COL.rowHover, 0), hoverFill = on and withA(COL.rowHover, 0) or COL.rowHover })
      local tx, tw = ox, ow
      if opt.icon then
        opt.icon(els, ox + 15, y0 + h / 2, 15, on and COL.accentText or COL.fg2)
        tx, tw = ox + 20, ow - 20
      end
      labels[i] = txt(els, opt.label, tx, y0 + (h - size * 1.25) / 2, tw, size * 1.4, size, on and COL.accentText or COL.fg2,
        { font = "semi", align = "center", lb = "clip" })
    end
    local prev = segPrev[prefix]
    segPrev[prefix] = sel
    if prev and prev ~= sel and prev <= n then
      local fx, tx = pillX(prev), pillX(sel)
      local selCol, unCol = COL.accentText, COL.fg2
      els[pillIdx].frame.x = fx
      els[labels[prev]].textColor = selCol
      els[labels[sel]].textColor = unCol
      Anim.run("setui", "pill:" .. prefix, 0.26, "out", function(e)
        local cv = settingsCanvas; if not cv then return end
        cv:elementAttribute(pillIdx, "frame", { x = lerp(fx, tx, e), y = y0 + inset, w = ow, h = ph })
        cv:elementAttribute(labels[sel], "textColor", lerpC(unCol, selCol, e))
        cv:elementAttribute(labels[prev], "textColor", lerpC(selCol, unCol, e))
      end)
    end
  end

  -- intestazione
  panelHeader(els, sHoverMap, pad, IW, y, "Impostazioni", ICON.gear, "s_close")
  y = y + 56

  segmented("tab", { { label = "Generale", val = "general", icon = ICON.sliders }, { label = "Tasti", val = "keys", icon = ICON.keyboard } },
    settingsPage, { y = y, h = 36, size = 12.5 })
  y = y + 36 + 20

  if settingsPage == "general" then
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
      hitRect(els, sHoverMap, "mic:" .. i, pad + 4, ry, IW - 8, 34, 9, { fill = withA(COL.rowHover, 0), hoverFill = COL.rowHover })
      local rx, rcy = pad + 24, ry + 17
      if cur then
        add({ type = "circle", action = "fill", fillColor = COL.accent, center = { x = rx, y = rcy }, radius = 8.5,
          fillGradient = "linear", fillGradientAngle = 90, fillGradientColors = { COL.accentHi, COL.accentLo } })
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
    y = y + bh + 18

    sec("DIMENSIONE")
    segmented("size", { { label = "Minimal", val = "minimal" }, { label = "Standard", val = "standard" }, { label = "Grande", val = "large" } },
      config.sizePreset, { y = y })
    y = y + 32 + 18

    sec("ORIENTAMENTO")
    segmented("orient", { { label = "Orizzontale", val = "horizontal", icon = ICON.orientH }, { label = "Verticale", val = "vertical", icon = ICON.orientV } },
      config.orientation, { y = y })
    y = y + 32 + 18

    -- STILE: campioni di colore (gradiente della famiglia, nel tema corrente)
    sec("STILE")
    local mode = resolveMode()
    local cw = IW / #FAMILY_ORDER
    for i, key in ipairs(FAMILY_ORDER) do
      local F = FAMILIES[key]; local T = F[mode]
      local cx, cy = pad + (i - 0.5) * cw, y + 18
      local cur = (config.style == key)
      add({ type = "circle", action = "fill", fillColor = T.accent, center = { x = cx, y = cy }, radius = 13,
        fillGradient = "linear", fillGradientAngle = 90, fillGradientColors = { T.accentHi, T.accentLo } })
      hitCircle(els, sHoverMap, "style:" .. key, cx, cy, 17, { fill = CLEAR,
        stroke = cur and T.accent or withA(T.accent, 0), hoverStroke = cur and T.accent or withA(T.accent, 0.6), sw = 2 })
      if cur then ICON.check(els, cx, cy, 14, T.accentText, 2.4) end
      txt(els, F.name, cx - cw / 2, y + 40, cw, 13, 10, cur and COL.fg or COL.fg3, { font = cur and "semi" or "reg", align = "center", lb = "clip" })
    end
    y = y + 62

    sec("TEMA")
    segmented("theme", { { label = "Dark", val = "dark" }, { label = "Light", val = "light" }, { label = "Auto", val = "auto" } },
      config.themeMode, { y = y })
    y = y + 32 + 18

    -- OMBRA: interruttore animato + intensità
    sec("OMBRA")
    local on = config.shadowOn ~= false
    local bh2 = on and 88 or 44
    box(pad, y, IW, bh2)
    hitRect(els, sHoverMap, "shadowtoggle", pad + 4, y + 2, IW - 8, 40, 9, { fill = withA(COL.rowHover, 0), hoverFill = COL.rowHover })
    txt(els, on and "Ombra attiva" or "Ombra disattivata", pad + 16, y + 13, IW - 90, 18, 13, COL.fg, { font = "semi" })
    local tw, th = 42, 24
    local tx0, ty0 = pad + IW - 16 - tw, y + 10
    add({ type = "rectangle", action = "fill", fillColor = COL.track, roundedRectRadii = { xRadius = th / 2, yRadius = th / 2 },
      frame = { x = tx0, y = ty0, w = tw, h = th } })
    local onIdx = add({ type = "rectangle", action = "fill", fillColor = withA(COL.accent, on and 1 or 0),
      roundedRectRadii = { xRadius = th / 2, yRadius = th / 2 }, frame = { x = tx0, y = ty0, w = tw, h = th } })
    local kxOn, kxOff = tx0 + tw - th / 2, tx0 + th / 2
    local knobIdx = add({ type = "circle", action = "strokeAndFill", fillColor = COL.fgWhite, strokeColor = { red = 0, green = 0, blue = 0, alpha = 0.16 },
      strokeWidth = 1, center = { x = on and kxOn or kxOff, y = ty0 + th / 2 }, radius = th / 2 - 2.5 })
    if togglePrev ~= nil and togglePrev ~= on then
      local fromX, toX = on and kxOff or kxOn, on and kxOn or kxOff
      local fromA, toA = on and 0 or 1, on and 1 or 0
      els[knobIdx].center.x = fromX
      els[onIdx].fillColor = withA(COL.accent, fromA)
      Anim.run("setui", "toggle", 0.26, "spring", function(e, p)
        local cv = settingsCanvas; if not cv then return end
        cv:elementAttribute(knobIdx, "center", { x = lerp(fromX, toX, e), y = ty0 + th / 2 })
        cv:elementAttribute(onIdx, "fillColor", withA(COL.accent, lerp(fromA, toA, clamp01(p * 1.4))))
      end)
    end
    togglePrev = on
    if on then
      local sy = y + 44
      add({ type = "rectangle", action = "fill", fillColor = COL.divider, frame = { x = pad + 16, y = sy, w = IW - 32, h = 1 } })
      txt(els, "Intensità", pad + 16, sy + 14, 70, 16, 12, COL.fg2, {})
      local tx, tw2 = pad + 16 + 74, IW - 32 - 74 - 40
      local ty = sy + 22
      sliderTrackX, sliderTrackW, sliderTrackY, sliderH, sliderKnobY = tx, tw2, ty - 2.5, 5, ty
      local k = config.shadowIntensity or 0.5
      add({ type = "rectangle", action = "fill", fillColor = COL.track, roundedRectRadii = { xRadius = 2.5, yRadius = 2.5 },
        frame = { x = tx, y = ty - 2.5, w = tw2, h = 5 } })
      sliderFillIdx = add({ type = "rectangle", action = "fill", fillColor = COL.accent, roundedRectRadii = { xRadius = 2.5, yRadius = 2.5 },
        frame = { x = tx, y = ty - 2.5, w = math.max(0.1, k * tw2), h = 5 } })
      sliderKnobIdx = add({ type = "circle", action = "strokeAndFill", fillColor = COL.fgWhite, strokeColor = { red = 0, green = 0, blue = 0, alpha = 0.2 },
        strokeWidth = 1, center = { x = tx + k * tw2, y = ty }, radius = 8.5 })
      sliderValIdx = txt(els, string.format("%d%%", math.floor(k * 100 + 0.5)), tx + tw2 + 6, sy + 14, 34, 16, 12, COL.fg3, { align = "right", lb = "clip" })
      add({ type = "rectangle", action = "fill", fillColor = CLEAR, frame = { x = tx - 10, y = sy + 6, w = tw2 + 20, h = 32 },
        trackMouseDown = true, id = "shadowslider" })
    end
    y = y + bh2 + 6
  else
    -- TASTI: una card per tasto [tasto] [gesto] [elimina]
    local function bindings(actionKey, list, gestures)
      for i, b in ipairs(list) do
        local rh = 46
        box(pad, y, IW, rh)
        local label = bindLabel(b)
        local cw = math.max(46, (utf8.len(label) or #label) * 8.5 + 22)
        add({ type = "rectangle", action = "strokeAndFill", fillColor = COL.track, strokeColor = COL.divider, strokeWidth = 1,
          roundedRectRadii = { xRadius = 8, yRadius = 8 }, frame = { x = pad + 10, y = y + 9, w = cw, h = 28 } })
        txt(els, label, pad + 10, y + 14, cw, 18, 13, COL.accentInk, { font = "mono", align = "center", lb = "clip" })
        local dcx = pad + IW - 10 - 10
        local gx = pad + 10 + cw + 10
        local gw = dcx - 10 - 8 - gx
        segmented("gest:" .. actionKey .. ":" .. i, gestures, b.gesture, { x = gx, y = y + 10, w = gw, h = 26, size = 10.5, inset = 2 })
        circleButton(els, sHoverMap, "del:" .. actionKey .. ":" .. i, dcx, y + rh / 2, 10, "ghost",
          function(e, cx, cy) ICON.close(e, cx, cy, 12, COL.fg2, 1.8) end)
        y = y + rh + 8
      end
      local ai = hitRect(els, sHoverMap, "add:" .. actionKey, pad, y, IW, 36, 12,
        { fill = withA(COL.accent, 0), hoverFill = COL.accentFaint, stroke = COL.borderSoft, hoverStroke = COL.border })
      els[ai].strokeDashPattern = { 5, 4 }
      ICON.plus(els, pad + IW / 2 - 58, y + 18, 14, COL.accentInk, 1.9)
      txt(els, "Aggiungi tasto", pad + IW / 2 - 44, y + 10, 110, 16, 12.5, COL.accentInk, { font = "semi", lb = "clip" })
      y = y + 36 + 18
    end
    sec("AVVIO / STOP")
    bindings("ss", config.ssBindings, { { label = "2 tap", val = "double" }, { label = "1 tap", val = "single" }, { label = "hold", val = "hold" } })
    sec("PAUSA")
    bindings("pause", config.pauseBindings, { { label = "1 tap", val = "single" }, { label = "2 tap", val = "double" } })
    y = y - 12
  end

  local H = y + PSP + 8
  fillShell(els, W, H, "s_drag")

  local sf = hs.screen.mainScreen():frame()
  local fx, fy
  if settingsPos then fx, fy = settingsPos.x, settingsPos.y
  else fx = sf.x + (sf.w - W) / 2; fy = sf.y + (sf.h - H) / 2 end
  fy = math.max(sf.y, math.min(fy, sf.y + sf.h - H))
  local isNew = (settingsCanvas == nil)
  if isNew then
    settingsCanvas = hs.canvas.new({ x = fx, y = fy, w = W, h = H })
    settingsCanvas:level(hs.canvas.windowLevels.overlay)
    settingsCanvas:behavior({ "canJoinAllSpaces", "fullScreenAuxiliary" })
    settingsCanvas:mouseCallback(settingsMouse)
    settingsCanvas:replaceElements(els)
    settingsCanvas:alpha(0)
    settingsCanvas:show()
    panelIn("setvis", settingsCanvas, fx, fy, W, H, 18)
  else
    settingsCanvas:frame({ x = fx, y = fy, w = W, h = H })
    settingsCanvas:replaceElements(els)
    if opts.page then panelIn("setvis", settingsCanvas, fx, fy, W, H, 8, 0.4) end
  end
end

openSettings = function()
  segPrev = {}; togglePrev = nil
  getAudioDevices(function(list) deviceCache = list; settingsDevices = list; renderSettings() end)
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
      hitRect(els, hHoverMap, "copy:" .. i, pad, y, IW, ch, 14,
        { fill = COL.rowBg, hoverFill = COL.rowHover, stroke = COL.divider, hoverStroke = COL.borderSoft })
      -- barra d'accento (la più recente è piena, le altre sfumano)
      add({ type = "rectangle", action = "fill", fillColor = i == 1 and COL.accent or withA(COL.accent, 0.4),
        roundedRectRadii = { xRadius = 1.5, yRadius = 1.5 }, frame = { x = pad + 9, y = y + 14, w = 3, h = ch - 28 } })
      txt(els, os.date("%d/%m · %H:%M", e.ts), pad + 24, y + 14, 140, 14, 11, COL.fg3, { font = "semi", lb = "clip" })
      -- chip "Copia"
      local cwid, cx0, cy0 = 74, pad + IW - 12 - 74, y + 10
      local c = {}
      c.chipBg = add({ type = "rectangle", action = "fill", fillColor = COL.accentSoft, roundedRectRadii = { xRadius = 11, yRadius = 11 },
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
      if db and db > config.silenceDb then
        lastSoundAt = lastRmsAt
        if micWarned then micWarned = false; gwAlert("🎙️ Audio di nuovo ricevuto", 1.5) end
      end
      table.remove(levels, 1); levels[#levels + 1] = mapLevel(db)
    end
  end
  return true
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
local function startSegment()
  local p = segPath(segIndex); os.remove(p); segments[#segments + 1] = p
  lastSoundAt, lastRmsAt, micWarned = now(), now(), false
  local args = { "-y", "-f", "avfoundation", "-i", config.audioDevice, "-ac", "1", "-ar", "16000",
    "-af", "asetnsamples=1600:p=0,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level", p }
  recTask = hs.task.new(config.ffmpeg, function() M._onSegmentFinished() end, onStream, args)
  if not recTask:start() then gwAlert("❌ ffmpeg non parte"); recTask = nil; return false end
  segStart = now(); stopRotTimer()
  if config.maxSegmentSec and config.maxSegmentSec > 0 then rotTimer = hs.timer.doAfter(config.maxSegmentSec, function() rotate() end) end
  return true
end
function M._onSegmentFinished()
  recTask = nil
  if intent == "pause" then intent = nil
  elseif intent == "stop" then intent = nil; finalizeAndTranscribe()
  elseif intent == "cancel" then intent = nil; cleanupSegments()
  elseif intent == "rotate" then intent = nil; segIndex = segIndex + 1; startSegment()
  elseif recording and not paused then
    -- ffmpeg uscito da solo: il microfono non c'è / si è staccato
    warnNoMic("❌ Registrazione interrotta: microfono non disponibile" .. (micName and ("\nMic: " .. micName) or "") ..
      "\nFerma per trascrivere quello che c'è")
  end
end
local function stopCurrentSegment(newIntent)
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
  recoverOrphans(); cleanupSegments()
  local dev, fellBack, name = resolveMic()
  config.audioDevice = dev; micName = name; refreshDevices()
  elapsed = 0; segStart = nil; paused = false; segIndex = 0
  if fellBack then gwAlert("🎙️ Mic salvato non disponibile → uso “" .. (name or dev) .. "”", 3) end
  resetLevels()
  if not startSegment() then return end
  recording = true; showRecordingHUD()
end
function M.stop()
  if not recording then return end
  recording = false; stopRotTimer()
  if paused then finalizeAndTranscribe()
  else elapsed = elapsed + (now() - (segStart or now())); stopCurrentSegment("stop") end
end
function M.cancel()
  if not recording then hideOverlay(); cleanupSegments(); return end
  recording = false; paused = false; busy = false; stopRotTimer(); hideOverlay()
  if recTask then stopCurrentSegment("cancel") else cleanupSegments() end
end
function M.togglePause()
  if not recording then return end
  if paused then
    paused = false; segIndex = segIndex + 1; startSegment()
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
local function checkUpdate(silent)
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
function M.settings(page) if page then settingsPage = page end openSettings() end
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
  hs.audiodevice.watcher.setCallback(function() refreshDevices() end)
  hs.audiodevice.watcher.start()
  -- segui il tema di sistema quando themeAuto è attivo
  M._appearanceWatcher = hs.distributednotifications.new(function()
    if config.themeMode == "auto" or config.themeAuto then applyTheme(); rebuildHUD() end
  end, "AppleInterfaceThemeChangedNotification")
  M._appearanceWatcher:start()
  initHotkeys()
  -- HUD sempre in cima: guardia periodica + riposizionamento al cambio app/desktop
  if M._guardTimer then M._guardTimer:stop() end
  M._guardTimer = hs.timer.doEvery(1, guardTick)
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
