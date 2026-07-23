-- groq_dictation.lua  (Golden Whisper)
-- Dettatura vocale stile Whisper Flow per macOS.
-- START = doppio tap Option dx (o Ctrl dx) | STOP = un tap | PAUSA = un tap Shift dx.
-- Registra (ffmpeg) -> Groq Whisper -> incolla al cursore (+ resta in clipboard).
-- HUD trascinabile (black/white/gold), orizzontale o verticale, con sizing e menu impostazioni.
-- Robustezza: auto-spezza l'audio (limite Groq ~25MB) e trascrive a pezzi; audio mai perso.

local M = {}

------------------------------------------------------------------------
-- CONFIG default (sovrascrivibile da settings.lua)
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
  startStopKeycode = 61, startStopFlag = "alt",
  pauseKeycode     = 60, pauseFlag     = "shift",
  doubleTapSec = 0.50,
  maxSegmentSec = 480,
  restoreClipboard = false,
  autoUpdate   = true,
  updateCheckHours = 24,
  git          = "/usr/bin/git",
  repoDir      = os.getenv("HOME") .. "/golden-whisper",
  sizePreset   = "standard",     -- standard | large | minimal
  orientation  = "horizontal",   -- horizontal | vertical
  style        = "gold",         -- gold | mono (WIP)
  scale        = 1.0,
  -- posX / posY (centro della card) impostati dal drag
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

-- forward decl (funzioni HUD mutuamente referenziate)
local placeCanvas, mouseCb, startDrag, pushBadge
local setRecordingElements, setProcessingElements, setStatus, updateUI
local showAnimated, hideAnimated, showRecordingHUD, stopUITimer
local openSettings, rebuildHUD, renderSettings, settingsMouse, closeSettings
local settingsCanvas
local settingsDevices = {}

------------------------------------------------------------------------
-- PALETTE
------------------------------------------------------------------------
local PALETTES = {
  gold = { bg = { red = 0.05, green = 0.05, blue = 0.06, alpha = 0.97 },
           accent = { red = 0.83, green = 0.68, blue = 0.36 },
           accentDim = { red = 0.48, green = 0.40, blue = 0.23 },
           white = { white = 0.97 }, clear = { alpha = 0 } },
  mono = { bg = { red = 0.06, green = 0.06, blue = 0.07, alpha = 0.97 },
           accent = { white = 0.86 }, accentDim = { white = 0.42 },
           white = { white = 0.98 }, clear = { alpha = 0 } },
}
local COL = PALETTES.gold

local IMG = {
  mic   = hs.image.imageFromName("NSTouchBarAudioInputTemplate"),
  pause = hs.image.imageFromName("NSTouchBarPauseTemplate"),
  play  = hs.image.imageFromName("NSTouchBarPlayTemplate"),
}

local function scaleFor(preset)
  if preset == "minimal" then return 0.72
  elseif preset == "large" then return 1.2
  else return 1.0 end
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
  if s.startStopKeycode then config.startStopKeycode = s.startStopKeycode end
  if s.startStopFlag    then config.startStopFlag = s.startStopFlag end
  if s.pauseKeycode     then config.pauseKeycode = s.pauseKeycode end
  if s.pauseFlag        then config.pauseFlag = s.pauseFlag end
  if s.doubleTapSec     then config.doubleTapSec = s.doubleTapSec end
  if s.maxSegmentSec    then config.maxSegmentSec = s.maxSegmentSec end
  if s.restoreClipboard ~= nil then config.restoreClipboard = s.restoreClipboard end
  if s.autoUpdate ~= nil then config.autoUpdate = s.autoUpdate end
  if s.repoDir then config.repoDir = s.repoDir end
  if s.sizePreset  then config.sizePreset = s.sizePreset end
  if s.orientation then config.orientation = s.orientation end
  if s.style       then config.style = s.style end
  if s.posX then config.posX = s.posX end
  if s.posY then config.posY = s.posY end
  config.scale = scaleFor(config.sizePreset)
  COL = PALETTES[config.style] or PALETTES.gold
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

