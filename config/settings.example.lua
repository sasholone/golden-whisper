-- Golden Whisper — impostazioni
-- Tutto è modificabile dal menu Impostazioni: metti in pausa e clicca l'ingranaggio ⚙.
-- Dopo aver modificato a mano, ricarica:  hs -c "hs.reload()"
--
-- Per vedere gli indici dei microfoni a mano:
--   /opt/homebrew/bin/ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -A20 "audio devices"

return {
  language  = "it",                       -- "it" forza italiano | "auto" = riconoscimento automatico
  micDevice = ":0",                       -- indice input (fallback); di norma scegli dall'HUD
  -- micName si salva da solo quando scegli il mic dall'HUD: risolto per NOME a ogni registrazione,
  -- così se stacchi il dispositivo salvato (es. AirPods) passa da solo a quello disponibile.
  -- micName = "AirPods di ...",
  model     = "whisper-large-v3-turbo",   -- alt: "whisper-large-v3" (più accurato, un filo più lento)

  -- TASTO AVVIO / STOP
  startStopKeycode = 61,                  -- 61=Option dx | 62=Ctrl dx | 54=Cmd dx | 60=Shift dx
  startStopFlag    = "alt",               -- deve combaciare: alt / ctrl / cmd / shift
  ssGesture        = "double",            -- double (2 tap avvia, 1 tap ferma) | single (1 tap alterna) | hold (tieni premuto)

  -- TASTO PAUSA / RIPRENDI
  pauseKeycode = 60,                      -- 60 = Shift destro
  pauseFlag    = "shift",
  pauseGesture = "single",                -- single (1 tap) | double (2 tap)

  doubleTapSec  = 0.50,                   -- finestra del doppio tap (secondi)
  maxSegmentSec = 480,                    -- auto-taglia l'audio ogni N sec (sotto il limite ~13min/25MB di Groq)
  restoreClipboard = false,               -- false = il testo resta in clipboard (consigliato) | true = ripristina quella precedente
  autoUpdate = true,                      -- controlla GitHub ogni giorno e si aggiorna da solo (mai durante una registrazione)

  -- Aspetto
  sizePreset  = "standard",               -- standard | large (+20%) | minimal (-30%)
  orientation = "horizontal",             -- horizontal | vertical
  style       = "gold",                   -- gold | mono | goldlight | monolight
  themeAuto   = false,                    -- true = segue il tema chiaro/scuro del sistema (usa la famiglia di 'style')
  -- posX / posY = centro della card; si salvano da soli quando trascini l'overlay col mouse
}
