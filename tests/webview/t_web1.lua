-- WEB 1: ciclo di vita, fallback a canvas, configurazione finestra, navigazione, stato, throttle, JSON, nessun CoreAudio
local base = STATS()
T("W1 default settingsUI=canvas: si apre la canvas, nessuna webview", function()
  if C.settingsUI ~= "canvas" and DEF.settingsUI ~= "canvas" then return "default non canvas" end
  M.settings("keys"); advance(0.5)
  if WV.live() ~= 0 then return "webview creata col default canvas" end
  if not D.scv() then return "canvas non aperta" end
  return true end)
T("W2 settingsUI=web: webview (non canvas), configurazione finestra", function()
  C.settingsUI = "web"; M.settings("general"); advance(0.05)
  local w = WV.cur(); if not w then return "nessuna webview" end
  if D.scv() then return "canvas aperta insieme alla webview" end
  local cf = w.cfg
  local e = eq(cf.windowStyle, 0 + 128, "windowStyle") or eq(cf.transparent, true, "transparent") or eq(cf.shadow, false, "shadow")
    or eq(cf.allowTextEntry, false, "allowTextEntry") or eq(cf.allowNewWindows, false, "allowNewWindows") or eq(cf.privateBrowsing, true, "privateBrowsing")
    or eq(cf.behavior, 257, "behavior") or eq(cf.level, 1, "level")
  if e then return e end
  if cf.darkMode ~= nil then return "darkMode forzato" end
  if w.alpha ~= 0 or not w.shown then return "prima di ready: alpha " .. tostring(w.alpha) .. " shown " .. tostring(w.shown) end
  if #w.js ~= 0 then return "JS inviato prima di ready" end
  if w.url ~= "file://" .. PAGE or w.html ~= nil then return "pagina non caricata da file: " .. tostring(w.url) end
  local pg = FAKE[PAGE]; if not pg then return "pagina non scritta su file" end
  if not pg:find("Content-Security-Policy", 1, true) then return "CSP non iniettata" end
  if not pg:find("connect-src 'none'", 1, true) or not pg:find("img-src data: file: blob:", 1, true) then return "CSP incompleta" end
  local hs_, he = pg:find("<head[^>]*>"); local ms = pg:find("Content-Security-Policy", 1, true)
  if not hs_ or ms < hs_ or ms > he + 400 then return "CSP non subito dopo <head>" end
  if not pg:find(D.ICON.webHtml:sub(300, 380), 1, true) then return "pagina non e' quella incollata" end
  if w.cfg.windowStyleTable ~= true then return "windowStyle non passato come tabella" end
  if w.base ~= nil then return "baseURL impostata" end
  WV.send({ op = "ready" }, w); advance(0.2)
  if w.alpha ~= 1 then return "dopo ready alpha " .. w.alpha end
  if nstate(w) ~= 1 then return "onState dopo ready: " .. nstate(w) end
  return true end)
T("W3 nessun ready entro 4 s: fallback a canvas, webview distrutta, poi canvas diretta", function()
  C.settingsUI = "web"; M.settings("general"); advance(3.5)
  if D.scv() then return "canvas troppo presto" end
  advance(1)
  if not D.scv() then return "nessun fallback a canvas dopo 4 s" end
  if WV.live() ~= 0 then return "webview non distrutta" end
  if not W.failed then return "failed non impostato" end
  pcall(D.sclose); advance(1)
  local n0 = #WV.list
  M.settings("general"); advance(0.5)
  if #WV.list ~= n0 then return "ritenta la webview dopo un fallimento: " .. (#WV.list - n0) end
  if not D.scv() then return "seconda apertura non su canvas" end
  return true end)
T("W4 ready arriva a 3,9 s: nessun fallback", function()
  C.settingsUI = "web"; M.settings("general"); advance(3.9)
  local w = WV.cur(); WV.send({ op = "ready" }, w); advance(1)
  if D.scv() then return "fallback nonostante ready" end
  if not WV.cur() then return "webview sparita" end
  return true end)
T("W5 hs.webview assente: canvas", function()
  local n0 = #WV.list
  HSF.webview = false; C.settingsUI = "web"; M.settings("theme"); advance(0.5)
  if not D.scv() then return "nessun fallback" end
  if #WV.list ~= n0 then return "webview creata" end
  return true end)
