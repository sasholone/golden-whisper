-- Golden Whisper — impostazioni
-- Dopo aver modificato, ricarica:  hs -c "hs.reload()"
--
-- Il microfono si può scegliere anche dall'HUD: metti in pausa (doppio Shift destro) e
-- clicca il pulsante microfono a sinistra. La scelta viene salvata qui sotto (micDevice).
--
-- Per vedere gli indici dei microfoni a mano:
--   /opt/homebrew/bin/ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -A20 "audio devices"

return {
  language  = "it",                       -- "it" forza italiano | "auto" = riconoscimento automatico
  micDevice = ":0",                       -- ":0" = MacBook Air Microphone (o scegli dall'HUD)
  model     = "whisper-large-v3-turbo",   -- alt: "whisper-large-v3" (più accurato, un filo più lento)

  -- Trigger 1: START / STOP  (doppio tap)
  startStopKeycode = 61,                  -- 61=Option dx | 62=Ctrl dx | 54=Cmd dx | 60=Shift dx
  startStopFlag    = "alt",               -- deve combaciare: alt / ctrl / cmd / shift

  -- Trigger 2: PAUSA / RIPRENDI  (doppio tap)
  pauseKeycode = 60,                      -- 60 = Shift destro
  pauseFlag    = "shift",

  doubleTapSec  = 0.50,                   -- finestra del doppio tap (secondi)
  maxSegmentSec = 480,                    -- auto-taglia l'audio ogni N sec (sotto il limite ~13min/25MB di Groq)
  restoreClipboard = false,               -- false = il testo resta in clipboard (consigliato) | true = ripristina quella precedente
  autoUpdate = true,                      -- controlla GitHub ogni giorno e si aggiorna da solo (mai durante una registrazione)
}
