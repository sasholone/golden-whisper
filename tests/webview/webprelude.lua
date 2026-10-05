-- prelude comune dei test t_web*: T(), reset, helper di apertura
local D = M._dbg
local C = M.config
local W = D.ICON.web
local DEF = {}; for k, v in pairs(C) do DEF[k] = v end
local nfail, ntest = 0, 0
local function reset()
  pcall(D.sclose); advance(1)
  for k in pairs(C) do if DEF[k] == nil and k ~= "LOOK" then C[k] = nil end end
  for k, v in pairs(DEF) do C[k] = v end
  C.ssBindings = { { kc = 61, mod = "alt", gesture = "double" } }; C.pauseBindings = { { kc = 60, mod = "shift", gesture = "single" } }
  C.settingsUI = "canvas"
  FAKE[C.settingsPath] = nil; FAKE[C.keyPath] = nil; PASTE = nil; CURLM = "ok"; LISTDEV = nil; BUTTONS = nil
  VFS.dirs = {}; VFS.attr = {}; WV.mode = "ok"; HSF.webview = WVMOD
  FRONT = "slack"; ACT = {}; WRITEFAIL = nil; W.failed = nil; W.pos = nil; W.size = { w = 560, h = 640 }; W.devs = nil
  M.config.audioDevice = ":0"; M.config.micName = nil
end
local function T(name, f, allow)
  WD_T0 = os.clock(); ntest = ntest + 1
  reset()
  local e0 = #errors
  local ok, e = xpcall(f, debug.traceback)
  local why = nil
  if not ok then why = "eccezione " .. tostring(e):sub(1, 400)
  elseif e ~= true then why = tostring(e) end
  -- errori nuovi nel harness (pcall falliti, NaN, ...) = fallimento, salvo il baseline 'gw_sticky'
  if not why then for i = e0 + 1, #errors do if not tostring(errors[i]):find("harness:%d+: no$") and not (allow and tostring(errors[i]):find(allow, 1, true)) then why = "errore harness: " .. tostring(errors[i]):sub(1, 200); break end end end
  if why then nfail = nfail + 1; why = tostring(why):gsub("[\128-\255]", "?") end
  OUT[#OUT + 1] = string.format("%-70s %s", name, why and ("FAIL " .. why) or "PASS")
  reset()
end
local function openWeb(page)
  C.settingsUI = "web"; M.settings(page or "general"); advance(0.05)
  local w = WV.cur(); if not w then return nil end
  WV.send({ op = "ready" }, w); advance(0.2)
  return w
end
local function closeWeb() pcall(D.sclose); advance(0.5) end
local function nstate(w) return #WV.states(w) end
local function ev(kc, ty, flags) return { getKeyCode = function() return kc end, getType = function() return ty end, getFlags = function() return flags or {} end, getProperty = function() return 0 end } end
local function deliver(e)
  local eaten = false
  local snap = {}; for _, t in ipairs(TAPS or {}) do snap[#snap + 1] = t end
  for _, t in ipairs(snap) do
    if t.on then for _, ty in ipairs(t.types) do if ty == e:getType() then if t.f(e) then eaten = true end break end end end
  end
  return eaten
end
local function mev(ty) return { getType = function() return ty end, getKeyCode = function() return 0 end, getFlags = function() return {} end, getProperty = function() return 0 end } end
local KEY = "gsk_" .. string.rep("AbCd1234", 5)
local function anyJsHas(needle)
  for _, w in ipairs(WV.list) do for _, j in ipairs(w.js) do if j:find(needle, 1, true) then return true end end end
  return false
end
local function outHas(needle) for _, l in ipairs(OUT) do if l:find(needle, 1, true) then return true end end return false end
local function eq(a, b, what) if a ~= b then return (what or "") .. " atteso " .. tostring(b) .. " ottenuto " .. tostring(a) end return nil end

local HOMEDIR = C.keyPath:gsub("/%.config/groq%-dictation/api_key$", "")
local PAGE = HOMEDIR .. "/.config/groq-dictation/ui/settings.html"

local function fresh(w) M.settings(); advance(0.2); return WV.lastState(w) end
local function lastEv(w, name) local r; for _, e in ipairs(WV.events(w)) do if e.name == name then r = e end end return r end