T("W6 usercontent assente: canvas", function()
  HSF.webview = { new = WVMOD.new, windowMasks = WV_MASKS }; C.settingsUI = "web"; M.settings("theme"); advance(0.5)
  if not D.scv() then return "nessun fallback" end
  return true end)
T("W7 hs.webview.new lancia: canvas, nessun residuo", function()
  WV.mode = "newthrows"; C.settingsUI = "web"; M.settings("theme"); advance(0.5)
  if not D.scv() then return "nessun fallback" end
  if WV.liveUC() ~= 0 then return "usercontent orfano con callback" end
  return true end, "hs.webview.new: simulato")
T("W8 hs.webview.new torna nil: canvas", function()
  WV.mode = "newnil"; C.settingsUI = "web"; M.settings("theme"); advance(0.5)
  if not D.scv() then return "nessun fallback" end
  if WV.liveUC() ~= 0 then return "usercontent orfano" end
  return true end, "ha restituito nil")
T("W9 pagina non incollata (ICON.webHtml nil): canvas", function()
  local h = D.ICON.webHtml; D.ICON.webHtml = nil
  C.settingsUI = "web"; M.settings("theme"); advance(0.5)
  D.ICON.webHtml = h
  if not D.scv() then return "nessun fallback" end
  return true end)
T("W10 op fallback dalla pagina: chiude la web e apre la canvas", function()
  local w = openWeb(); WV.send({ op = "fallback" }, w); advance(0.5)
  if not D.scv() or WV.live() ~= 0 then return "fallback non eseguito" end
  return true end)
T("W11 close dalla pagina: nascosta subito, distrutta dopo, nessuna canvas", function()
  local w = openWeb(); WV.send({ op = "close" }, w)
  if w.shown then return "ancora visibile" end
  advance(0.5)
  if not w.deleted then return "non distrutta" end
  if WV.liveUC() ~= 0 then return "usercontent con callback" end
  if D.scv() then return "canvas comparsa" end
  return true end)
T("W12 riaprire con la finestra gia' aperta: nessuna seconda webview, stato fresco", function()
  local w = openWeb(); local n0 = nstate(w)
  M.settings("general"); advance(0.3); M.settings("keys"); advance(0.3)
  if WV.live() ~= 1 then return "webview vive " .. WV.live() end
  if nstate(w) <= n0 then return "nessuno stato fresco" end
  if WV.lastState(w).tab ~= "keys" then return "tab " .. tostring(WV.lastState(w).tab) end
  return true end)
T("W13 apri/chiudi x50: nessun residuo", function()
  advance(15); local s0 = STATS()
  for i = 1, 50 do
    C.settingsUI = "web"; M.settings(({ "general", "keys", "theme" })[i % 3 + 1]); advance(0.02)
    local w = WV.cur(); WV.send({ op = "ready" }, w); advance(0.06)
    WV.send({ op = "set", key = "style", value = (i % 2 == 0) and "ocean" or "gold" }, w)
    WV.send({ op = "drag_start" }, w); WV.send({ op = "resize_request", w = 600 + i, h = 500 }, w); WV.send({ op = "capture_start", action = "ss" }, w)
    advance(0.05)
    if i % 2 == 0 then WV.send({ op = "close" }, w) else M.settings("general"); pcall(D.sclose) end
    advance(0.2)
  end
  advance(12)
  local s1 = STATS()
  if WV.live() ~= 0 then return "webview vive " .. WV.live() end
  if WV.liveUC() ~= 0 then return "usercontent vivi " .. WV.liveUC() end
  if s1.tapsOn ~= s0.tapsOn then return "eventtap acceso: " .. s1.tapsOn end
  if s1.every ~= s0.every then return "timer ricorrenti " .. s0.every .. " -> " .. s1.every end
  if s1.once ~= s0.once then return "timer one-shot " .. s0.once .. " -> " .. s1.once end
  if s1.cvLive ~= s0.cvLive then return "canvas vive " .. s1.cvLive end
  return true end)
