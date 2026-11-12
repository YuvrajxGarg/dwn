"""Builds the site's legal pages from the repository's PRIVACY.md and TERMS.md,
so the website and GitHub always say the same thing.

    python3 site/build.py      # writes site/privacy.html and site/terms.html

Handles the small Markdown subset those files use: headings, paragraphs,
bullet lists, links, <autolinks>, **bold**, _italic_ and `code`.
"""

import html
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
SITE = ROOT / "site"

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} — Dwn</title>
<meta name="description" content="{description}">
<meta name="theme-color" content="#0b0b0c">
<link rel="canonical" href="https://dwn.pxlvzn.in/{slug}">
<link rel="icon" type="image/png" href="/assets/icon.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@300..900&family=Inter+Tight:wght@100..900&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
<link rel="stylesheet" href="/assets/style.css?v=5">
</head>
<body>
<header class="nav scrolled">
  <div class="wrap">
    <a href="/" class="wordmark" aria-label="Dwn home">dwn<svg viewBox="0 0 36 56"><path d="M11.88 25.76V6.12a6.12 6.12 0 0 1 12.24 0v19.64H36L18 56 0 25.76z"/></svg></a>
    <div class="nav-right"><a class="btn btn-primary btn-sm" href="/#download">Download</a></div>
  </div>
</header>
<main class="doc">
  <div class="wrap">
    <a class="back" href="/"><svg viewBox="0 0 24 24"><path fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" d="M15 5l-7 7 7 7"/></svg>Back to Dwn</a>
    <article class="prose">
{body}
    </article>
  </div>
</main>
<footer>
  <div class="wrap">
    <a href="/" class="wordmark" aria-label="Dwn home">dwn<svg viewBox="0 0 36 56"><path d="M11.88 25.76V6.12a6.12 6.12 0 0 1 12.24 0v19.64H36L18 56 0 25.76z"/></svg></a>
    <nav aria-label="Footer"><a href="/privacy">Privacy</a><a href="/terms">Terms</a><a href="https://github.com/YuvrajxGarg/dwn">GitHub</a><a href="https://github.com/YuvrajxGarg/dwn/issues">Support</a></nav>
    <div class="fine"><span>© 2026 Yuvraj Garg. MIT licensed.</span></div>
  </div>
</footer>
</body>
</html>
"""

# Links between the documents point at the site's own pages.
LOCAL = {"PRIVACY.md": "/privacy", "TERMS.md": "/terms", "LICENSE": "https://github.com/YuvrajxGarg/dwn/blob/main/LICENSE"}


def inline(text: str) -> str:
    out, last = [], 0
    pattern = re.compile(r"`([^`]+)`|\[([^\]]+)\]\(([^)]+)\)|<(https?://[^>]+)>|\*\*([^*]+)\*\*|_([^_]+)_")
    for m in pattern.finditer(text):
        out.append(html.escape(text[last:m.start()]))
        code, label, href, auto, bold, em = m.groups()
        if code:
            out.append(f"<code>{html.escape(code)}</code>")
        elif label:
            href = LOCAL.get(href, href)
            out.append(f'<a href="{html.escape(href)}">{inline(label)}</a>')
        elif auto:
            out.append(f'<a href="{html.escape(auto)}">{html.escape(auto.replace("https://", ""))}</a>')
        elif bold:
            out.append(f"<strong>{inline(bold)}</strong>")
        else:
            out.append(f"<em>{inline(em)}</em>")
        last = m.end()
    out.append(html.escape(text[last:]))
    return "".join(out)


def convert(md: str) -> tuple[str, str]:
    lines, body, para, items, title = md.splitlines(), [], [], [], ""

    def flush():
        nonlocal para, items
        if para:
            body.append(f"<p>{inline(' '.join(para))}</p>")
            para = []
        if items:
            body.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>")
            items = []

    for line in lines:
        s = line.strip()
        if not s:
            flush()
        elif m := re.match(r"^(#{1,3})\s+(.*)", s):
            flush()
            level = len(m.group(1))
            if level == 1:
                title = m.group(2)
            body.append(f"<h{level}>{inline(m.group(2))}</h{level}>")
        elif s.startswith("- "):
            if para:
                flush()
            items.append(s[2:])
        elif items and line.startswith("  "):
            items[-1] += " " + s
        else:
            para.append(s)
    flush()
    return title, "\n".join("      " + b for b in body)


def main():
    pages = [("PRIVACY.md", "privacy", "How Dwn handles your data: everything stays on your computer."),
             ("TERMS.md", "terms", "The terms for using Dwn, the free downloader for Mac and Windows.")]
    for src, slug, desc in pages:
        title, body = convert((ROOT / src).read_text())
        short = title.replace("Dwn ", "").capitalize()
        (SITE / f"{slug}.html").write_text(PAGE.format(title=short, description=desc, slug=slug, body=body))
        print("wrote", f"site/{slug}.html")


if __name__ == "__main__":
    main()
