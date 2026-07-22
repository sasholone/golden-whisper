-- groq_dictation.lua
-- Dettatura vocale stile Whisper Flow per macOS.
-- Trigger: doppio tap Option destro = start/stop | doppio tap Shift destro = pausa/riprendi.
-- Registra (ffmpeg) -> Groq Whisper -> incolla al cursore.
-- HUD in basso (black/white/gold): timer, waveform REALE del microfono (RMS via stderr),
-- pulsanti Pausa/Stop con icone di sistema, feedback a step (Ricevuto->Inviato->Trascrivo->Fatto).
-- In pausa: pulsante microfono a sinistra -> sceglie l'input tra quelli del Mac (salvato in settings).
-- Impostazioni utente in ~/.config/groq-dictation/settings.lua.

local M = {}

------------------------------------------------------------------------
-- CONFIG default (sovrascrivibile da settings.lua)
------------------------------------------------------------------------
local config = {
  keyPath      = os.getenv("HOME") .. "/.config/groq-dictation/api_key",
  settingsPath = os.getenv("HOME") .. "/.config/groq-dictation/settings.lua",
  audioDevice  = ":0",
  language     = "it",
  model        = "whisper-large-v3-turbo",
  ffmpeg       = "/opt/homebrew/bin/ffmpeg",
  curl         = "/usr/bin/curl",
  kill         = "/bin/kill",
  startStopKeycode = 61, startStopFlag = "alt",    -- Option destro
  pauseKeycode     = 60, pauseFlag     = "shift",  -- Shift destro
  doubleTapSec = 0.50,
  restoreClipboard = true,
}

local N_BARS = 14

------------------------------------------------------------------------
-- STATO
------------------------------------------------------------------------
local recording = false
local paused    = false
local busy      = false
local recTask   = nil
local intent    = nil
local segments  = {}
local segIndex  = 0
local elapsed   = 0
local segStart  = nil
local levels    = {}

local overlay   = nil
local uiTimer   = nil
local mode      = nil          -- "rec" | "proc"
local RECIDX    = nil          -- mappa indici elementi in modalità rec
local taps      = {}           -- keycode -> ultimo tap

------------------------------------------------------------------------
-- PALETTE (black / white / gold)
------------------------------------------------------------------------
local COL = {
  bg       = { red = 0.05, green = 0.05, blue = 0.06, alpha = 0.97 },
  gold     = { red = 0.83, green = 0.68, blue = 0.36 },
  goldDim  = { red = 0.48, green = 0.40, blue = 0.23 },
  white    = { white = 0.97 },
  clear    = { alpha = 0 },
}

local IMG = {
  mic   = hs.image.imageFromName("NSTouchBarAudioInputTemplate"),
  pause = hs.image.imageFromName("NSTouchBarPauseTemplate"),
  play  = hs.image.imageFromName("NSTouchBarPlayTemplate"),
  stop  = hs.image.imageFromName("NSTouchBarRecordStopTemplate"),
}

------------------------------------------------------------------------
-- SETTINGS
------------------------------------------------------------------------
local function loadSettings()
  local f = io.open(config.settingsPath, "r"); if not f then return end; f:close()
  local ok, s = pcall(dofile, config.settingsPath)
  if not ok or type(s) ~= "table" then hs.alert.show("⚠️ settings.lua non valido") return end
  if s.language ~= nil then config.language = (s.language == "auto") and nil or s.language end
  if s.micDevice then config.audioDevice = s.micDevice end
  if s.model     then config.model = s.model end
  if s.startStopKeycode then config.startStopKeycode = s.startStopKeycode end
  if s.startStopFlag    then config.startStopFlag = s.startStopFlag end
  if s.pauseKeycode     then config.pauseKeycode = s.pauseKeycode end
  if s.pauseFlag        then config.pauseFlag = s.pauseFlag end
  if s.doubleTapSec     then config.doubleTapSec = s.doubleTapSec end
  if s.restoreClipboard ~= nil then config.restoreClipboard = s.restoreClipboard end
end