T("W14 policy di navigazione: solo about:blank / data: / file:// temi", function()
  local w = openWeb(); local P = w.policy; if not P then return "nessuna policyCallback" end
  local home = C.keyPath:gsub("/%.config/groq%-dictation/api_key$", "")
  local ok = { "about:blank", "data:text/html,<b>x</b>", "data:image/png;base64,AAAA", "file://" .. home .. "/.config/groq-dictation/themes/gold/icon.png",
    "file://" .. home .. "/.config/groq-dictation/ui/settings.html", "file://" .. home .. "/.config/groq-dictation/themes/gold/spazio%20x.gif" }
  local no = { "https://example.com/", "http://127.0.0.1:8080/", "file:///etc/passwd", "file://" .. home .. "/.config/groq-dictation/api_key",
    "file://" .. home .. "/.config/groq-dictation/themes/../api_key", "file://" .. home .. "/.config/groq-dictation/themes/%2e%2e/api_key",
    "file://" .. home .. "/.config/groq-dictation/ui/other.html", "file://" .. home .. "/.config/groq-dictation/uix/settings.html", "javascript:alert(1)", "ftp://x/", "x-apple.systempreferences:" }
  for _, u in ipairs(ok) do
    if P("navigationAction", w, { request = { URL = u } }) ~= true then return "negato: " .. u end
    if P("navigationAction", w, { request = { URL = { url = u } } }) ~= true then return "negato (URL tabella): " .. u end
  end
  for _, u in ipairs(no) do
    if P("navigationAction", w, { request = { URL = u } }) ~= false then return "permesso: " .. u end
    if P("navigationAction", w, { request = { url = u } }) ~= false then return "permesso (url minuscolo): " .. u end
    if P("navigationAction", w, { request = { URL = { url = u } } }) ~= false then return "permesso (URL tabella): " .. u end
    if P("navigationResponse", w, { response = { URL = { url = u } } }) ~= false then return "permesso (response tabella): " .. u end
    if P("navigationResponse", w, { response = { URL = u } }) ~= false then return "permesso (response): " .. u end
  end
  if P("newWindow", w, { request = { URL = "about:blank" } }) ~= false then return "newWindow permessa" end
  if P("authenticationChallenge", w, {}) ~= false then return "challenge permessa" end
  return true end)
T("W15 caricamento fallito prima di ready: fallback subito", function()
  C.settingsUI = "web"; M.settings("general"); advance(0.05)
  local w = WV.cur(); w.nav("didFailProvisionalNavigation", w, "err"); advance(0.3)
  if not D.scv() then return "nessun fallback" end
  return true end)
T("W16 navigazione fallita DOPO ready (annullata dalla policy): ignorata", function()
  local w = openWeb(); w.nav("didFailNavigation", w, "cancelled"); advance(0.3)
  if D.scv() or not WV.cur() then return "chiusa per un errore di navigazione annullata" end
  return true end)
T("W17 stato: forma completa, tutti gli stili, cats, token hex", function()
  local w = openWeb(); local s = WV.lastState(w)
  if type(s.version) ~= "string" then return "version" end
  local O = D.O
  if #s.styles ~= #O then return "stili " .. #s.styles .. " attesi " .. #O end
  local seen = {}
  for i, st in ipairs(s.styles) do
    if st.id ~= O[i] then return "ordine stili @" .. i end
    seen[st.id] = true
    for _, m in ipairs({ "dark", "light" }) do
      local t = st[m]
      for _, k in ipairs({ "bg1", "bg2", "fg", "fg2", "accent" }) do if type(t[k]) ~= "string" or not t[k]:match("^#%x%x%x%x%x%x$") then return st.id .. "." .. m .. "." .. k .. " = " .. tostring(t[k]) end end
      if type(t.grad) ~= "table" or #t.grad < 2 then return st.id .. " grad" end
      for _, g in ipairs(t.grad) do if not g:match("^#%x%x%x%x%x%x$") then return st.id .. " grad hex" end end
    end
    if type(st.name) ~= "string" or st.name == "" then return st.id .. " name" end
    if type(st.cat) ~= "string" then return st.id .. " cat" end
  end
  for id in pairs(D.F) do if not seen[id] then return "stile mancante " .. id end end
  local blocky; for _, st in ipairs(s.styles) do if st.id == "blocky" then blocky = st end end
  if not blocky or not blocky.fx or blocky.fx.icon ~= "blockmic" or blocky.fx.bar ~= "pixel" then return "fx blocky" end
  for _, st in ipairs(s.styles) do if st.id == "gold" and st.fx ~= nil then return "gold ha fx" end end
  if #s.cats < 2 or s.cats[1].id ~= "all" then return "cats" end
  for _, k in ipairs({ "style", "themeMode", "glassOpacity", "cornerStyle", "animOn", "animSpeed", "waveStyle", "waveColor", "micPulse", "glowOn",
    "uiFont", "timerFont", "density", "idleOpacity", "shadowOn", "shadowIntensity" }) do if s.look[k] == nil then return "look." .. k .. " mancante" end end
  if type(s.look.animOn) ~= "boolean" or type(s.look.glassOpacity) ~= "number" then return "tipi look" end
  if s.effectiveMode ~= "dark" then return "effectiveMode " .. tostring(s.effectiveMode) end
  if s.general.sizePreset ~= "standard" or s.general.orientation ~= "horizontal" then return "general" end
  if type(s.keys.ss) ~= "table" or #s.keys.ss ~= 1 or s.keys.ss[1].gesture ~= "double" or type(s.keys.ss[1].label) ~= "string" then return "keys.ss" end
  if #s.keys.pause ~= 1 or s.keys.pause[1].gesture ~= "single" then return "keys.pause" end
  if s.groq.has ~= false or s.groq.mask ~= nil then return "groq senza chiave" end
  return true end)
