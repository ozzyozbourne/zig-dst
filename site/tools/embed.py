#!/usr/bin/env python3
"""Copies captured output into the pages.

Every <script type="text/plain" id="..." data-src="data/NN/file.txt"></script> in site/*.html gets
its body replaced with the current contents of that file, so pages work when opened directly
(file://) without fetch(). Run by capture.sh; safe to run on its own.
"""
import html, pathlib, re, sys

site = pathlib.Path(__file__).resolve().parent.parent
pat = re.compile(r'(<script type="text/plain"[^>]*data-src="([^"]+)"[^>]*>)(.*?)(</script>)', re.S)
missing = 0
for page in sorted(site.glob("*.html")):
    src = page.read_text()
    def sub(m):
        global missing
        f = site / m.group(2)
        if not f.exists():
            print(f"{page.name}: missing {m.group(2)}", file=sys.stderr); missing += 1
            return m.group(0)
        body = f.read_text().replace("</script", "<\\/script")
        return m.group(1) + "\n" + body + m.group(4)
    out = pat.sub(sub, src)
    if out != src:
        page.write_text(out); print(f"embedded data into {page.name}")
sys.exit(1 if missing else 0)
