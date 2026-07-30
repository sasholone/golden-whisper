#!/bin/bash
# Golden Whisper — installer self-contained (bundle Hammerspoon + ffmpeg).
# Il collega fa doppio click su questo file dal DMG. Nessun git, nessun Homebrew.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="$HERE/.resources"
HS_DIR="$HOME/.hammerspoon"
CFG="$HOME/.config/groq-dictation"
MARKER="golden-whisper"

say() { printf "\033[1;33m▶\033[0m %s\n" "$1"; }
ok()  { printf "\033[1;32m✓\033[0m %s\n" "$1"; }
err() { printf "\033[1;31m✕\033[0m %s\n" "$1" >&2; }

clear
echo "==================================================="
echo "   🎙️  Golden Whisper — installazione"
echo "==================================================="
echo

# 0. Sanity
if [ "$(uname)" != "Darwin" ]; then err "Questo installer è solo per macOS."; exit 1; fi
if [ ! -d "$RES" ]; then err "Risorse non trovate. Apri il DMG e lancia l'installer da lì."; exit 1; fi

mkdir -p "$HS_DIR" "$CFG" "$CFG/bin"

# 1. Hammerspoon (il motore dell'app) → /Applications
if [ ! -d "/Applications/Hammerspoon.app" ]; then
  say "Installo Hammerspoon…"
  cp -R "$RES/Hammerspoon.app" "/Applications/" 2>/dev/null || { err "Non riesco a copiare Hammerspoon in /Applications"; exit 1; }
  xattr -dr com.apple.quarantine "/Applications/Hammerspoon.app" 2>/dev/null || true
  ok "Hammerspoon installato"
else
  ok "Hammerspoon già presente"
fi

# 2. ffmpeg giusto per l'architettura (nativo, niente Rosetta)
ARCH="$(uname -m)"
rm -rf "$CFG/bin/lib" "$CFG/bin/ffmpeg"
if [ "$ARCH" = "arm64" ]; then
  say "Configuro ffmpeg (Apple Silicon)…"
  cp "$RES/ffmpeg-arm64/ffmpeg" "$CFG/bin/ffmpeg"
  cp -R "$RES/ffmpeg-arm64/lib" "$CFG/bin/lib"
else
  say "Configuro ffmpeg (Intel)…"
  cp "$RES/ffmpeg-x86_64" "$CFG/bin/ffmpeg"
fi
chmod +x "$CFG/bin/ffmpeg"
xattr -dr com.apple.quarantine "$CFG/bin" 2>/dev/null || true
ok "ffmpeg pronto ($ARCH)"

# 3. Modulo + versione + settings
cp "$RES/groq_dictation.lua" "$HS_DIR/groq_dictation.lua"
cp "$RES/VERSION" "$CFG/version"
ok "Modulo copiato (v$(cat "$CFG/version" 2>/dev/null | tr -d '[:space:]'))"
if [ ! -f "$CFG/settings.lua" ]; then
  cp "$RES/settings.example.lua" "$CFG/settings.lua"
  ok "Creato settings.lua"
else
  ok "settings.lua già presente (lasciato com'è)"
fi

# 4. init.lua (append idempotente, non tocca eventuale config esistente)
INIT="$HS_DIR/init.lua"; touch "$INIT"
if ! grep -q "$MARKER" "$INIT"; then
  cat >> "$INIT" <<'LUA'

-- >>> golden-whisper >>>
require("hs.ipc")
require("groq_dictation").init()
hs.alert.show("🎙️ Golden Whisper attivo — doppio Option destro", 2)
-- <<< golden-whisper <<<
LUA
  ok "Caricamento aggiunto a init.lua"
else
  ok "init.lua già configurato"
fi

# 5. Chiave Groq (gratis) — necessaria per trascrivere
KEY_FILE="$CFG/api_key"
if [ ! -s "$KEY_FILE" ]; then
  echo
  say "Serve una chiave Groq — è GRATIS e ci vuole 1 minuto."
  echo "   Ti apro la pagina: accedi (Google/GitHub/email), crea una API Key,"
  echo "   copia quella che inizia con gsk_ e incollala qui sotto."
  open "https://console.groq.com/keys" >/dev/null 2>&1 || true
  echo
  printf "   Incolla la chiave (gsk_...) e premi Invio: "
  read -r GKEY
  if [ -n "${GKEY:-}" ]; then
    printf '%s' "$GKEY" > "$KEY_FILE"; chmod 600 "$KEY_FILE"
    ok "Chiave salvata"
  else
    err "Nessuna chiave inserita — potrai metterla dopo in $KEY_FILE"
  fi
else
  ok "Chiave Groq già presente"
fi

# 6. Avvia Hammerspoon
say "Avvio Golden Whisper…"
open -a Hammerspoon >/dev/null 2>&1 || true
sleep 2

echo
echo "==================================================="
ok  "Installazione completata!"
echo "==================================================="
echo
say "ULTIMI 2 PASSI (permessi macOS, una volta sola):"
echo "   1) ACCESSIBILITÀ — serve per incollare il testo dove hai il cursore."
echo "      Ti apro le impostazioni: attiva Hammerspoon nella lista."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true
echo "   2) MICROFONO — la prima volta che detti, macOS lo chiede: consenti."
echo
say "COME SI USA:"
echo "   • doppio tap Option destro  → START (parla)"
echo "   • un tap Option destro      → STOP (il testo viene incollato al cursore)"
echo "   • icona 🎙️ nella barra in alto → menu / impostazioni"
echo
echo "Puoi chiudere questa finestra."
echo