T("W18 themeMode auto: effectiveMode segue il sistema", function()
  C.themeMode = "auto"; local w = openWeb(); local s = WV.lastState(w)
  if s.look.themeMode ~= "auto" then return "themeMode " .. tostring(s.look.themeMode) end
  if s.effectiveMode ~= "dark" and s.effectiveMode ~= "light" then return "effective " .. tostring(s.effectiveMode) end
  return true end)
T("W19 chiave salvata: mask = prime 4 + ... + ultime 4, mai la chiave intera", function()
  FAKE[C.keyPath] = KEY
  local w = openWeb(); local s = WV.lastState(w)
  if s.groq.has ~= true then return "has" end
  if s.groq.mask ~= KEY:sub(1, 4) .. "…" .. KEY:sub(-4) then return "mask " .. tostring(s.groq.mask) end
  if anyJsHas(KEY) then return "la chiave intera e' finita nel JS" end
  if anyJsHas(KEY:sub(5, -5)) then return "pezzo centrale della chiave nel JS" end
  return true end)
T("W20 throttle: 40 random_look nello stesso istante = al massimo 2 onState, l'ultimo stato e' quello giusto", function()
  local w = openWeb(); advance(0.1); local n0 = nstate(w)
  for i = 1, 40 do WV.send({ op = "random_look" }, w) end
  advance(0.3)
  local n = nstate(w) - n0
  if n > 2 or n < 1 then return "onState " .. n end
  if WV.lastState(w).look.style ~= C.style then return "ultimo stato non allineato" end
  return true end)
T("W21 throttle nel tempo: 1 op ogni 10 ms per 2 s = onState distanziati di almeno 50 ms", function()
  local w = openWeb(); advance(0.1); local n0 = #w.js
  for i = 1, 200 do WV.send({ op = "random_look" }, w); advance(0.01) end
  advance(0.2)
  local nn, last = 0, nil
  for i = n0 + 1, #w.js do
    if w.js[i]:find("^gw%.onState") then
      nn = nn + 1
      if last and w.jt[i] - last < 0.049 then return "onState a " .. string.format("%.3f", w.jt[i] - last) .. " s dal precedente" end
      last = w.jt[i]
    end
  end
  if nn < 10 then return "troppo pochi: " .. nn end
  return true end)
