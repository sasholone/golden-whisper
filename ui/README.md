# Golden Whisper - Impostazioni su pagina web (hs.webview)

Pagina unica (HTML/CSS/JS vanilla, zero rete) che sostituisce la finestra Impostazioni disegnata con `hs.canvas`.
L'host Lua la carica in un `hs.webview` (WKWebView, GPU) e dialoga col **ponte** descritto sotto.

## Aprirla subito in un browser (MOCK)
- Doppio click su `ui/dist/settings.html` (build, un solo file) oppure su `ui/index.html` (sorgenti separati).
- Fuori da hs.webview non esiste `window.webkit.messageHandlers.gw`: `gw-bridge.js` usa il **mock** (`js/mock.js`): 70 stili generati, 12 microfoni (uno con nome ostile `<script>`), chiave Groq finta (25% di errore al "Incolla"), cattura tasti simulata, "Sorprendimi" vero.
- Tab iniziale via hash: `settings.html#theme`, `#keys`, `#general`. Materiale: `#material=solid` (default) o `#material=glass`; si combinano: `#theme&material=glass&style=ocean&themeMode=light` (qualsiasi chiave di look; cambiando l'hash la pagina si ricarica).
- Riga bassa a sinistra "MOCK: ..." = sei sul mock.

## Build
`node ui/build-inline.mjs` -> `ui/dist/settings.html` (CSS+JS inline, CSP stretta, dimensione stampata; esce con errore se > 250 KB o se trova riferimenti esterni nei test). Il file `dist/settings.html` e' versionato: rigenerarlo dopo ogni modifica (un test lo verifica).

## Test
```
cd ui && npm install      # solo per jsdom (devDependency, node_modules ignorata da git)
node --test tests/         # 78 test, ~6 s
GW_SMOKE=1 node --test tests/smoke.test.mjs   # UNA volta: Chrome headless, 0 errori console, 70 carte
```

## Contratto del ponte (v1)
**JS -> Lua**: `window.webkit.messageHandlers.gw.postMessage({op, ...args})`

| op | args | note |
|---|---|---|
| `ready` | - | pagina pronta; Lua risponde con `gw.onState(stato)` |
| `set` | `{key, value}` | chiavi: style, themeMode, glassOpacity, cornerStyle, animOn, animSpeed, waveStyle, waveColor, micPulse, glowOn, uiFont, timerFont, density, idleOpacity, shadowOn, shadowIntensity, sizePreset, orientation, material (`solid`|`glass`, opzionale in `look`, default `solid`). Gli slider mandano al max 1 messaggio / 80 ms + l'ultimo valore garantito |
| `random_look` / `reset_look` | - | Sorprendimi / Reset look (la UI chiede doppio tocco per il reset) |
| `pick_mic` | `{name}` | |
| `refresh_devices` | - | risposta: evento `devices` |
| `key_paste` | - | **nessun payload**: Lua legge il clipboard, valida con Groq, salva. Il JS non vede mai la chiave |
| `key_remove` | - | inviato solo al 2o tocco entro 3 s |
| `open_groq` | - | |
| `capture_start` / `capture_cancel` | `{action:'ss'\|'pause'}` / - | |
| `key_remove_binding` | `{action, index}` | |
| `key_set_gesture` | `{action, index, gesture:'single'\|'double'\|'hold'}` | |
| `set_tab` | `{tab}` | general / keys / theme |
| `close` | - | |
| `drag_start` | `{sx, sy}` | mousedown sull'header (screenX/screenY). Niente `-webkit-app-region` |
| `resize_request` | `{w, h}` | w=432 (general/keys) o 800 (theme); h = altezza naturale (header+tab+contenuto) **con tetto**: general/keys 680, theme 760 (oltre, il corpo scorre dentro). L'host clampa a min(schermo-24, 820 x 760). Inviato a cambio tab e quando cambia il contenuto (debounce 90 ms) |
| `interact` | - | UNA volta, al primo `pointerdown` |
| `hb` | - | heartbeat ogni 1000 ms |

**Lua -> JS**: la pagina definisce `window.gw = { onState(state), onEvent(name, payload) }`.
- `onState(state)` sostituisce tutto (la UI e' ottimistica: dopo un `set` si e' gia' aggiornata). Campi mancanti = default sensati (vedi `js/state.js: normalize`). Stato: `{version, tab, look:{...17 chiavi, `material` opzionale}, general:{micName, devices:[{name,bt}], sizePreset, orientation}, keys:{ss:[{label,gesture}], pause:[...]}, groq:{has,mask}, styles:[{id,name,cat,dark:{bg1,bg2,fg,fg2,accent,grad[]},light:{...},fx:{icon,bar,part}|null}], cats:[{id,name}], effectiveMode, assets:{<styleId>:{icon?,spin?}}}`.
- `onEvent('key_status', {has, mask, msg, kind:'ok'|'error'|'busy'})`, `('devices', [..])`, `('capture_result', {ok,label,action})`, `('toast', {text})`.
- Il messaggio `key_status` sparisce da solo dopo 9 s (come in Lua); `busy` resta finche' non arriva un altro stato.

**Dove serve davvero `onState` dopo un'azione** (la UI non puo' prevederlo): `random_look`, `reset_look` (la UI azzera da sola, ma meglio confermare), `capture_result` ok (nuova lista tasti), `key_paste`/`key_remove` (anche `key_status`).

**Sanificazione**: nomi microfono, etichette tasti, messaggi, nomi stile -> sempre `textContent`, mai HTML; colori solo `#rrggbb`; id stile `[a-z0-9_-]{1,40}`; url asset solo `file:`, `blob:`, `data:image/*` (http(s) scartato).

**Fatti dallo spike hs.webview**: font solo keyword (`-apple-system`/`system-ui`, `ui-rounded`, `ui-monospace`); asset `file:///...` solo in `<img>`/CSS background (no fetch/XHR); CSP `default-src 'none'; img-src data: file: blob:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; font-src data:`; niente eval/window.open/navigazioni; Esc lo gestisce l'host (la pagina manda solo `capture_cancel` se la cattura e' attiva); nessun click-through.

