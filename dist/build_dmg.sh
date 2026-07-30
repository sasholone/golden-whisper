#!/usr/bin/env bash
# Golden Whisper — costruisce il DMG self-contained da distribuire al team.
# Assembla: installer + Leggimi + (nascosto) Hammerspoon.app, ffmpeg arm64+intel, modulo.
# Prerequisiti (solo sul Mac di build): Hammerspoon in /Applications, ffmpeg preparati in _scratch/build.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$REPO/dist"
BUILD="$REPO/_scratch/build"
STAGE="$REPO/_scratch/dmg-stage"
VOL="Golden Whisper"
OUT="$REPO/_scratch/Golden Whisper.dmg"

FFMPEG_ARM64="$BUILD/ffmpeg-arm64-bundle"       # ffmpeg + lib/  (nativo Apple Silicon)
FFMPEG_X86="$BUILD/ffmpeg-x86_64/ffmpeg"        # binario statico Intel
HS_APP="/Applications/Hammerspoon.app"

say() { printf "\033[1;33m▶\033[0m %s\n" "$1"; }
ok()  { printf "\033[1;32m✓\033[0m %s\n" "$1"; }
die() { printf "\033[1;31m✕\033[0m %s\n" "$1" >&2; exit 1; }

# --- pre-check ---
[ -d "$HS_APP" ]              || die "Hammerspoon non trovato in /Applications"
[ -x "$FFMPEG_ARM64/ffmpeg" ] || die "ffmpeg arm64 bundle mancante ($FFMPEG_ARM64)"
[ -x "$FFMPEG_X86" ]          || die "ffmpeg x86_64 mancante ($FFMPEG_X86)"

say "Preparo lo staging…"
rm -rf "$STAGE"; mkdir -p "$STAGE/$VOL/.resources"
ROOT="$STAGE/$VOL"; RES="$ROOT/.resources"

# --- file visibili (quello che il collega vede nel DMG) ---
cp "$DIST/Installa Golden Whisper.command" "$ROOT/"
chmod +x "$ROOT/Installa Golden Whisper.command"
cp "$DIST/Leggimi.txt" "$ROOT/"

# --- risorse nascoste ---
cp "$REPO/src/groq_dictation.lua"        "$RES/groq_dictation.lua"
cp "$REPO/VERSION"                       "$RES/VERSION"
cp "$REPO/config/settings.example.lua"   "$RES/settings.example.lua"
say "Copio Hammerspoon.app (40MB)…"
cp -R "$HS_APP" "$RES/Hammerspoon.app"
say "Copio ffmpeg arm64 + Intel…"
mkdir -p "$RES/ffmpeg-arm64"
cp "$FFMPEG_ARM64/ffmpeg" "$RES/ffmpeg-arm64/ffmpeg"
cp -R "$FFMPEG_ARM64/lib" "$RES/ffmpeg-arm64/lib"
cp "$FFMPEG_X86" "$RES/ffmpeg-x86_64"
chmod +x "$RES/ffmpeg-arm64/ffmpeg" "$RES/ffmpeg-x86_64"
ok "Staging pronto"

# --- crea il DMG compresso ---
say "Creo il DMG…"
rm -f "$OUT"
hdiutil create -volname "$VOL" -srcfolder "$ROOT" -ov -format UDZO "$OUT" >/dev/null
SIZE=$(du -sh "$OUT" | cut -f1)
ok "DMG creato: $OUT ($SIZE)"