T("W21b set validi: NESSUN eco (UI ottimistica); valore corretto -> eco; themeMode -> eco", function()
  local w = openWeb(); advance(0.2); local n0 = nstate(w)
  for _, o in ipairs({ { "style", "ocean" }, { "animSpeed", "calm" }, { "glassOpacity", 0.7 }, { "micPulse", 0.2 }, { "sizePreset", "large" }, { "orientation", "vertical" }, { "glowOn", true } }) do
    WV.send({ op = "set", key = o[1], value = o[2] }, w); advance(0.3)
  end
  if nstate(w) ~= n0 then return "eco su set validi: " .. (nstate(w) - n0) end
  WV.send({ op = "set", key = "animSpeed", value = "boh" }, w); advance(0.2)
  if nstate(w) ~= n0 + 1 or WV.lastState(w).look.animSpeed ~= "normal" then return "nessun eco correttivo" end
  WV.send({ op = "set", key = "themeMode", value = "light" }, w); advance(0.2)
  if nstate(w) ~= n0 + 2 or WV.lastState(w).effectiveMode ~= "light" then return "themeMode senza eco" end
  WV.send({ op = "pick_mic", name = "x" }, w); WV.send({ op = "key_set_gesture", action = "ss", index = 0, gesture = "hold" }, w)
  WV.send({ op = "key_remove_binding", action = "pause", index = 0 }, w); advance(0.3)
  if nstate(w) ~= n0 + 2 then return "eco su pick_mic/gesture/remove" end
  return true end)
T("W22 stato inviato SOLO dopo ready; mai dopo la chiusura", function()
  C.settingsUI = "web"; M.settings("general"); advance(0.5)
  local w = WV.cur(); if #w.js ~= 0 then return "stato prima di ready" end
  WV.send({ op = "ready" }, w); advance(0.2); local n = #w.js
  WV.send({ op = "close" }, w); advance(0.5)
  M.settings("general"); advance(0.1); M.config.style = "ocean"
  if #w.js ~= n then return "JS inviato dopo la chiusura" end
  return true end)
T("W23 JSON: nomi mic malevoli (script, virgolette, unicode, U+2028, utf8 invalido)", function()
  LISTDEV = 'AVFoundation audio devices:\n[0] </script><script>alert(1)</script>\n[1] "quoted" \\ back\\slash\n[2] \230\151\165\230\156\172\232\170\158 \240\159\142\164\n[3] AirPods \226\128\168 sep \226\128\169\n[4] bad\255byte\n[5] x\');alert(1);//\n[6] a\ttab'
  C.settingsUI = "web"; M.settings("general"); advance(0.2); local w = WV.cur()
  WV.send({ op = "ready" }, w); advance(0.5); WV.send({ op = "refresh_devices" }, w); advance(0.5)
  local evd = lastEv(w, "devices"); if not evd then return "evento devices mancante" end
  local s = fresh(w); local devs = s.general.devices
  if #evd.data ~= 7 or evd.data[1].name ~= devs[1].name then return "evento devices diverso dallo stato" end
  if #devs ~= 7 then return "dispositivi " .. #devs end
  if devs[1].name ~= "</script><script>alert(1)</script>" then return "nome 1: " .. devs[1].name end
  if devs[2].name ~= '"quoted" \\ back\\slash' then return "nome 2" end
  if devs[3].name ~= "\230\151\165\230\156\172\232\170\158 \240\159\142\164" then return "unicode" end
  if devs[4].bt ~= true then return "AirPods bt" end
  if devs[1].bt ~= false then return "bt a caso" end
  for _, j in ipairs(w.js) do
    if j:find("\226\128\168", 1, true) or j:find("\226\128\169", 1, true) then return "U+2028/9 grezzo nel JS" end
    if not (j:match("^gw%.onState%(.*%)$") or j:match("^gw%.onEvent%('[%w_]+', .*%)$")) then return "forma JS: " .. j:sub(1, 60) end
    if j:find("alert(1)</script>", 1, true) and not j:find('"</script><script>alert(1)</script>"', 1, true) then return "script fuori da una stringa JSON" end
  end
  if devs[5].name:find("\255", 1, true) then return "utf8 invalido passato" end
  return true end)
T("W24 mai hs.audiodevice / hs.sound", function()
  FAKE[C.keyPath] = KEY
  local w = openWeb()
  for _, o in ipairs({ { op = "refresh_devices" }, { op = "pick_mic", name = "Mic Tre" }, { op = "random_look" }, { op = "reset_look" }, { op = "key_paste" },
    { op = "capture_start", action = "ss" }, { op = "capture_cancel" }, { op = "set", key = "style", value = "ocean" } }) do WV.send(o, w); advance(0.3) end
  closeWeb()
  if AUDIO_CALLS ~= 0 then return "chiamate CoreAudio: " .. AUDIO_CALLS end
  return true end)
