-- WEB 2: operazioni del ponte JS->Lua (set, look, mic, chiave, tasti, capture, drag, resize, asset)
local LOOKK = { "style", "themeMode", "glassOpacity", "cornerStyle", "animOn", "animSpeed", "waveStyle", "waveColor", "micPulse", "glowOn", "uiFont", "timerFont",
  "density", "idleOpacity", "shadowOn", "shadowIntensity" }
local VALID = {
  style = { "ocean", "sakura", "mono", "blocky" }, themeMode = { "dark", "light", "auto" }, glassOpacity = { 0.5, 0.8, 1 }, cornerStyle = { "round", "medium", "square" },
  animOn = { true, false }, animSpeed = { "calm", "normal", "lively" }, waveStyle = { "bars", "thin", "dots", "line" }, waveColor = { "accent", "gradient", "auto" },
  micPulse = { 0, 0.3, 1 }, glowOn = { true, false }, uiFont = { "sf", "rounded", "mono" }, timerFont = { "mono", "sf", "rounded" }, density = { "compact", "normal", "wide" },
  idleOpacity = { 0.3, 0.7, 1 }, shadowOn = { true, false }, shadowIntensity = { 0, 0.5, 1 },
}
local BAD = { "abc", "", "../../etc/passwd", 0 / 0, math.huge, -math.huge, -5, 99, {}, { 1 }, "true", "false", "0.5", 1e308, string.rep("x", 5000), "\0", "nan", -0.0 }
local function persisted() local s = FAKE[C.settingsPath]; if not s then return nil end local f = load(s, "=s"); if not f then return false end local ok, t = pcall(f); return ok and t or false end
local function validLook()
  for _, k in ipairs(LOOKK) do
    if C[k] ~= nil and C.LOOK.clean(k, C[k]) ~= C[k] then return k .. " non valido in config: " .. tostring(C[k]) end
  end
  return nil
end
T("W30 set: ogni chiave di look con valori validi si applica e persiste (nessun eco)", function()
  local w = openWeb(); local n0 = nstate(w)
  for _, k in ipairs(LOOKK) do
    for _, v in ipairs(VALID[k]) do
      WV.send({ op = "set", key = k, value = v }, w); advance(0.12)
      local want = C.LOOK.clean(k, v)
      if C[k] ~= want then return k .. "=" .. tostring(v) .. " -> config " .. tostring(C[k]) end
      local p = persisted(); if not p then return "settings.lua non valido dopo " .. k end
      if k ~= "glassOpacity" and k ~= "shadowIntensity" and k ~= "micPulse" and k ~= "idleOpacity" and p[k] ~= want then return k .. " non persistita: " .. tostring(p[k]) end
    end
  end
  advance(0.5)
  local p = persisted()
  for _, k in ipairs({ "glassOpacity", "shadowIntensity", "micPulse", "idleOpacity" }) do if p[k] ~= C[k] then return "slider " .. k .. " non persistito dopo la coda: " .. tostring(p[k]) .. " vs " .. tostring(C[k]) end end
  local s = fresh(w)
  for _, k in ipairs(LOOKK) do if s.look[k] ~= C.LOOK.clean(k, C[k]) then return "stato fresco " .. k end end
  return true end)
T("W31 set: valori invalidi/stringhe/NaN/inf/tabelle -> sanificati, mai errore, file valido, eco correttivo", function()
  local w = openWeb()
  for _, k in ipairs(LOOKK) do
    for _, v in ipairs(BAD) do
      WV.send({ op = "set", key = k, value = v }, w)
      local bad = validLook(); if bad then return k .. " <- " .. tostring(v):sub(1, 20) .. ": " .. bad end
    end
    WV.send({ op = "set", key = k }, w)       -- senza value
    local bad = validLook(); if bad then return k .. " senza value: " .. bad end
  end
  advance(1)
  if not persisted() then return "settings.lua rotto" end
  local s = WV.lastState(w)
  if not s then return "nessun eco correttivo" end
  for _, k in ipairs(LOOKK) do if s.look[k] == nil then return "stato.look." .. k .. " nil" end end
  return true end)
T("W32 set style/themeMode: applyTheme eseguito (COL cambia), stile sconosciuto -> default", function()
  local w = openWeb(); local oc = D.C().accent
  WV.send({ op = "set", key = "style", value = "ocean" }, w); advance(0.12)
  local c = D.C(); if c == oc or c ~= D.F.ocean.dark then return "COL non e' ocean dark" end
  WV.send({ op = "set", key = "themeMode", value = "light" }, w); advance(0.12)
  if D.C() ~= D.F.ocean.light then return "COL non e' ocean light" end
  if WV.lastState(w).effectiveMode ~= "light" then return "effectiveMode" end
  WV.send({ op = "set", key = "style", value = "nonesiste" }, w); advance(0.12)
  if C.style ~= "gold" then return "stile sconosciuto -> " .. tostring(C.style) end
  return true end)
T("W33 set glassOpacity: applyTheme live, persist/rebuild in coda (poche scritture)", function()
  local w = openWeb(); local p0 = (FILEW or {})[C.settingsPath] or 0
  for i = 1, 100 do WV.send({ op = "set", key = "glassOpacity", value = 0.5 + i / 200 }, w); advance(0.01) end
  if math.abs(D.C().bg.alpha - C.glassOpacity) > 1e-9 then return "vetro non live: " .. D.C().bg.alpha .. " vs " .. C.glassOpacity end
  advance(1)
  local n = ((FILEW or {})[C.settingsPath] or 0) - p0
  if n > 3 then return "scritture settings.lua: " .. n end
  if n < 1 then return "mai persistito" end
  if persisted().glassOpacity ~= 1 then return "valore finale non persistito: " .. tostring(persisted().glassOpacity) end
  return true end)
