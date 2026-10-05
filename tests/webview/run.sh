#!/bin/bash
# Test della finestra Impostazioni web, FUORI da Hammerspoon (Lua standalone con lupa + hs finto + watchdog). Mai hs -c.
#   LUAPY=<python con lupa>  ./run.sh [src.lua]       -> t_web1 (ciclo di vita/stato), t_web2 (op del ponte), t_web3 (fuzz), test_build.py
#   FZ_SEED0=1 FZ_N=2500 FZ_LEN=30 ./run.sh           -> intensita' del fuzz
# head9.lua = harness storico (head8) + JSON vero + hs.webview/usercontent finti + FS virtuale + app in primo piano finta.
cd "$(dirname "$0")"
PY=${LUAPY:-python3}
SRC=${1:-$(cd ../.. && pwd)/src/groq_dictation.lua}
for t in t_web1 t_web2 t_web3; do
  cat webprelude.lua $t.lua > /tmp/_gw_$t.lua
  FZ_SEED0=${FZ_SEED0:-1} FZ_N=${FZ_N:-500} FZ_LEN=${FZ_LEN:-14} perl -e 'alarm 120; exec @ARGV' $PY run.py head9.lua /tmp/_gw_$t.lua "$SRC" 2>&1 | grep -E "TOTALE|FAIL|LOADERR|^false"
done
$PY test_build.py | tail -1
