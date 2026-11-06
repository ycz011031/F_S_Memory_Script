#!/usr/bin/env python3
"""Build one artifact page per archive file in docs/archive/.

    py -3 docs/archive/mkpage.py <out-dir> [name.md ...]

Each page embeds its markdown verbatim (HTML-escaped inside a <textarea>,
so a page read back as raw HTML still holds the text) and renders it in the
browser with marked; without marked it shows the plain text. Publish each
<out-dir>/<stem>.html to the artifact URL in HANDOFF.md's "Archive" table.
"""
import html, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))

TITLES = {
    "pre-pips.md": "Pre-PIPS Testbed Archive",
    "pips-0a02-0a05.md": "PIPS 0x0A02–0x0A05 Archive",
    "pips-0a06.md": "PIPS 0x0A06 Archive",
    "pips-0a07.md": "PIPS 0x0A07 Archive",
    "pips-alias-1.md": "PIPS Alias Campaign 1 Archive",
    "handoff-log.md": "Handoff Log Archive",
    "claude-md-state-log.md": "Claude Session State Log",
}

PAGE = """<title>{title}</title>
<meta name="claude:viewport-fit-sides" content="cover">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;600&family=IBM+Plex+Sans+Condensed:wght@600&family=IBM+Plex+Mono:wght@400;500&display=swap">
<style>
/* Layout: a contents rail beside one reading column; tables and code scroll in their own boxes. */
:root {{
  --bg: #f6f7f5; --panel: #ffffff; --fg: #1d2420; --muted: #5b6660;
  --rule: #d7ddd8; --accent: #2f6b4f; --code-bg: #eef1ee; --mark: #e6efe9;
  --f-display: "IBM Plex Sans Condensed", "Arial Narrow", sans-serif;
  --f-body: "IBM Plex Sans", system-ui, -apple-system, "Segoe UI", sans-serif;
  --f-mono: "IBM Plex Mono", ui-monospace, "Cascadia Mono", Consolas, monospace;
}}
@media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{
  --bg: #121614; --panel: #181d1a; --fg: #dde3df; --muted: #9aa69f;
  --rule: #2c3530; --accent: #7cc4a0; --code-bg: #1f2622; --mark: #1d2b24; color-scheme: dark; }} }}
:root[data-theme="dark"] {{
  --bg: #121614; --panel: #181d1a; --fg: #dde3df; --muted: #9aa69f;
  --rule: #2c3530; --accent: #7cc4a0; --code-bg: #1f2622; --mark: #1d2b24; color-scheme: dark; }}
body {{ background: var(--bg); color: var(--fg); font: 15px/1.6 var(--f-body);
  padding-left: max(16px, env(safe-area-inset-left, 0px));
  padding-right: max(16px, env(safe-area-inset-right, 0px)); padding-block: 24px 64px; }}
.wrap {{ display: grid; grid-template-columns: minmax(0, 15rem) minmax(0, 52rem); gap: 40px;
  justify-content: center; }}
nav {{ position: sticky; top: env(safe-area-inset-top, 0px); align-self: start; max-height: 100vh;
  overflow-y: auto; padding-block: 8px; font-size: 13px; min-width: 0; }}
nav .eyebrow {{ font: 600 11px/1.4 var(--f-body); letter-spacing: .08em; text-transform: uppercase;
  color: var(--muted); margin-bottom: 8px; }}
nav a {{ display: block; color: var(--muted); text-decoration: none; padding: 2px 0; overflow-wrap: anywhere; }}
nav a.l3 {{ padding-left: 12px; }}
nav a:hover, nav a:focus-visible {{ color: var(--accent); }}
nav summary {{ cursor: pointer; }}
@media (max-width: 900px) {{ .wrap {{ grid-template-columns: minmax(0, 1fr); gap: 16px; }} nav {{ position: static; max-height: none; }} }}
main {{ min-width: 0; }}
.eyebrow-top {{ font: 600 11px/1.4 var(--f-body); letter-spacing: .08em; text-transform: uppercase;
  color: var(--accent); }}
h1, h2, h3, h4 {{ font-family: var(--f-display); font-weight: 600; text-wrap: balance; line-height: 1.25; }}
h1 {{ font-size: 2rem; margin: .2em 0 .6em; }}
h2 {{ font-size: 1.45rem; margin: 2.2em 0 .5em; padding-top: .6em; border-top: 1px solid var(--rule); }}
h3 {{ font-size: 1.15rem; margin: 1.8em 0 .4em; }}
h4 {{ font-size: 1rem; margin: 1.4em 0 .3em; }}
p, li {{ max-width: 72ch; }}
a {{ color: var(--accent); overflow-wrap: anywhere; }}
code {{ font: 500 .86em var(--f-mono); background: var(--code-bg); padding: .08em .3em; border-radius: 3px;
  overflow-wrap: anywhere; }}
pre {{ background: var(--code-bg); padding: 12px 14px; border-radius: 4px; overflow-x: auto; }}
pre code {{ background: none; padding: 0; font-size: 13px; overflow-wrap: normal; }}
blockquote {{ margin: 2em 0 1em; padding: 6px 14px; background: var(--mark); border-left: 3px solid var(--accent);
  color: var(--fg); }}
blockquote p {{ margin: .3em 0; }}
hr {{ border: 0; border-top: 1px solid var(--rule); margin: 2em 0; }}
.tw {{ overflow-x: auto; margin: 1em 0; }}
table {{ border-collapse: collapse; font-size: 13px; font-variant-numeric: tabular-nums; }}
th, td {{ border: 1px solid var(--rule); padding: 4px 8px; vertical-align: top; text-align: left; }}
th {{ background: var(--code-bg); font-weight: 600; }}
td code, th code {{ overflow-wrap: normal; }}
#md {{ display: none; }}
.plain {{ white-space: pre-wrap; font: 13px/1.5 var(--f-mono); }}
</style>
<div class="wrap">
  <nav aria-label="Contents"><details id="tocbox"><summary class="eyebrow">Contents</summary><div id="toc"></div></details></nav>
  <main>
    <div class="eyebrow-top">HANDOFF archive · verbatim · moved 2026-11-06</div>
    <div id="out"><p>Loading…</p></div>
  </main>
</div>
<textarea id="md" readonly aria-hidden="true">{md}</textarea>
<script src="https://cdnjs.cloudflare.com/ajax/libs/marked/12.0.2/marked.min.js"></script>
<script>
(function () {{
  var src = document.getElementById('md').value;
  var out = document.getElementById('out');
  function esc(s) {{ return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }}
  if (!window.marked) {{ out.innerHTML = '<div class="plain">' + esc(src) + '</div>'; return; }}
  marked.use({{ gfm: true, renderer: {{
    html: function (t) {{ return esc(typeof t === 'string' ? t : (t.raw || t.text || '')); }}
  }} }});
  out.innerHTML = marked.parse(src);
  out.querySelectorAll('table').forEach(function (t) {{
    var w = document.createElement('div'); w.className = 'tw'; t.parentNode.insertBefore(w, t); w.appendChild(t);
  }});
  if (window.matchMedia && matchMedia('(min-width: 901px)').matches) document.getElementById('tocbox').open = true;
  var seen = {{}}, toc = document.getElementById('toc');
  out.querySelectorAll('h1, h2, h3').forEach(function (h) {{
    var id = h.textContent.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 's';
    if (seen[id]) {{ id += '-' + (++seen[id]); }} else {{ seen[id] = 1; }}
    h.id = id;
    if (h.tagName === 'H1') return;
    var a = document.createElement('a'); a.href = '#' + id; a.textContent = h.textContent;
    if (h.tagName === 'H3') a.className = 'l3';
    toc.appendChild(a);
  }});
}})();
</script>
"""

def build(name, outdir):
    with open(os.path.join(HERE, name), encoding="utf-8") as f:
        md = f.read()
    body = PAGE.format(title=TITLES[name], md=html.escape(md, quote=False))
    out = os.path.join(outdir, name[:-3] + ".html")
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(body)
    print(f"[mkpage] {name} -> {out} ({len(body.encode()) // 1024} KiB)", flush=True)

def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)
    names = sys.argv[2:] or sorted(TITLES)
    for i, n in enumerate(names, 1):
        print(f"[mkpage] {i}/{len(names)}", flush=True)
        build(n, outdir)

if __name__ == "__main__":
    main()
