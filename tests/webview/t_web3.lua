-- WEB 3: FUZZ di sequenze di operazioni (aperture, chiusure, ready, op valide e spazzatura, eventi mouse/tastiera, avanzamenti di tempo, modalita' di guasto)
local SEED0 = tonumber(os.getenv("FZ_SEED0") or "1"); local NSEQ = tonumber(os.getenv("FZ_N") or "500"); local LEN = tonumber(os.getenv("FZ_LEN") or "14")
local LOOKK = { "style", "themeMode", "glassOpacity", "cornerStyle", "animOn", "animSpeed", "waveStyle", "waveColor", "micPulse", "glowOn", "uiFont", "timerFont",
  "density", "idleOpacity", "shadowOn", "shadowIntensity", "sizePreset", "orientation", "language", "__index", "", 5 }
local VALS = { "ocean", "sakura", "gold", "dark", "light", "auto", "calm", "lively", "bars", "dots", "round", "square", "sf", "rounded", "mono", "compact", "wide", "large", "minimal",
  "vertical", "horizontal", "accent", "gradient", true, false, 0, 0.3, 0.5, 0.99, 1, 7, -3, 1e308, 0 / 0, math.huge, -math.huge, "abc", "", {}, { 1, 2 }, "true", string.rep("z", 3000), "\0\1" }
local TABS_ = { "general", "keys", "theme", "x", 5 }
local PAGES = { "general", "keys", "theme" }
local NAMES = { "AirPods Uno", "MacBook Mic Due", "Mic Tre", "</script>", "nope", "", 7 }
local LISTS = { 'AVFoundation audio devices:\n[0] AirPods Uno\n[1] MacBook Mic Due\n[2] Mic Tre', 'AVFoundation audio devices:\n[0] </script>"\\\n[1] \255x', "", 'AVFoundation audio devices:\n[0] Solo' }
local CURLMS = { "ok", "http401", "http403", "fail", "hang", "http429" }
local FAULTS = { "ok", "ok", "ok", "ok", "ok", "newthrows", "newnil" }
local KEYS = { KEY, "gsk_x", "", "ciao", KEY, "gsk_" .. string.rep("Q", 60) }
local function rnd(n) return math.random(n) end
local function pick(t) return t[rnd(#t)] end
local function num() return pick({ 0, 1, 100, 239, 240, 500, 700, 1e4, 1e9, -1, -500, 0.5, 0 / 0, math.huge, "x", {} }) end
local EV = { 6, 2, 12, 10, 11, 22 }
local OPS = {
  function(w) WV.send({ op = "ready" }, w) end,
  function(w) WV.send({ op = "set", key = pick(LOOKK), value = pick(VALS) }, w) end,
  function(w) WV.send({ op = "set", key = pick(LOOKK), value = pick(VALS) }, w) end,
  function(w) WV.send({ op = "set", key = pick(LOOKK), value = pick(VALS) }, w) end,
  function(w) WV.send({ op = "random_look" }, w) end,
  function(w) WV.send({ op = "reset_look" }, w) end,
  function(w) WV.send({ op = "pick_mic", name = pick(NAMES) }, w) end,
  function(w) WV.send({ op = "refresh_devices" }, w) end,
  function(w) PASTE = pick(KEYS); WV.send({ op = "key_paste" }, w) end,
  function(w) WV.send({ op = "key_remove" }, w) end,
  function(w) WV.send({ op = "open_groq" }, w) end,
  function(w) WV.send({ op = "capture_start", action = pick({ "ss", "pause", "x", 5 }) }, w) end,
  function(w) WV.send({ op = "capture_cancel" }, w) end,
  function(w) WV.send({ op = "key_remove_binding", action = pick({ "ss", "pause", "x" }), index = pick({ 0, 1, 2, -1, 99, 0.5, "x" }) }, w) end,
  function(w) WV.send({ op = "key_set_gesture", action = pick({ "ss", "pause" }), index = pick({ 0, 1, 5 }), gesture = pick({ "single", "double", "hold", "x", 5 }) }, w) end,
  function(w) WV.send({ op = "set_tab", tab = pick(TABS_) }, w) end,
  function(w) WV.send({ op = "drag_start" }, w) end,
  function(w) WV.send({ op = "resize_request", w = num(), h = num() }, w) end,
  function(w) WV.send({ op = "resize_request", w = 300 + rnd(600), h = 250 + rnd(500) }, w) end,
  function(w) WV.send({ op = pick({ "close", "close", "boom", "", 5, "fallback" }) }, w) end,
  function(w) w.uc.cb(pick({ 5, "s", {}, { body = 5 }, { body = { op = {} } } })) end,
  function(w) MOUSE.x, MOUSE.y = rnd(1600) - 100, rnd(1000) - 50; deliver(mev(pick(EV))) end,
  function(w) deliver(ev(pick({ 0, 53, 61, 62, 36, 49 }), pick({ 10, 12, 11 }), { alt = true, ctrl = true, shift = true, cmd = true })) end,
  function(w) WV.send({ op = pick({ "hb", "hb", "interact", "interact" }) }, w) end,
  function(w) FRONT = pick({ "slack", "hs", "mail" }) end,
  function(w) w.crashed = pick({ true, false, false, false }) end,
  function(w) local f = w.fr; MOUSE.x, MOUSE.y = f.x + rnd(math.max(1, math.floor(f.w))), f.y + rnd(math.max(1, math.floor(f.h))); deliver(ev(53, 10)) end,
  function(w) w.nav(pick({ "didFailNavigation", "didFinishNavigation", "didFailProvisionalNavigation" }), w) end,
  function(w) w.policy(pick({ "navigationAction", "newWindow", "x" }), w, { request = { URL = pick({ "about:blank", "https://x.y", "file:///etc/passwd" }) } }) end,
}
local function step(w)
  local k = rnd(100)
  if k <= 55 then local f = pick(OPS); local ww = WV.cur() or WV.last(); if ww and ww.uc and ww.uc.cb and (ww.nav or ww.policy) then f(ww) end
  elseif k <= 65 then C.settingsUI = pick({ "web", "web", "web", "canvas" }); M.settings(pick(PAGES))
  elseif k <= 70 then pcall(D.sclose)
  elseif k <= 75 then advance(pick({ 0, 0.001, 0.01, 0.03, 0.05, 0.2, 1, 4.5, 11 }))
  elseif k <= 78 then CURLM = pick(CURLMS)
  elseif k <= 80 then BUTTONS = pick({ {}, { true }, nil })
  elseif k <= 82 then LISTHANG = pick({ true, nil, nil }); LISTDEV = pick(LISTS)
  elseif k <= 84 then WV.mode = pick(FAULTS)
  elseif k <= 85 then HSF.webview = pick({ WVMOD, WVMOD, WVMOD, false })
  elseif k <= 90 then local ww = WV.cur(); if ww then WV.send({ op = "ready" }, ww) end
  else advance(pick({ 0.016, 0.1, 0.3 })) end
end
local function setupVfs()
  VFS.dirs = {}; VFS.attr = {}
  local b = (C.keyPath:gsub("/api_key$", "")) .. "/themes"
  if rnd(2) == 1 then return end
  VFS.attr[b] = { mode = "directory" }; VFS.dirs[b] = {}
  for i = 1, rnd(5) do
    local sid = pick({ "gold", "ocean", "mono", "nonesiste", "..", "sakura" }); VFS.dirs[b][#VFS.dirs[b] + 1] = sid
    VFS.attr[b .. "/" .. sid] = { mode = pick({ "directory", "directory", "link", "file" }) }; VFS.dirs[b .. "/" .. sid] = {}
    for j = 1, rnd(8) do
      local nm = pick({ "icon.png", "spin.gif", "x.svg", "a b.png", "big.png", ".h.png", "z" .. j .. ".webp" })
      VFS.dirs[b .. "/" .. sid][#VFS.dirs[b .. "/" .. sid] + 1] = nm
      VFS.attr[b .. "/" .. sid .. "/" .. nm] = { mode = pick({ "file", "file", "link" }), size = pick({ 100, 0, 6e6, 4e6 }) }
    end
  end
end
local base = STATS()
local allow = { "no$", "simulato", "restituito nil" }
local function okErr(e) for _, a in ipairs(allow) do if tostring(e):find(a) then return true end end return false end
local fails, totalOps = {}, 0
local keyLeak = false
local maxLive = 0
for seq = SEED0, SEED0 + NSEQ - 1 do
  math.randomseed(seq * 7919 + 13)
  WD_T0 = os.clock()
  reset()
  local e0 = #errors
  local nl0 = #WV.list
  local ok, err = xpcall(function()
    C.settingsUI = "web"; setupVfs(); WRITEFAIL = (rnd(6) == 1) or nil; FRONT = pick({ "slack", "hs" })
    for i = 1, LEN do step(); totalOps = totalOps + 1; WD_T0 = os.clock() end
  end, debug.traceback)
  local why
  if not ok then why = "eccezione: " .. tostring(err):sub(1, 500) end
  pcall(D.sclose); LISTHANG = nil; WV.mode = "ok"; HSF.webview = WVMOD; BUTTONS = nil
  advance(0.6)
  if not why then
    for i = e0 + 1, #errors do if not okErr(errors[i]) then why = "errore harness: " .. tostring(errors[i]):sub(1, 300); break end end
  end
  if not why then
    local s = STATS()
    if WV.live() ~= 0 then why = "webview vive " .. WV.live() elseif WV.liveUC() ~= 0 then why = "usercontent vivi " .. WV.liveUC()
    elseif s.tapsOn ~= base.tapsOn then why = "eventtap accesi " .. s.tapsOn
    elseif s.every ~= base.every then why = "timer ricorrenti " .. s.every .. " vs " .. base.every
    elseif s.cvLive ~= base.cvLive then why = "canvas vive " .. s.cvLive
    elseif D.ICON.capTap then why = "capTap vivo" end
  end
  if not why then
    for i = nl0 + 1, #WV.list do
      local w = WV.list[i]
      for _, j in ipairs(w.js) do
        local a = j:match("^gw%.onState%((.*)%)$")
        local n, b = j:match("^gw%.onEvent%('([%w_]+)', (.*)%)$")
        if a then local o, e = pcall(JSON.decode, a); if not o then why = "stato non JSON: " .. tostring(e); break end
        elseif n then local o, e = pcall(JSON.decode, b); if not o then why = "evento non JSON: " .. tostring(e); break end
        else why = "JS di forma strana: " .. j:sub(1, 80); break end
        if j:find(KEY, 1, true) or j:find(KEY:sub(5, -5), 1, true) then why = "CHIAVE NEL JS"; break end
      end
      if why then break end
    end
  end
  if why then fails[#fails + 1] = "seed " .. seq .. ": " .. why; if #fails >= 5 then break end end
  if seq % 50 == 0 then COMPACT() end
end
OUT[#OUT + 1] = string.format("TOTALE web3 fuzz: sequenze %d (seed %d..%d), op %d, webview create %d, falliti %d", NSEQ, SEED0, SEED0 + NSEQ - 1, totalOps, #WV.list, #fails)
for _, f in ipairs(fails) do OUT[#OUT + 1] = "FAIL " .. f end
if #fails == 0 then OUT[#OUT + 1] = "PASS fuzz" end
return table.concat(OUT, "\n")
