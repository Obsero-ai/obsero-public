#!/usr/bin/env python3
"""Rebuild the docs chrome.

Edit the prose directly in docs/*.html -- everything between the breadcrumb
<nav> and the "Was this page helpful?" block is the page body, and this script
leaves it alone. Then:

    python3 docs/build.py        # run from the repo root

It re-derives, from that prose, the things that would otherwise drift:

  * the left-nav tree, and the section list under the current page
  * the "On this page" table of contents (h2 and h3)
  * heading anchor links
  * assets/search-index.js -- the full text of every section, so the sidebar
    search finds terms that appear only in body copy
  * breadcrumbs, prev/next links, <title> and meta description

Running it twice in a row produces byte-identical files, so it is safe to run
any time you are unsure. Standard library only.
"""
import os, re, html, json

DOCS = "docs"
REPO = "https://github.com/Obsero-ai/obsero-public"
ISSUES = REPO + "/issues/new"

PAGES = [
    # file, title, group, description
    ("index.html",           "Overview",        "Get started",
     "Stream every CDN request to Obsero so AI agent traffic can be classified on request headers. Reference implementations for AWS CloudFront and Google Cloud."),
    ("quickstart.html",      "Quickstart",      "Get started",
     "One command: deploy a mock site, create the ingestion pipeline with your tracking ID, then tear it all down."),
    ("contract.html",        "The contract",    "Reference",
     "The URL you POST to and the payload Obsero expects. The only thing you have to get right."),
    ("aws.html",             "AWS",             "Deployment guides",
     "CloudFront to Firehose to a Lambda adapter. Choosing a log source, measured gotchas, and cost."),
    ("gcp.html",             "GCP",             "Deployment guides",
     "Load balancer request logs to Pub/Sub to a Cloud Run adapter. Named headers on the cheap path, permissions, and cost."),
    ("troubleshooting.html", "Troubleshooting", "Support",
     "Symptom, cause, fix for both clouds. Most reported bugs are documented behaviour of the underlying service."),
]

ICONS = {
    "note":    "M11 7h2v2h-2zm0 4h2v6h-2zm1-9C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8z",
    "caution": "M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z",
    "warning": "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z",
    "success": "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z",
}
KIND = {"warn": "caution", "bad": "warning", "good": "success", "": "note"}


def strip_tags(s):
    """Heading text, entities decoded, anchor links removed."""
    s = re.sub(r'<a class="anchor".*?</a>', "", s, flags=re.S)
    return html.unescape(re.sub(r"<[^>]+>", "", s)).strip()


def extract_body(path):
    s = open(path, encoding="utf-8").read()
    m = (re.search(r"<main>\n(.*?)\n    </main>", s, re.S)
         or re.search(r'      </nav>\n\n(.*?)\n\n      <div class="helpful">', s, re.S))
    if not m:
        raise SystemExit("could not find the article body in " + path)
    return m.group(1)


def to_asides(body):
    """<div class="note warn"><span class="label">X</span>…</div> -> devsite aside."""
    def repl(m):
        kind = KIND[m.group(1).strip()]
        inner = m.group(2)
        inner = re.sub(r'<span class="label">(.*?)</span>',
                       r'<p><b class="label">\1</b></p>', inner, flags=re.S)
        return ('<div class="aside %s" role="note">'
                '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="%s"/></svg>'
                '<div class="body">%s</div></div>' % (kind, ICONS[kind], inner))

    return re.sub(r'<div class="note ?([a-z]*)">(.*?)</div>\n', repl, body, flags=re.S)


def add_anchors(body):
    def repl(m):
        tag, hid, text = m.group(1), m.group(2), m.group(3)
        text = re.sub(r'<a class="anchor".*?</a>', "", text, flags=re.S)
        return ('<%s id="%s"><a class="anchor" href="#%s" aria-label="Link to this section">#</a>%s</%s>'
                % (tag, hid, hid, text, tag))
    return re.sub(r'<(h2|h3) id="([^"]+)">(.*?)</\1>', repl, body, flags=re.S)


def outline(body):
    """Ordered [(level, id, title)] from the h2/h3 in a body."""
    out = []
    for m in re.finditer(r'<(h2|h3) id="([^"]+)">(.*?)</\1>', body, re.S):
        out.append((int(m.group(1)[1]), m.group(2), strip_tags(m.group(3))))
    return out