## Budget di performance (verificato da `tests/build.test.mjs`)
- Si animano SOLO `transform` e `opacity` (scansione di ogni `transition`/`@keyframes`/`will-change`); mai width/height/box-shadow/filter/blur/gradient/SVG path. Niente `animation: infinite`, niente `setInterval` (l'heartbeat e' una catena di `setTimeout`), niente `.animate()`.
- Hover = overlay `::before/::after` con opacity (ombra/sfondo gia' disegnati). Pillola dei segmented = `translateX(var(--i)*100%)`. Switch = knob translateX + overlay opacity.
- UN solo `backdrop-filter` (il `.panel` radice).
- Anteprima HUD: `<canvas>` 2D a <= 30 Hz; il loop rAF gira solo con mouse sopra l'anteprima + finestra visibile + tab Tema + `animOn` + niente `prefers-reduced-motion`; altrimenti `cancelAnimationFrame` e un solo disegno statico. `pv.dataset.running` = '1'/'0' (hook di test).
- 70+ carte a FINESTRA di righe: nel DOM solo le righe visibili +-3 (spaziatori sopra/sotto), carta + mini onda SVG create solo quando la riga entra in finestra, spunta solo sulla carta corrente; categoria iniziale = quella dello stile corrente (finche' l'utente non ne sceglie un'altra), scroll alla carta selezionata. Gradienti CSS statici (`--gd/--gl`), nessuna animazione per carta. Cambio categoria = ricostruzione della sola lista. Nodi DOM del tab Tema all'apertura: ~460 totali (prima 1228).
- Altezza: header + tab fissi; il corpo ha altezza vincolata e scorre dentro per colonna (tab Tema: sinistra = carte, destra = controlli; hero, categorie e anteprima restano fissi). I tab si costruiscono alla prima apertura.
- Materiali (`data-material` sul root + token in `js/theme.js: applyMaterial`): `solid` (default: pannello alpha .97/.985, bordo accento pieno, ombre statiche a 2 strati, controlli con bordo netto, pillola con ombra di contatto, testo piu' contrastato, niente gloss) e `glass` (morbido, come prima). Cambia solo la finestra, non l'anteprima HUD. Un solo `backdrop-filter` (pannello radice) in entrambi.
- Scroll nativo (`-webkit-overflow-scrolling`), scrollbar sottile che compare solo in hover. Cambio tab = cross-fade + translate (mai width/height: il resize lo fa Lua via `resize_request`).
- `prefers-reduced-motion`: tutte le transizioni a ~0.
- Peso: ~116 KB non compresso (budget 250 KB).

## Struttura
```
ui/index.html            sorgente (file separati, CSP larga solo in dev)
ui/css/{base,components,tab-general,tab-keys,tab-theme}.css
ui/js/util.js            DOM helper sicuri (h(), svg()), sanificazione, throttle
ui/js/options.js         SCHEMA delle opzioni: chiavi, enum, default, icone, OPS del ponte
ui/js/state.js           normalize + reducer puro + store
ui/js/theme.js           token stile -> CSS custom properties (--bg1 --bg2 --fg --fg2 --accent --g1..g4 --glass-alpha --radius(--r-*) --font-ui --font-timer --density ...)
ui/js/icons.js           registro icone SVG (dati) + costruttore
ui/js/gw-bridge.js       adattatore ponte (nativo o mock) + window.gw
ui/js/actions.js         azioni utente: ottimistico + messaggio
ui/js/mock.js            finto host Lua
ui/js/components/*.js    segmented, switch, slider, chip, card-stile, tooltip (i), toast, section
ui/js/tabs/{general,keys,theme}.js
ui/js/preview.js         anteprima HUD viva
ui/js/app.js             montaggio, cambio tab, resize_request, interact/hb
ui/build-inline.mjs      build in un solo file
ui/tests/*.mjs           node:test (+ jsdom)
```

## Come aggiungere
- **Un'opzione**: 1) riga in `SCHEMA` (`options.js`: tipo, default, icona, scelte con icona); 2) icona in `icons.js` se manca (il test "ogni opzione ha un'icona" ti avvisa); 3) controllo nel tab (`tabs/theme.js`: `seg('chiave')`/`sl('chiave')` + `C.x.set(...)` in `update`); 4) lato Lua gestisci `set {key,value}` e aggiungi la chiave a `look`. Il test del contratto elenca le chiavi: aggiornalo.
- **Uno stile**: non serve toccare la UI. Basta che Lua lo includa in `state.styles` (+ `cats`). Eventuali PNG/GIF in `~/.config/groq-dictation/themes/<id>/` arrivano in `state.assets[<id>].icon` (usata nella carta e nel badge dell'anteprima) e `.spin` (riservata, non usata dall'anteprima).
- **Un'icona**: una voce in `icons.js` (`els`: `['p', d]`, `['c', cx, cy, r]`, `['r', x, y, w, h, rx]`...).

## Limiti noti
- L'anteprima HUD non riproduce i "pack" dei temi (forme del corpo, particelle, easter egg): solo vetro, badge, onda, timer, ombra/alone, angoli, densita', opacita' a riposo. Orientamento verticale e dimensione Minimal/Standard/Grande non cambiano l'anteprima.
- `waveColor:'auto'` e' valido (gradiente solo sugli stili multicolore); il selettore mostra Accento/Gradiente risolti.
