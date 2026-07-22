-- groq_dictation.lua
-- Dettatura vocale stile Whisper Flow per macOS.
-- Trigger: doppio tap Option destro = start/stop | doppio tap Shift destro = pausa/riprendi.
-- Registra (ffmpeg) -> Groq Whisper -> incolla al cursore (+ resta in clipboard).
-- HUD in basso (black/white/gold): timer, waveform reale del microfono, pausa/stop, badge ✕ (annulla).
-- Robustezza: auto-spezza l'audio ogni maxSegmentSec (limite Groq ~25MB), trascrive ogni pezzo e
-- unisce il testo; se una trascrizione fallisce, salva l'audio in ~/.config/groq-dictation/recordings/.
-- Impostazioni utente in ~/.config/groq-dictation/settings.lua.

local M = {}

------------------------------------------------------------------------
-- CONFIG default (sovrascrivibile da settings.lua)
------------------------------------------------------------------------
local config = {
  keyPath      = os.getenv("HOME") .. "/.config/groq-dictation/api_key",
  settingsPath = os.getenv("HOME") .. "/.config/groq-dictation/settings.lua",
  recDir       = os.getenv("HOME") .. "/.config/groq-dictation/recordings",
  workDir      = os.getenv("HOME") .. "/.config/groq-dictation/segments",  -- persistente (NON /tmp): sopravvive a reload/crash
  audioDevice  = ":0",
  language     = "it",
  model        = "whisper-large-v3-turbo",
  ffmpeg       = "/opt/homebrew/bin/ffmpeg",
  curl         = "/usr/bin/curl",
  kill         = "/bin/kill",
  startStopKeycode = 61, startStopFlag = "alt",    -- Option destro
  pauseKeycode     = 60, pauseFlag     = "shift",  -- Shift destro
  doubleTapSec = 0.50,
  maxSegmentSec = 480,        -- auto-taglio ogni 8 min (sotto il limite ~13min/25MB di Groq)
  restoreClipboard = false,   -- false = il testo resta in clipboard | true = ripristina quella precedente
}

local N_BARS = 12

------------------------------------------------------------------------
-- STATO
------------------------------------------------------------------------
local recording = false
local paused    = false
local busy      = false
local recTask   = nil
local intent    = nil          -- "pause" | "stop" | "cancel" | "rotate"
local segments  = {}
local segIndex  = 0
local elapsed   = 0
local segStart  = nil
local levels    = {}

local overlay   = nil
local uiTimer   = nil
local rotTimer  = nil
local mode      = nil          -- "rec" | "proc"
local RECIDX    = nil
local taps      = {}

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
  if s.maxSegmentSec    then config.maxSegmentSec = s.maxSegmentSec end
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

