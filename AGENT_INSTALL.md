# 🤖 Autonomous install prompt — Golden Whisper

Copy everything in the block below and paste it into an AI coding agent running on your Mac
(e.g. **Claude Code**, Cursor, or any agent with shell access). It will install and configure
**Golden Whisper** end‑to‑end, walking you through creating a **free** Groq API key and the two
macOS permission dialogs.

---

```text
You are installing "Golden Whisper", a macOS voice-dictation tool, on this machine.
Work autonomously and only stop when you genuinely need input from me. Be very plain and
friendly in your instructions — assume I am not technical.

Goal: after you finish, I can double-tap Right Option, speak, double-tap again, and see my
speech pasted at the cursor in any app.

Steps:

1. Preconditions
   - Confirm this is macOS. If not, stop and tell me.
   - Ensure Homebrew is installed (`command -v brew`). If missing, give me the one-liner from
     https://brew.sh and stop until I've installed it.

2. Get the code
   - Clone the repo into my home directory:
       git clone https://github.com/sasholone/golden-whisper.git ~/golden-whisper
   - If the folder already exists, run `git -C ~/golden-whisper pull` instead.

3. Groq API key — GUIDE ME, it's free and takes ~1 minute
   - Check whether ~/.config/groq-dictation/api_key already exists and is non-empty. If yes, skip this.
   - Otherwise, open the sign-up page in my browser for me:
       open "https://console.groq.com/keys"
   - Then tell me, in simple steps:
       1) "Sign up (Google/GitHub/email) — it's free, no credit card."
       2) "Once logged in you're on the API Keys page. Click 'Create API Key', give it any name
          (e.g. 'golden-whisper'), and Create."
       3) "Copy the key that starts with gsk_ — you only see it once."
       4) "Paste it here in the chat."
   - When I paste it, save it (without ever printing it back):
       mkdir -p ~/.config/groq-dictation
       printf '%s' '<THE_KEY_I_PASTED>' > ~/.config/groq-dictation/api_key
       chmod 600 ~/.config/groq-dictation/api_key
     NEVER echo the key, log it, or commit it anywhere.

4. Run the installer
   - Run: `bash ~/golden-whisper/install.sh`
     (Installs ffmpeg + Hammerspoon via brew if missing, copies the module into ~/.hammerspoon/,
     wires init.lua non-destructively, creates settings.lua, records the repo path for auto-update,
     and reloads Hammerspoon. It won't ask for the key again since we already saved it.)

5. Permissions (these require ME to click — guide me clearly, one at a time)
   - Open Hammerspoon and grant it ACCESSIBILITY in
     System Settings → Privacy & Security → Accessibility (needed to paste at the cursor).
   - Tell me that the first time I record, macOS will ask for MICROPHONE access — I must click Allow.

6. Verify
   - Reload: `hs -c "hs.reload()"`.
   - Confirm no Lua errors:
       hs -c "return string.sub(hs.console.getConsole(), -300)"
   - Connectivity check to Groq with a generated test tone (no mic needed):
       ffmpeg -y -f lavfi -i "sine=frequency=440:duration=1" -ac 1 -ar 16000 /tmp/gw_test.wav
       curl -s -o /dev/null -w "%{http_code}" https://api.groq.com/openai/v1/audio/transcriptions \
         -H "Authorization: Bearer $(cat ~/.config/groq-dictation/api_key)" \
         -F model=whisper-large-v3-turbo -F file=@/tmp/gw_test.wav -F response_format=text
     Expect HTTP 200.

7. Report — plain language
   - Tell me it's ready and how to use it:
     • double-tap Right Option = start / stop
     • double-tap Right Shift = pause / resume (in pause, click the mic button to switch input)
     • the ✕ bubble (top-right) cancels and discards a recording
   - Tell me it auto-updates from GitHub daily (I can also update anytime with:
       bash ~/golden-whisper/update.sh   — or ask you to "update Golden Whisper").
   - Tell me to put my cursor somewhere and try it.

Constraints:
- Do not restart or kill unrelated processes. Never reload Hammerspoon while a recording is active.
- Do not print or log my API key.
- If any step fails twice, stop and show me the exact error instead of guessing.
```

---

## Updating later

Golden Whisper checks GitHub once a day and updates itself automatically (it only restarts when
you're not recording). To update on demand, run `bash ~/golden-whisper/update.sh`, or just tell your
agent: **"update Golden Whisper"**.
