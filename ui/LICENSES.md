# Licenze

## Icone (`js/icons.js`)
- Set di 65 icone SVG inline, griglia 24x24, tratto uniforme 1.5, estremi e giunti arrotondati, colore `currentColor`.
- **Disegnate per questo progetto** (geometrie originali scritte a mano come dati nel registro `defs`). Stile e convenzioni sono quelli del genere "line icons" (Lucide / Phosphor Light), ma **nessun path e' stato copiato da libreria** (in questa sessione non c'era rete per scaricarle).
- Per correttezza: Lucide (https://lucide.dev) e' ISC e Phosphor (https://phosphoricons.com) e' MIT. Alcune forme elementari (check, x, plus, chevron, info, play) coincidono per necessita' geometrica con quelle di Lucide: in caso di dubbio vale la licenza piu' permissiva, **ISC (Lucide Contributors, Cole Bemis 2013-2022)**. Il testo ISC e' riportato sotto per chi volesse sostituire il set con quello originale.
- Eccezioni di spessore dichiarate nel registro: `wvBars` 3, `wvThin` 1.3, `pause` 2.2.
- Le icone "Aa" e "09" (font UI e timer) non sono path: sono `<text>` nel font di sistema vero (SF / SF Rounded / SF Mono via keyword `-apple-system`, `ui-rounded`, `ui-monospace`).

ISC License — Copyright (c) for portions of Lucide are held by Cole Bemis 2013-2022 as part of Feather (MIT). All other copyright (c) for Lucide are held by Lucide Contributors 2022. Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted, provided that the above copyright notice and this permission notice appear in all copies. THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

## Font
Nessun font web e nessun file font: solo i font di sistema macOS tramite keyword generiche.

## Librerie
Nessuna libreria a runtime (vanilla ES2020, zero dipendenze, zero rete). Solo per i test, in `ui/node_modules` (ignorata da git): `jsdom` (MIT).
