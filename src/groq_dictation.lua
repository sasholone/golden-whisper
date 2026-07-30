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
  restoreClipboard = false,
  autoUpdate   = true,
  updateCheckHours = 24,
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

local overlay, uiTimer, rotTimer, animTimer, dragTap = nil, nil, nil, nil, nil
local finalFrame, mode, RECIDX = nil, nil, nil
local procTextIdx = nil
local taps = {}
local hoverMap = {}     -- id -> {idx, fill, hoverFill, stroke, hoverStroke}  (overlay)

local placeCanvas, mouseCb, startDrag, pushBadge, pushGear, pushPause, pushPlay, pushShadow
local setRecordingElements, setProcessingElements, setStatus, updateUI
local showAnimated, hideAnimated, showRecordingHUD, stopUITimer
local openSettings, rebuildHUD, renderSettings, settingsMouse, closeSettings, dragCanvas
local startCapture, saveBindings
local settingsCanvas
local settingsDevices = {}
local sHoverMap = {}
local settingsPage = "general"   -- general | keys
local startShadowSlider
local sliderTrackX, sliderTrackW, sliderTrackY, sliderH, sliderKnobIdx, sliderFillIdx, sliderKnobY

------------------------------------------------------------------------
-- PALETTE / STILI
------------------------------------------------------------------------
local function C(r, g, b, a) return { red = r, green = g, blue = b, alpha = a or 1 } end
local function lighten(c, t) return { red = c.red + (1 - c.red) * t, green = c.green + (1 - c.green) * t, blue = c.blue + (1 - c.blue) * t, alpha = 1 } end
local function mix(a, b, t) return { red = a.red * (1 - t) + b.red * t, green = a.green * (1 - t) + b.green * t, blue = a.blue * (1 - t) + b.blue * t, alpha = 1 } end
local function faint(c) return { red = c.red, green = c.green, blue = c.blue, alpha = 0.20 } end
local function variant(bg, accent, fg)
  return { bg = bg, accent = accent, fg = fg, clear = { alpha = 0 },
    bg2 = lighten(bg, (fg.red or fg.white or 1) > 0.5 and 0.06 or -0.0),   -- gradiente sottile
    accentDim = mix(accent, bg, 0.45), accentHover = lighten(accent, 0.30), accentFaint = faint(accent) }
end
local DARK = C(0.05, 0.05, 0.06, 0.97)

