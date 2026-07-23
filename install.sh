#!/usr/bin/env bash
# Golden Whisper — installer per macOS
# Copia il modulo in Hammerspoon, installa le dipendenze, configura la chiave Groq.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HS_DIR="$HOME/.hammerspoon"
CFG_DIR="$HOME/.config/groq-dictation"
MARKER="golden-whisper"

say() { printf "\033[1;33m▶\033[0m %s\n" "$1"; }
ok()  { printf "\033[1;32m✓\033[0m %s\n" "$1"; }
err() { printf "\033[1;31m✕\033[0m %s\n" "$1" >&2; }

# 1. Homebrew
if ! command -v brew >/dev/null 2>&1; then
  err "Homebrew non trovato. Installalo da https://brew.sh e rilancia."
  exit 1
fi

# 2. Dipendenze
if ! command -v ffmpeg >/dev/null 2>&1; then
  say "Installo ffmpeg…"; brew install ffmpeg
fi
ok "ffmpeg presente"

if [ ! -d "/Applications/Hammerspoon.app" ]; then
  say "Installo Hammerspoon…"; brew install --cask hammerspoon
fi
ok "Hammerspoon presente"

# 3. Copia il modulo
mkdir -p "$HS_DIR" "$CFG_DIR"
cp "$SCRIPT_DIR/src/groq_dictation.lua" "$HS_DIR/groq_dictation.lua"
ok "Modulo copiato in $HS_DIR/groq_dictation.lua"

# 4. init.lua (append idempotente, non tocca la tua config esistente)
INIT="$HS_DIR/init.lua"
touch "$INIT"
if ! grep -q "$MARKER" "$INIT"; then
  cat >> "$INIT" <<'LUA'

-- >>> golden-whisper >>>
require("hs.ipc")
require("groq_dictation").init()
hs.alert.show("🎙️ Golden Whisper attivo — doppio Option destro", 2)
-- <<< golden-whisper <<<
LUA
  ok "Aggiunto il caricamento a init.lua"
else
  ok "init.lua già configurato"
fi

# 4b. Registra il path del clone per l'auto-update
printf '%s' "$SCRIPT_DIR" > "$CFG_DIR/repo_path"
ok "Path repo registrato per l'auto-update"

# 5. settings.lua (non sovrascrive se esiste)
if [ ! -f "$CFG_DIR/settings.lua" ]; then
  cp "$SCRIPT_DIR/config/settings.example.lua" "$CFG_DIR/settings.lua"
  ok "Creato settings.lua (personalizzabile)"
else
  ok "settings.lua già presente (lasciato com'è)"
fi

# 6. Chiave Groq
KEY_FILE="$CFG_DIR/api_key"
if [ ! -s "$KEY_FILE" ]; then
  if [ -n "${GROQ_API_KEY:-}" ]; then
    printf '%s' "$GROQ_API_KEY" > "$KEY_FILE"; chmod 600 "$KEY_FILE"
    ok "Chiave Groq presa da \$GROQ_API_KEY"
  else
    say "Serve una chiave Groq (gratis su https://console.groq.com/keys)"
    printf "Incolla la chiave (gsk_...) e premi invio: "
    read -r GKEY
    printf '%s' "$GKEY" > "$KEY_FILE"; chmod 600 "$KEY_FILE"
    ok "Chiave salvata in $KEY_FILE"
  fi
else
  ok "Chiave Groq già presente"
fi

# 7. Ricarica Hammerspoon
open -a Hammerspoon >/dev/null 2>&1 || true
sleep 2
hs -c "hs.reload()" >/dev/null 2>&1 || true

echo
ok "Installazione completata."
echo
say "ULTIMI 2 PASSI MANUALI (permessi macOS):"
echo "   1. Apri Hammerspoon → concedi ACCESSIBILITÀ (serve per incollare al cursore)"
echo "   2. Al primo utilizzo concedi il MICROFONO"
echo
say "USO:"
echo "   • doppio tap Option destro (o Ctrl destro) → START"
echo "   • un tap dello stesso tasto                 → STOP"
echo "   • un tap Shift destro                       → pausa / riprendi (in pausa scegli il mic dall'HUD)"
echo "   • ✕ in alto a destra                        → annulla e scarta la registrazione"
echo "   Metti il cursore dove vuoi il testo, detta, e viene incollato lì."
echo
say "Golden Whisper si auto-aggiorna da GitHub (update manuale: bash $SCRIPT_DIR/update.sh)"