local function resetLevels()
  levels = {}
  for _ = 1, N_BARS do levels[#levels + 1] = 0 end
end

-- Recupero anti-perdita: se in workDir ci sono segmenti di una sessione interrotta
-- (reload/crash), li salva (con header riparato) in recordings/ e avvisa. Mai persi in silenzio.
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
      -- remux per riparare l'header di un wav non finalizzato; se fallisce, copia grezza
      hs.execute(string.format("'%s' -y -i '%s' -c copy '%s' 2>/dev/null || cp '%s' '%s'",
        config.ffmpeg, p, dest, p, dest))
    end
    os.remove(p)
  end
  if n > 0 then hs.alert.show("💾 Recuperato audio da una sessione interrotta:\n" .. config.recDir, 8) end
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
-- La card (pill) è inset di MT/MR dentro il canvas, così il badge ✕ può sporgere
-- dall'angolo in alto a destra senza allargare la card.
------------------------------------------------------------------------
local PILL_W, PILL_H = 356, 66
local MT, MR = 11, 12
local W, H = PILL_W + MR, PILL_H + MT

local function ensureCanvas()
  if overlay then return end
  local sf = hs.screen.mainScreen():frame()
  local x = sf.x + (sf.w - PILL_W) / 2
  local y = sf.y + sf.h - 80 - H
  overlay = hs.canvas.new({ x = x, y = y, w = W, h = H })
  overlay:level(hs.canvas.windowLevels.overlay)
  overlay:behavior({ "canJoinAllSpaces", "stationary" })
  overlay:clickActivating(false)
  overlay:mouseCallback(function(_c, msg, id)
    if msg ~= "mouseUp" then return end
    if id == "pause" then M.togglePause()
    elseif id == "stop" then M.stop()
    elseif id == "mic" then openMicChooser()
    elseif id == "cancel" then M.cancel()
    elseif id == "close" then hideOverlay() end
  end)
end

local function bgEl()
  return { type = "rectangle", action = "strokeAndFill",
           fillColor = COL.bg, strokeColor = COL.gold, strokeWidth = 1.2,
           roundedRectRadii = { xRadius = 16, yRadius = 16 },
           frame = { x = 0, y = MT, w = PILL_W, h = PILL_H } }
end

-- badge ✕ sporgente dall'angolo in alto a destra (✕ = due linee incrociate, centrata)
local function pushCloseBadge(els, id)
  local cx, cy = PILL_W, MT
  els[#els + 1] = { type = "circle", action = "strokeAndFill", fillColor = COL.bg,
    strokeColor = COL.gold, strokeWidth = 1.2, center = { x = cx, y = cy }, radius = 10,
    trackMouseUp = true, id = id }
  els[#els + 1] = { type = "segments", action = "stroke", strokeColor = COL.gold, strokeWidth = 1.7,
    closed = false, coordinates = { { x = cx - 3.5, y = cy - 3.5 }, { x = cx + 3.5, y = cy + 3.5 } } }
  els[#els + 1] = { type = "segments", action = "stroke", strokeColor = COL.gold, strokeWidth = 1.7,
    closed = false, coordinates = { { x = cx - 3.5, y = cy + 3.5 }, { x = cx + 3.5, y = cy - 3.5 } } }
end

-- y helper (offset della card)
local function Y(v) return v + MT end

local function setRecordingElements(isPaused)
  local els, idx = {}, { bars = {} }
  local function add(el) els[#els + 1] = el; return #els end

  add(bgEl())

  if isPaused then
    idx.mic = add({ type = "rectangle", action = "fill", fillColor = COL.gold,
      roundedRectRadii = { xRadius = 9, yRadius = 9 },
      frame = { x = 12, y = Y(17), w = 36, h = 32 }, trackMouseUp = true, id = "mic" })
    add({ type = "image", image = IMG.mic, imageScaling = "scaleProportionally",
      frame = { x = 21, y = Y(23), w = 18, h = 20 } })
  else
    idx.dot = add({ type = "circle", action = "fill", fillColor = COL.gold,
      center = { x = 30, y = Y(33) }, radius = 7 })
  end

  idx.timer = add({ type = "text", text = "0:00", textSize = 21, textColor = COL.white,
    textFont = "Menlo-Bold", textAlignment = "left", frame = { x = 56, y = Y(20), w = 52, h = 28 } })

  for i = 1, N_BARS do
    idx.bars[i] = add({ type = "rectangle", action = "fill", fillColor = COL.gold,
      roundedRectRadii = { xRadius = 2, yRadius = 2 },
      frame = { x = 112 + (i - 1) * 9, y = Y(31), w = 4, h = 4 } })
  end

  -- pausa / play
  add({ type = "rectangle", action = "fill", fillColor = COL.gold,
    roundedRectRadii = { xRadius = 9, yRadius = 9 },
    frame = { x = 226, y = Y(17), w = 38, h = 32 }, trackMouseUp = true, id = "pause" })
  add({ type = "image", image = isPaused and IMG.play or IMG.pause, imageScaling = "scaleProportionally",
    frame = { x = 234, y = Y(23), w = 22, h = 20 } })

  -- stop (ferma e trascrive)
  add({ type = "rectangle", action = "strokeAndFill", fillColor = COL.clear,
    strokeColor = COL.gold, strokeWidth = 1.4,
    roundedRectRadii = { xRadius = 9, yRadius = 9 },
    frame = { x = 272, y = Y(17), w = 38, h = 32 }, trackMouseUp = true, id = "stop" })
  add({ type = "rectangle", action = "fill", fillColor = COL.gold,
    roundedRectRadii = { xRadius = 3, yRadius = 3 },
    frame = { x = 284, y = Y(26), w = 14, h = 14 } })

  pushCloseBadge(els, "cancel")   -- ✕ annulla (butta l'audio)

  overlay:replaceElements(els)
  RECIDX = idx
  mode = "rec"
end

local function setProcessingElements(text)
  local els = {}
  els[1] = bgEl()
  els[2] = { type = "circle", action = "fill", fillColor = COL.gold, center = { x = 30, y = Y(33) }, radius = 6 }
  els[3] = { type = "text", text = text or "…", textSize = 17, textColor = COL.white,
             textFont = "Menlo-Bold", textAlignment = "left", frame = { x = 48, y = Y(22), w = PILL_W - 84, h = 26 } }
  pushCloseBadge(els, "close")
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
    overlay:elementAttribute(bidx, "frame", { x = 112 + (i - 1) * 9, y = Y(33) - h / 2, w = 4, h = h })
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

function hideOverlay()
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
      local dest = string.format("%s/rec-%s-%d.wav", config.recDir, stamp, i)
      hs.execute(string.format("cp '%s' '%s'", p, dest))
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
  ensureCanvas()
  setProcessingElements("🎙️  Ricevuto")
  overlay:show()
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

local rotate  -- fwd
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
  stopCurrentSegment("rotate")   -- chiude il pezzo e ne apre un altro (continuità timer)
end

local function start()
  recoverOrphans()   -- salva eventuali segmenti di una sessione interrotta prima di ripulire
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
  if (t - last) < config.doubleTapSec then taps[kc] = 0; action()
  else taps[kc] = t end
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
  hs.execute("mkdir -p '" .. config.workDir .. "' '" .. config.recDir .. "'")
  recoverOrphans()   -- recupera audio di un'eventuale sessione interrotta (reload/crash)
  initHotkeys()
  return M
end

M.config = config
return M