# --- read every body once, so search and nav can see the whole site ---------

bodies, outlines = {}, {}
for f, *_ in PAGES:
    b = extract_body(os.path.join(DOCS, f))
    if f == "quickstart.html":          # money warning reads as an error, not a caution
        b = b.replace('<div class="note warn">\n  <span class="label">This costs real money</span>',
                      '<div class="note bad">\n  <span class="label">This costs real money</span>')
    bodies[f] = b
    outlines[f] = outline(b)

def section_text(body, start_id, end_id):
    """Plain text of one h2 section, for search matching only."""
    a = body.find('id="%s"' % start_id)
    b = body.find('id="%s"' % end_id) if end_id else len(body)
    chunk = body[a:b if b > a else len(body)]
    chunk = re.sub(r"<[^>]+>", " ", chunk)
    return re.sub(r"\s+", " ", html.unescape(chunk)).strip()


INDEX = []
for f, t, g, d in PAGES:
    h2s = [(i, ttl) for lvl, i, ttl in outlines[f] if lvl == 2]
    sections = []
    for n, (i, ttl) in enumerate(h2s):
        nxt = h2s[n + 1][0] if n + 1 < len(h2s) else None
        sections.append({"id": i, "title": ttl, "text": section_text(bodies[f], i, nxt)})
    head = bodies[f][:bodies[f].find('id="%s"' % h2s[0][0])] if h2s else bodies[f]
    head = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", head))).strip()
    INDEX.append({"href": f, "title": t, "group": g,
                  "text": d + " " + head, "sections": sections})

GROUPS = []
for f, t, g, d in PAGES:
    if not GROUPS or GROUPS[-1][0] != g:
        GROUPS.append((g, []))
    GROUPS[-1][1].append((f, t))


def sidenav(current):
    parts = ['<nav class="sidenav" id="sidenav" aria-label="Documentation">',
             '  <div class="navsearch">',
             '    <input id="navsearch-input" type="search" placeholder="Search docs" '
             'aria-label="Search the documentation" autocomplete="off" spellcheck="false">',
             '  </div>',
             '  <div id="navresults" class="navresults" hidden></div>',
             '  <div id="navtree">']
    for group, items in GROUPS:
        parts.append('    <div class="navgroup">%s</div>' % html.escape(group))
        parts.append("    <ul>")
        for f, t in items:
            cur = f == current
            parts.append('      <li><a class="navitem%s" href="%s"%s>%s</a>'
                         % (" current" if cur else "", f,
                            ' aria-current="page"' if cur else "", html.escape(t)))
            if cur:
                subs = [s for lvl, i, s in outlines[f] if lvl == 2]
                ids = [i for lvl, i, s in outlines[f] if lvl == 2]
                if subs:
                    parts.append('        <ul class="subnav">')
                    for i, s in zip(ids, subs):
                        parts.append('          <li><a href="#%s">%s</a></li>' % (i, html.escape(s)))
                    parts.append("        </ul>")
            parts.append("      </li>")
        parts.append("    </ul>")
    parts += ["  </div>", "</nav>"]
    return "\n".join(parts)


def toc(f):
    items = outlines[f]
    if not items:
        return ""
    lis = "\n".join(
        '          <li%s><a href="#%s">%s</a></li>'
        % (' class="sub"' if lvl == 3 else "", i, html.escape(t))
        for lvl, i, t in items
    )
    return ('      <aside class="toc">\n'
            '        <div class="toc-inner">\n'
            '          <h2>On this page</h2>\n'
            '          <ul>\n%s\n          </ul>\n'
            '        </div>\n'
            '      </aside>\n' % lis)


THUMB_UP = "M1 21h4V9H1v12zm22-11c0-1.1-.9-2-2-2h-6.31l.95-4.57.03-.32c0-.41-.17-.79-.44-1.06L14.17 1 7.59 7.59C7.22 7.95 7 8.45 7 9v10c0 1.1.9 2 2 2h9c.83 0 1.54-.5 1.84-1.22l3.02-7.05c.09-.23.14-.47.14-.73v-2z"
THUMB_DN = "M15 3H6c-.83 0-1.54.5-1.84 1.22l-3.02 7.05c-.09.23-.14.47-.14.73v2c0 1.1.9 2 2 2h6.31l-.95 4.57-.03.32c0 .41.17.79.44 1.06L9.83 23l6.59-6.59c.36-.36.58-.86.58-1.41V5c0-1.1-.9-2-2-2zm4 0v12h4V3h-4z"


