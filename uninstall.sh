#!/usr/bin/env bash
# whisperflow-groq — disinstalla (lascia intatta la tua init.lua a parte il nostro blocco)
set -euo pipefail

HS_DIR="$HOME/.hammerspoon"
CFG_DIR="$HOME/.config/groq-dictation"
INIT="$HS_DIR/init.lua"

rm -f "$HS_DIR/groq_dictation.lua"

# rimuove solo il blocco marcato da init.lua
if [ -f "$INIT" ]; then
  /usr/bin/sed -i '' '/-- >>> whisperflow-groq >>>/,/-- <<< whisperflow-groq <<</d' "$INIT"
fi

echo "Rimosso il modulo e il blocco da init.lua."
echo "La config personale è ancora in $CFG_DIR (rimuovila a mano se vuoi: rm -rf $CFG_DIR)."
hs -c "hs.reload()" >/dev/null 2>&1 || true
