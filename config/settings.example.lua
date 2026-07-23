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
  micDevice = ":0",                       -- indice input (fallback); di norma scegli dall'HUD
  -- micName si salva da solo quando scegli il mic dall'HUD: il mic è risolto per NOME a ogni
  -- registrazione, così se stacchi il dispositivo salvato (es. AirPods) passa da solo a quello disponibile.
  -- micName = "AirPods di ...",
  model     = "whisper-large-v3-turbo",   -- alt: "whisper-large-v3" (più accurato, un filo più lento)

  -- Trigger START/STOP: START = DOPPIO tap | STOP = UN tap. (Ctrl destro è sempre valido come alternativa.)
  startStopKeycode = 61,                  -- 61=Option dx | 62=Ctrl dx | 54=Cmd dx | 60=Shift dx
  startStopFlag    = "alt",               -- deve combaciare: alt / ctrl / cmd / shift

  -- Trigger PAUSA/RIPRENDI: UN tap
  pauseKeycode = 60,                      -- 60 = Shift destro
  pauseFlag    = "shift",

  doubleTapSec  = 0.50,                   -- finestra del doppio tap (secondi)
  maxSegmentSec = 480,                    -- auto-taglia l'audio ogni N sec (sotto il limite ~13min/25MB di Groq)
  restoreClipboard = false,               -- false = il testo resta in clipboard (consigliato) | true = ripristina quella precedente
  autoUpdate = true,                      -- controlla GitHub ogni giorno e si aggiorna da solo (mai durante una registrazione)

  -- Aspetto (modificabili anche dal menu Impostazioni: pausa → click sul pulsante a sinistra)
  sizePreset  = "standard",               -- standard | large (+20%) | minimal (-30%)
  orientation = "horizontal",             -- horizontal | vertical
  style       = "gold",                   -- gold | mono (WIP)
  -- posX / posY = centro della card; si salvano da soli quando trascini l'overlay col mouse
}