-- Famiglie di stile: ognuna con variante dark e light. Primario = accent.
local FAMILIES = {
  gold    = { name = "Gold",    dark = variant(DARK, C(0.83, 0.68, 0.36), C(1, 1, 1)),
                                 light = variant(C(0.99, 0.98, 0.95, 0.98), C(0.66, 0.50, 0.14), C(0.14, 0.12, 0.08)) },
  mono    = { name = "Mono",    dark = variant(DARK, C(0.88, 0.88, 0.90), C(1, 1, 1)),
                                 light = variant(C(0.98, 0.98, 0.99, 0.98), C(0.18, 0.18, 0.22), C(0.10, 0.10, 0.12)) },
  ocean   = { name = "Ocean",   dark = variant(C(0.04, 0.07, 0.12, 0.97), C(0.36, 0.56, 0.98), C(0.95, 0.97, 1)),
                                 light = variant(C(0.95, 0.97, 1, 0.98), C(0.15, 0.40, 0.85), C(0.08, 0.12, 0.20)) },
  violet  = { name = "Violet",  dark = variant(C(0.09, 0.06, 0.14, 0.97), C(0.62, 0.46, 0.96), C(0.97, 0.95, 1)),
                                 light = variant(C(0.97, 0.95, 1, 0.98), C(0.46, 0.30, 0.85), C(0.14, 0.10, 0.20)) },
  emerald = { name = "Emerald", dark = variant(C(0.03, 0.10, 0.08, 0.97), C(0.15, 0.80, 0.56), C(0.94, 1, 0.97)),
                                 light = variant(C(0.94, 1, 0.97, 0.98), C(0.05, 0.60, 0.42), C(0.06, 0.16, 0.12)) },
  rose    = { name = "Rose",    dark = variant(C(0.12, 0.05, 0.08, 0.97), C(0.98, 0.46, 0.56), C(1, 0.96, 0.97)),
                                 light = variant(C(1, 0.95, 0.96, 0.98), C(0.85, 0.25, 0.40), C(0.18, 0.08, 0.10)) },
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

local function applyTheme()
  local fam = FAMILIES[config.style] or FAMILIES.gold
  local mode = config.themeMode
  if mode == "auto" then mode = systemIsDark() and "dark" or "light" end
  if mode ~= "dark" and mode ~= "light" then mode = "dark" end
  COL = fam[mode]
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
  if not ok or type(s) ~= "table" then hs.alert.show("⚠️ settings.lua non valido") return end
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
  local v = (db + 60) / 60
  if v < 0 then v = 0 elseif v > 1 then v = 1 end
  return v
end
local function nBars() return (config.orientation == "vertical") and 9 or 12 end
local function resetLevels() levels = {}; for _ = 1, nBars() do levels[#levels + 1] = 0 end end

local function recoverOrphans()
  local out = hs.execute("ls -1 '" .. config.workDir .. "'/groq_seg_*.wav 2>/dev/null")
  local files = {}
  for l in (out or ""):gmatch("[^\n]+") do files[#files + 1] = l end
  if #files == 0 then return end
  hs.execute("mkdir -p '" .. config.recDir .. "'")
  local stamp = os.date("%Y%m%d-%H%M%S")
  local n = 0
  for i, p in ipairs(files) do
    if fileSize(p) > 1000 then
      n = n + 1
      local dest = string.format("%s/recovered-%s-%d.wav", config.recDir, stamp, i)
      hs.execute(string.format("'%s' -y -i '%s' -c copy '%s' 2>/dev/null || cp '%s' '%s'", config.ffmpeg, p, dest, p, dest))
    end
    os.remove(p)
  end
  if n > 0 then hs.alert.show("💾 Recuperato audio da una sessione interrotta:\n" .. config.recDir, 8) end
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
local function resolveMic()
  if config.micName and #deviceCache > 0 then
    for _, d in ipairs(deviceCache) do if d.name == config.micName then return d.idx, false, d.name end end
    return deviceCache[1].idx, true, deviceCache[1].name
  end
  if #deviceCache > 0 then return deviceCache[1].idx, false, deviceCache[1].name end
  return config.audioDevice or ":0", false, nil
end

------------------------------------------------------------------------
-- HUD
------------------------------------------------------------------------
mouseCb = function(_c, msg, id)
  if msg == "mouseEnter" then
    local h = hoverMap[id]; if h then
      if h.hoverFill then overlay:elementAttribute(h.idx, "fillColor", h.hoverFill) end
      if h.hoverStroke then overlay:elementAttribute(h.idx, "strokeColor", h.hoverStroke) end
    end
    return
  elseif msg == "mouseExit" then
    local h = hoverMap[id]; if h then
      if h.fill then overlay:elementAttribute(h.idx, "fillColor", h.fill) end
      if h.stroke then overlay:elementAttribute(h.idx, "strokeColor", h.stroke) end
    end
    return
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
  local sf = hs.screen.mainScreen():frame()
  local cx, cy
  if config.posX and config.posY then cx, cy = config.posX, config.posY
  else cx = sf.x + sf.w / 2; cy = sf.y + sf.h - 24 - h / 2 end
  local fx = math.max(sf.x, math.min(cx - w / 2, sf.x + sf.w - w))
  local fy = math.max(sf.y, math.min(cy - h / 2, sf.y + sf.h - h))
  finalFrame = { x = math.floor(fx), y = math.floor(fy), w = w, h = h }
  if not overlay then
    overlay = hs.canvas.new(finalFrame)
    overlay:level(hs.canvas.windowLevels.overlay)
    overlay:behavior({ "canJoinAllSpaces", "stationary", "fullScreenAuxiliary" })
    overlay:clickActivating(false)
    overlay:mouseCallback(mouseCb)
  else
    overlay:frame(finalFrame)
  end
end

dragCanvas = function(cv, persistPos)
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

startShadowSlider = function()
  if not settingsCanvas or not sliderTrackW then return end
  if dragTap then dragTap:stop(); dragTap = nil end
  local function apply(commit)
    local f = settingsCanvas:frame()
    local rel = (hs.mouse.absolutePosition().x - f.x - sliderTrackX) / sliderTrackW
    if rel < 0 then rel = 0 elseif rel > 1 then rel = 1 end
    config.shadowIntensity = rel
    settingsCanvas:elementAttribute(sliderKnobIdx, "center", { x = sliderTrackX + rel * sliderTrackW, y = sliderKnobY })
    settingsCanvas:elementAttribute(sliderFillIdx, "frame", { x = sliderTrackX, y = sliderTrackY, w = rel * sliderTrackW, h = sliderH })
    if commit then persist("shadowIntensity", tonumber(string.format("%.2f", rel))); rebuildHUD() end
  end
  dragTap = hs.eventtap.new({ hs.eventtap.event.types.leftMouseDragged, hs.eventtap.event.types.leftMouseUp }, function(e)
    if e:getType() == hs.eventtap.event.types.leftMouseUp then dragTap:stop(); dragTap = nil; apply(true); return false end
    apply(false); return false
  end)
  apply(false)
  dragTap:start()
end

-- ✕ badge (cancel/close) sporgente dall'angolo
pushBadge = function(els, id, cx, cy, s, map)
  local r, a = 10 * s, 3.5 * s
  pushShadow(els, cx - r, cy - r, 2 * r, 2 * r, s, r, 5, 0.03, 2 * s, 1.2 * s)   -- ombrina sotto il badge
  local ci = #els + 1
  els[ci] = { type = "circle", action = "strokeAndFill", fillColor = COL.bg,
    strokeColor = COL.accent, strokeWidth = 1.2 * s, center = { x = cx, y = cy }, radius = r,
    trackMouseUp = true, trackMouseEnterExit = true, id = id }
  els[#els + 1] = { type = "segments", action = "stroke", strokeColor = COL.accent, strokeWidth = 1.7 * s,
    closed = false, coordinates = { { x = cx - a, y = cy - a }, { x = cx + a, y = cy + a } } }
  els[#els + 1] = { type = "segments", action = "stroke", strokeColor = COL.accent, strokeWidth = 1.7 * s,
    closed = false, coordinates = { { x = cx - a, y = cy + a }, { x = cx + a, y = cy - a } } }
  if map then map[id] = { idx = ci, fill = COL.bg, hoverFill = mix(COL.bg, COL.accent, 0.16), stroke = COL.accent, hoverStroke = COL.accentHover } end
end

-- ingranaggio pieno (impostazioni)
pushGear = function(els, cx, cy, r, s, id, map)
  local hit = #els + 1
  els[hit] = { type = "rectangle", action = "fill", fillColor = COL.clear,
    frame = { x = cx - r - 6 * s, y = cy - r - 6 * s, w = (r + 6 * s) * 2, h = (r + 6 * s) * 2 },
    trackMouseUp = true, trackMouseEnterExit = true, id = id }
  local td = 3.4 * s
  for i = 0, 7 do
    local ang = (i / 8) * 2 * math.pi
    local tx = cx + math.cos(ang) * (r + 1 * s)
    local ty = cy + math.sin(ang) * (r + 1 * s)
    els[#els + 1] = { type = "rectangle", action = "fill", fillColor = COL.accent,
      roundedRectRadii = { xRadius = 1 * s, yRadius = 1 * s }, frame = { x = tx - td / 2, y = ty - td / 2, w = td, h = td } }
  end
  local disc = #els + 1
  els[disc] = { type = "circle", action = "fill", fillColor = COL.accent, center = { x = cx, y = cy }, radius = r }
  els[#els + 1] = { type = "circle", action = "fill", fillColor = COL.bg, center = { x = cx, y = cy }, radius = r * 0.36 }
  if map then map[id] = { idx = disc, fill = COL.accent, hoverFill = COL.accentHover } end
end

pushPause = function(els, cx, cy, s, col)
  local bw, bh, gap = 3 * s, 12 * s, 3.5 * s
  els[#els + 1] = { type = "rectangle", action = "fill", fillColor = col, roundedRectRadii = { xRadius = 1 * s, yRadius = 1 * s },
    frame = { x = cx - gap / 2 - bw, y = cy - bh / 2, w = bw, h = bh } }
  els[#els + 1] = { type = "rectangle", action = "fill", fillColor = col, roundedRectRadii = { xRadius = 1 * s, yRadius = 1 * s },
    frame = { x = cx + gap / 2, y = cy - bh / 2, w = bw, h = bh } }
end

pushPlay = function(els, cx, cy, s, col)
  local r = 6 * s
  els[#els + 1] = { type = "segments", action = "fill", fillColor = col, closed = true,
    coordinates = { { x = cx - r * 0.65, y = cy - r }, { x = cx - r * 0.65, y = cy + r }, { x = cx + r, y = cy } } }
end

-- drop shadow disegnato a mano (l'attributo shadow del canvas HS non viene renderizzato):
-- strati concentrici sfumati dietro la card → penumbra morbida.
pushShadow = function(list, x, y, w, h, s, radius, layers, alpha, off, spread)
  if config.shadowOn == false then return end
  local k = config.shadowIntensity or 0.5
  layers = layers or 6; alpha = alpha or 0.035
  off = (off or 5 * s) * k; spread = (spread or 2 * s) * k
  for i = 1, layers do
    local e = i * spread
    list[#list + 1] = { type = "rectangle", action = "fill",
      fillColor = { red = 0, green = 0, blue = 0, alpha = alpha },
      roundedRectRadii = { xRadius = radius + e, yRadius = radius + e },
      frame = { x = x - e, y = y - e + off, w = w + 2 * e, h = h + 2 * e } }
  end
end

local function cardBg(s, x, y, w, h)
  return { type = "rectangle", action = "strokeAndFill", fillColor = COL.bg, strokeColor = COL.accent,
    strokeWidth = 1.2 * s, roundedRectRadii = { xRadius = 14 * s, yRadius = 14 * s },
    frame = { x = x, y = y, w = w, h = h },
    fillGradient = "linear", fillGradientAngle = 90, fillGradientColors = { COL.bg, COL.bg2 or COL.bg },
    trackMouseDown = true, id = "drag" }
end

setRecordingElements = function(isPaused)
  local s = config.scale
  local function sc(v) return v * s end
  local P = sc(40)   -- margine uniforme attorno alla card (spazio per ombra + badge)
  local els, idx = {}, { bars = {} }
  hoverMap = {}
  local function add(el) els[#els + 1] = el; return #els end

  if config.orientation == "vertical" then
    local pw, ph = 52, 180
    local cx = P + sc(pw / 2)
    placeCanvas(sc(pw) + 2 * P, sc(ph) + 2 * P)
    pushShadow(els, P, P, sc(pw), sc(ph), s, 14 * s)
    add(cardBg(s, P, P, sc(pw), sc(ph)))
    if isPaused then
      pushGear(els, cx, P + sc(16), sc(7), s, "settings", hoverMap)
    else
      idx.dot = add({ type = "circle", action = "fill", fillColor = COL.accent, center = { x = cx, y = P + sc(16) }, radius = sc(4.5) })
    end
    idx.timer = add({ type = "text", text = "0:00", textSize = math.floor(12 * s), textColor = COL.fg,
      textFont = "Menlo-Bold", textAlignment = "center", frame = { x = P, y = P + sc(28), w = sc(pw), h = sc(16) } })
    local by, pitch = 48, 7
    for i = 1, 9 do
      local yb = P + sc(by + (i - 1) * pitch)
      local ei = add({ type = "rectangle", action = "fill", fillColor = COL.accent, roundedRectRadii = { xRadius = 2 * s, yRadius = 2 * s },
        frame = { x = cx - sc(3), y = yb, w = sc(6), h = sc(3) } })
      idx.bars[i] = { idx = ei, cx = cx, y = yb }
    end
    idx.barMeta = { horizontal = false, s = s, barH = sc(3), maxLen = 28 }
    local pbi = add({ type = "rectangle", action = "fill", fillColor = COL.accent, roundedRectRadii = { xRadius = 7 * s, yRadius = 7 * s },
      frame = { x = cx - sc(12), y = P + sc(112), w = sc(24), h = sc(24) }, trackMouseUp = true, trackMouseEnterExit = true, id = "pause" })
    hoverMap["pause"] = { idx = pbi, fill = COL.accent, hoverFill = COL.accentHover }
    if isPaused then pushPlay(els, cx, P + sc(124), s, COL.bg) else pushPause(els, cx, P + sc(124), s, COL.bg) end
    local sti = add({ type = "rectangle", action = "strokeAndFill", fillColor = COL.clear, strokeColor = COL.accent,
      strokeWidth = 1.4 * s, roundedRectRadii = { xRadius = 7 * s, yRadius = 7 * s },
      frame = { x = cx - sc(12), y = P + sc(142), w = sc(24), h = sc(24) }, trackMouseUp = true, trackMouseEnterExit = true, id = "stop" })
    hoverMap["stop"] = { idx = sti, fill = COL.clear, hoverFill = COL.accentFaint, stroke = COL.accent, hoverStroke = COL.accentHover }
    add({ type = "rectangle", action = "fill", fillColor = COL.accent, roundedRectRadii = { xRadius = 3 * s, yRadius = 3 * s },
      frame = { x = cx - sc(6), y = P + sc(148), w = sc(12), h = sc(12) } })
    pushBadge(els, "cancel", P + sc(pw), P, s, hoverMap)
  else
    local pw, ph = 276, 54
    placeCanvas(sc(pw) + 2 * P, sc(ph) + 2 * P)
    pushShadow(els, P, P, sc(pw), sc(ph), s, 14 * s)
    add(cardBg(s, P, P, sc(pw), sc(ph)))
    if isPaused then
      pushGear(els, P + sc(22), P + sc(27), sc(8), s, "settings", hoverMap)
    else
      idx.dot = add({ type = "circle", action = "fill", fillColor = COL.accent, center = { x = P + sc(22), y = P + sc(27) }, radius = sc(6) })
    end
    idx.timer = add({ type = "text", text = "0:00", textSize = math.floor(19 * s), textColor = COL.fg,
      textFont = "Menlo-Bold", textAlignment = "left", frame = { x = P + sc(46), y = P + sc(15), w = sc(48), h = sc(26) } })
    local bx, pitch = 100, 7
    for i = 1, 12 do
      local xb = P + sc(bx + (i - 1) * pitch)
      local ei = add({ type = "rectangle", action = "fill", fillColor = COL.accent, roundedRectRadii = { xRadius = 2 * s, yRadius = 2 * s },
        frame = { x = xb, y = P + sc(25), w = sc(3), h = sc(4) } })
      idx.bars[i] = { idx = ei, x = xb }
    end
    idx.barMeta = { horizontal = true, s = s, barW = sc(3), maxLen = 22, cy = P + sc(27) }
    local pbi = add({ type = "rectangle", action = "fill", fillColor = COL.accent, roundedRectRadii = { xRadius = 8 * s, yRadius = 8 * s },
      frame = { x = P + sc(190), y = P + sc(12), w = sc(32), h = sc(30) }, trackMouseUp = true, trackMouseEnterExit = true, id = "pause" })
    hoverMap["pause"] = { idx = pbi, fill = COL.accent, hoverFill = COL.accentHover }
    if isPaused then pushPlay(els, P + sc(206), P + sc(27), s, COL.bg) else pushPause(els, P + sc(206), P + sc(27), s, COL.bg) end
    local sti = add({ type = "rectangle", action = "strokeAndFill", fillColor = COL.clear, strokeColor = COL.accent,
      strokeWidth = 1.4 * s, roundedRectRadii = { xRadius = 8 * s, yRadius = 8 * s },
      frame = { x = P + sc(230), y = P + sc(12), w = sc(32), h = sc(30) }, trackMouseUp = true, trackMouseEnterExit = true, id = "stop" })
    hoverMap["stop"] = { idx = sti, fill = COL.clear, hoverFill = COL.accentFaint, stroke = COL.accent, hoverStroke = COL.accentHover }
    add({ type = "rectangle", action = "fill", fillColor = COL.accent, roundedRectRadii = { xRadius = 3 * s, yRadius = 3 * s },
      frame = { x = P + sc(239), y = P + sc(20), w = sc(14), h = sc(14) } })
    pushBadge(els, "cancel", P + sc(pw), P, s, hoverMap)
  end

  overlay:replaceElements(els)
  RECIDX = idx
  mode = "rec"
end

setProcessingElements = function(text)
  local s = config.scale
  local function sc(v) return v * s end
  local P = sc(40)
  hoverMap = {}
  local pw, ph = 178, 46
  placeCanvas(sc(pw) + 2 * P, sc(ph) + 2 * P)
  local els = {}
  pushShadow(els, P, P, sc(pw), sc(ph), s, 14 * s)
  els[#els + 1] = cardBg(s, P, P, sc(pw), sc(ph))
  els[#els + 1] = { type = "text", text = text or "…", textSize = math.floor(15 * s), textColor = COL.fg,
    textFont = "Menlo-Bold", textAlignment = "center", frame = { x = P + sc(8), y = P + sc(13), w = sc(pw) - sc(24), h = sc(22) } }
  procTextIdx = #els
  pushBadge(els, "close", P + sc(pw), P, s, hoverMap)
  overlay:replaceElements(els)
  mode = "proc"
end

setStatus = function(text)
  if overlay and mode == "proc" and procTextIdx then overlay:elementAttribute(procTextIdx, "text", text) end
end

updateUI = function()
  if not overlay or mode ~= "rec" or not RECIDX then return end
  overlay:elementAttribute(RECIDX.timer, "text", fmtTime(currentElapsed()))
  if RECIDX.dot then
    local a = 0.45 + 0.55 * math.abs(math.sin(now() * 3.2))
    local c = {}
    for k, v in pairs(COL.accent) do c[k] = v end
    c.alpha = a
    overlay:elementAttribute(RECIDX.dot, "fillColor", c)
  end
  local bm = RECIDX.barMeta
  local barCol = (recording and not paused) and COL.accent or COL.accentDim
  for i, b in ipairs(RECIDX.bars) do
    local lv = levels[i] or 0
    local fr
    if bm.horizontal then
      local h = (4 + lv * bm.maxLen) * bm.s
      fr = { x = b.x, y = bm.cy - h / 2, w = bm.barW, h = h }
    else
      local w = (5 + lv * bm.maxLen) * bm.s
      fr = { x = b.cx - w / 2, y = b.y, w = w, h = bm.barH }
    end
    overlay:elementAttribute(b.idx, "fillColor", barCol)
    overlay:elementAttribute(b.idx, "frame", fr)
  end
end

showAnimated = function()
  if not overlay or not finalFrame then return end
  if animTimer then animTimer:stop(); animTimer = nil end
  local f = finalFrame
  overlay:alpha(0); overlay:frame({ x = f.x, y = f.y + 14, w = f.w, h = f.h }); overlay:show()
  local steps, i = 9, 0
  animTimer = hs.timer.doEvery(0.016, function()
    i = i + 1
    local e = 1 - (1 - i / steps) ^ 2
    overlay:alpha(e); overlay:frame({ x = f.x, y = f.y + 14 * (1 - e), w = f.w, h = f.h })
    if i >= steps then animTimer:stop(); animTimer = nil; overlay:alpha(1); overlay:frame(f) end
  end)
end

hideAnimated = function()
  if not overlay or not finalFrame then if overlay then overlay:hide() end return end
  if animTimer then animTimer:stop(); animTimer = nil end
  local f = finalFrame
  local steps, i = 8, 0
  animTimer = hs.timer.doEvery(0.016, function()
    i = i + 1
    local e = (i / steps) ^ 2
    overlay:alpha(1 - e); overlay:frame({ x = f.x, y = f.y + 10 * e, w = f.w, h = f.h })
    if i >= steps then animTimer:stop(); animTimer = nil; overlay:hide(); overlay:alpha(1); overlay:frame(f) end
  end)
end

showRecordingHUD = function()
  setRecordingElements(false)
  showAnimated()
  if uiTimer then uiTimer:stop() end
  uiTimer = hs.timer.new(0.06, updateUI); uiTimer:start()
end
stopUITimer = function() if uiTimer then uiTimer:stop(); uiTimer = nil end end
function hideOverlay() stopUITimer(); mode = nil; RECIDX = nil; hideAnimated() end
rebuildHUD = function() if mode == "rec" then setRecordingElements(paused) end end

------------------------------------------------------------------------
-- MENU IMPOSTAZIONI (canvas, on-brand, trascinabile, con hover)
------------------------------------------------------------------------
local SPANEL_W = 300
local KEYMAP = { opt = { 61, "alt" }, ctrl = { 62, "ctrl" }, cmd = { 54, "cmd" }, shift = { 60, "shift" } }

closeSettings = function() if settingsCanvas then settingsCanvas:delete(); settingsCanvas = nil end end

settingsMouse = function(_c, msg, id)
  if msg == "mouseEnter" then
    local h = sHoverMap[id]; if h and settingsCanvas then
      if h.hoverFill then settingsCanvas:elementAttribute(h.idx, "fillColor", h.hoverFill) end
      if h.hoverStroke then settingsCanvas:elementAttribute(h.idx, "strokeColor", h.hoverStroke) end
    end
    return
  elseif msg == "mouseExit" then
    local h = sHoverMap[id]; if h and settingsCanvas then
      if h.fill then settingsCanvas:elementAttribute(h.idx, "fillColor", h.fill) end
      if h.stroke then settingsCanvas:elementAttribute(h.idx, "strokeColor", h.stroke) end
    end
    return
  elseif msg == "mouseDown" then
    if id == "s_drag" then dragCanvas(settingsCanvas, false)
    elseif id == "shadowslider" then startShadowSlider() end
    return
  elseif msg ~= "mouseUp" then return end

  if id == "s_close" then closeSettings(); return end
  if id == "shadowtoggle" then config.shadowOn = not config.shadowOn; persist("shadowOn", config.shadowOn); rebuildHUD(); renderSettings(); return end
  local kind, val = id:match("^(%a+):(.+)$")
  if not kind then return end
  if kind == "tab" then settingsPage = val
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
  renderSettings()
end

renderSettings = function()
  local SP = 26                       -- margine attorno al pannello (per ombra + bordo non tagliato)
  local W, pad = SPANEL_W + 2 * SP, 16 + SP
  local els, y = {}, 12 + SP
  sHoverMap = {}
  -- riservo gli slot per ombra + sfondo IN TESTA (indici stabili → l'hover non corrompe gli elementi)
  local NSHADOW = 14
  for i = 1, NSHADOW + 1 do els[i] = { type = "rectangle", action = "fill", fillColor = { alpha = 0 }, frame = { x = 0, y = 0, w = 1, h = 1 } } end
  local function add(el) els[#els + 1] = el; return #els end
  local function label(txt)
    add({ type = "text", text = txt, textSize = 10, textColor = COL.accentDim, textFont = "Menlo-Bold",
      textAlignment = "left", frame = { x = pad, y = y, w = W - pad * 2, h = 14 } })
    y = y + 18
  end
  local function segRow(options, current, prefix)
    local n = #options; local gap = 6; local tw = W - pad * 2; local pwid = (tw - (n - 1) * gap) / n
    for i, opt in ipairs(options) do
      local x = pad + (i - 1) * (pwid + gap); local cur = (opt.val == current)
      local ri = add({ type = "rectangle", action = "strokeAndFill", fillColor = cur and COL.accent or COL.clear,
        strokeColor = COL.accent, strokeWidth = 1, roundedRectRadii = { xRadius = 7, yRadius = 7 },
        frame = { x = x, y = y, w = pwid, h = 30 }, trackMouseUp = true, trackMouseEnterExit = true, id = prefix .. ":" .. opt.val })
      sHoverMap[prefix .. ":" .. opt.val] = { idx = ri,
        fill = cur and COL.accent or COL.clear, hoverFill = cur and COL.accentHover or COL.clear,
        stroke = COL.accent, hoverStroke = COL.accentHover }
      add({ type = "text", text = opt.label, textSize = 11, textColor = cur and COL.bg or COL.accent,
        textFont = "Menlo-Bold", textAlignment = "center", frame = { x = x, y = y + 9, w = pwid, h = 16 } })
    end
    y = y + 40
  end
  -- una card per bind: [tasto] a sinistra, [gesto: 2tap/1tap/hold] a destra, [×] elimina
  local function bindings(actionKey, list, gestures)
    local IW = W - pad * 2
    for i, b in ipairs(list) do
      add({ type = "rectangle", action = "strokeAndFill", fillColor = COL.clear, strokeColor = COL.accentDim, strokeWidth = 1,
        roundedRectRadii = { xRadius = 9, yRadius = 9 }, frame = { x = pad, y = y, w = IW, h = 36 } })
      add({ type = "text", text = bindLabel(b), textSize = 13, textColor = COL.accent, textFont = "Menlo-Bold",
        textAlignment = "left", frame = { x = pad + 12, y = y + 10, w = 56, h = 16 } })
      -- × elimina (estremo destro)
      local dcx = pad + IW - 16
      local ci = add({ type = "circle", action = "strokeAndFill", fillColor = COL.bg, strokeColor = COL.accent, strokeWidth = 1,
        center = { x = dcx, y = y + 18 }, radius = 8, trackMouseUp = true, trackMouseEnterExit = true, id = "del:" .. actionKey .. ":" .. i })
      sHoverMap["del:" .. actionKey .. ":" .. i] = { idx = ci, fill = COL.bg, hoverFill = mix(COL.bg, COL.accent, 0.16), stroke = COL.accent, hoverStroke = COL.accentHover }
      add({ type = "segments", action = "stroke", strokeColor = COL.accent, strokeWidth = 1.3, closed = false,
        coordinates = { { x = dcx - 3, y = y + 15 }, { x = dcx + 3, y = y + 21 } } })
      add({ type = "segments", action = "stroke", strokeColor = COL.accent, strokeWidth = 1.3, closed = false,
        coordinates = { { x = dcx - 3, y = y + 21 }, { x = dcx + 3, y = y + 15 } } })
      -- gesti (centro-destra)
      local gx, gx2 = pad + 78, pad + IW - 34
      local n, gap = #gestures, 4
      local pw2 = (gx2 - gx - (n - 1) * gap) / n
      for j, opt in ipairs(gestures) do
        local x = gx + (j - 1) * (pw2 + gap); local curg = (b.gesture == opt.val)
        local ri = add({ type = "rectangle", action = "strokeAndFill", fillColor = curg and COL.accent or COL.clear,
          strokeColor = COL.accent, strokeWidth = 1, roundedRectRadii = { xRadius = 6, yRadius = 6 },
          frame = { x = x, y = y + 5, w = pw2, h = 26 }, trackMouseUp = true, trackMouseEnterExit = true,
          id = "gest:" .. actionKey .. ":" .. i .. ":" .. opt.val })
        sHoverMap["gest:" .. actionKey .. ":" .. i .. ":" .. opt.val] = { idx = ri,
          fill = curg and COL.accent or COL.clear, hoverFill = curg and COL.accentHover or COL.clear,
          stroke = COL.accent, hoverStroke = COL.accentHover }
        add({ type = "text", text = opt.label, textSize = 10, textColor = curg and COL.bg or COL.accent,
          textFont = "Menlo-Bold", textAlignment = "center", frame = { x = x, y = y + 11, w = pw2, h = 13 } })
      end
      y = y + 42
    end
    local ai = add({ type = "rectangle", action = "strokeAndFill", fillColor = COL.clear, strokeColor = COL.accent, strokeWidth = 1,
      roundedRectRadii = { xRadius = 7, yRadius = 7 }, frame = { x = pad, y = y, w = IW, h = 28 },
      trackMouseUp = true, trackMouseEnterExit = true, id = "add:" .. actionKey })
    sHoverMap["add:" .. actionKey] = { idx = ai, fill = COL.clear, hoverFill = COL.accentFaint }
    add({ type = "text", text = "+  aggiungi tasto", textSize = 12, textColor = COL.accent, textFont = "Menlo-Bold",
      textAlignment = "center", frame = { x = pad, y = y + 7, w = IW, h = 16 } })
    y = y + 34
  end

  add({ type = "text", text = "IMPOSTAZIONI", textSize = 13, textColor = COL.accent, textFont = "Menlo-Bold",
    textAlignment = "left", frame = { x = pad, y = y, w = W - pad * 2 - 22, h = 18 } })
  y = y + 30

  -- switcher di tab
  segRow({ { label = "Generale", val = "general" }, { label = "Tasti", val = "keys" } }, settingsPage, "tab")
  y = y + 4

  if settingsPage == "general" then
    label("MICROFONO")
    for i, d in ipairs(settingsDevices) do
      local cur = (d.name == config.micName)
      local ri = add({ type = "rectangle", action = "fill", fillColor = COL.clear,
        frame = { x = pad, y = y, w = W - pad * 2, h = 30 }, trackMouseUp = true, trackMouseEnterExit = true, id = "mic:" .. i })
      sHoverMap["mic:" .. i] = { idx = ri, fill = COL.clear, hoverFill = COL.accentFaint }
      local bx, byy = pad + 2, y + 8
      add({ type = "rectangle", action = "strokeAndFill", fillColor = cur and COL.accent or COL.clear, strokeColor = COL.accent,
        strokeWidth = 1.3, roundedRectRadii = { xRadius = 4, yRadius = 4 }, frame = { x = bx, y = byy, w = 14, h = 14 } })
      if cur then
        add({ type = "segments", action = "stroke", strokeColor = COL.bg, strokeWidth = 1.8, closed = false,
          coordinates = { { x = bx + 3, y = byy + 7 }, { x = bx + 6, y = byy + 10 }, { x = bx + 11, y = byy + 4 } } })
      end
      add({ type = "text", text = d.name, textSize = 12, textColor = cur and COL.accent or COL.fg,
        textFont = "Menlo-Bold", textAlignment = "left", frame = { x = pad + 24, y = y + 8, w = W - pad * 2 - 24, h = 16 } })
      y = y + 34
    end
    y = y + 6

    label("DIMENSIONE")
    segRow({ { label = "Minimal", val = "minimal" }, { label = "Standard", val = "standard" }, { label = "Grande", val = "large" } }, config.sizePreset, "size")
    label("ORIENTAMENTO")
    segRow({ { label = "Orizzontale", val = "horizontal" }, { label = "Verticale", val = "vertical" } }, config.orientation, "orient")
    label("STILE")
    segRow({ { label = "Gold", val = "gold" }, { label = "Mono", val = "mono" } }, config.style, "style")
    segRow({ { label = "Ocean", val = "ocean" }, { label = "Violet", val = "violet" } }, config.style, "style")
    segRow({ { label = "Emerald", val = "emerald" }, { label = "Rose", val = "rose" } }, config.style, "style")
    label("TEMA")
    segRow({ { label = "Dark", val = "dark" }, { label = "Light", val = "light" }, { label = "Auto", val = "auto" } }, config.themeMode, "theme")
    label("OMBRA")
    local swW, swH = 44, 24
    local on = config.shadowOn ~= false
    add({ type = "rectangle", action = "fill", fillColor = on and COL.accent or COL.accentDim,
      roundedRectRadii = { xRadius = swH / 2, yRadius = swH / 2 }, frame = { x = pad, y = y, w = swW, h = swH },
      trackMouseUp = true, id = "shadowtoggle" })
    add({ type = "circle", action = "fill", fillColor = COL.bg,
      center = { x = pad + (on and (swW - swH / 2) or (swH / 2)), y = y + swH / 2 }, radius = swH / 2 - 4 })
    add({ type = "text", text = on and "Ombra attiva" or "Ombra disattivata", textSize = 12, textColor = COL.fg,
      textFont = "Menlo-Bold", textAlignment = "left", frame = { x = pad + swW + 12, y = y + 5, w = W - pad * 2 - swW - 12, h = 16 } })
    y = y + 34
    if on then
      local tx, tw, ty = pad + 4, W - pad * 2 - 8, y + 8
      sliderTrackX, sliderTrackW, sliderTrackY, sliderH, sliderKnobY = tx, tw, ty, 6, ty + 3
      local k = config.shadowIntensity or 0.5
      add({ type = "rectangle", action = "fill", fillColor = COL.accentDim, roundedRectRadii = { xRadius = 3, yRadius = 3 }, frame = { x = tx, y = ty, w = tw, h = 6 } })
      sliderFillIdx = add({ type = "rectangle", action = "fill", fillColor = COL.accent, roundedRectRadii = { xRadius = 3, yRadius = 3 }, frame = { x = tx, y = ty, w = k * tw, h = 6 } })
      sliderKnobIdx = add({ type = "circle", action = "strokeAndFill", fillColor = COL.accent, strokeColor = COL.bg, strokeWidth = 2, center = { x = tx + k * tw, y = ty + 3 }, radius = 9 })
      add({ type = "rectangle", action = "fill", fillColor = COL.clear, frame = { x = tx - 10, y = y, w = tw + 20, h = 24 }, trackMouseDown = true, id = "shadowslider" })
      y = y + 30
    end
  else
    label("AVVIO / STOP")
    bindings("ss", config.ssBindings, { { label = "2 tap", val = "double" }, { label = "1 tap", val = "single" }, { label = "hold", val = "hold" } })
    label("PAUSA")
    bindings("pause", config.pauseBindings, { { label = "1 tap", val = "single" }, { label = "2 tap", val = "double" } })
  end

  local H = y + SP + 4
  -- riempio gli slot riservati: ombra sfumata + sfondo
  local head = {}
  pushShadow(head, SP, SP, W - 2 * SP, H - 2 * SP, 1, 16, NSHADOW, 0.02, 6, 1.1)
  head[#head + 1] = { type = "rectangle", action = "strokeAndFill", fillColor = COL.bg, strokeColor = COL.accent,
    strokeWidth = 1.5, roundedRectRadii = { xRadius = 16, yRadius = 16 },
    frame = { x = SP, y = SP, w = W - 2 * SP, h = H - 2 * SP },
    fillGradient = "linear", fillGradientAngle = 90, fillGradientColors = { COL.bg, COL.bg2 or COL.bg },
    trackMouseDown = true, id = "s_drag" }
  for i = 1, NSHADOW + 1 do els[i] = head[i] or { type = "rectangle", action = "fill", fillColor = { alpha = 0 }, frame = { x = 0, y = 0, w = 1, h = 1 } } end
  local cbi = add({ type = "circle", action = "strokeAndFill", fillColor = COL.bg, strokeColor = COL.accent, strokeWidth = 1.2,
    center = { x = W - SP - 22, y = SP + 24 }, radius = 11, trackMouseUp = true, trackMouseEnterExit = true, id = "s_close" })
  sHoverMap["s_close"] = { idx = cbi, fill = COL.bg, hoverFill = mix(COL.bg, COL.accent, 0.16), stroke = COL.accent, hoverStroke = COL.accentHover }
  add({ type = "segments", action = "stroke", strokeColor = COL.accent, strokeWidth = 1.7, closed = false,
    coordinates = { { x = W - SP - 26, y = SP + 20 }, { x = W - SP - 18, y = SP + 28 } } })
  add({ type = "segments", action = "stroke", strokeColor = COL.accent, strokeWidth = 1.7, closed = false,
    coordinates = { { x = W - SP - 26, y = SP + 28 }, { x = W - SP - 18, y = SP + 20 } } })

  local sf = hs.screen.mainScreen():frame()
  local fx = sf.x + (sf.w - W) / 2
  local fy = sf.y + (sf.h - H) / 2
  if settingsCanvas then settingsCanvas:delete() end
  settingsCanvas = hs.canvas.new({ x = fx, y = fy, w = W, h = H })
  settingsCanvas:level(hs.canvas.windowLevels.overlay)
  settingsCanvas:behavior({ "canJoinAllSpaces", "fullScreenAuxiliary" })
  settingsCanvas:replaceElements(els)
  settingsCanvas:mouseCallback(settingsMouse)
  settingsCanvas:show()
end

openSettings = function()
  getAudioDevices(function(list) deviceCache = list; settingsDevices = list; renderSettings() end)
end

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
local function backupSegments()
  hs.execute("mkdir -p '" .. config.recDir .. "'")
  local stamp = os.date("%Y%m%d-%H%M%S"); local n = 0
  for i, p in ipairs(segments) do
    if fileSize(p) > 1000 then hs.execute(string.format("cp '%s' '%s/rec-%s-%d.wav'", p, config.recDir, stamp, i)); n = n + 1 end
  end
  return n
end
local function failSaving(msg)
  busy = false
  local n = backupSegments(); cleanupSegments()
  setStatus("✕ " .. msg)
  if n > 0 then hs.alert.show("💾 Audio salvato in\n" .. config.recDir, 6) end
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
local function finalizeAndTranscribe()
  busy = true; stopUITimer()
  if animTimer then animTimer:stop(); animTimer = nil end
  setProcessingElements("🎙️  Ricevuto")
  if overlay then overlay:alpha(1); overlay:show() end
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
    for m in err:gmatch("RMS_level=(%S+)") do table.remove(levels, 1); levels[#levels + 1] = mapLevel(tonumber(m)) end
  end
  return true
end
local function stopRotTimer() if rotTimer then rotTimer:stop(); rotTimer = nil end end
local rotate
local function startSegment()
  local p = segPath(segIndex); os.remove(p); segments[#segments + 1] = p
  local args = { "-y", "-f", "avfoundation", "-i", config.audioDevice, "-ac", "1", "-ar", "16000",
    "-af", "asetnsamples=1600:p=0,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level", p }
  recTask = hs.task.new(config.ffmpeg, function() M._onSegmentFinished() end, onStream, args)
  if not recTask:start() then hs.alert.show("❌ ffmpeg non parte"); recTask = nil; return false end
  segStart = now(); stopRotTimer()
  if config.maxSegmentSec and config.maxSegmentSec > 0 then rotTimer = hs.timer.doAfter(config.maxSegmentSec, function() rotate() end) end
  return true
end
function M._onSegmentFinished()
  recTask = nil
  if intent == "pause" then intent = nil
  elseif intent == "stop" then intent = nil; finalizeAndTranscribe()
  elseif intent == "cancel" then intent = nil; cleanupSegments()
  elseif intent == "rotate" then intent = nil; segIndex = segIndex + 1; startSegment() end
end
local function stopCurrentSegment(newIntent)
  stopRotTimer(); intent = newIntent
  if recTask then
    local pid = recTask:pid()
    if pid and pid > 0 then hs.execute(config.kill .. " -INT " .. pid) else recTask:terminate() end
  end
end
rotate = function()
  if not recording or paused then return end
  elapsed = elapsed + (now() - (segStart or now())); segStart = nil; stopCurrentSegment("rotate")
end
local function start()
  recoverOrphans(); cleanupSegments()
  local dev, fellBack, name = resolveMic()
  config.audioDevice = dev; refreshDevices()
  elapsed = 0; segStart = nil; paused = false; segIndex = 0
  if fellBack then hs.alert.show("🎙️ Mic salvato non disponibile → uso “" .. (name or dev) .. "”", 3) end
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
  hs.alert.show("Premi il tasto per « " .. (actionKey == "ss" and "Avvio / Stop" or "Pausa") .. " »…", 2)
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
      os.remove(tmp); hs.alert.show("Golden Whisper: download update fallito"); return
    end
    os.rename(tmp, dest)
    writeLocalVersion(newVer)
    hs.alert.show("⬆️ Golden Whisper aggiornato (" .. newVer .. ") — riavvio appena sei fermo", 4)
    deferReload()
  end, { "-fsSL", RAW_BASE .. "/src/groq_dictation.lua", "-o", tmp })
  t:start()
end
local function checkUpdate(silent)
  local t = hs.task.new(config.curl, function(code, out)
    if code ~= 0 then if not silent then hs.alert.show("Update: controllo fallito (rete?)") end return end
    local rem = trim(out or "")
    if rem == "" then if not silent then hs.alert.show("Update: versione remota vuota") end return end
    local loc = localVersion()
    if loc ~= rem then
      if config.autoUpdate then applyUpdate(rem)
      else hs.alert.show("⬆️ Golden Whisper: update disponibile (" .. rem .. ")", 5) end
    elseif not silent then hs.alert.show("Golden Whisper è aggiornato ✓ (" .. loc .. ")", 2) end
  end, { "-fsSL", RAW_BASE .. "/VERSION" })
  t:start()
end

function M.update() checkUpdate(false) end
function M.settings(page) if page then settingsPage = page end openSettings() end
function M.toggle() if not busy then if recording then M.stop() else start() end end end

-- PREVIEW per verifica estetica
function M._preview(orient, isPaused)
  config.orientation = orient or "vertical"; paused = isPaused and true or false
  setRecordingElements(paused)
  if RECIDX and RECIDX.timer then overlay:elementAttribute(RECIDX.timer, "text", "0:03") end
  local demo = { 0.25, 0.55, 0.85, 0.4, 0.95, 0.3, 0.7, 0.5, 0.65, 0.45, 0.8, 0.35 }
  local bm = RECIDX.barMeta
  for i, b in ipairs(RECIDX.bars) do
    local lv = demo[i] or 0.5
    if bm.horizontal then local h = (4 + lv * bm.maxLen) * bm.s; overlay:elementAttribute(b.idx, "frame", { x = b.x, y = bm.cy - h / 2, w = bm.barW, h = h })
    else local w = (5 + lv * bm.maxLen) * bm.s; overlay:elementAttribute(b.idx, "frame", { x = b.cx - w / 2, y = b.y, w = w, h = bm.barH }) end
  end
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
  recoverOrphans()
  refreshDevices()
  hs.audiodevice.watcher.setCallback(function() refreshDevices() end)
  hs.audiodevice.watcher.start()
  -- segui il tema di sistema quando themeAuto è attivo
  M._appearanceWatcher = hs.distributednotifications.new(function()
    if config.themeAuto then applyTheme(); rebuildHUD() end
  end, "AppleInterfaceThemeChangedNotification")
  M._appearanceWatcher:start()
  initHotkeys()
  -- icona menu bar: apri impostazioni / avvia-ferma senza passare dalla pausa
  if not M._menu then M._menu = hs.menubar.new() end
  if M._menu then
    M._menu:setTitle("🎙️")
    M._menu:setTooltip("Golden Whisper")
    M._menu:setMenu({
      { title = "🎙️  Avvia / Ferma dettatura", fn = function() M.toggle() end },
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
