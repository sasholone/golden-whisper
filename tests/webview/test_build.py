#!/usr/bin/env python3
"""Test del build (build.py): round-trip, idempotenza, bracket lunghi, compilazione Lua, limite locali, marcatori mancanti.
Uso:  LUAPY=<python con lupa> test_build.py   (lavora su una COPIA temporanea del repo: non tocca src/ ne' ui/)."""
import os, shutil, subprocess, sys, tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
nfail = 0
ntest = 0


def chk(name, cond, why=""):
    global nfail, ntest
    ntest += 1
    if not cond:
        nfail += 1
    print("%-70s %s" % (name, "PASS" if cond else "FAIL " + str(why)))


def run(tmp, *args):
    return subprocess.run([sys.executable, os.path.join(tmp, "build.py")] + list(args), capture_output=True, text=True)


def mk():
    tmp = tempfile.mkdtemp(prefix="gwbuild_")
    os.makedirs(os.path.join(tmp, "src"))
    shutil.copy(os.path.join(ROOT, "build.py"), tmp)
    shutil.copytree(os.path.join(ROOT, "ui-stub"), os.path.join(tmp, "ui-stub"))
    shutil.copy(os.path.join(ROOT, "src", "groq_dictation.lua"), os.path.join(tmp, "src"))
    return tmp


def src_of(tmp):
    return open(os.path.join(tmp, "src", "groq_dictation.lua"), encoding="utf-8").read()


def block_html(text):
    """Esegue il blocco in Lua e ritorna ICON.webHtml (verifica reale del livello di bracket)."""
    from lupa import LuaRuntime
    a, b = text.index("-- <<WEB_HTML_BEGIN>>"), text.index("-- <<WEB_HTML_END>>")
    lua = LuaRuntime()
    return lua.execute("ICON = {}\n" + text[a:b] + "\nreturn ICON.webHtml")


def main():
    tmp = mk()
    try:
        orig = src_of(tmp)
        # 1. build dalla pagina segnaposto, idempotente
        r = run(tmp); chk("T1 build ok (ui-stub)", r.returncode == 0, r.stderr + r.stdout)
        chk("T1 stampa la dimensione", "KB" in r.stdout, r.stdout)
        s1 = src_of(tmp)
        r = run(tmp); chk("T2 idempotente: seconda esecuzione 'invariato'", "[invariato]" in r.stdout and src_of(tmp) == s1, r.stdout)
        r = run(tmp, "--check"); chk("T3 --check ok dopo il build", r.returncode == 0, r.stdout)
        # 2. modifica la pagina (ui/dist): --check fallisce, build riallinea
        os.makedirs(os.path.join(tmp, "ui", "dist"))
        page = os.path.join(tmp, "ui", "dist", "settings.html")
        open(page, "w", encoding="utf-8").write("<!doctype html><html><head><title>x</title></head><body>UI nuova</body></html>\n")
        r = run(tmp, "--check"); chk("T4 --check FALLISCE se ui/dist e' diverso dal blocco", r.returncode == 1, r.stdout)
        r = run(tmp); chk("T5 build prende ui/dist (precede ui-stub)", r.returncode == 0 and "ui/dist" in r.stdout, r.stdout)
        r = run(tmp, "--check"); chk("T6 --check ok dopo il nuovo build", r.returncode == 0, r.stdout)
        open(page, "a", encoding="utf-8").write("<!-- modifica -->\n")
        r = run(tmp, "--check"); chk("T7 round-trip: modifica ui -> check fallisce", r.returncode == 1, r.stdout)
        r = run(tmp); r2 = run(tmp, "--check"); chk("T8 round-trip: build -> check ok", r.returncode == 0 and r2.returncode == 0)
        # 3. il build riscrive SOLO il blocco
        s2 = src_of(tmp)
        a1, b1 = s2.index("-- <<WEB_HTML_BEGIN>>"), s2.index("-- <<WEB_HTML_END>>") + len("-- <<WEB_HTML_END>>")
        a0, b0 = orig.index("-- <<WEB_HTML_BEGIN>>"), orig.index("-- <<WEB_HTML_END>>") + len("-- <<WEB_HTML_END>>")
        chk("T9 fuori dai marcatori il file e' identico", s2[:a1] == orig[:a0] and s2[b1:] == orig[b0:])
        # 4. contenuti ostici: chiusure di bracket lunghi, CRLF, UTF-8, backslash, byte NUL
        nasty = "<!doctype html><html><head></head><body>a]]b ]=]c ]==]d ]===]e ]====]f \\n \\\\ è  \U0001F3A4 [[x]] --[==[ \r\nriga2\r\n</body></html>"
        open(page, "w", encoding="utf-8", newline="").write(nasty)
        r = run(tmp); chk("T10 contenuto con ]]/]=]/]==]/]===]/CRLF/unicode: build ok", r.returncode == 0, r.stdout + r.stderr)
        try:
            got = block_html(src_of(tmp))
            want = nasty.replace("\r\n", "\n") + "\n"
            chk("T11 Lua restituisce ESATTAMENTE la pagina (livello di bracket sicuro)", got == want, repr(got)[:120])
        except ImportError:
            chk("T11 (lupa assente: salto)", True)
        chk("T12 il livello scelto e' >= 5 per ]====]", "[=====[" in src_of(tmp) or "[======[" in src_of(tmp) or "[=======[" in src_of(tmp), "")
        # 5. il Lua compila ed ha <= 199 locali
        try:
            from lupa import LuaRuntime
            lua = LuaRuntime()
            f = lua.eval("function(code) local fn, e = load(code, '=x'); return fn ~= nil, e end")
            ok, e = f(src_of(tmp)); chk("T13 il Lua risultante compila (load)", ok, e)
            ok, e = f("local " + ",".join("__x%d" % i for i in range(1)) + "\n" + src_of(tmp)); chk("T14 almeno 1 local libero (<=199 usati)", ok, e)
        except ImportError:
            chk("T13 (lupa assente: salto)", True)
        # 6. marcatori mancanti -> errore, file intatto
        s3 = src_of(tmp)
        open(os.path.join(tmp, "src", "groq_dictation.lua"), "w", encoding="utf-8").write(s3.replace("-- <<WEB_HTML_END>>", ""))
        before = src_of(tmp)
        r = run(tmp); chk("T15 marcatori mancanti: errore", r.returncode != 0, r.stdout)
        chk("T16 marcatori mancanti: file non toccato", src_of(tmp) == before)
        r = run(tmp, "--check"); chk("T17 marcatori mancanti: --check errore", r.returncode != 0)
        open(os.path.join(tmp, "src", "groq_dictation.lua"), "w", encoding="utf-8").write(s3)
        # 7. pagina enorme: avviso oltre 600 KB
        open(page, "w", encoding="utf-8").write("<!doctype html><html><head></head><body>" + "x" * (700 * 1024) + "</body></html>")
        r = run(tmp); chk("T18 oltre 600 KB: avviso", "ATTENZIONE" in r.stdout, r.stdout)
        # 8. nessuna pagina: errore chiaro
        os.remove(page); shutil.rmtree(os.path.join(tmp, "ui-stub"))
        r = run(tmp); chk("T19 nessuna pagina: errore", r.returncode != 0, r.stdout)
        # 9. la copia reale in repo e' allineata alla sua pagina sorgente
        r = subprocess.run([sys.executable, os.path.join(ROOT, "build.py"), "--check"], capture_output=True, text=True)
        chk("T20 repo reale: --check", r.returncode == 0, r.stdout)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("TOTALE build: test %d, falliti %d" % (ntest, nfail))
    sys.exit(1 if nfail else 0)


main()