def render(i):
    f, title, group, desc = PAGES[i]
    body = add_anchors(to_asides(bodies[f]))

    crumbs = ['<a href="index.html">Obsero ingestion</a>',
              '<span aria-hidden="true">&rsaquo;</span>',
              '<span>%s</span>' % html.escape(group)]
    if f != "index.html":
        crumbs += ['<span aria-hidden="true">&rsaquo;</span>',
                   '<span>%s</span>' % html.escape(title)]

    prev_l = next_l = '<span class="spacer"></span>'
    if i > 0:
        prev_l = '<a href="%s">&larr; %s</a>' % (PAGES[i - 1][0], html.escape(PAGES[i - 1][1]))
    if i < len(PAGES) - 1:
        next_l = '<a href="%s">%s &rarr;</a>' % (PAGES[i + 1][0], html.escape(PAGES[i + 1][1]))

    issue = "%s?title=%s" % (ISSUES, html.escape("Docs: " + title).replace(" ", "+"))

    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}&nbsp;&nbsp;|&nbsp;&nbsp;Obsero ingestion</title>
<meta name="description" content="{html.escape(desc)}">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Roboto:wght@300;400;500;700&amp;family=Roboto+Mono:wght@400;500&amp;display=swap" rel="stylesheet">
<link rel="stylesheet" href="assets/docs.css">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Ccircle cx='12' cy='12' r='10' fill='%231a73e8'/%3E%3Ccircle cx='12' cy='12' r='4' fill='white'/%3E%3C/svg%3E">
</head>
<body>
<a class="skip" href="#main">Skip to main content</a>

<header class="topbar">
  <button class="iconbtn" id="nav-toggle" type="button" aria-label="Open navigation" aria-expanded="false" aria-controls="sidenav">
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M3 18h18v-2H3v2zm0-5h18v-2H3v2zm0-7v2h18V6H3z"/></svg>
  </button>
  <a class="product" href="index.html"><b>Obsero ingestion</b> <span>Documentation</span></a>
  <div class="topbar-end">
    <a class="topbar-link" href="contract.html">The contract</a>
    <a class="topbar-link" href="{REPO}">GitHub</a>
  </div>
</header>

<div class="scrim" hidden-desktop></div>

<div class="shell">
{sidenav(f)}

  <div class="content">
    <article id="main">
      <nav class="breadcrumb" aria-label="Breadcrumb">
        {" ".join(crumbs)}
      </nav>

{body}

      <div class="helpful">
        <span>Was this page helpful?</span>
        <span class="thumbs">
          <a class="thumb" href="{issue}" aria-label="Yes, this page was helpful"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="{THUMB_UP}"/></svg></a>
          <a class="thumb" href="{issue}" aria-label="No, this page needs work"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="{THUMB_DN}"/></svg></a>
        </span>
      </div>

      <nav class="nextprev" aria-label="Pagination">
        {prev_l}
        {next_l}
      </nav>
    </article>

{toc(f)}
    <div class="pagefoot">
      <p>Reference implementations for streaming CDN request logs to Obsero &mdash; a starting point, not a product. Fork it and keep the parts that match your stack. <a href="{REPO}">Source on GitHub</a>.</p>
      <p>Measured numbers on these pages come from live deployments and are recorded in each cloud's <code>NOTES.md</code>. Confirm current cloud pricing before quoting any cost figure.</p>
    </div>
  </div>
</div>

<script src="assets/search-index.js" defer></script>
<script src="assets/docs.js" defer></script>
</body>
</html>
"""


with open(os.path.join(DOCS, "assets", "search-index.js"), "w", encoding="utf-8") as fh:
    fh.write("/* Generated. Section index for the sidebar search in docs.js. */\n")
    fh.write("window.__DOCS_INDEX__ = %s;\n" % json.dumps(INDEX, separators=(",", ":")))
print("wrote %-22s %6d bytes" % ("assets/search-index.js",
      os.path.getsize(os.path.join(DOCS, "assets", "search-index.js"))))

for i, (f, *_rest) in enumerate(PAGES):
    out = render(i)
    with open(os.path.join(DOCS, f), "w", encoding="utf-8") as fh:
        fh.write(out)
    print("wrote %-22s %6d bytes  %d sections" % (f, len(out), len(outlines[f])))
