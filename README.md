# 🎙️ whisperflow-groq

A tiny **Whisper Flow–style voice dictation** overlay for macOS, powered by the
[Groq](https://groq.com) Whisper API. Double‑tap a key, speak, and the transcript
is pasted **right where your cursor is** — in any app.

No Electron, no menu‑bar app to build: it runs as a small
[Hammerspoon](https://www.hammerspoon.org) module with a floating HUD.

The HUD lives at the bottom of the screen (black / white / gold): a recording timer, a live
microphone waveform, and pause / stop buttons.

---

## Features

- **Global hotkeys** — double‑tap **Right Option** to start/stop, double‑tap **Right Shift** to pause/resume.
- **Paste at cursor + clipboard** — the transcription lands wherever you're typing **and** stays on the clipboard, so you never lose it (toggle with `restoreClipboard`).
- **Cancel anytime** — a ✕ in the top‑right of the HUD stops recording and **discards** it (no transcription).
- **Fast** — uses `whisper-large-v3-turbo`; a ~20s note transcribes in ~1–2s.
- **Live HUD** (black / white / gold) — recording timer, a **real** microphone waveform, pause & stop buttons.
- **Clean pause** — recording is segmented, so pausing doesn't record dead silence.
- **Mic picker** — while paused, click the 🎙️ button to switch input device (saved to your settings).
- **Configurable** — language, mic, model and trigger keys live in a plain settings file.

## Requirements

- macOS (Apple Silicon or Intel)
- [Homebrew](https://brew.sh)
- A **Groq API key** (free tier is plenty) → https://console.groq.com/keys

`ffmpeg` and `Hammerspoon` are installed automatically by the installer if missing.

## Install

```bash
git clone https://github.com/sasholone/whisperflow-groq.git
cd whisperflow-groq
bash install.sh
```

The installer will:
1. Install `ffmpeg` and `Hammerspoon` via Homebrew if needed.
2. Copy the module into `~/.hammerspoon/` and wire it into your `init.lua` (non‑destructively).
3. Create `~/.config/groq-dictation/settings.lua` from the example.
4. Ask for your Groq API key (or read it from `$GROQ_API_KEY`).
5. Reload Hammerspoon.

Then do the **two manual permission steps** macOS requires:
- Open **Hammerspoon** → grant **Accessibility** (needed to paste at the cursor).
- On first use, grant the **Microphone** permission.

> Prefer to have an AI agent do all of this for you? See **[AGENT_INSTALL.md](AGENT_INSTALL.md)** —
> paste that prompt into Claude Code (or any coding agent) and it runs the whole install autonomously.

## Usage

Put your cursor where you want the text, then:

| Action | Shortcut |
| --- | --- |
| Start / stop recording | double‑tap **Right Option** (⌥) |
| Pause / resume | double‑tap **Right Shift** (⇧) |
| Switch microphone | pause, then click the 🎙️ button in the HUD |
| Stop & transcribe | click the ■ button |
| Cancel & discard | click the ✕ bubble (top‑right) |

After you stop, the HUD shows the pipeline — **Received → Sent → Transcribing → Done** — and the text is pasted.

## Configuration

Edit `~/.config/groq-dictation/settings.lua`, then reload with `hs -c "hs.reload()"`:

```lua
return {
  language  = "it",                        -- "it" forces Italian | "auto" = auto-detect
  micDevice = ":0",                        -- avfoundation input index (or pick from the HUD)
  model     = "whisper-large-v3-turbo",    -- or "whisper-large-v3" (more accurate, a touch slower)

  startStopKeycode = 61, startStopFlag = "alt",    -- Right Option
  pauseKeycode     = 60, pauseFlag     = "shift",  -- Right Shift
  doubleTapSec     = 0.50,                          -- double-tap window
  restoreClipboard = false,                         -- false = transcript stays on the clipboard | true = restore previous clipboard
}
```

Key codes: `61`=Right Option, `62`=Right Ctrl, `54`=Right Cmd, `60`=Right Shift.
List microphone indices with:

```bash
ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -A20 "audio devices"
```

## How it works

`Hammerspoon hotkey → ffmpeg records mono 16kHz WAV → Groq /audio/transcriptions → paste (⌘V) at cursor`.

The live waveform reads ffmpeg's real‑time RMS level (via `astats`) off stderr. Pause/resume records
separate WAV segments that are concatenated before transcription.

## Privacy

Your audio is sent to Groq's API for transcription. Nothing else leaves your machine; the API key is
stored locally in `~/.config/groq-dictation/api_key` and is **never** committed.

## Uninstall

```bash
bash uninstall.sh
```

## License

MIT — see [LICENSE](LICENSE).
