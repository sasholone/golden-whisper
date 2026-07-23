# 🎙️ Golden Whisper

A tiny **Whisper Flow–style voice dictation** overlay for macOS, powered by the
[Groq](https://groq.com) Whisper API. Double‑tap a key, speak, and the transcript is pasted
**right where your cursor is** — in any app.

No Electron, no menu‑bar app to build: it runs as a small
[Hammerspoon](https://www.hammerspoon.org) module with a floating HUD.

The HUD lives at the bottom of the screen (black / white / gold): a recording timer, a live
microphone waveform, and pause / stop buttons, with a ✕ badge to cancel.

---

## Features

- **Global hotkeys** — **double‑tap Right Option** (or **Right Ctrl**) to start; a **single tap** of that key to stop; a **single Right Shift** tap to pause/resume.
- **Paste at cursor + clipboard** — the transcription lands wherever you're typing **and** stays on the clipboard, so you never lose it.
- **Cancel anytime** — a ✕ in the top‑right of the HUD stops recording and **discards** it (no transcription).
- **Fast** — uses `whisper-large-v3-turbo`; a ~20s note transcribes in ~1–2s.
- **Live HUD** (black / white / gold) — recording timer, a **real** microphone waveform, pause & stop buttons.
- **Clean pause** — recording is segmented, so pausing doesn't record dead silence.
- **No length limit / never lose audio** — long recordings are auto‑split (every `maxSegmentSec`, default 8 min) so they stay under Groq's file limit; each chunk is transcribed and the text is joined. If a transcription fails, the audio is saved to `~/.config/groq-dictation/recordings/` instead of being lost.
- **Draggable** — grab the bar anywhere and move it (even while recording); position is remembered.
- **Settings menu** (tabbed) — while paused, click the ⚙ gear. **General** tab: microphone, **size** (standard/large/minimal), **orientation** (horizontal/vertical), **style** (Gold, Mono, Gold Light, Mono Light) and a **theme toggle** (fixed, or **Auto** to follow the macOS light/dark appearance). **Keys** tab: rebind Start/Stop and Pause — pick the key (right Option/Ctrl/Cmd/Shift) and the gesture (double‑tap / single‑tap / hold).
- **Polished HUD** — hover feedback on every control and a soft drop shadow; the panel and bar are draggable.
- **Auto‑update** — checks GitHub daily and updates itself (only ever restarts when you're not recording).

## Requirements

- macOS (Apple Silicon or Intel)
- [Homebrew](https://brew.sh)
- A **free Groq API key** → https://console.groq.com/keys (see below)

`ffmpeg` and `Hammerspoon` are installed automatically by the installer if missing.

## Get a free Groq API key (~1 min)

1. Go to **https://console.groq.com/keys** and sign up (Google/GitHub/email) — **free, no credit card**.
2. On the **API Keys** page click **Create API Key**, name it anything (e.g. `golden-whisper`), Create.
3. Copy the key starting with `gsk_` (shown once).
4. The installer will ask you to paste it — done.

## Install

```bash
git clone https://github.com/sasholone/golden-whisper.git
cd golden-whisper
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
> paste that prompt into Claude Code (or any coding agent) and it runs the whole install
> autonomously, including opening the Groq page and walking you through the key.

## Usage

Put your cursor where you want the text, then:

| Action | Shortcut |
| --- | --- |
| Start recording | **double‑tap Right Option** (⌥) — or **Right Ctrl** |
| Stop recording | **single tap** the same key |
| Pause / resume | **single tap Right Shift** (⇧) |
| Open settings (mic, size, orientation, style) | pause, then click the 🎙️ button |
| Move the bar | drag it anywhere with the mouse |
| Stop & transcribe | click the ■ button |
| Cancel & discard | click the ✕ bubble (top‑right) |

Start needs a double‑tap (so you never trigger it by accident while typing); once recording, a single tap
is enough to stop or pause. **Right Ctrl** works as an alternative start/stop key for keyboards without a
usable right Option/Cmd.

After you stop, the HUD shows the pipeline — **Received → Sent → Transcribing → Done** — and the text is pasted.

## Updating

Golden Whisper checks GitHub once a day and updates itself automatically (it only restarts when
you're not recording). To update on demand:

```bash
bash ~/golden-whisper/update.sh
```

…or just tell your AI agent **"update Golden Whisper"**.

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
  maxSegmentSec    = 480,                           -- auto-split every N seconds (stays under Groq's ~13min/25MB limit)
  restoreClipboard = false,                         -- false = transcript stays on the clipboard | true = restore previous clipboard
  autoUpdate       = true,                          -- daily GitHub self-update (never restarts mid-recording)
}
```

Key codes: `61`=Right Option, `62`=Right Ctrl, `54`=Right Cmd, `60`=Right Shift.
List microphone indices with:

```bash
ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -A20 "audio devices"
```

## How it works

`Hammerspoon hotkey → ffmpeg records mono 16kHz WAV → Groq /audio/transcriptions → paste (⌘V) at cursor`.

The live waveform reads ffmpeg's real‑time RMS level (via `astats`) off stderr. Pause/resume and the
auto‑split write separate WAV segments that are transcribed individually and joined — so recording
length is effectively unlimited and audio survives interruptions.

## Privacy

Your audio is sent to Groq's API for transcription. Nothing else leaves your machine; the API key is
stored locally in `~/.config/groq-dictation/api_key` and is **never** committed.

## Uninstall

```bash
bash uninstall.sh
```

## License

MIT — see [LICENSE](LICENSE).
