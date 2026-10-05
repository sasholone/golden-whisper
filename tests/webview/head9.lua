-- Harness: hs finto + clock virtuale. Eseguito dentro hs -c ma con env isolato (nessun hs reale toccato).
local OUT = {}
local function log(...) local t = {}; for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end OUT[#OUT + 1] = table.concat(t, " ") end
local clock = 1000.0
local timers = {}
local errors = {}
local function bad(v, path, where)
  if type(v) == "number" then if v ~= v or v == math.huge or v == -math.huge then errors[#errors + 1] = "NaN/inf " .. where .. " " .. path end
  elseif type(v) == "table" then for k, x in pairs(v) do if k ~= "image" then bad(x, path .. "." .. tostring(k), where) end end end
end
local stub; stub = setmetatable({}, { __index = function() return stub end, __call = function() return stub end })
local SCREEN = { x = 0, y = 0, w = 1440, h = 900 }
local mouse = { x = 700, y = 300 }; MOUSE = mouse; SCREENT = SCREEN
WRITES = 0
local taps = {}
local canvases = {}; CANVASES = canvases
local function newCanvas(fr)
  local c = { els = {}, fr = { x = fr.x, y = fr.y, w = fr.w, h = fr.h }, a = 1, deleted = false, shown = false, ncalls = 0 }
  canvases[#canvases + 1] = c
  bad(fr, "frame", "new")
  local mt = {}
  function mt:level() return self end
  function mt:behavior() return self end
  function mt:mouseCallback(f) c.cb = f; return self end
  function mt:replaceElements(e) bad(e, "els", "replaceElements"); c.els = e; return self end
  function mt:appendElements(e) c.els[#c.els + 1] = e; return self end
  function mt:elementAttribute(i, k, v)
    bad(v, k, "elementAttribute")
    if not c.els[i] then errors[#errors + 1] = "elementAttribute idx fuori range " .. tostring(i) .. " " .. tostring(k) end
    if c.els[i] then c.els[i][k] = v end
    return self
  end
  function mt:elementCount() return #c.els end
  function mt:alpha(a) if a == nil then return c.a end bad(a, "alpha", "alpha"); c.a = a; return self end
  function mt:frame(f) if f == nil then return { x = c.fr.x, y = c.fr.y, w = c.fr.w, h = c.fr.h } end
    bad(f, "frame", "frame"); c.fr = { x = f.x, y = f.y, w = f.w, h = f.h }; return self end
  function mt:topLeft(p) c.fr.x, c.fr.y = p.x, p.y; return self end
  function mt:show() c.shown = true; return self end
  function mt:hide() c.shown = false; return self end
  function mt:delete() c.deleted = true end
  function mt:imageFromCanvas() return { img = true } end
  return setmetatable({}, { __index = function(_, k) local f = mt[k]; if f then return function(self, ...) return f(c_self or self, ...) end end end, __c = c }), c
end
OBJC = setmetatable({}, { __mode = 'k' })
local function mkcanvas(fr)
  local c = { els = {}, fr = { x = fr.x, y = fr.y, w = fr.w, h = fr.h }, a = 1, deleted = false, shown = false, w = 0, id = #canvases + 1, lvl = 5, beh = 7 }
  canvases[#canvases + 1] = c
  local o = {}
  function o:level(l) if l == nil then return c.lvl end c.lvl = l; return self end
  function o:behavior(b) if b == nil then return c.beh end c.beh = b; return self end
  function o:mouseCallback(f) c.cb = f; return self end
  function o:replaceElements(e) bad(e, "els", "replaceElements"); c.els = e; c.repl = (c.repl or 0) + 1; return self end
  function o:appendElements(e) c.els[#c.els + 1] = e; return self end
  function o:elementAttribute(i, k, v)
    WRITES = WRITES + 1; c.w = c.w + 1
    bad(v, k, "elementAttribute")
    if not c.els[i] then errors[#errors + 1] = "elementAttribute idx fuori range " .. tostring(i) .. " " .. tostring(k) .. " canvas c" .. c.id .. " #els=" .. #c.els .. " clock=" .. string.format("%.2f", clock) .. " " .. debug.traceback("", 2):gsub("\n", " <- "):sub(1, 400) else c.els[i][k] = v end
    return self
  end
  function o:alpha(a) if a == nil then return c.a end bad(a, "alpha", "alpha"); WWR = (WWR or 0) + 1; c.a = a; return self end
  function o:frame(f) if f == nil then return { x = c.fr.x, y = c.fr.y, w = c.fr.w, h = c.fr.h } end
    bad(f, "frame", "frame"); WWR = (WWR or 0) + 1; c.fr = { x = f.x, y = f.y, w = f.w, h = f.h }; return self end
  function o:topLeft(p) c.fr.x, c.fr.y = p.x, p.y; return self end
  function o:size(z) if z == nil then return { w = c.fr.w, h = c.fr.h } end c.fr.w, c.fr.h = z.w, z.h; return self end
  function o:show() if not c.shown then ZC = (ZC or 0) + 1; c.z = ZC end c.shown = true; return self end
  function o:hide() c.shown = false; return self end
  function o:orderAbove(other) local oc = other and OBJC[other]; if oc then c.z = (oc.z or 0) + 0.001 else ZC = (ZC or 0) + 1; c.z = ZC end return self end
  function o:delete() c.deleted = true; c.shown = false end
  function o:imageFromCanvas() return setmetatable({ img = true }, { __index = { croppedCopy = function(self, r) return { img = true, crop = r } end } }) end
  function o:isShowing() return c.shown end
  setmetatable(o, { __index = function() return function() return nil end end })
  c.obj = o
  OBJC[o] = c
  return o
end

-- TASKS: finto ffmpeg. TM = "live" (parte e emette livelli), "exit_sync" (callback subito dentro start), "exit_async" (esce dopo 0.1 s),
-- "mute" (resta vivo senza output), "failstart" (start() torna nil). kill -INT <pid> -> exit async dopo KILLDELAY.
TM = TM or "live"; KILLDELAY = KILLDELAY or 0.05
TASKS = { list = {}, nstart = 0, nkill = 0, nextpid = 1000, log = {} }
local function later(d, f) local t = { at = clock + d, f = f }; timers[#timers + 1] = t; return t end
CURLM = CURLM or "ok"; CURLDELAY = CURLDELAY or 0.3; CURLOUT = CURLOUT or "ciao mondo"; CURLARGS = {}
function TASKS.make(cmd, cb, scb, args)
  if type(scb) == 'table' and args == nil then args = scb; scb = nil end
  if tostring(cmd):find("afplay", 1, true) then AFPLAY = (AFPLAY or 0) + 1; return { start = function(self) return self end, isRunning = function() return false end, terminate = function() end, pid = function() return nil end } end
  if tostring(cmd):find("curl", 1, true) then
    local C = { alive = false, cb = cb, args = args, curl = true }
    TASKS.list[#TASKS.list + 1] = C
    function C:pid() return self.alive and 1 or nil end
    function C:isRunning() return self.alive end
    function C:terminate() if self.alive then self.alive = false; self.cb(15, "", "terminated") end end
    function C:setInput() return self end
    function C:closeInput() return self end
    function C:start()
      self.alive = true; CURLARGS[#CURLARGS + 1] = args
      local a = table.concat(args or {}, " ")
      local me = self
      local mode = CURLM
      if a:find("githubusercontent", 1, true) then
        if UPDHOOK then later(CURLDELAY, function() if me.alive then me.alive = false; local c, o = UPDHOOK(args); me.cb(c, o or "", "") end end); return self end
        mode = "fail"
      end
      if mode == "hang" then
        -- curl reale con --max-time: esce con 28 dopo il tetto
        local mt = a:match("%-%-max%-time (%d+)")
        if mt then later(tonumber(mt), function() if me.alive then me.alive = false; me.cb(28, "", "Operation timed out") end end) end
        return self
      end
      later(CURLDELAY, function()
        if not me.alive then return end
        me.alive = false
        if a:find("models", 1, true) and mode:match("^http%d+$") then me.cb(0, mode:match("^http(%d+)$"), ""); return end
        if mode == "ok" then
          local out = CURLOUT
          if a:find("%{http_code}", 1, true) then out = out .. (a:find("models", 1, true) and "" or "\n") .. "200" end
          if a:find("models", 1, true) then out = "200" end
          me.cb(0, out, "")
        elseif mode == "http401" then
          local out = '{"error":{"message":"Invalid API Key","type":"invalid_request_error","code":"invalid_api_key"}}'
          if a:find("%{http_code}", 1, true) then out = out .. "\n401" end
          me.cb(0, out, "")
        elseif mode == "http429" then
          local out = '{"error":{"message":"Rate limit reached","type":"tokens","code":"rate_limit_exceeded"}}'
          if a:find("%{http_code}", 1, true) then out = out .. "\n429" end
          me.cb(0, out, "")
        elseif mode == "empty" then
          local out = ""
          if a:find("%{http_code}", 1, true) then out = "\n200" end
          me.cb(0, out, "")
        else me.cb(6, "", "curl: (6) Could not resolve host") end
      end)
      return self
    end
    return C
  end
  local T = { alive = false, cb = cb, scb = scb, args = args }
  TASKS.list[#TASKS.list + 1] = T
  function T:pid() return self.alive and self.pidn or nil end
  function T:isRunning() return self.alive end
  function T:terminate() if not self.hangHard then TASKS.finish(self) end end
  function T:start()
    if args and table.concat(args, ' '):find('list_devices', 1, true) then LISTSTARTS = (LISTSTARTS or 0) + 1; self.listing = true; self.alive = true; self.pidn = TASKS.nextpid; TASKS.nextpid = TASKS.nextpid + 1; if LISTHANG then self.hang = true; return self end if LISTFAIL then self.alive = false; return nil end local me = self; later(0.05, function() if me.alive then me.alive = false; me.cb(0, '', LISTDEV or 'AVFoundation audio devices:\n[0] AirPods Uno\n[1] MacBook Mic Due\n[2] Mic Tre') end end); return self end
    TASKS.nstart = TASKS.nstart + 1
    if TM == "failstart" then return nil end
    if TM == "hang" then self.hang = true end
    if TM == "hanghard" then self.hang = true; self.hangHard = true end
    self.pidn = TASKS.nextpid; TASKS.nextpid = TASKS.nextpid + 1
    self.alive = true
    if args and type(args[#args]) == "string" and args[#args]:find("%.wav$") then FAKE[args[#args]] = string.rep("x", 4000) end
    if TM == "exit_sync" then self.alive = false; self.cb(1, "", "dead"); return self end
    if TM == "exit_async" then later(0.1, function() TASKS.finish(self) end) end
    local live = (TM == "live") or (TM == "late") or (TM == "retryok" and TASKS.nstart >= 2) or (TM == "fbok" and TASKS.nstart >= 3)
    if live then
      local tick; tick = function()
        if not self.alive then return end
        if self.scb then self.scb(self, "", "lavfi.astats.Overall.RMS_level=-" .. (20 + (TASKS.nstart % 7)) .. "\n") end
        later(0.1, tick)
      end
      later((TM == "late") and (LATE or 1.5) or 0.1, tick)
    end
    return self
  end
  return T
end
function TASKS.finish(T) if not T.alive then return end T.alive = false; T.cb(0, "", "") end
EXECS = {}
function TASKS.exec(cmd)
  EXECS[#EXECS + 1] = tostring(cmd); if #EXECS > 400 then table.remove(EXECS, 1) end
  local pid = tostring(cmd):match("%-INT (%d+)")
  if pid then
    TASKS.nkill = TASKS.nkill + 1
    for _, T in ipairs(TASKS.list) do if T.alive and tostring(T.pidn) == pid and not T.hang then later(KILLDELAY, function() TASKS.finish(T) end) end end
  end
  local tp = tostring(cmd):match("%-TERM (%d+)") or tostring(cmd):match("%-KILL (%d+)")
  if tp then for _, T in ipairs(TASKS.list) do if T.alive and tostring(T.pidn) == tp and not T.hangHard then later(0.02, function() TASKS.finish(T) end) end end end
  return ""
end
-- ===== estensione harness: JSON vero, hs.webview finto, FS virtuale per gli asset, base64 =====
local function jenc(v, out)
  local t = type(v)
  if t == "nil" then out[#out + 1] = "null"
  elseif t == "boolean" then out[#out + 1] = tostring(v)
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then error("json: NaN/inf") end
    out[#out + 1] = (v == math.floor(v) and math.abs(v) < 1e15) and string.format("%d", v) or string.format("%.14g", v)
  elseif t == "string" then
    if not utf8.len(v) then error("json: utf8 non valido") end
    out[#out + 1] = '"' .. v:gsub('[\0-\31"\\]', function(c)
      if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" elseif c == "\n" then return "\\n" elseif c == "\r" then return "\\r" elseif c == "\t" then return "\\t" end
      return string.format("\\u%04x", c:byte())
    end) .. '"'
  elseif t == "table" then
    local n, mx = 0, 0
    for k in pairs(v) do n = n + 1; if type(k) == "number" and k == math.floor(k) and k > 0 then mx = math.max(mx, k) end end
    if n == 0 then out[#out + 1] = "[]"
    elseif n == mx then
      out[#out + 1] = "["; for i = 1, n do if i > 1 then out[#out + 1] = "," end jenc(v[i], out) end out[#out + 1] = "]"
    else
      local keys = {}; for k in pairs(v) do if type(k) ~= "string" then error("json: chiave non stringa") end keys[#keys + 1] = k end
      table.sort(keys)
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do if i > 1 then out[#out + 1] = "," end jenc(k, out); out[#out + 1] = ":"; jenc(v[k], out) end
      out[#out + 1] = "}"
    end
  else error("json: tipo " .. t) end
end
JSON = {}
function JSON.encode(v) local o = {}; jenc(v, o); return table.concat(o) end
function JSON.decode(s)
  local i = 1
  local function ws() i = s:find("%S", i) or #s + 1 end
  local val
  local function str()
    local j = i + 1; local buf = {}
    while true do
      local c = s:sub(j, j)
      if c == "" then error("json: stringa non chiusa") end
      if c == '"' then i = j + 1; return table.concat(buf) end
      if c == "\\" then
        local n = s:sub(j + 1, j + 1)
        local m = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f", ["/"] = "/", ["\\"] = "\\", ['"'] = '"' }
        if n == "u" then buf[#buf + 1] = utf8.char(tonumber(s:sub(j + 2, j + 5), 16)); j = j + 6
        elseif m[n] then buf[#buf + 1] = m[n]; j = j + 2 else error("json: escape") end
      else
        if c:byte() < 32 then error("json: carattere di controllo in stringa") end
        buf[#buf + 1] = c; j = j + 1
      end
    end
  end
  function val()
    ws(); local c = s:sub(i, i)
    if c == "{" then
      i = i + 1; local o = {}; ws()
      if s:sub(i, i) == "}" then i = i + 1; return o end
      while true do ws(); if s:sub(i, i) ~= '"' then error("json: chiave") end local k = str(); ws(); if s:sub(i, i) ~= ":" then error("json: :") end i = i + 1; o[k] = val(); ws()
        local d = s:sub(i, i); i = i + 1; if d == "}" then return o elseif d ~= "," then error("json: , o }") end end
    elseif c == "[" then
      i = i + 1; local a = {}; ws()
      if s:sub(i, i) == "]" then i = i + 1; return a end
      while true do a[#a + 1] = val(); ws(); local d = s:sub(i, i); i = i + 1; if d == "]" then return a elseif d ~= "," then error("json: , o ]") end end
    elseif c == '"' then return str()
    elseif s:sub(i, i + 3) == "true" then i = i + 4; return true
    elseif s:sub(i, i + 4) == "false" then i = i + 5; return false
    elseif s:sub(i, i + 3) == "null" then i = i + 4; return nil
    else local n = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i); if not n or n == "" then error("json: valore @" .. i) end i = i + #n; return tonumber(n) end
  end
  local r = val(); ws(); if i <= #s then error("json: dati in coda") end
  return r
end
-- base64
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function B64ENC(d)
  local out = {}
  for i = 1, #d, 3 do
    local a, b, c = d:byte(i, i + 2)
    local n = (a << 16) | ((b or 0) << 8) | (c or 0)
    local c1, c2, c3, c4 = (n >> 18) & 63, (n >> 12) & 63, (n >> 6) & 63, n & 63
    out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1) .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
  end
  return table.concat(out)
end
-- FS virtuale: VFS.dirs[path] = { nomi }, VFS.attr[path] = { mode=, size= }
VFS = { dirs = {}, attr = {}, reads = 0 }
AUDIO_CALLS = 0
-- webview finto
WV = { list = {}, ucs = {}, mode = "ok", seq = 0 }
function WV.live() local n = 0; for _, w in ipairs(WV.list) do if not w.deleted then n = n + 1 end end return n end
function WV.liveUC() local n = 0; for _, u in ipairs(WV.ucs) do if u.cb ~= nil then n = n + 1 end end return n end
function WV.last() return WV.list[#WV.list] end
function WV.cur() for i = #WV.list, 1, -1 do if not WV.list[i].deleted then return WV.list[i] end end end
local function mkuc(name)
  local u = { name = name }
  WV.ucs[#WV.ucs + 1] = u
  return setmetatable({}, { __index = function(_, k)
    if k == "setCallback" then return function(self, f) u.cb = f; return self end end
    return function() end end, __u = u })
end
local function ucOf(o) return getmetatable(o).__u end
WV_MASKS = { borderless = 0, titled = 1, closable = 2, miniaturizable = 4, resizable = 8, utility = 16, nonactivating = 128, HUD = 8192 }
WVMOD = {
  windowMasks = WV_MASKS,
  new = function(fr, prefs, ucobj)
    if WV.mode == "newthrows" then error("hs.webview.new: simulato") end
    if WV.mode == "newnil" then return nil end
    WV.seq = WV.seq + 1
    local w = { id = WV.seq, fr = { x = fr.x, y = fr.y, w = fr.w, h = fr.h }, deleted = false, shown = false, alpha = 1, js = {}, calls = {}, html = nil, uc = ucobj and ucOf(ucobj) }
    WV.list[#WV.list + 1] = w
    local o = {}
    local function rec(n, ...) w.calls[#w.calls + 1] = { n, ... } end
    function o:frame(f) if f == nil then return { x = w.fr.x, y = w.fr.y, w = w.fr.w, h = w.fr.h } end
      for _, k in ipairs({ "x", "y", "w", "h" }) do if type(f[k]) ~= "number" or f[k] ~= f[k] or math.abs(f[k]) == math.huge then errors[#errors + 1] = "webview frame NaN/inf " .. k end end
      w.fr = { x = f.x, y = f.y, w = f.w, h = f.h }; w.nframe = (w.nframe or 0) + 1; return self end
    function o:topLeft(p) if p == nil then return { x = w.fr.x, y = w.fr.y } end w.fr.x, w.fr.y = p.x, p.y; return self end
    function o:size(z) if z == nil then return { w = w.fr.w, h = w.fr.h } end w.fr.w, w.fr.h = z.w, z.h; return self end
    function o:show() w.shown = true; w.nshow = (w.nshow or 0) + 1; return self end
    function o:hide() w.shown = false; return self end
    function o:delete() if w.deleted then errors[#errors + 1] = "webview delete doppio" end w.deleted = true; w.shown = false end
    function o:alpha(a) if a == nil then return w.alpha end w.alpha = a; return self end
    function o:html(h, base) w.html = h; w.base = base; w.url = nil; w.nhtml = (w.nhtml or 0) + 1; return self end
    function o:url(u) if u == nil then if w.crashed then return nil end return w.url or (w.html and "about:blank") or nil end w.url = u; w.html = nil; w.nurl = (w.nurl or 0) + 1; return self end
    function o:evaluateJavaScript(js, cb) if w.deleted then errors[#errors + 1] = "evaluateJavaScript su webview cancellata" end w.js[#w.js + 1] = js; w.jt = w.jt or {}; w.jt[#w.js] = HSF.timer.secondsSinceEpoch(); return self end
    function o:isVisible() return w.shown end
    function o:windowStyle(v) w.cfg = w.cfg or {}
      if type(v) == "table" then local m = 0; for _, n in ipairs(v) do m = m + (WV_MASKS[n] or error("windowStyle: maschera sconosciuta " .. tostring(n))) end w.cfg.windowStyle = m; w.cfg.windowStyleTable = true
      else w.cfg.windowStyle = v end return self end
    for _, n in ipairs({ "level", "behavior", "transparent", "shadow", "allowTextEntry", "allowNewWindows", "privateBrowsing", "allowGestures", "darkMode" }) do
      o[n] = function(self, v) w.cfg = w.cfg or {}; w.cfg[n] = v; return self end
    end
    function o:policyCallback(f) w.policy = f; return self end
    function o:navigationCallback(f) w.nav = f; return self end
    return o
  end,
  usercontent = { new = function(name) return mkuc(name) end },
}
-- helper di test
function WV.send(body, w) w = w or WV.cur(); assert(w and w.uc and w.uc.cb, "nessuna webview/callback"); return w.uc.cb({ body = body, name = "gw" }) end
function WV.states(w) w = w or WV.cur() or WV.last(); local out = {}
  for _, j in ipairs(w and w.js or {}) do local s = j:match("^gw%.onState%((.*)%)$"); if s then out[#out + 1] = JSON.decode(s) end end return out end
function WV.lastState(w) local t = WV.states(w); return t[#t] end
function WV.events(w) w = w or WV.cur() or WV.last(); local out = {}
  for _, j in ipairs(w and w.js or {}) do local n, s = j:match("^gw%.onEvent%('([%w_]+)', (.*)%)$"); if n then out[#out + 1] = { name = n, data = JSON.decode(s) } end end return out end

-- app in primo piano finta
APPS = {}
FRONT = "slack"
ACT = {}
local function mkapp(n) APPS[n] = { bundleID = function() return n == "hs" and "org.hammerspoon.Hammerspoon" or ("com." .. n) end, activate = function() FRONT = n; ACT[n] = (ACT[n] or 0) + 1; return true end, isRunning = function() return true end, name = function() return n end } end
mkapp("slack"); mkapp("hs"); mkapp("mail")

local hsF = setmetatable({
  canvas = setmetatable({ new = mkcanvas, windowLevels = { overlay = 1, screenSaver = 2 } }, { __index = stub }),
  timer = { secondsSinceEpoch = function() return clock end,
    doAfter = function(d, f) local t = { at = clock + d, f = f }; timers[#timers + 1] = t; return { stop = function() t.dead = true end } end,
    doEvery = function(d, f) local t = { at = clock + d, f = f, every = d }; timers[#timers + 1] = t; return { stop = function() t.dead = true end, start = function() end } end,
    new = function(d, f) local t = { at = clock + d, f = f, every = d }; timers[#timers + 1] = t; return { stop = function() t.dead = true end, start = function(self) return self end } end },
  screen = { watcher = stub, mainScreen = function() return { frame = function() return SCREEN end, id = function() return 1 end } end, allScreens = function() return { { frame = function() return SCREEN end, id = function() return 1 end } } end },
  geometry = { point = function(x, y) return { x = x, y = y, inside = function() return true end } end },
  mouse = { absolutePosition = function() return { x = mouse.x, y = mouse.y } end, getButtons = function() return BUTTONS or { true } end },
  task = { new = function(cmd, cb, scb, args) return TASKS.make(cmd, cb, scb, args) end },
  execute = function(cmd) return TASKS.exec(cmd) end,
  sound = setmetatable({}, { __index = function() AUDIO_CALLS = AUDIO_CALLS + 1; return function() return nil end end }),
  audiodevice = setmetatable({}, { __index = function() AUDIO_CALLS = AUDIO_CALLS + 1; return function() return {} end end }),
  pasteboard = { setContents = function() end, getContents = function() return PASTE or "" end },
  eventtap = { keyStroke = function() KEYSTROKES = (KEYSTROKES or 0) + 1 end, new = function(types, f) local t = { types = types, f = f, on = false }; taps[#taps + 1] = t
      TAPS = taps
      return { start = function() t.on = true end, stop = function() t.on = false end, isEnabled = function() return t.on end } end,
    event = { types = { scrollWheel = 22, leftMouseDragged = 6, leftMouseUp = 2, flagsChanged = 12, keyDown = 10, keyUp = 11 },
      properties = { scrollWheelEventPointDeltaAxis1 = 1, scrollWheelEventDeltaAxis1 = 2, keyboardEventAutorepeat = 3 } } },
  json = { encode = function(v) return JSON.encode(v) end, decode = function(s) return JSON.decode(s) end },
  fs = { mkdir = function(p) VFS.mk = VFS.mk or {}; VFS.mk[#VFS.mk + 1] = p; return true end, attributes = function(p, k) local a = VFS.attr[p]; if not a then return nil end if k then return a[k] end return a end,
    symlinkAttributes = function(p, k) local a = VFS.attr[p]; if not a then return nil end if k then return a[k] end return a end,
    dir = function(p) local l = VFS.dirs[p]; if not l then error("cannot open " .. p) end local i = 0; return function() i = i + 1; return l[i] end, {} end },
  webview = WVMOD,
  base64 = { encode = function(d) VFS.reads = VFS.reads + 1; return B64ENC(d) end },
  processInfo = { bundleID = "org.hammerspoon.Hammerspoon" },
  application = setmetatable({ frontmostApplication = function() return APPS[FRONT] end }, { __index = stub }),
  drawing = { windowBehaviors = { canJoinAllSpaces = 1, fullScreenAuxiliary = 256 } },
  alert = { show = function() end },
}, { __index = function() return stub end })
HSF = hsF
local envos = setmetatable({ remove = function(p) local had = FAKE[p] ~= nil; FAKE[p] = nil; if had then return true end return nil, "nofile" end, time = function() return SEED_T or os.time() end, getenv = function(k) if k == "HOME" then return GW_HOME or "/nonexistent-gw-test" end return os.getenv(k) end }, { __index = os })
FAKE = FAKE or {}
local envio = setmetatable({ open = function(p, m)
  m = m or "r"
  if GW_HOME and tostring(p):sub(1, #GW_HOME) == GW_HOME then return io.open(p, m) end
  if WRITEFAIL and m:find("w") and tostring(p):find("/ui/", 1, true) then return nil end
  if m:find("w") then local buf = {}; return { write = function(self, t) buf[#buf+1] = t; return self end, close = function() FAKE[p] = table.concat(buf); FILEW = FILEW or {}; FILEW[p] = (FILEW[p] or 0) + 1 end } end
  if FAKE[p] then local d = FAKE[p]; return { read = function() return d end, close = function() end, seek = function() return #d end } end
  return nil end }, { __index = io })
GLOBALS_R, GLOBALS_W = {}, {}
local STD = {}; for _, k in ipairs({ "string", "table", "math", "pairs", "ipairs", "next", "type", "tostring", "tonumber", "select", "setmetatable", "getmetatable", "rawget", "rawset", "rawequal", "error", "assert", "xpcall", "unpack", "collectgarbage", "utf8", "coroutine", "debug", "load", "loadstring", "_G", "rawlen" }) do STD[k] = true end
local env = setmetatable({ hs = hsF, os = envos, io = envio, print = function(...) log("[mod print]", ...) end }, { __index = function(_, k) if not STD[k] then GLOBALS_R[k] = (GLOBALS_R[k] or 0) + 1 end return _G[k] end,
  __newindex = function(t, k, v) GLOBALS_W[k] = (GLOBALS_W[k] or 0) + 1; rawset(t, k, v) end })
env.pcall = function(f, ...)
  local r = table.pack(pcall(f, ...))
  if not r[1] then errors[#errors + 1] = "pcall: " .. tostring(r[2]) end
  return table.unpack(r, 1, r.n)
end
env.dofile = function(p) if FAKE[p] then local f, e = load((FAKE[p]:gsub("^\239\187\191", "")), "="..p); if not f then error(e) end return f() end return dofile(p) end
env.require = function(n) if n == "gw_sticky" then error("no") end return require(n) end
local SRC = GW_SRC or "/Users/sasholo/golden-whisper-redesign/src/groq_dictation.lua"
local fh = io.open(SRC, "r"); local text = fh:read("*a"); fh:close()
local a, b = text:find("M.config = config\nreturn M", 1, true)
assert(a, "marker")
text = text:sub(1, a - 1) .. "M._dbg = { F = FAMILIES, O = FAMILY_ORDER, C = function() return COL end, ICON = ICON, I = function() return RECIDX end, ov = function() return overlay end, proc = function(t) setProcessingElements(t) end, status = function(t) setStatus(t) end, mode = function() return mode end, upd = function() updateUI() end, apply = function() applyTheme() end, setwarn = function(v) micWarned = v end, refresh = function() refreshDevices() end, guard = function() guardTick() end, micS = function() return ICON.micS end, warned = function() return micWarned end, setrec = function(v, pz) recording = v; paused = pz or false; segStart = hs.timer.secondsSinceEpoch() end, setlv = function(f) for i = 1, #levels do levels[i] = f(i) end end, nlv = function() return #levels end, setff = function(f) finalFrame = f end, PROC = function() return PROC end, SET = function() return SET end, open = function() openSettings() end, smouse = function(...) settingsMouse(...) end, spage = function(p) settingsPage = p end, scv = function() return settingsCanvas end, sclose = function() closeSettings() end, srender = function(o) renderSettings(o) end, loadS = function() loadSettings() end, ps = function(...) return pushShadow(...) end, setCOL = function(c) COL = c end, persist = function(k, v) persist(k, v) end, prev = function() return PREV end, DENS = DENS, ghost = function() return SET.ghost end, st = function() return { recording = recording, paused = paused, busy = busy, recTask = recTask, intent = intent, segs = #segments, mode = mode, uiTimer = uiTimer, rotTimer = rotTimer, dragTap = dragTap, overlay = overlay, hist = historyCanvas, anim = Anim.timer, nanim = (function() local n = 0; for _ in pairs(Anim.list) do n = n + 1 end return n end)(), prevT = previewTimer, stap = scrollTap } end, Anim = Anim, closeH = function() closeHistory() end, openH = function() openHistory() end, config = config }\n" .. text:sub(a)
local chunk, err = load(text, "=gw", "t", env)
if not chunk then return "LOADERR " .. tostring(err) end
local M = chunk()
TIMERS = timers
function CLOCKJUMP(d) clock = clock + d; for _, t in ipairs(timers) do if not t.dead then t.at = t.at + d end end end
function STATS()
  local st = { every = 0, once = 0, tapsOn = 0, cvLive = 0, cvShown = 0, tasks = 0, curl = 0 }
  for _, t in ipairs(timers) do if not t.dead then if t.every then st.every = st.every + 1 else st.once = st.once + 1 end end end
  for _, t in ipairs(taps) do if t.on then st.tapsOn = st.tapsOn + 1 end end
  for _, c in ipairs(canvases) do if not c.deleted then st.cvLive = st.cvLive + 1; if c.shown then st.cvShown = st.cvShown + 1 end end end
  for _, T in ipairs(TASKS.list) do if T.alive then if T.curl then st.curl = st.curl + 1 elseif not T.listing then st.tasks = st.tasks + 1 end end end
  return st
end
function COMPACT()
  local j = 0
  for i = 1, #timers do local t = timers[i]; if not t.dead then j = j + 1; timers[j] = t end end
  for i = #timers, j + 1, -1 do timers[i] = nil end
  local k = 0
  for i = 1, #TASKS.list do local T = TASKS.list[i]; if T.alive then k = k + 1; TASKS.list[k] = T end end
  for i = #TASKS.list, k + 1, -1 do TASKS.list[i] = nil end
end
function advance(sec)
  local steps = math.floor(sec * 60 + 0.5)
  for _ = 1, steps do
    WD_T0 = os.clock()
    clock = clock + 1 / 60
    local snap = {}; for i, t in ipairs(timers) do snap[i] = t end
    for _, t in ipairs(snap) do
      if not t.dead and t.at <= clock + 1e-9 then
        if t.every then t.at = t.at + t.every else t.dead = true end
        TFIRE = (TFIRE or 0) + 1
        local ok, e = pcall(t.f); if not ok then errors[#errors + 1] = "timer: " .. tostring(e) end
      end
    end
  end
end
