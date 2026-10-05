#!/usr/bin/env python3
"""Incolla la pagina delle impostazioni (ui/dist/settings.html, altrimenti ui-stub/settings.html)
dentro src/groq_dictation.lua, tra i marcatori -- <<WEB_HTML_BEGIN>> e -- <<WEB_HTML_END>>.
L'auto-update scarica SOLO quel file: la pagina deve stare dentro.

  python3 build.py           riscrive SOLO il blocco (idempotente), stampa dimensioni
  python3 build.py --check   exit 1 se il blocco in src non coincide con la pagina sorgente
"""
import os, re, sys

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "src", "groq_dictation.lua")
PAGES = [os.path.join(ROOT, "ui", "dist", "settings.html"),
         # sorgente alternativa per il build locale finche' i rami non sono uniti (worktree del frontend, sola lettura)
         os.path.normpath(os.path.join(ROOT, "..", "golden-whisper-webview-ui", "ui", "dist", "settings.html")),
         os.path.join(ROOT, "ui-stub", "settings.html")]
BEGIN, END = "-- <<WEB_HTML_BEGIN>>", "-- <<WEB_HTML_END>>"
LIMIT = 600 * 1024


def rel(p):
    r = os.path.relpath(p, ROOT)
    return r if not r.startswith("..") else p


def page_path():
    for p in PAGES:
        if os.path.isfile(p):
            return p
    sys.exit("nessuna pagina: manca ui/dist/settings.html (e le alternative)")


def block(html):
    # livello di bracket lungo: il piu' piccolo (>=2) la cui chiusura non compare nel contenuto
    lvl = 2
    while ("]" + "=" * lvl + "]") in html or html.endswith("]" + "=" * lvl):
        lvl += 1
    eq = "=" * lvl
    if "\x00" in html:
        sys.exit("la pagina contiene byte NUL")
    # una nuova riga dopo l'apertura viene ignorata da Lua; una prima del chiusura garantisce la separazione
    body = html if html.endswith("\n") else html + "\n"
    return (BEGIN + "\ndo\n  ICON.webHtml = [" + eq + "[\n" + body + "]" + eq + "]\nend\n" + END)


def split(text):
    a = text.find(BEGIN)
    b = text.find(END)
    if a < 0 or b < 0 or b < a:
        sys.exit("marcatori %s / %s non trovati in src/groq_dictation.lua" % (BEGIN, END))
    return text[:a], text[a:b + len(END)], text[b + len(END):]


def main():
    check = "--check" in sys.argv[1:]
    p = page_path()
    html = open(p, "rb").read().decode("utf-8")
    html = html.replace("\r\n", "\n")
    want = block(html)
    text = open(SRC, "rb").read().decode("utf-8")
    pre, cur, post = split(text)
    if check:
        if cur != want:
            print("DIVERSO: il blocco in src non coincide con %s (lancia build.py)" % rel(p))
            sys.exit(1)
        print("ok: il blocco coincide con %s" % rel(p))
        return
    out = pre + want + post
    if out != text:
        tmp = SRC + ".tmp"
        open(tmp, "wb").write(out.encode("utf-8"))
        os.replace(tmp, SRC)
    sz = len(out.encode("utf-8"))
    print("pagina: %s (%d byte) | src/groq_dictation.lua: %d byte (%.1f KB)%s" % (
        rel(p), len(html.encode("utf-8")), sz, sz / 1024,
        "  [riscritto]" if out != text else "  [invariato]"))
    if sz > LIMIT:
        print("ATTENZIONE: il file supera %d KB" % (LIMIT // 1024))


if __name__ == "__main__":
    main()
