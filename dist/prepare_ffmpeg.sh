#!/usr/bin/env bash
# Golden Whisper — prepara i due ffmpeg statici che finiscono nel DMG.
#   arm64  → il tuo ffmpeg Homebrew reso autonomo con dylibbundler (nativo Apple Silicon)
#   x86_64 → build statico Intel da evermeet.cx (fonte canonica ffmpeg statico macOS)
# Output in _scratch/build/. Idempotente: se già presenti e -f non passato, non rifà.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$REPO/_scratch/build"
ARM_DIR="$BUILD/ffmpeg-arm64-bundle"
X86_DIR="$BUILD/ffmpeg-x86_64"
FORCE="${1:-}"

say() { printf "\033[1;33m▶\033[0m %s\n" "$1"; }
ok()  { printf "\033[1;32m✓\033[0m %s\n" "$1"; }
die() { printf "\033[1;31m✕\033[0m %s\n" "$1" >&2; exit 1; }

command -v dylibbundler >/dev/null 2>&1 || die "dylibbundler mancante → brew install dylibbundler"
BREW_FFMPEG="$(command -v ffmpeg || true)"
[ -x "$BREW_FFMPEG" ] || die "ffmpeg (Homebrew) non trovato → brew install ffmpeg"

mkdir -p "$BUILD"

# --- arm64: ripacchetta il binario Homebrew + le sue dylib con path relativi ---
if [ "$FORCE" = "-f" ] || [ ! -x "$ARM_DIR/ffmpeg" ]; then
  say "Preparo ffmpeg arm64 (dylibbundler)…"
  rm -rf "$ARM_DIR"; mkdir -p "$ARM_DIR/lib"
  cp "$BREW_FFMPEG" "$ARM_DIR/ffmpeg"
  ( cd "$ARM_DIR" && dylibbundler -b -x ./ffmpeg -d ./lib -p @executable_path/lib/ -of -cd >/dev/null )
  refs=$(otool -L "$ARM_DIR/ffmpeg" "$ARM_DIR"/lib/*.dylib 2>/dev/null | grep -c "/opt/homebrew" || true)
  [ "$refs" -eq 0 ] || die "arm64 non autonomo: restano $refs riferimenti a /opt/homebrew"
  ok "arm64 pronto ($(ls "$ARM_DIR/lib" | wc -l | tr -d ' ') dylib incluse)"
else
  ok "arm64 già presente (usa -f per rifare)"
fi

# --- x86_64: build statico Intel da evermeet ---
if [ "$FORCE" = "-f" ] || [ ! -x "$X86_DIR/ffmpeg" ]; then
  say "Scarico ffmpeg Intel statico (evermeet.cx)…"
  rm -rf "$X86_DIR"; mkdir -p "$X86_DIR"
  ( cd "$X86_DIR" && curl -fsSL "https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip" -o ff.zip && unzip -oq ff.zip && rm -f ff.zip )
  [ -x "$X86_DIR/ffmpeg" ] || die "download evermeet fallito"
  chmod +x "$X86_DIR/ffmpeg"
  arch=$(file "$X86_DIR/ffmpeg" | grep -o "x86_64" || true)
  [ "$arch" = "x86_64" ] || die "il binario evermeet non è x86_64"
  ok "Intel pronto (statico)"
else
  ok "Intel già presente (usa -f per rifare)"
fi

echo; ok "ffmpeg pronti in $BUILD"