local function persistSetting(key, value)
  local f = io.open(config.settingsPath, "r"); if not f then return end
  local txt = f:read("*a"); f:close()
  local pat = key .. "%s*=%s*\"[^\"]*\""
  if txt:find(pat) then txt = txt:gsub(pat, key .. ' = "' .. value .. '"')
  else txt = txt:gsub("return%s*{", 'return {\n  ' .. key .. ' = "' .. value .. '",') end
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

local function segPath(i) return string.format("/tmp/groq_seg_%d.wav", i) end
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

local function resetLevels()
  levels = {}
  for _ = 1, N_BARS do levels[#levels + 1] = 0 end
end

------------------------------------------------------------------------
-- MIC CHOOSER (in pausa)
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

local function openMicChooser()
  getAudioDevices(function(list)
    local choices = {}
    for _, d in ipairs(list) do
      choices[#choices + 1] = {
        text = d.name,
        subText = "input " .. d.idx .. (d.idx == config.audioDevice and "   •   attuale" or ""),
        idx = d.idx, name = d.name,
      }
    end
    if #choices == 0 then hs.alert.show("Nessun microfono trovato") return end
    local ch = hs.chooser.new(function(choice)
      if not choice then return end
      config.audioDevice = choice.idx
      persistSetting("micDevice", choice.idx)
      hs.alert.show("🎙️  " .. choice.name)
    end)
    ch:placeholderText("Scegli microfono di input")
    ch:choices(choices)
    ch:show()
  end)
end

------------------------------------------------------------------------
-- HUD OVERLAY
------------------------------------------------------------------------
local W, H = 356, 66

local function ensureCanvas()
  if overlay then return end
  local sf = hs.screen.mainScreen():frame()
  local x = sf.x + (sf.w - W) / 2
  local y = sf.y + sf.h - H - 80
  overlay = hs.canvas.new({ x = x, y = y, w = W, h = H })
  overlay:level(hs.canvas.windowLevels.overlay)
  overlay:behavior({ "canJoinAllSpaces", "stationary" })
  overlay:clickActivating(false)
  overlay:mouseCallback(function(_c, msg, id)
    if msg ~= "mouseUp" then return end
    if id == "pause" then M.togglePause()
    elseif id == "stop" then M.stop()
    elseif id == "mic" then openMicChooser() end
  end)
end

local function bgEl()
  return { type = "rectangle", action = "strokeAndFill",
           fillColor = COL.bg, strokeColor = COL.gold, strokeWidth = 1.2,
           roundedRectRadii = { xRadius = 16, yRadius = 16 } }
end

-- Modalità registrazione. isPaused cambia il pulsante sinistro (dot<->mic) e pausa<->play.
local function setRecordingElements(isPaused)
  local els, idx = {}, { bars = {} }
  local function add(el) els[#els + 1] = el; return #els end

  add(bgEl())

  -- slot sinistro
  if isPaused then
    idx.mic = add({ type = "rectangle", action = "fill", fillColor = COL.gold,
      roundedRectRadii = { xRadius = 9, yRadius = 9 },
      frame = { x = 12, y = 17, w = 36, h = 32 }, trackMouseUp = true, id = "mic" })
    add({ type = "image", image = IMG.mic, imageScaling = "scaleProportionally",
      frame = { x = 21, y = 23, w = 18, h = 20 } })
  else
    idx.dot = add({ type = "circle", action = "fill", fillColor = COL.gold,
      center = { x = 30, y = 33 }, radius = 7 })
  end

  idx.timer = add({ type = "text", text = "0:00", textSize = 21, textColor = COL.white,
    textFont = "Menlo-Bold", textAlignment = "left", frame = { x = 56, y = 20, w = 52, h = 28 } })

  for i = 1, N_BARS do
    idx.bars[i] = add({ type = "rectangle", action = "fill", fillColor = COL.gold,
      roundedRectRadii = { xRadius = 2, yRadius = 2 },
      frame = { x = 112 + (i - 1) * 9, y = 31, w = 4, h = 4 } })
  end

  -- pausa / play
  add({ type = "rectangle", action = "fill", fillColor = COL.gold,
    roundedRectRadii = { xRadius = 9, yRadius = 9 },
    frame = { x = 244, y = 17, w = 42, h = 32 }, trackMouseUp = true, id = "pause" })
  add({ type = "image", image = isPaused and IMG.play or IMG.pause, imageScaling = "scaleProportionally",
    frame = { x = 253, y = 23, w = 24, h = 20 } })

  -- stop
  add({ type = "rectangle", action = "strokeAndFill", fillColor = COL.clear,
    strokeColor = COL.gold, strokeWidth = 1.4,
    roundedRectRadii = { xRadius = 9, yRadius = 9 },
    frame = { x = 294, y = 17, w = 42, h = 32 }, trackMouseUp = true, id = "stop" })
  add({ type = "rectangle", action = "fill", fillColor = COL.gold,
    roundedRectRadii = { xRadius = 3, yRadius = 3 },
    frame = { x = 308, y = 26, w = 15, h = 15 } })

  overlay:replaceElements(els)
  RECIDX = idx
  mode = "rec"
end

local function setProcessingElements(text)
  local els = {}
  els[1] = bgEl()
  els[2] = { type = "circle", action = "fill", fillColor = COL.gold, center = { x = 30, y = 33 }, radius = 6 }
  els[3] = { type = "text", text = text or "…", textSize = 17, textColor = COL.white,
             textFont = "Menlo-Bold", textAlignment = "left", frame = { x = 48, y = 22, w = W - 64, h = 26 } }
  overlay:replaceElements(els)
  mode = "proc"
end

local function setStatus(text)
  if overlay and mode == "proc" then overlay:elementAttribute(3, "text", text) end
end

local function updateUI()
  if not overlay or mode ~= "rec" or not RECIDX then return end
  overlay:elementAttribute(RECIDX.timer, "text", fmtTime(currentElapsed()))
  if RECIDX.dot then
    local a = 0.45 + 0.55 * math.abs(math.sin(now() * 3.2))
    overlay:elementAttribute(RECIDX.dot, "fillColor",
      { red = COL.gold.red, green = COL.gold.green, blue = COL.gold.blue, alpha = a })
  end
  local barCol = (recording and not paused) and COL.gold or COL.goldDim
  for i, bidx in ipairs(RECIDX.bars) do
    local lv = levels[i] or 0
    local h = 4 + lv * 26
    overlay:elementAttribute(bidx, "fillColor", barCol)
    overlay:elementAttribute(bidx, "frame", { x = 112 + (i - 1) * 9, y = 33 - h / 2, w = 4, h = h })
  end
end

local function showRecordingHUD()
  ensureCanvas()
  setRecordingElements(false)
  overlay:show()
  if uiTimer then uiTimer:stop() end
  uiTimer = hs.timer.new(0.06, updateUI); uiTimer:start()
end

local function stopUITimer() if uiTimer then uiTimer:stop(); uiTimer = nil end end

local function hideOverlay()
  stopUITimer()
  if overlay then overlay:hide() end
  mode = nil; RECIDX = nil
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
local function cleanupSegments()
  for _, p in ipairs(segments) do os.remove(p) end
  os.remove("/tmp/groq_seg_list.txt"); os.remove("/tmp/groq_combined.wav")
  segments = {}; segIndex = 0
end

local function finishError(msg)
  busy = false
  setStatus("✕ " .. msg)
  hs.timer.doAfter(2.2, hideOverlay)
  cleanupSegments()
end

local function transcribe(wavPath)
  local key = readKey()
  if not key then finishError("Nessuna chiave Groq") return end

  setStatus("☁️  Inviato")
  hs.timer.doAfter(0.35, function() if busy then setStatus("✍️  Trascrivo…") end end)

  local args = { "-s", "-S",
    "https://api.groq.com/openai/v1/audio/transcriptions",
    "-H", "Authorization: Bearer " .. key,
    "-F", "model=" .. config.model,
    "-F", "file=@" .. wavPath,
    "-F", "response_format=text",
    "-F", "temperature=0" }
  if config.language then table.insert(args, "-F"); table.insert(args, "language=" .. config.language) end

  local t = hs.task.new(config.curl, function(code, out, err)
    if code ~= 0 then finishError("Groq errore " .. tostring(code)) return end
    local text = trim(out)
    if text == "" then finishError("Nessun testo") return end
    busy = false
    setStatus("✓  Fatto")
    hs.timer.doAfter(0.30, function() pasteText(text) end)
    hs.timer.doAfter(0.85, hideOverlay)
    cleanupSegments()
  end, args)
  t:start()
end

local function concatThen(cb)
  local valid = {}
  for _, p in ipairs(segments) do if fileSize(p) > 1000 then valid[#valid + 1] = p end end
  if #valid == 0 then cb(nil) return end
  if #valid == 1 then cb(valid[1]) return end
  local listPath = "/tmp/groq_seg_list.txt"
  local f = io.open(listPath, "w")
  for _, p in ipairs(valid) do f:write("file '" .. p .. "'\n") end
  f:close()
  local out = "/tmp/groq_combined.wav"; os.remove(out)
  local t = hs.task.new(config.ffmpeg, function(code) cb(code == 0 and out or nil) end,
    { "-y", "-f", "concat", "-safe", "0", "-i", listPath, "-c", "copy", out })
  t:start()
end

local function finalizeAndTranscribe()
  busy = true
  stopUITimer()
  ensureCanvas()
  setProcessingElements("🎙️  Ricevuto")
  overlay:show()
  hs.timer.doAfter(0.25, function()
    concatThen(function(path)
      if not path then finishError("Audio vuoto") return end
      transcribe(path)
    end)
  end)
end

------------------------------------------------------------------------
-- REGISTRAZIONE (segmenti) + waveform reale (RMS su stderr, real-time)
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

local function onSegmentFinished()
  recTask = nil
  if intent == "pause" then intent = nil
  elseif intent == "stop" then intent = nil; finalizeAndTranscribe() end
end

local function startSegment()
  local p = segPath(segIndex)
  os.remove(p)
  segments[#segments + 1] = p
  local args = { "-y", "-f", "avfoundation", "-i", config.audioDevice,
    "-ac", "1", "-ar", "16000",
    "-af", "asetnsamples=1600:p=0,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level",
    p }
  recTask = hs.task.new(config.ffmpeg, onSegmentFinished, onStream, args)
  if not recTask:start() then hs.alert.show("❌ ffmpeg non parte"); recTask = nil; return false end
  segStart = now()
  return true
end

local function stopCurrentSegment(newIntent)
  intent = newIntent
  if recTask then
    local pid = recTask:pid()
    if pid and pid > 0 then hs.execute(config.kill .. " -INT " .. pid)
    else recTask:terminate() end
  end
end

local function start()
  cleanupSegments()
  elapsed = 0; segStart = nil; paused = false; segIndex = 0
  resetLevels()
  if not startSegment() then return end
  recording = true
  showRecordingHUD()
end

function M.stop()
  if not recording then return end
  recording = false
  if paused then
    finalizeAndTranscribe()
  else
    elapsed = elapsed + (now() - (segStart or now()))
    stopCurrentSegment("stop")
  end
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

local function toggle()
  if busy then return end
  if recording then M.stop() else start() end
end

------------------------------------------------------------------------
-- HOTKEY: doppio tap (Option dx = start/stop, Shift dx = pausa)
------------------------------------------------------------------------
local watcher = nil
local function handleDouble(kc, action)
  local t = now()
  local last = taps[kc] or 0
  if (t - last) < config.doubleTapSec then
    taps[kc] = 0
    action()
  else
    taps[kc] = t
  end
end

local function initHotkeys()
  watcher = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
    local kc, fl = e:getKeyCode(), e:getFlags()
    if kc == config.startStopKeycode and fl[config.startStopFlag] then
      handleDouble(kc, toggle)
    elseif kc == config.pauseKeycode and fl[config.pauseFlag] then
      handleDouble(kc, function() if not busy then M.togglePause() end end)
    end
    return false
  end)
  watcher:start()
end

function M.init()
  loadSettings()
  initHotkeys()
  return M
end

M.config = config
return M