T("W25 settings.lua: settingsUI web/canvas letto, invalido ignorato", function()
  FAKE[C.settingsPath] = 'return { settingsUI = "web" }'; D.loadS()
  if C.settingsUI ~= "web" then return "web non letto: " .. tostring(C.settingsUI) end
  FAKE[C.settingsPath] = 'return { settingsUI = "canvas" }'; D.loadS()
  if C.settingsUI ~= "canvas" then return "canvas non letto" end
  FAKE[C.settingsPath] = 'return { settingsUI = "html5" }'; D.loadS()
  if C.settingsUI ~= "canvas" then return "valore invalido accettato: " .. tostring(C.settingsUI) end
  FAKE[C.settingsPath] = 'return { settingsUI = 7 }'; D.loadS()
  if C.settingsUI ~= "canvas" then return "numero accettato" end
  return true end)
T("W26 messaggi malformati / op sconosciute / flood: nessun errore, nessuno stato falso", function()
  local w = openWeb()
  local junk = { nil, 5, "x", {}, { body = 5 }, { body = {} }, { body = { op = 5 } }, { body = { op = "boom" } }, { body = { op = "set" } }, { body = { op = "set", key = {} } },
    { body = { op = "pick_mic", name = {} } }, { body = { op = "resize_request", w = {}, h = "x" } }, { body = { op = "set", key = "__index", value = 1 } } }
  for i = 1, 13 do w.uc.cb(junk[i]) end
  for i = 1, 1500 do WV.send({ op = "set_tab", tab = "keys" }, w) end
  advance(0.3)
  if D.scv() or not WV.cur() then return "finestra chiusa da messaggi spazzatura" end
  return true end)
T("W27 set_tab e M.settings(page)", function()
  local w = openWeb("keys"); if WV.lastState(w).tab ~= "keys" then return "tab iniziale " .. tostring(WV.lastState(w).tab) end
  WV.send({ op = "set_tab", tab = "theme" }, w); M.settings(); advance(0.2)
  if WV.lastState(w).tab ~= "theme" then return "set_tab non ricordato" end
  WV.send({ op = "set_tab", tab = "evil" }, w); M.settings(); advance(0.2)
  if WV.lastState(w).tab ~= "theme" then return "tab invalido accettato" end
  return true end)
T("W28 posizione: centrata, poi ultima posizione dopo il drag", function()
  local w = openWeb(); local f = w.fr
  if math.abs(f.x + f.w / 2 - 720) > 2 then return "non centrata x: " .. f.x end
  w.fr.x = 100; w.fr.y = 50
  WV.send({ op = "close" }, w); advance(0.5)
  local w2 = openWeb(); local f2 = w2.fr
  if math.abs(f2.x + f2.w / 2 - (100 + f.w / 2)) > 2 or math.abs(f2.y - 50) > 2 then return "posizione non ricordata " .. f2.x .. "," .. f2.y end
  return true end)
T("W29 schermo piccolo: la finestra sta dentro lo schermo", function()
  local o = { SCREENT.x, SCREENT.y, SCREENT.w, SCREENT.h }
  SCREENT.w, SCREENT.h = 500, 400
  local w = openWeb()
  local f = w.fr
  SCREENT.x, SCREENT.y, SCREENT.w, SCREENT.h = o[1], o[2], o[3], o[4]
  if f.w > 500 or f.h > 400 then return "finestra " .. f.w .. "x" .. f.h .. " > schermo" end
  return true end)
T("W29b contratto: ogni op che la pagina dichiara (var OPS) esiste nell'host; ogni evento host e' gestito dalla pagina", function()
  local h = D.ICON.webHtml
  local list = h:match("var OPS = (%b[])")
  if not list then return true end                    -- pagina segnaposto: niente da confrontare
  local n = 0
  for op in list:gmatch("'([%w_]+)'") do n = n + 1; if not W.OP[op] then return "op '" .. op .. "' della pagina non gestita dall'host" end end
  if n < 15 then return "pochi op letti: " .. n end
  for _, name in ipairs({ "key_status", "devices", "capture_result", "toast" }) do
    if not h:find("case '" .. name .. "'", 1, true) then return "evento '" .. name .. "' dell'host non gestito dalla pagina" end
  end
  return true end)
return "TOTALE web1: test " .. ntest .. ", falliti " .. nfail .. "\n" .. table.concat(OUT, "\n")
