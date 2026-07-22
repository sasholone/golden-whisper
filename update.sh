#!/usr/bin/env bash
# Golden Whisper — aggiornamento manuale (git pull + copia modulo + reload sicuro)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HS_DIR="$HOME/.hammerspoon"

echo "▶ Aggiorno Golden Whisper…"
git -C "$SCRIPT_DIR" pull --ff-only
cp "$SCRIPT_DIR/src/groq_dictation.lua" "$HS_DIR/groq_dictation.lua"

# reload SOLO se non c'è una registrazione attiva (non perdere audio)
if pgrep -fl "avfoundation.*groq_seg" >/dev/null 2>&1; then
  echo "⚠️ Registrazione in corso: modulo aggiornato, riavvia Hammerspoon quando hai finito (⌘⌥R)."
else
  hs -c "hs.reload()" >/dev/null 2>&1 || open -a Hammerspoon
  echo "✓ Aggiornato e ricaricato."
fi