local function fmtTime(t)
  local m = math.floor(t / 60); local s = math.floor(t % 60)
  return string.format("%d:%02d", m, s)
end

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

local function resetLevels()
  levels = {}
  for _ = 1, nBars() do levels[#levels + 1] = 0 end
end

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
      hs.execute(string.format("'%s' -y -i '%s' -c copy '%s' 2>/dev/null || cp '%s' '%s'",
        config.ffmpeg, p, dest, p, dest))
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

-- ritorna: idx, fellBack(bool), name
local function resolveMic()
  if config.micName and #deviceCache > 0 then
    for _, d in ipairs(deviceCache) do
      if d.name == config.micName then return d.idx, false, d.name end
    end
    return deviceCache[1].idx, true, deviceCache[1].name
  end
  if #deviceCache > 0 then return deviceCache[1].idx, false, deviceCache[1].name end
  return config.audioDevice or ":0", false, nil
end

------------------------------------------------------------------------
-- HUD
------------------------------------------------------------------------
mouseCb = function(_c, msg, id)
  if msg == "mouseDown" and id == "drag" then startDrag() return end
  if msg ~= "mouseUp" then return end
  if id == "pause" then M.togglePause()
  elseif id == "stop" then M.stop()
  elseif id == "settings" then openSettings()
  elseif id == "cancel" then M.cancel()
  elseif id == "close" then hideOverlay() end
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
    overlay:behavior({ "canJoinAllSpaces", "stationary" })
    overlay:clickActivating(false)
    overlay:mouseCallback(mouseCb)
  else
    overlay:frame(finalFrame)
  end
end

local function dragCanvas(cv, persistPos)
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

-- badge ✕ sporgente dall'angolo (✕ = due linee incrociate, centrata)
pushBadge = function(els, id, cx, cy, s)
  local r, a = 10 * s, 3.5 * s
  els[#els + 1] = { type = "circle", action = "strokeAndFill", fillColor = COL.bg,
    strokeColor = COL.accent, strokeWidth = 1.2 * s, center = { x = cx, y = cy }, radius = r,
    trackMouseUp = true, id = id }
  els[#els + 1] = { type = "segments", action = "stroke", strokeColor = COL.accent, strokeWidth = 1.7 * s,
    closed = false, coordinates = { { x = cx - a, y = cy - a }, { x = cx + a, y = cy + a } } }
  els[#els + 1] = { type = "segments", action = "stroke", strokeColor = COL.accent, strokeWidth = 1.7 * s,
    closed = false, coordinates = { { x = cx - a, y = cy + a }, { x = cx + a, y = cy - a } } }
end

setRecordingElements = function(isPaused)
  local s = config.scale
  local function sc(v) return v * s end
  local els, idx = {}, { bars = {} }
  local function add(el) els[#els + 1] = el; return #els end
  local MTp = sc(10)

  if config.orientation == "vertical" then
    local pw, ph = 56, 214
    local cx = sc(pw / 2)
    placeCanvas(sc(pw) + sc(10), sc(ph) + MTp)
    add({ type = "rectangle", action = "strokeAndFill", fillColor = COL.bg, strokeColor = COL.accent,
      strokeWidth = 1.2 * s, roundedRectRadii = { xRadius = 14 * s, yRadius = 14 * s },
      frame = { x = 0, y = MTp, w = sc(pw), h = sc(ph) }, trackMouseDown = true, id = "drag" })
    if isPaused then
      idx.mic = add({ type = "rectangle", action = "fill", fillColor = COL.accent,
        roundedRectRadii = { xRadius = 7 * s, yRadius = 7 * s },
        frame = { x = cx - sc(14), y = MTp + sc(6), w = sc(28), h = sc(24) }, trackMouseUp = true, id = "settings" })
      add({ type = "image", image = IMG.mic, imageScaling = "scaleProportionally",
        frame = { x = cx - sc(9), y = MTp + sc(8), w = sc(18), h = sc(20) } })
    else
      idx.dot = add({ type = "circle", action = "fill", fillColor = COL.accent,
        center = { x = cx, y = MTp + sc(18) }, radius = sc(5) })
    end
    idx.timer = add({ type = "text", text = "0:00", textSize = math.floor(13 * s), textColor = COL.white,
      textFont = "Menlo-Bold", textAlignment = "center", frame = { x = 0, y = MTp + sc(34), w = sc(pw), h = sc(18) } })
    local by, pitch = 54, 8
    for i = 1, 9 do
      local yb = MTp + sc(by + (i - 1) * pitch)
      local ei = add({ type = "rectangle", action = "fill", fillColor = COL.accent,
        roundedRectRadii = { xRadius = 2 * s, yRadius = 2 * s }, frame = { x = cx - sc(3), y = yb, w = sc(6), h = sc(3) } })
      idx.bars[i] = { idx = ei, cx = cx, y = yb }
    end
    idx.barMeta = { horizontal = false, s = s, barH = sc(3), maxLen = 30 }
    add({ type = "rectangle", action = "fill", fillColor = COL.accent, roundedRectRadii = { xRadius = 8 * s, yRadius = 8 * s },
      frame = { x = cx - sc(15), y = MTp + sc(140), w = sc(30), h = sc(28) }, trackMouseUp = true, id = "pause" })
    add({ type = "image", image = isPaused and IMG.play or IMG.pause, imageScaling = "scaleProportionally",
      frame = { x = cx - sc(9), y = MTp + sc(145), w = sc(18), h = sc(18) } })
    add({ type = "rectangle", action = "strokeAndFill", fillColor = COL.clear, strokeColor = COL.accent,
      strokeWidth = 1.4 * s, roundedRectRadii = { xRadius = 8 * s, yRadius = 8 * s },
      frame = { x = cx - sc(15), y = MTp + sc(172), w = sc(30), h = sc(28) }, trackMouseUp = true, id = "stop" })
    add({ type = "rectangle", action = "fill", fillColor = COL.accent, roundedRectRadii = { xRadius = 3 * s, yRadius = 3 * s },
      frame = { x = cx - sc(7), y = MTp + sc(179), w = sc(14), h = sc(14) } })
    pushBadge(els, "cancel", sc(pw), MTp, s)
  else
    local pw, ph = 276, 54
    placeCanvas(sc(pw) + sc(10), sc(ph) + MTp)
    add({ type = "rectangle", action = "strokeAndFill", fillColor = COL.bg, strokeColor = COL.accent,
      strokeWidth = 1.2 * s, roundedRectRadii = { xRadius = 14 * s, yRadius = 14 * s },
      frame = { x = 0, y = MTp, w = sc(pw), h = sc(ph) }, trackMouseDown = true, id = "drag" })
    if isPaused then
      idx.mic = add({ type = "rectangle", action = "fill", fillColor = COL.accent,
        roundedRectRadii = { xRadius = 8 * s, yRadius = 8 * s },
        frame = { x = sc(8), y = MTp + sc(12), w = sc(30), h = sc(30) }, trackMouseUp = true, id = "settings" })
      add({ type = "image", image = IMG.mic, imageScaling = "scaleProportionally",
        frame = { x = sc(14), y = MTp + sc(17), w = sc(18), h = sc(20) } })
    else
      idx.dot = add({ type = "circle", action = "fill", fillColor = COL.accent,
        center = { x = sc(22), y = MTp + sc(27) }, radius = sc(6) })
    end
    idx.timer = add({ type = "text", text = "0:00", textSize = math.floor(19 * s), textColor = COL.white,
      textFont = "Menlo-Bold", textAlignment = "left", frame = { x = sc(46), y = MTp + sc(15), w = sc(48), h = sc(26) } })
    local bx, pitch = 100, 7
    for i = 1, 12 do
      local xb = sc(bx + (i - 1) * pitch)
      local ei = add({ type = "rectangle", action = "fill", fillColor = COL.accent,
        roundedRectRadii = { xRadius = 2 * s, yRadius = 2 * s }, frame = { x = xb, y = MTp + sc(25), w = sc(3), h = sc(4) } })
      idx.bars[i] = { idx = ei, x = xb }
    end
    idx.barMeta = { horizontal = true, s = s, barW = sc(3), maxLen = 22, cy = MTp + sc(27) }
    add({ type = "rectangle", action = "fill", fillColor = COL.accent, roundedRectRadii = { xRadius = 8 * s, yRadius = 8 * s },
      frame = { x = sc(190), y = MTp + sc(12), w = sc(32), h = sc(30) }, trackMouseUp = true, id = "pause" })
    add({ type = "image", image = isPaused and IMG.play or IMG.pause, imageScaling = "scaleProportionally",
      frame = { x = sc(197), y = MTp + sc(17), w = sc(18), h = sc(20) } })
    add({ type = "rectangle", action = "strokeAndFill", fillColor = COL.clear, strokeColor = COL.accent,
      strokeWidth = 1.4 * s, roundedRectRadii = { xRadius = 8 * s, yRadius = 8 * s },
      frame = { x = sc(230), y = MTp + sc(12), w = sc(32), h = sc(30) }, trackMouseUp = true, id = "stop" })
    add({ type = "rectangle", action = "fill", fillColor = COL.accent, roundedRectRadii = { xRadius = 3 * s, yRadius = 3 * s },
      frame = { x = sc(239), y = MTp + sc(20), w = sc(14), h = sc(14) } })
    pushBadge(els, "cancel", sc(pw), MTp, s)
  end

  overlay:replaceElements(els)
  RECIDX = idx
  mode = "rec"
end

setProcessingElements = function(text)
  local s = config.scale
  local function sc(v) return v * s end
  local MTp = sc(10)
  local pw, ph = 178, 46
  placeCanvas(sc(pw) + sc(10), sc(ph) + MTp)
  local els = {}
  els[#els + 1] = { type = "rectangle", action = "strokeAndFill", fillColor = COL.bg, strokeColor = COL.accent,
    strokeWidth = 1.2 * s, roundedRectRadii = { xRadius = 14 * s, yRadius = 14 * s },
    frame = { x = 0, y = MTp, w = sc(pw), h = sc(ph) }, trackMouseDown = true, id = "drag" }
  els[#els + 1] = { type = "text", text = text or "…", textSize = math.floor(15 * s), textColor = COL.white,
    textFont = "Menlo-Bold", textAlignment = "center", frame = { x = sc(8), y = MTp + sc(13), w = sc(pw) - sc(24), h = sc(22) } }
  procTextIdx = #els
  pushBadge(els, "close", sc(pw), MTp, s)
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
    overlay:elementAttribute(RECIDX.dot, "fillColor",
      { red = COL.accent.red, green = COL.accent.green, blue = COL.accent.blue, white = COL.accent.white, alpha = a })
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
  overlay:alpha(0)
  overlay:frame({ x = f.x, y = f.y + 14, w = f.w, h = f.h })
  overlay:show()
  local steps, i = 9, 0
  animTimer = hs.timer.doEvery(0.016, function()
    i = i + 1
    local e = 1 - (1 - i / steps) ^ 2
    overlay:alpha(e)
    overlay:frame({ x = f.x, y = f.y + 14 * (1 - e), w = f.w, h = f.h })
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
    overlay:alpha(1 - e)
    overlay:frame({ x = f.x, y = f.y + 10 * e, w = f.w, h = f.h })
    if i >= steps then
      animTimer:stop(); animTimer = nil
      overlay:hide(); overlay:alpha(1); overlay:frame(f)
    end
  end)
end

showRecordingHUD = function()
  setRecordingElements(false)
  showAnimated()
  if uiTimer then uiTimer:stop() end
  uiTimer = hs.timer.new(0.06, updateUI); uiTimer:start()
end

stopUITimer = function() if uiTimer then uiTimer:stop(); uiTimer = nil end end

function hideOverlay()
  stopUITimer()
  mode = nil; RECIDX = nil
  hideAnimated()
end

rebuildHUD = function()
  if mode == "rec" then setRecordingElements(paused) end
end

local SPANEL_W = 260

closeSettings = function()
  if settingsCanvas then settingsCanvas:delete(); settingsCanvas = nil end
end

settingsMouse = function(_c, msg, id)
  if msg == "mouseDown" and id == "s_drag" then dragCanvas(settingsCanvas, false); return end
  if msg ~= "mouseUp" or not id then return end
  if id == "s_close" then closeSettings(); return end
  local kind, val = id:match("^(%a+):(.+)$")
  if not kind then return end
  if kind == "mic" then
    local d = settingsDevices[tonumber(val)]
    if d then config.audioDevice = d.idx; config.micName = d.name
      persist("micDevice", d.idx); persist("micName", d.name) end
  elseif kind == "size" then config.sizePreset = val; config.scale = scaleFor(val); persist("sizePreset", val); rebuildHUD()
  elseif kind == "orient" then config.orientation = val; persist("orientation", val); resetLevels(); rebuildHUD()
  elseif kind == "style" then config.style = val; COL = PALETTES[val] or PALETTES.gold; persist("style", val); rebuildHUD()
  end
  renderSettings()   -- ridisegna con lo stato aggiornato (evidenzia la scelta)
end

renderSettings = function()
  local W, pad = SPANEL_W, 16
  local els, y = {}, 12
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
      add({ type = "rectangle", action = "strokeAndFill", fillColor = cur and COL.accent or COL.clear,
        strokeColor = COL.accent, strokeWidth = 1, roundedRectRadii = { xRadius = 7, yRadius = 7 },
        frame = { x = x, y = y, w = pwid, h = 30 }, trackMouseUp = true, id = prefix .. ":" .. opt.val })
      add({ type = "text", text = opt.label, textSize = 11, textColor = cur and COL.bg or COL.accent,
        textFont = "Menlo-Bold", textAlignment = "center", frame = { x = x, y = y + 9, w = pwid, h = 16 } })
    end
    y = y + 40
  end

  -- header
  add({ type = "text", text = "IMPOSTAZIONI", textSize = 13, textColor = COL.accent, textFont = "Menlo-Bold",
    textAlignment = "left", frame = { x = pad, y = y, w = W - pad * 2 - 22, h = 18 } })
  y = y + 30

  label("MICROFONO")
  for i, d in ipairs(settingsDevices) do
    local cur = (d.name == config.micName)
    add({ type = "rectangle", action = "fill", fillColor = COL.clear,
      frame = { x = pad, y = y, w = W - pad * 2, h = 30 }, trackMouseUp = true, id = "mic:" .. i })
    local bx, byy = pad + 2, y + 8
    add({ type = "rectangle", action = "strokeAndFill", fillColor = cur and COL.accent or COL.clear,
      strokeColor = COL.accent, strokeWidth = 1.3, roundedRectRadii = { xRadius = 4, yRadius = 4 },
      frame = { x = bx, y = byy, w = 14, h = 14 } })
    if cur then
      add({ type = "segments", action = "stroke", strokeColor = COL.bg, strokeWidth = 1.8, closed = false,
        coordinates = { { x = bx + 3, y = byy + 7 }, { x = bx + 6, y = byy + 10 }, { x = bx + 11, y = byy + 4 } } })
    end
    add({ type = "text", text = d.name, textSize = 12, textColor = cur and COL.accent or COL.white,
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

  local H = y + 8
  table.insert(els, 1, { type = "rectangle", action = "strokeAndFill", fillColor = COL.bg, strokeColor = COL.accent,
    strokeWidth = 1.5, roundedRectRadii = { xRadius = 16, yRadius = 16 }, frame = { x = 0, y = 0, w = W, h = H },
    trackMouseDown = true, id = "s_drag" })
  add({ type = "circle", action = "strokeAndFill", fillColor = COL.bg, strokeColor = COL.accent, strokeWidth = 1.2,
    center = { x = W - 22, y = 24 }, radius = 11, trackMouseUp = true, id = "s_close" })
  add({ type = "segments", action = "stroke", strokeColor = COL.accent, strokeWidth = 1.7, closed = false,
    coordinates = { { x = W - 26, y = 20 }, { x = W - 18, y = 28 } } })
  add({ type = "segments", action = "stroke", strokeColor = COL.accent, strokeWidth = 1.7, closed = false,
    coordinates = { { x = W - 26, y = 28 }, { x = W - 18, y = 20 } } })

  local sf = hs.screen.mainScreen():frame()
  local fx = sf.x + (sf.w - W) / 2
  local fy = sf.y + (sf.h - H) / 2
  if settingsCanvas then settingsCanvas:delete() end
  settingsCanvas = hs.canvas.new({ x = fx, y = fy, w = W, h = H })
  settingsCanvas:level(hs.canvas.windowLevels.overlay)
  settingsCanvas:behavior({ "canJoinAllSpaces" })
  settingsCanvas:replaceElements(els)
  settingsCanvas:mouseCallback(settingsMouse)
  settingsCanvas:show()
end

openSettings = function()
  getAudioDevices(function(list)
    deviceCache = list
    settingsDevices = list
    renderSettings()
  end)
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
-- TRASCRIZIONE (per-segmento, testo unito) + backup su errore
------------------------------------------------------------------------
local function cleanupSegments()
  for _, p in ipairs(segments) do os.remove(p) end
  segments = {}; segIndex = 0
end

local function backupSegments()
  hs.execute("mkdir -p '" .. config.recDir .. "'")
  local stamp = os.date("%Y%m%d-%H%M%S")
  local n = 0
  for i, p in ipairs(segments) do
    if fileSize(p) > 1000 then
      hs.execute(string.format("cp '%s' '%s/rec-%s-%d.wav'", p, config.recDir, stamp, i))
      n = n + 1
    end
  end
  return n
end

local function failSaving(msg)
  busy = false
  local n = backupSegments()
  cleanupSegments()
  setStatus("✕ " .. msg)
  if n > 0 then hs.alert.show("💾 Audio salvato in\n" .. config.recDir, 6) end
  hs.timer.doAfter(2.6, hideOverlay)
end

local function transcribeOne(wavPath, cb)
  local key = readKey()
  if not key then cb(false, nil, "Nessuna chiave Groq") return end
  local args = { "-s", "-S",
    "https://api.groq.com/openai/v1/audio/transcriptions",
    "-H", "Authorization: Bearer " .. key,
    "-F", "model=" .. config.model,
    "-F", "file=@" .. wavPath,
    "-F", "response_format=text",
    "-F", "temperature=0" }
  if config.language then table.insert(args, "-F"); table.insert(args, "language=" .. config.language) end
  local t = hs.task.new(config.curl, function(code, out, err)
    if code ~= 0 then cb(false, nil, "Groq errore " .. tostring(code) .. " " .. trim(err))
    else cb(true, trim(out)) end
  end, args)
  t:start()
end

local function transcribeAll(paths, i, acc)
  if i > #paths then
    local text = trim(table.concat(acc, " "))
    if text == "" then failSaving("Nessun testo") return end
    busy = false
    setStatus("✓  Fatto")
    hs.timer.doAfter(0.30, function() pasteText(text) end)
    hs.timer.doAfter(0.85, hideOverlay)
    cleanupSegments()
    return
  end
  if #paths > 1 then setStatus(string.format("✍️  Trascrivo… (%d/%d)", i, #paths))
  else setStatus("✍️  Trascrivo…") end
  transcribeOne(paths[i], function(ok, text, err)
    if not ok then failSaving(err or "Errore trascrizione") return end
    acc[i] = text
    transcribeAll(paths, i + 1, acc)
  end)
end

local function finalizeAndTranscribe()
  busy = true
  stopUITimer()
  if animTimer then animTimer:stop(); animTimer = nil end
  setProcessingElements("🎙️  Ricevuto")
  if overlay then overlay:alpha(1); overlay:show() end
  hs.timer.doAfter(0.25, function()
    local valid = {}
    for _, p in ipairs(segments) do if fileSize(p) > 1000 then valid[#valid + 1] = p end end
    if #valid == 0 then failSaving("Audio vuoto") return end
    setStatus("☁️  Inviato")
    transcribeAll(valid, 1, {})
  end)
end

------------------------------------------------------------------------
-- REGISTRAZIONE (segmenti) + waveform reale + auto-taglio a tempo
------------------------------------------------------------------------
local function onStream(_t, _out, err)
  if err and recording and not paused then
    for m in err:gmatch("RMS_level=(%S+)") do
      table.remove(levels, 1)
      levels[#levels + 1] = mapLevel(tonumber(m))
    end
  end
  return true
end

local function stopRotTimer() if rotTimer then rotTimer:stop(); rotTimer = nil end end

local rotate
local function startSegment()
  local p = segPath(segIndex)
  os.remove(p)
  segments[#segments + 1] = p
  local args = { "-y", "-f", "avfoundation", "-i", config.audioDevice,
    "-ac", "1", "-ar", "16000",
    "-af", "asetnsamples=1600:p=0,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level",
    p }
  recTask = hs.task.new(config.ffmpeg, function() M._onSegmentFinished() end, onStream, args)
  if not recTask:start() then hs.alert.show("❌ ffmpeg non parte"); recTask = nil; return false end
  segStart = now()
  stopRotTimer()
  if config.maxSegmentSec and config.maxSegmentSec > 0 then
    rotTimer = hs.timer.doAfter(config.maxSegmentSec, function() rotate() end)
  end
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
  stopRotTimer()
  intent = newIntent
  if recTask then
    local pid = recTask:pid()
    if pid and pid > 0 then hs.execute(config.kill .. " -INT " .. pid)
    else recTask:terminate() end
  end
end

rotate = function()
  if not recording or paused then return end
  elapsed = elapsed + (now() - (segStart or now()))
  segStart = nil
  stopCurrentSegment("rotate")
end

local function start()
  recoverOrphans()
  cleanupSegments()
  local dev, fellBack, name = resolveMic()
  config.audioDevice = dev
  refreshDevices()
  elapsed = 0; segStart = nil; paused = false; segIndex = 0
  if fellBack then hs.alert.show("🎙️ Mic salvato non disponibile → uso “" .. (name or dev) .. "”", 3) end
  resetLevels()
  if not startSegment() then return end
  recording = true
  showRecordingHUD()
end

function M.stop()
  if not recording then return end
  recording = false
  stopRotTimer()
  if paused then
    finalizeAndTranscribe()
  else
    elapsed = elapsed + (now() - (segStart or now()))
    stopCurrentSegment("stop")
  end
end

function M.cancel()
  if not recording then hideOverlay(); cleanupSegments(); return end
  recording = false
  paused = false
  busy = false
  stopRotTimer()
  hideOverlay()
  if recTask then stopCurrentSegment("cancel") else cleanupSegments() end
end

function M.togglePause()
  if not recording then return end
  if paused then
    paused = false
    segIndex = segIndex + 1
    startSegment()
    if mode == "rec" then setRecordingElements(false) end
  else
    paused = true
    elapsed = elapsed + (now() - (segStart or now()))
    segStart = nil
    stopCurrentSegment("pause")
    if mode == "rec" then setRecordingElements(true) end
  end
end

------------------------------------------------------------------------
-- HOTKEY: START = doppio tap (Option dx o Ctrl dx) | STOP/PAUSA = un tap
------------------------------------------------------------------------
local watcher = nil
local function handleDouble(kc, action)
  local t = now()
  local last = taps[kc] or 0
  if (t - last) < config.doubleTapSec then taps[kc] = 0; action()
  else taps[kc] = t end
end

local function initHotkeys()
  local ss = { { config.startStopKeycode, config.startStopFlag } }
  local hasCtrl = false
  for _, k in ipairs(ss) do if k[1] == 62 then hasCtrl = true end end
  if not hasCtrl then table.insert(ss, { 62, "ctrl" }) end
  local pz = { { config.pauseKeycode, config.pauseFlag } }

  watcher = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
    local kc, fl = e:getKeyCode(), e:getFlags()
    for _, k in ipairs(ss) do
      if kc == k[1] and fl[k[2]] then
        if recording then if not busy then M.stop() end
        else handleDouble(kc, function() if not busy then start() end end) end
        return false
      end
    end
    for _, k in ipairs(pz) do
      if kc == k[1] and fl[k[2]] then
        if recording and not busy then M.togglePause() end
        return false
      end
    end
    return false
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

local function applyUpdate(dir)
  local t = hs.task.new(config.git, function(code)
    if code ~= 0 then hs.alert.show("Golden Whisper: update fallito (git pull)") return end
    hs.execute(string.format("cp '%s/src/groq_dictation.lua' '%s/.hammerspoon/groq_dictation.lua'",
      dir, os.getenv("HOME")))
    hs.alert.show("⬆️ Golden Whisper aggiornato — riavvio appena sei fermo", 4)
    deferReload()
  end, { "-C", dir, "pull", "--ff-only", "--quiet" })
  t:start()
end

local function checkUpdate(silent)
  local dir = config.repoDir
  if not dir or fileSize(dir .. "/.git/HEAD") == 0 then
    if not silent then hs.alert.show("Update: " .. tostring(dir) .. " non è un clone git") end
    return
  end
  local t = hs.task.new(config.git, function(code)
    if code ~= 0 then if not silent then hs.alert.show("Update: fetch fallito") end return end
    local loc = trim(hs.execute(config.git .. " -C '" .. dir .. "' rev-parse HEAD 2>/dev/null"))
    local rem = trim(hs.execute(config.git .. " -C '" .. dir .. "' rev-parse '@{u}' 2>/dev/null"))
    if loc ~= "" and rem ~= "" and loc ~= rem then
      if config.autoUpdate then applyUpdate(dir)
      else hs.alert.show("⬆️ Golden Whisper: update disponibile — lancia update.sh", 5) end
    elseif not silent then hs.alert.show("Golden Whisper è aggiornato ✓", 2) end
  end, { "-C", dir, "fetch", "--quiet" })
  t:start()
end

function M.update() checkUpdate(false) end
function M.settings() openSettings() end   -- apri impostazioni:  hs -c "require('groq_dictation').settings()"

function M.init()
  loadSettings()
  hs.execute("mkdir -p '" .. config.workDir .. "' '" .. config.recDir .. "'")
  recoverOrphans()
  refreshDevices()
  hs.audiodevice.watcher.setCallback(function() refreshDevices() end)
  hs.audiodevice.watcher.start()
  initHotkeys()
  if config.autoUpdate ~= false then
    hs.timer.doAfter(45, function() checkUpdate(true) end)
    hs.timer.doEvery(config.updateCheckHours * 3600, function() checkUpdate(true) end)
  end
  return M
end

M.config = config
return M
