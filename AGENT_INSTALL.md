# 🤖 Autonomous install prompt

Copy everything in the block below and paste it into an AI coding agent running on your Mac
(e.g. **Claude Code**, Cursor, or any agent with shell access). It will install and configure
**whisperflow-groq** end‑to‑end, only pausing to ask you for your Groq API key and to walk you
through the two macOS permission dialogs.

---

```text
You are installing "whisperflow-groq", a macOS voice-dictation tool, on this machine.
Work autonomously and only stop to ask me when you genuinely need input from me.

Goal: after you finish, I can double-tap Right Option, speak, double-tap again, and see my
speech pasted at the cursor in any app.

Steps:

1. Preconditions
   - Confirm this is macOS. If not, stop and tell me.
   - Ensure Homebrew is installed (`command -v brew`). If missing, give me the one-liner from
     https://brew.sh and stop until I've installed it.

2. Get the code
   - Clone the repo into my home directory:
       git clone https://github.com/sasholone/whisperflow-groq.git ~/whisperflow-groq
   - If the folder already exists, `git -C ~/whisperflow-groq pull` instead.

3. Groq API key
   - Check whether ~/.config/groq-dictation/api_key already exists and is non-empty.
   - If not, ask me to create a free key at https://console.groq.com/keys and paste it.
     Write it to that file with `printf '%s' '<KEY>' > ~/.config/groq-dictation/api_key`
     and `chmod 600` it. NEVER echo the key back, print it, or commit it anywhere.

4. Run the installer
   - Run: `bash ~/whisperflow-groq/install.sh`
     (It installs ffmpeg + Hammerspoon via brew if missing, copies the module into
     ~/.hammerspoon/, wires init.lua non-destructively, creates settings.lua, and reloads
     Hammerspoon.)
   - If the installer already found the key, it won't prompt again.

5. Permissions (these require ME to click — guide me clearly)
   - Tell me to open Hammerspoon and grant it ACCESSIBILITY in
     System Settings → Privacy & Security → Accessibility (needed to paste at the cursor).
   - Tell me that on first recording macOS will ask for MICROPHONE access — I must allow it.

6. Verify
   - Reload the config: `hs -c "hs.reload()"`.
   - Read the last lines of the Hammerspoon console to confirm no Lua errors:
       hs -c "return string.sub(hs.console.getConsole(), -300)"
   - Optionally run a connectivity check to Groq with a generated test tone (no mic needed):
       ffmpeg -y -f lavfi -i "sine=frequency=440:duration=1" -ac 1 -ar 16000 /tmp/wf_test.wav
       curl -s -o /dev/null -w "%{http_code}" https://api.groq.com/openai/v1/audio/transcriptions \
         -H "Authorization: Bearer $(cat ~/.config/groq-dictation/api_key)" \
         -F model=whisper-large-v3-turbo -F file=@/tmp/wf_test.wav -F response_format=text
     Expect HTTP 200.

7. Report
   - Summarize what you did and remind me of the shortcuts:
     • double-tap Right Option = start/stop
     • double-tap Right Shift = pause/resume (in pause, click the mic button to switch input)
   - Tell me to put my cursor somewhere and try it.

Constraints:
- Do not restart or kill unrelated processes.
- Do not print or log my API key.
- If any step fails twice, stop and show me the exact error instead of guessing.
```

---

That's it — the agent handles cloning, dependencies, wiring and verification; you handle the Groq
key and the two permission clicks.
