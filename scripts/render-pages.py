#!/usr/bin/env python3
"""Render the two public pages from their markdown, so they cannot drift.

`docs/privacy-policy.md` and `docs/support.md` are the sources — they are written from
the code and reviewed there. These render them to `docs/web/*.html`, ready to drop on any
static host, so publishing is a copy rather than a toolchain. The owner-only note at the
top of each source (the blockquote) is stripped: it is instructions for publishing, not
something a reader or a reviewer should see.

Run after editing either source:  python3 scripts/render-pages.py
"""
import html, pathlib, re

STYLE = """
  :root { color-scheme: light dark; --ink: #16181d; --muted: #5b6270; --bg: #fff; --rule: #e3e6ec; }
  @media (prefers-color-scheme: dark) {
    :root { --ink: #e9ecf2; --muted: #9aa3b2; --bg: #121419; --rule: #262a33; }
  }
  * { box-sizing: border-box; }
  body { margin: 0; padding: 48px 20px 96px; background: var(--bg); color: var(--ink);
         font: 17px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
  main { max-width: 42rem; margin: 0 auto; }
  h1 { font-size: 2rem; line-height: 1.2; letter-spacing: -0.02em; margin: 0 0 .5rem; }
  h2 { font-size: 1.15rem; margin: 2.5rem 0 .75rem; padding-top: 1.25rem;
       border-top: 1px solid var(--rule); letter-spacing: -0.01em; }
  em { color: var(--muted); font-style: normal; }
  ul { padding-left: 1.15rem; } li { margin: .5rem 0; }
  a { color: inherit; text-decoration-color: var(--muted); text-underline-offset: 3px; }
  code { font-size: .92em; }
"""


def inline(text):
    text = html.escape(text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"\*([^*]+)\*", r"<em>\1</em>", text)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", text)


def render(source, title, destination):
    md = re.sub(r"^> .*$\n?", "", pathlib.Path(source).read_text(), flags=re.M)
    out, buf, in_ul = [], [], False

    def flush():
        if buf:
            out.append("<p>" + inline(" ".join(buf)) + "</p>")
            buf.clear()

    for raw in md.split("\n"):
        line = raw.rstrip()
        if line.startswith("## "):
            flush()
            if in_ul:
                out.append("</ul>")
                in_ul = False
            out.append("<h2>" + inline(line[3:]) + "</h2>")
        elif line.startswith("# "):
            flush()
            out.append("<h1>" + inline(line[2:]) + "</h1>")
        elif line.startswith("- "):
            flush()
            if not in_ul:
                out.append("<ul>")
                in_ul = True
            out.append("<li>" + inline(line[2:]) + "</li>")
        elif not line.strip():
            flush()
            if in_ul:
                out.append("</ul>")
                in_ul = False
        elif in_ul:
            out[-1] = out[-1][:-5] + " " + inline(line.strip()) + "</li>"
        else:
            buf.append(line.strip())
    flush()
    if in_ul:
        out.append("</ul>")

    page = (
        '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        f"<title>{html.escape(title)}</title>\n<style>{STYLE}</style>\n</head>\n"
        "<body><main>\n" + "\n".join(out) + "\n</main></body>\n</html>\n"
    )
    pathlib.Path(destination).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(destination).write_text(page)
    print(f"{destination}  ({len(page)} bytes)")
    if "CONTACT EMAIL" in page:
        print("   ^ still has the CONTACT EMAIL placeholder — fill it before publishing.")


root = pathlib.Path(__file__).resolve().parent.parent
render(root / "docs/privacy-policy.md", "Privacy Policy — Ezra", root / "docs/web/privacy.html")
render(root / "docs/support.md", "Ezra — Help", root / "docs/web/support.html")
