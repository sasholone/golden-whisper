import sys, os
from lupa import LuaRuntime
# uso: run.py head.lua body.lua [GW_SRC]
head, body = sys.argv[1], sys.argv[2]
src = sys.argv[3] if len(sys.argv) > 3 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "src", "groq_dictation.lua")
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("GW_SRC=%r; GW_OUTFILE=%r" % (src, "/dev/stdout"))
code = open(head).read() + "\n" + open(body).read()
# watchdog: hook count
lua.execute("""
local n = 0
WD_T0 = os.clock(); WD_MAX = 4
debug.sethook(function() if os.clock() - WD_T0 > WD_MAX then WD_T0 = os.clock(); error(debug.traceback('WATCHDOG loop >' .. WD_MAX .. 's', 2), 0) end end, '', 100000)
""")
f = lua.eval("function(code) local fn, e = load(code, '=harness'); if not fn then return 'LOADERR '..tostring(e) end; local ok, r = xpcall(fn, debug.traceback); return tostring(ok)..' '..tostring(r) end")
print(f(code))