T("W34 slider: valore in sospeso viene persistito anche alla chiusura immediata", function()
  local w = openWeb(); WV.send({ op = "set", key = "micPulse", value = 0.9 }, w); WV.send({ op = "close" }, w); advance(0.5)
  local p = persisted(); if not p or p.micPulse ~= 0.9 then return "micPulse perso: " .. tostring(p and p.micPulse) end
  return true end)
T("W35 set sizePreset/orientation: validati, scala, persist", function()
  local w = openWeb()
  WV.send({ op = "set", key = "sizePreset", value = "large" }, w); advance(0.1)
  if C.sizePreset ~= "large" or C.scale ~= 1.2 or persisted().sizePreset ~= "large" then return "large" end
  WV.send({ op = "set", key = "sizePreset", value = "minimal" }, w); advance(0.1)
  if C.scale ~= 0.72 then return "minimal scala " .. tostring(C.scale) end
  WV.send({ op = "set", key = "sizePreset", value = "enorme" }, w); advance(0.1)
  if C.sizePreset ~= "standard" or C.scale ~= 1.0 then return "invalido -> " .. tostring(C.sizePreset) end
  WV.send({ op = "set", key = "orientation", value = "vertical" }, w); advance(0.1)
  if C.orientation ~= "vertical" or persisted().orientation ~= "vertical" then return "vertical" end
  if fresh(w).general.orientation ~= "vertical" then return "stato orientation" end
  for _, v in ipairs({ "diagonale", 5, {}, false }) do WV.send({ op = "set", key = "orientation", value = v }, w); advance(0.1)
    if C.orientation ~= "horizontal" then return "orientation invalida accettata: " .. tostring(v) end end
  return true end)
T("W36 set chiavi non di look ignorate (language, ffmpeg, keyPath, settingsUI...)", function()
  local w = openWeb()
  local before = { C.language, C.ffmpeg, C.keyPath, C.settingsPath, C.model, C.settingsUI }
  for _, k in ipairs({ "language", "ffmpeg", "keyPath", "settingsPath", "model", "settingsUI", "ssBindings", "LOOK", "posX", "layers", "micDevice" }) do
    WV.send({ op = "set", key = k, value = "x" }, w) end
  advance(0.3)
  local after = { C.language, C.ffmpeg, C.keyPath, C.settingsPath, C.model, C.settingsUI }
  for i = 1, #before do if before[i] ~= after[i] then return "cambiata la chiave " .. i end end
  if type(C.ssBindings) ~= "table" or C.layers == "x" or C.posX == "x" then return "chiave non di look scritta" end
  return true end)
T("W37 random_look: stile cambia, tutto valido, stato aggiornato; reset_look: default", function()
  local w = openWeb(); WV.send({ op = "random_look" }, w); advance(0.2)
  if C.style == "gold" then return "stile non cambiato" end
  local bad = validLook(); if bad then return bad end
  if WV.lastState(w).look.style ~= C.style then return "stato non aggiornato" end
  WV.send({ op = "reset_look" }, w); advance(0.2)
  for _, k in ipairs(LOOKK) do if C[k] ~= C.LOOK.def[k] then return "reset: " .. k .. "=" .. tostring(C[k]) end end
  if WV.lastState(w).look.style ~= "gold" then return "stato dopo reset" end
  for i = 1, 30 do WV.send({ op = "random_look" }, w); advance(0.06); local b = validLook(); if b then return "random " .. i .. ": " .. b end end
  return true end)
T("W38 pick_mic: dal nome; sconosciuto/non stringa ignorato", function()
  LISTDEV = 'AVFoundation audio devices:\n[0] AirPods Uno\n[1] MacBook Mic Due\n[2] Mic Tre'
  local w = openWeb(); advance(1); WV.send({ op = "refresh_devices" }, w); advance(0.5)
  local evd = lastEv(w, "devices"); if not evd or #evd.data ~= 3 then return "evento devices" end
  local s = fresh(w); if #s.general.devices ~= 3 then return "dispositivi " .. #s.general.devices end
  if s.general.devices[1].bt ~= true or s.general.devices[2].bt ~= false then return "bt per nome" end
  WV.send({ op = "pick_mic", name = "MacBook Mic Due" }, w); advance(0.2)
  if C.micName ~= "MacBook Mic Due" or C.audioDevice ~= ":1" then return "mic " .. tostring(C.micName) .. " " .. tostring(C.audioDevice) end
  local p = persisted(); if p.micName ~= "MacBook Mic Due" or p.micDevice ~= ":1" then return "non persistito" end
  if fresh(w).general.micName ~= "MacBook Mic Due" then return "stato micName" end
  for _, v in ipairs({ "Non Esiste", "", 5, {}, false }) do WV.send({ op = "pick_mic", name = v }, w) end
  advance(0.2)
  if not lastEv(w, "toast") then return "nessun toast per il microfono sconosciuto" end
  if C.micName ~= "MacBook Mic Due" then return "mic cambiato da nome sconosciuto" end
  return true end)
T("W39 refresh_devices: lista bloccata -> la finestra resta viva, cache usata", function()
  LISTDEV = 'AVFoundation audio devices:\n[0] Mic Uno'
  local w = openWeb(); advance(1)
  LISTHANG = true
  WV.send({ op = "refresh_devices" }, w); advance(11)
  LISTHANG = nil
  if not WV.cur() then return "finestra chiusa" end
  if #fresh(w).general.devices ~= 1 then return "lista persa" end
  return true end)
T("W40 apertura con lista device bloccata: la finestra si apre comunque", function()
  LISTHANG = true
  C.settingsUI = "web"; M.settings("general"); advance(0.1)
  local w = WV.cur(); WV.send({ op = "ready" }, w); advance(0.3)
  LISTHANG = nil; advance(11)
  if not WV.cur() or #WV.states(w) < 1 then return "niente stato" end
  return true end)
-- chiave Groq
T("W41 key_paste Groq 200: salvata (chmod 600), eventi busy->ok, stato has/mask, la chiave non compare nel JS", function()
  PASTE = KEY; local w = openWeb(); local cn = #CURLARGS
  WV.send({ op = "key_paste" }, w); advance(0.05)
  local evs = WV.events(w); if #evs < 1 or evs[1].name ~= "key_status" or evs[1].data.kind ~= "busy" or not evs[1].data.msg then return "evento busy mancante" end
  advance(1)
  evs = WV.events(w); local last = evs[#evs]
  if not last or last.data.kind ~= "ok" or last.data.has ~= true or last.data.mask ~= KEY:sub(1, 4) .. "…" .. KEY:sub(-4) or not last.data.msg then return "esito: " .. tostring(last and last.data.kind) end
  if FAKE[C.keyPath] ~= KEY then return "chiave non salvata" end
  local chm = false; for _, e in ipairs(EXECS) do if e:find("chmod 600", 1, true) then chm = true end end
  if not chm then return "nessun chmod 600" end
  local s = WV.lastState(w); if s.groq.has ~= true or s.groq.mask ~= KEY:sub(1, 4) .. "…" .. KEY:sub(-4) then return "stato groq" end
  if anyJsHas(KEY) or anyJsHas(KEY:sub(5, -5)) then return "chiave nel JS" end
  if outHas(KEY) or outHas(KEY:sub(5, -5)) then return "chiave nei log" end
  if #CURLARGS ~= cn + 1 then return "curl " .. (#CURLARGS - cn) end
  return true end)
for _, c in ipairs({ { "http401", "401" }, { "http403", "403" }, { "http429", "429" }, { "fail", "rete" } }) do
  T("W42 key_paste Groq " .. c[2] .. ": errore, NIENTE salvato, nessuna chiave verso JS/log", function()
    CURLM = c[1]; PASTE = KEY; local w = openWeb()
    WV.send({ op = "key_paste" }, w); advance(2)
    local evs = WV.events(w); local last = evs[#evs]
    if not last or last.data.kind ~= "error" or last.data.has ~= false then return "esito " .. tostring(last and last.data.kind) end
    if FAKE[C.keyPath] ~= nil then return "chiave salvata con esito " .. c[2] end
    if WV.lastState(w).groq.has ~= false then return "has true" end
    if anyJsHas(KEY) or anyJsHas(KEY:sub(5, -5)) then return "chiave nel JS" end
    if outHas(KEY) or outHas(KEY:sub(5, -5)) then return "chiave nei log" end
    return true end)
end
T("W43 key_paste: appunti non validi/vuoti -> errore, nessun curl", function()
  local w = openWeb()
  for _, v in ipairs({ "", "   ", "ciao", "gsk_corta", "sk-" .. string.rep("a", 40), "gsk_" .. string.rep("a", 200), "gsk_" .. string.rep("a", 30) .. " spazio", "gsk_" .. string.rep("a", 25) }) do
    PASTE = v; local cn = #CURLARGS; local ne = #WV.events(w)
    WV.send({ op = "key_paste" }, w); advance(0.3)
    if #CURLARGS ~= cn then return "curl partito per " .. v:sub(1, 12) end
    local evs = WV.events(w); if #evs ~= ne + 1 or evs[#evs].data.kind ~= "error" then return "evento err mancante per '" .. v:sub(1, 12) .. "'" end
  end
  return true end)
T("W44 key_paste doppio click: un solo controllo alla volta", function()
  PASTE = KEY; local w = openWeb(); local cn = #CURLARGS
  WV.send({ op = "key_paste" }, w); WV.send({ op = "key_paste" }, w); WV.send({ op = "key_paste" }, w); advance(1)
  if #CURLARGS ~= cn + 1 then return "curl lanciati " .. (#CURLARGS - cn) end
  return true end)
T("W45 key_remove: chiave tolta, stato has=false, evento info", function()
  FAKE[C.keyPath] = KEY; local w = openWeb()
  if WV.lastState(w).groq.has ~= true then return "has iniziale" end
  WV.send({ op = "key_remove" }, w); advance(0.3)
  if FAKE[C.keyPath] ~= nil then return "file ancora presente" end
  if WV.lastState(w).groq.has ~= false then return "has dopo remove" end
  local evs = WV.events(w); if evs[#evs].data.kind ~= "ok" or evs[#evs].data.has ~= false then return "evento" end
  return true end)
T("W46 open_groq: apre il sito, evento info", function()
  local w = openWeb(); WV.send({ op = "open_groq" }, w); advance(0.2)
  local evs = WV.events(w); if #evs < 1 or evs[#evs].name ~= "key_status" then return "evento mancante" end
  return true end)
T("W47 chiusura finestra durante il controllo chiave: nessun errore, nessun JS dopo la chiusura", function()
  PASTE = KEY; local w = openWeb(); WV.send({ op = "key_paste" }, w); advance(0.05); WV.send({ op = "close" }, w); local n = #w.js; advance(2)
  if #w.js ~= n then return "JS dopo la chiusura" end
  if FAKE[C.keyPath] ~= KEY then return "chiave non salvata (il salvataggio deve completarsi)" end
  return true end)
-- tasti
T("W48 capture_start ss: nuovo tasto aggiunto, evento capture_result ok, stato aggiornato", function()
  local w = openWeb(); WV.send({ op = "capture_start", action = "ss" }, w); advance(0.1)
  if not ICON_CAP and not D.ICON.capTap then return "tap non armato" end
  deliver(ev(62, 12, { ctrl = true })); advance(0.2)
  local evs = WV.events(w); local r = evs[#evs]
  if not r or r.name ~= "capture_result" or r.data.ok ~= true or r.data.action ~= "ss" or type(r.data.label) ~= "string" or r.data.label == "" then return "evento" end
  if #C.ssBindings ~= 2 or #WV.lastState(w).keys.ss ~= 2 then return "binding non aggiunto" end
  if D.ICON.capTap then return "tap ancora armato" end
  if not persisted() or not tostring(persisted().ssBindings):find("62:ctrl:double", 1, true) then return "non persistito" end
  return true end)
T("W49 capture_start pause + tasto normale (consumato)", function()
  local w = openWeb(); WV.send({ op = "capture_start", action = "pause" }, w); advance(0.1)
  local eaten = deliver(ev(0, 10)); advance(0.2)
  if not eaten then return "tasto non consumato" end
  if #C.pauseBindings ~= 2 or C.pauseBindings[2].gesture ~= "single" then return "binding pausa" end
  local evs = WV.events(w); if evs[#evs].data.action ~= "pause" or evs[#evs].data.ok ~= true then return "evento" end
  return true end)
T("W50 capture + Esc: annullata, evento cancel, niente aggiunto", function()
  local w = openWeb(); WV.send({ op = "capture_start", action = "ss" }, w); advance(0.1)
  deliver(ev(53, 10)); advance(0.2)
  local evs = WV.events(w); local r = evs[#evs]
  if not r or r.data.ok ~= false or r.data.reason ~= "cancel" then return "evento" end
  if #C.ssBindings ~= 1 or D.ICON.capTap then return "stato" end
  return true end)
T("W51 capture: 10 s senza tasti -> timeout, evento, tap spento", function()
  local w = openWeb(); WV.send({ op = "capture_start", action = "ss" }, w); advance(9.5)
  if not D.ICON.capTap then return "scaduta troppo presto" end
  advance(1)
  local evs = WV.events(w); local r = evs[#evs]
  if not r or r.data.reason ~= "timeout" then return "evento timeout" end
  if D.ICON.capTap or deliver(ev(0, 10)) then return "ancora armata" end
  return true end)
T("W52 capture_cancel: annulla, evento; senza cattura attiva: nessun evento", function()
  local w = openWeb(); local n0 = #WV.events(w)
  WV.send({ op = "capture_cancel" }, w); advance(0.1)
  if #WV.events(w) ~= n0 then return "evento senza cattura" end
  WV.send({ op = "capture_start", action = "pause" }, w); advance(0.1)
  WV.send({ op = "capture_cancel" }, w); advance(0.1)
  local evs = WV.events(w); if #evs ~= n0 + 1 or evs[#evs].data.reason ~= "cancel" then return "evento cancel" end
  if deliver(ev(0, 10)) or #C.pauseBindings ~= 1 then return "cattura ancora armata" end
  return true end)
T("W53 capture + chiusura finestra: cattura annullata, la 'a' non diventa un tasto", function()
  local w = openWeb(); WV.send({ op = "capture_start", action = "ss" }, w); advance(0.1)
  WV.send({ op = "close" }, w); advance(1)
  if deliver(ev(0, 10)) or #C.ssBindings ~= 1 then return "cattura sopravvissuta" end
  return true end)
T("W54 capture_start action invalida ignorata", function()
  local w = openWeb()
  for _, a in ipairs({ "x", 5, {}, false }) do WV.send({ op = "capture_start", action = a }, w) end
  advance(0.2); if D.ICON.capTap then return "tap armato" end
  return true end)
T("W55 capture dup: stesso tasto due volte = una sola voce, evento ok con dup", function()
  local w = openWeb(); WV.send({ op = "capture_start", action = "ss" }, w); advance(0.1)
  deliver(ev(61, 12, { alt = true })); advance(0.2)
  if #C.ssBindings ~= 1 then return "duplicato aggiunto" end
  local evs = WV.events(w); if evs[#evs].data.dup ~= true then return "dup" end
  return true end)
T("W56 key_remove_binding / key_set_gesture: indice da 0, validazioni", function()
  C.ssBindings = { { kc = 61, mod = "alt", gesture = "double" }, { kc = 62, mod = "ctrl", gesture = "single" }, { kc = 54, mod = "cmd", gesture = "hold" } }
  local w = openWeb(); if #WV.lastState(w).keys.ss ~= 3 then return "stato iniziale" end
  WV.send({ op = "key_set_gesture", action = "ss", index = 1, gesture = "hold" }, w); advance(0.1)
  if C.ssBindings[2].gesture ~= "hold" then return "gesto non cambiato" end
  for _, g in ipairs({ "triple", 5, {}, false, "" }) do WV.send({ op = "key_set_gesture", action = "ss", index = 0, gesture = g }, w) end
  if C.ssBindings[1].gesture ~= "double" then return "gesto invalido accettato" end
  WV.send({ op = "key_set_gesture", action = "pause", index = 0, gesture = "hold" }, w); advance(0.1)
  if C.pauseBindings[1].gesture ~= "single" then return "hold accettato sulla pausa" end
  WV.send({ op = "key_set_gesture", action = "pause", index = 0, gesture = "double" }, w); advance(0.1)
  if C.pauseBindings[1].gesture ~= "double" then return "double pausa" end
  for _, i in ipairs({ -1, 3, 99, 0.5, "x", {}, 1e9 }) do
    WV.send({ op = "key_remove_binding", action = "ss", index = i }, w); WV.send({ op = "key_set_gesture", action = "ss", index = i, gesture = "hold" }, w) end
  if #C.ssBindings ~= 3 then return "rimosso con indice invalido: " .. #C.ssBindings end
  WV.send({ op = "key_remove_binding", action = "ss", index = 0 }, w); advance(0.1)
  if #C.ssBindings ~= 2 or C.ssBindings[1].kc ~= 62 then return "rimozione indice 0" end
  if #fresh(w).keys.ss ~= 2 then return "stato dopo rimozione" end
  WV.send({ op = "key_remove_binding", action = "boh", index = 0 }, w)
  if not tostring(persisted().ssBindings):find("62:ctrl:hold", 1, true) then return "non persistito: " .. tostring(persisted().ssBindings) end
  return true end)
-- drag
T("W57 drag_start: sposta la finestra col mouse, rilascio con mouse su", function()
  local w = openWeb(); local t0 = STATS().tapsOn
  w.fr.x, w.fr.y = 300, 200; MOUSE.x, MOUSE.y = 400, 250
  WV.send({ op = "drag_start" }, w); advance(0.05)
  if STATS().tapsOn ~= t0 + 1 then return "eventtap non acceso" end
  MOUSE.x, MOUSE.y = 450, 290; deliver(mev(6)); advance(0.01)
  if w.fr.x ~= 350 or w.fr.y ~= 240 then return "frame " .. w.fr.x .. "," .. w.fr.y end
  MOUSE.x, MOUSE.y = 500, 300; deliver(mev(6))
  if w.fr.x ~= 400 or w.fr.y ~= 250 then return "frame2 " .. w.fr.x .. "," .. w.fr.y end
  deliver(mev(2)); advance(0.05)
  if STATS().tapsOn ~= t0 then return "tap non spento al rilascio" end
  MOUSE.x = 800; deliver(mev(6)); if w.fr.x ~= 400 then return "si muove dopo il rilascio" end
  if W.pos.cx ~= 400 + w.fr.w / 2 then return "posizione non ricordata" end
  return true end)
T("W58 drag: mouse rilasciato fuori (nessun mouseUp) -> rilascio dal controllo bottoni", function()
  local w = openWeb(); local t0 = STATS().tapsOn
  WV.send({ op = "drag_start" }, w); advance(0.1)
  BUTTONS = {}; advance(0.5)
  if STATS().tapsOn ~= t0 then return "tap ancora acceso" end
  return true end)
T("W59 drag: timeout di sicurezza a 15 s anche con bottone 'giu'", function()
  local w = openWeb(); local t0 = STATS().tapsOn
  WV.send({ op = "drag_start" }, w); advance(14)
  if STATS().tapsOn ~= t0 + 1 then return "rilasciato troppo presto" end
  advance(2); if STATS().tapsOn ~= t0 then return "non rilasciato dopo 15 s" end
  return true end)
T("W60 drag + chiusura finestra: tap spento; drag doppio = un solo tap", function()
  local w = openWeb(); local t0 = STATS().tapsOn
  WV.send({ op = "drag_start" }, w); WV.send({ op = "drag_start" }, w); WV.send({ op = "drag_start" }, w)
  if STATS().tapsOn ~= t0 + 1 then return "tap " .. (STATS().tapsOn - t0) end
  WV.send({ op = "close" }, w); advance(0.5)
  if STATS().tapsOn ~= t0 - 1 then return "tap vivo dopo chiusura (t0=" .. t0 .. " ora " .. STATS().tapsOn .. ")" end
  return true end)
T("W61 drag: clamp, la finestra resta in parte visibile", function()
  local w = openWeb(); w.fr.x, w.fr.y = 300, 200; MOUSE.x, MOUSE.y = 400, 250
  WV.send({ op = "drag_start" }, w); MOUSE.x, MOUSE.y = -50000, -50000; deliver(mev(6))
  if w.fr.x < -w.fr.w or w.fr.y < 0 then return "fuori schermo " .. w.fr.x .. "," .. w.fr.y end
  MOUSE.x, MOUSE.y = 50000, 50000; deliver(mev(6))
  if w.fr.x > SCREENT.w or w.fr.y > SCREENT.h then return "fuori schermo (basso/destra) " .. w.fr.x .. "," .. w.fr.y end
  deliver(mev(2)); return true end)
-- resize
T("W62 resize_request: la prima misura subito, poi animata ease-out, centro x e bordo alto fissi", function()
  local w = openWeb(); advance(1)
  w.fr.x, w.fr.y, w.fr.w, w.fr.h = 400, 100, 500, 400
  local cx = 400 + 250
  local n0 = w.nframe or 0
  WV.send({ op = "resize_request", w = 700, h = 600 }, w)
  local prev, steps, mono = 400 - 0, 0, true
  local widths = {}
  for i = 1, 20 do advance(1 / 60); widths[#widths + 1] = w.fr.w end
  if w.fr.w ~= 700 or w.fr.h ~= 600 then return "finale " .. w.fr.w .. "x" .. w.fr.h end
  if math.abs(w.fr.x + w.fr.w / 2 - cx) > 0.01 then return "centro x spostato " .. (w.fr.x + w.fr.w / 2) end
  if w.fr.y ~= 100 then return "bordo alto spostato " .. w.fr.y end
  local nf = (w.nframe or 0) - n0
  if nf < 4 or nf > 10 then return "passi " .. nf end
  for i = 2, #widths do if widths[i] < widths[i - 1] - 1e-9 then return "non monotona" end end
  local d1, d2 = widths[1] - 500, widths[2] - widths[1]
  local firstStep = widths[1]
  local last = widths[#widths]; local before = 700
  -- ease-out: il primo passo e' il piu' grande
  local steps_ = {}; local pw = 500; for i = 1, #widths do steps_[#steps_ + 1] = widths[i] - pw; pw = widths[i] end
  if steps_[1] < steps_[3] then return "non ease-out: " .. steps_[1] .. " " .. steps_[3] end
  return true end)
T("W63 resize iniziale (entro 0,6 s da ready): applicato subito, senza animare", function()
  C.settingsUI = "web"; M.settings("general"); advance(0.05); local w = WV.cur()
  WV.send({ op = "ready" }, w); advance(0.1); local n0 = w.nframe or 0
  WV.send({ op = "resize_request", w = 640, h = 520 }, w)
  if w.fr.w ~= 640 or w.fr.h ~= 520 then return "non immediato" end
  if (w.nframe or 0) - n0 ~= 1 then return "frame impostati " .. ((w.nframe or 0) - n0) end
  return true end)
T("W64 resize: clamp allo schermo (grande, negativo, NaN, stringhe)", function()
  local w = openWeb(); advance(1); local f0 = { w.fr.x, w.fr.y, w.fr.w, w.fr.h }
  WV.send({ op = "resize_request", w = 99999, h = 99999 }, w); advance(0.5)
  if w.fr.w > SCREENT.w or w.fr.h > SCREENT.h or w.fr.x < SCREENT.x or w.fr.y < SCREENT.y or w.fr.y + w.fr.h > SCREENT.y + SCREENT.h or w.fr.x + w.fr.w > SCREENT.x + SCREENT.w then
    return "fuori schermo " .. w.fr.x .. "," .. w.fr.y .. " " .. w.fr.w .. "x" .. w.fr.h end
  WV.send({ op = "resize_request", w = -10, h = 0 }, w); advance(0.5)
  if w.fr.w < 240 or w.fr.h < 160 then return "troppo piccola " .. w.fr.w .. "x" .. w.fr.h end
  local fw, fh = w.fr.w, w.fr.h
  for _, v in ipairs({ { 0 / 0, 300 }, { 300, math.huge }, { "x", 300 }, { {}, {} }, { nil, nil } }) do
    WV.send({ op = "resize_request", w = v[1], h = v[2] }, w); advance(0.5)
    if w.fr.w ~= fw or w.fr.h ~= fh then return "valore invalido ha ridimensionato" end
  end
  return true end)
T("W65 resize vicino al bordo basso: la cima sale per restare dentro lo schermo", function()
  local w = openWeb(); advance(1); w.fr.x, w.fr.y, w.fr.w, w.fr.h = 400, 700, 500, 150
  WV.send({ op = "resize_request", w = 500, h = 600 }, w); advance(0.5)
  if w.fr.y + w.fr.h > SCREENT.y + SCREENT.h + 0.01 then return "esce dal basso: " .. w.fr.y .. "+" .. w.fr.h end
  return true end)
T("W66 resize ripetuti in raffica: un solo timer, finale giusto, nessun residuo", function()
  local w = openWeb(); advance(1); local t0 = STATS().every
  for i = 1, 40 do WV.send({ op = "resize_request", w = 300 + i * 10, h = 300 + i * 5 }, w); advance(0.01) end
  advance(1)
  if w.fr.w ~= 700 or w.fr.h ~= 500 then return "finale " .. w.fr.w .. "x" .. w.fr.h end
  if STATS().every > t0 then return "timer ricorrente residuo" end
  return true end)
T("W67 resize + chiusura durante l'animazione: nessun errore, nessun frame dopo", function()
  local w = openWeb(); advance(1); WV.send({ op = "resize_request", w = 800, h = 600 }, w); advance(0.03)
  WV.send({ op = "close" }, w); advance(0.5)
  local n = w.nframe or 0; advance(1)
  if (w.nframe or 0) ~= n then return "frame dopo la chiusura" end
  return true end)
T("W68 resize: tetto di sicurezza w<=820 h<=760 (anche se lo schermo e' enorme), mai oltre schermo-24", function()
  local w = openWeb(); advance(1)
  if W.maxW ~= 820 or W.maxH ~= 760 then return "costanti " .. tostring(W.maxW) .. "x" .. tostring(W.maxH) end
  WV.send({ op = "resize_request", w = 5000, h = 5000 }, w); advance(0.5)
  if w.fr.w ~= 820 or w.fr.h ~= 760 then return "tetto non applicato: " .. w.fr.w .. "x" .. w.fr.h end
  WV.send({ op = "resize_request", w = 800, h = 1100 }, w); advance(0.5)
  if w.fr.h ~= 760 then return "h 1100 -> " .. w.fr.h end
  WV.send({ op = "resize_request", w = 432, h = 680 }, w); advance(0.5)
  if w.fr.w ~= 432 or w.fr.h ~= 680 then return "valori sotto il tetto alterati: " .. w.fr.w .. "x" .. w.fr.h end
  local o = { SCREENT.w, SCREENT.h }
  SCREENT.w, SCREENT.h = 600, 500
  WV.send({ op = "resize_request", w = 5000, h = 5000 }, w); advance(0.5)
  SCREENT.w, SCREENT.h = o[1], o[2]
  if w.fr.w > 576 or w.fr.h > 476 then return "schermo piccolo: " .. w.fr.w .. "x" .. w.fr.h end
  return true end)
-- asset
local function themesBase() return (C.keyPath:gsub("/api_key$", "")) .. "/themes" end
local function vfsAsset(sid, name, size, content, mode)
  local p = themesBase() .. "/" .. sid .. "/" .. name
  VFS.attr[p] = { mode = mode or "file", size = size or #content }; FAKE[p] = content
  local l = VFS.dirs[themesBase() .. "/" .. sid]; l[#l + 1] = name
  return p
end
local function vfsStyle(sid)
  VFS.attr[themesBase()] = VFS.attr[themesBase()] or { mode = "directory" }
  VFS.dirs[themesBase()] = VFS.dirs[themesBase()] or {}
  local l = VFS.dirs[themesBase()]; l[#l + 1] = sid
  VFS.attr[themesBase() .. "/" .. sid] = { mode = "directory" }; VFS.dirs[themesBase() .. "/" .. sid] = {}
end
local function furl(sid, name) return "file://" .. themesBase():gsub("([^%w%-%._~/])", function(c) return string.format("%%%02X", c:byte()) end) .. "/" .. sid .. "/" .. name end
T("W68 asset: png/gif del tema -> URL file:// in state.assets (una volta sola), nessuna lettura dei file", function()
  vfsStyle("gold"); vfsAsset("gold", "icon.png", nil, "\137PNGdata1"); vfsAsset("gold", "spin.gif", nil, "GIF89aXYZ")
  local w = openWeb(); advance(1)
  local got
  for _, s in ipairs(WV.states(w)) do if s.assets then if got then return "assets inviati due volte" end got = s.assets end end
  if not got then return "nessun asset" end
  if got.gold.icon ~= furl("gold", "icon.png") then return "icon: " .. tostring(got.gold.icon) end
  if got.gold.spin ~= furl("gold", "spin.gif") then return "spin" end
  if VFS.reads ~= 0 then return "file letti/codificati: " .. VFS.reads end
  if fresh(w).assets then return "assets rimandati negli stati successivi" end
  return true end)
T("W69 asset: filtri (stile sconosciuto, traversal, estensioni, symlink, >5MB, nomi strani)", function()
  vfsStyle("gold"); vfsStyle("nonesiste"); vfsStyle("..")
  vfsAsset("gold", "ok.png", nil, "PNG1"); vfsAsset("gold", "big.png", 6 * 1024 * 1024, "BIG"); vfsAsset("gold", "x.svg", nil, "<svg onload=alert(1)>")
  vfsAsset("gold", "link.png", nil, "SECRET", "link"); vfsAsset("gold", ".hidden.png", nil, "H"); vfsAsset("gold", "a b.png", nil, "SP"); vfsAsset("gold", "../api_key", nil, "K")
  vfsAsset("gold", "empty.png", 0, ""); vfsAsset("gold", "x.PNG", nil, "UP"); vfsAsset("gold", "dir.png", nil, "D", "directory")
  vfsAsset("nonesiste", "z.png", nil, "Z")
  local w = openWeb(); advance(1)
  local a; for _, s in ipairs(WV.states(w)) do if s.assets then a = s.assets end end
  if not a then return "nessun asset" end
  if a.nonesiste or a[".."] then return "stile non valido" end
  local n = 0; for k in pairs(a.gold) do n = n + 1 end
  if a.gold.ok == nil or a.gold.x == nil then return "ok/x mancanti" end
  for _, bad in ipairs({ "big", "link", "hidden", "empty", "dir", "a b", "api_key" }) do if a.gold[bad] ~= nil then return "accettato " .. bad end end
  if n ~= 2 then return "chiavi gold " .. n end
  return true end)
T("W70 asset: tetto 20 file/stile", function()
  vfsStyle("gold"); for i = 1, 30 do vfsAsset("gold", string.format("f%02d.png", i), nil, "P" .. i) end
  local w = openWeb(); advance(1)
  local a; for _, s in ipairs(WV.states(w)) do if s.assets then a = s.assets end end
  local n = 0; for k in pairs(a.gold) do n = n + 1 end
  if n ~= 20 then return "file " .. n end
  return true end)
T("W71 asset: nessuna cartella temi -> nessun assets nello stato, nessun errore", function()
  local w = openWeb(); advance(1)
  for _, s in ipairs(WV.states(w)) do if s.assets then return "assets senza cartella" end end
  return true end)
T("W72 asset: chiusura durante la scansione: nessun JS, nessun residuo", function()
  for i = 1, 40 do local sid = D.O[i]; vfsStyle(sid); vfsAsset(sid, "icon.png", nil, "P" .. i) end
  local w = openWeb(); WV.send({ op = "close" }, w); local n = #w.js; advance(3)
  if #w.js ~= n then return "JS dopo la chiusura" end
  return true end)
T("W73 asset: la scelta del metodo e' sostituibile (ICON.web.assetUrl)", function()
  vfsStyle("gold"); vfsAsset("gold", "icon.png", nil, "ZZZ")
  local old = W.assetUrl; W.assetUrl = function(p, ext) return "data:fake/" .. ext end
  local w = openWeb(); advance(1); W.assetUrl = old
  local a; for _, s in ipairs(WV.states(w)) do if s.assets then a = s.assets end end
  if not a or a.gold.icon ~= "data:fake/png" then return "assetUrl sostituita ignorata" end
  return true end)
T("W74 asset: URL con spazi/unicode nel percorso percent-encoded", function()
  local old = C.keyPath
  vfsStyle("gold"); vfsAsset("gold", "icon.png", nil, "Q")
  local w = openWeb(); advance(1)
  local a; for _, s in ipairs(WV.states(w)) do if s.assets then a = s.assets end end
  if not a or a.gold.icon:find("[ \128-\255\"'<>]") then return "URL non codificato" end
  return true end)
-- pagina su file, ripiego html(), focus, watchdog, Esc
T("W75 scrittura pagina fallita: html(str), asset disattivati, finestra funziona", function()
  WRITEFAIL = true; vfsStyle("gold"); vfsAsset("gold", "icon.png", nil, "Q")
  local w = openWeb(); advance(1)
  if w.url ~= nil or not w.html or not w.html:find("Content-Security-Policy", 1, true) then return "html() non usato" end
  for _, s in ipairs(WV.states(w)) do if s.assets then return "asset con html()" end end
  if #WV.states(w) < 1 then return "nessuno stato" end
  return true end)
T("W76 pagina riscritta a ogni apertura (segue gli aggiornamenti); chmod 600 una volta", function()
  local w = openWeb(); closeWeb()
  FAKE[PAGE] = "VECCHIA"; local n0 = 0; for _, e in ipairs(EXECS) do if e:find("chmod 600 '" .. PAGE, 1, true) then n0 = n0 + 1 end end
  w = openWeb(); if FAKE[PAGE] == "VECCHIA" or not FAKE[PAGE]:find("Content-Security-Policy", 1, true) then return "non riscritta" end
  local n1 = 0; for _, e in ipairs(EXECS) do if e:find("chmod 600 '" .. PAGE, 1, true) then n1 = n1 + 1 end end
  if n1 ~= n0 then return "chmod ripetuto" end
  return true end)
T("W77 interact: se Hammerspoon ha rubato il focus, si riattiva l'app precedente; altrimenti no", function()
  FRONT = "slack"; local w = openWeb()
  WV.send({ op = "interact" }, w); advance(0.5)
  if (ACT.slack or 0) ~= 0 then return "riattivata senza furto" end
  FRONT = "hs"; WV.send({ op = "interact" }, w); advance(0.5)
  if FRONT ~= "slack" or ACT.slack ~= 1 then return "focus non restituito: " .. FRONT end
  FRONT = "mail"; WV.send({ op = "interact" }, w); advance(0.5)
  if FRONT ~= "mail" then return "toccato il focus di un'altra app" end
  FRONT = "hs"; for i = 1, 20 do WV.send({ op = "interact" }, w) end
  if (ACT.slack or 0) > 2 then return "attivazioni a raffica: " .. ACT.slack end
  return true end)
T("W78 interact senza app precedente (HS era gia' in primo piano): nessun errore", function()
  FRONT = "hs"; local w = openWeb(); WV.send({ op = "interact" }, w); advance(0.3)
  if (ACT.slack or 0) ~= 0 or (ACT.hs or 0) ~= 0 then return "attivazioni" end
  return true end)
T("W79 watchdog: url() nil (WebContent morto) -> ricrea; dopo 2 ricreazioni, canvas", function()
  local w = openWeb(); advance(1)
  local n0 = #WV.list
  w.crashed = true; advance(1.5)
  local w2 = WV.cur(); if not w2 or w2 == w or #WV.list ~= n0 + 1 then return "non ricreata" end
  if not w.deleted then return "vecchia non distrutta" end
  WV.send({ op = "ready" }, w2); advance(0.5)
  if #WV.states(w2) < 1 then return "nessuno stato dopo ricreazione" end
  w2.crashed = true; advance(1.5)
  local w3 = WV.cur(); if not w3 or w3 == w2 then return "seconda ricreazione mancata" end
  WV.send({ op = "ready" }, w3); advance(0.5)
  w3.crashed = true; advance(1.5)
  if not D.scv() then return "dopo 2 ricreazioni non cade sulla canvas" end
  if WV.live() ~= 0 then return "webview vive " .. WV.live() end
  return true end)
T("W80 watchdog: battito `hb` regolare = nessuna ricreazione; senza battito per 3 s (dopo il primo) = ricrea", function()
  local w = openWeb(); local n0 = #WV.list
  for i = 1, 8 do WV.send({ op = "hb" }, w); advance(1) end
  if #WV.list ~= n0 then return "ricreata con battito regolare" end
  advance(2.5); if #WV.list ~= n0 then return "ricreata troppo presto (2.5 s)" end
  advance(1.5); if #WV.list ~= n0 + 1 then return "non ricreata dopo 4 s senza battito" end
  return true end)
T("W81 watchdog: pagina che non manda mai hb (stub) e url ok: mai ricreata", function()
  local w = openWeb(); local n0 = #WV.list; advance(30)
  if #WV.list ~= n0 or D.scv() then return "ricreata/canvas senza hb" end
  return true end)
T("W82 Esc: chiude se il mouse e' sopra la finestra; non ingoia mai il tasto", function()
  local w = openWeb(); local f = w.fr
  MOUSE.x, MOUSE.y = f.x + 10, f.y + 10
  local eaten = deliver(ev(53, 10)); advance(0.3)
  if eaten then return "Esc ingoiato" end
  if WV.cur() then return "non chiusa" end
  return true end)
T("W83 Esc con mouse fuori dalla finestra o con cattura tasto: non chiude", function()
  local w = openWeb(); local f = w.fr
  MOUSE.x, MOUSE.y = f.x + f.w + 50, f.y + f.h + 50
  deliver(ev(53, 10)); advance(0.3)
  if not WV.cur() then return "chiusa con mouse fuori" end
  MOUSE.x, MOUSE.y = f.x + 10, f.y + 10
  WV.send({ op = "capture_start", action = "ss" }, w); advance(0.1)
  deliver(ev(53, 10)); advance(0.3)
  if not WV.cur() then return "chiusa durante la cattura" end
  deliver(ev(0, 11)); deliver(ev(36, 10)); advance(0.2)
  return true end)
T("W84 Esc/tap spenti alla chiusura (nessun tap residuo)", function()
  local t0 = STATS().tapsOn; local w = openWeb()
  if STATS().tapsOn ~= t0 + 1 then return "tap Esc non acceso: " .. (STATS().tapsOn - t0) end
  WV.send({ op = "close" }, w); advance(0.5)
  if STATS().tapsOn ~= t0 then return "tap residuo" end
  return true end)
return "TOTALE web2: test " .. ntest .. ", falliti " .. nfail .. "\n" .. table.concat(OUT, "\n")
