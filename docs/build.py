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
  * links to GitHub: any <code>path</code> in the prose that names a file in
    the repo, plus the "Code on this page" box from SOURCES below
  * a Markdown copy of every page (docs/<page>.md), llms.txt and
    llms-full.txt -- the same docs in the shape coding agents read best

Running it twice in a row produces byte-identical files, so it is safe to run
any time you are unsure. Standard library only.
"""
import os, re, html, json, subprocess
from html.parser import HTMLParser

DOCS = "docs"
REPO = "https://github.com/Obsero-ai/obsero-public"
BRANCH = "main"
SITE = "https://obsero-ai.github.io/obsero-public/"
ISSUES = REPO + "/issues/new"

PAGES = [
    # file, title, group, description
    ("index.html",           "Overview",        "Get started",
     "Stream every CDN request to Obsero so AI agent traffic can be classified on request headers. Reference implementations for AWS CloudFront and Google Cloud."),
    ("quickstart.html",      "Quickstart",      "Get started",
     "Step by step: deploy a mock site, deploy the ingestion pipeline with your tracking ID, connect it to your CloudFront distributions, then tear it all down."),
    ("contract.html",        "The contract",    "Reference",
     "The URL you POST to and the payload Obsero expects. The only thing you have to get right."),
    ("aws.html",             "AWS",             "Deployment guides",
     "CloudFront to Firehose to a Lambda adapter. Choosing a log source, measured gotchas, and cost."),
    ("gcp.html",             "GCP",             "Deployment guides",
     "Load balancer request logs to Pub/Sub to a Cloud Run adapter. Named headers on the cheap path, permissions, and cost."),
    ("troubleshooting.html", "Troubleshooting", "Support",
     "Symptom, cause, fix for both clouds. Most reported bugs are documented behaviour of the underlying service."),
]

# The files each page is about, shown as "Code on this page" under the prose.
# A path that stops existing fails the build rather than shipping a dead link.
SOURCES = {
    "index.html": [
        ("README.md",       "the same overview, as it reads on GitHub"),
        ("AGENTS.md",       "instructions for a coding agent working in the repo"),
        ("obsero.mjs",      "the contract as code: build, validate and POST an event"),
    ],
    "quickstart.html": [
        ("setup.sh",        "the interactive installer this page walks through"),
        ("destroy.sh",      "teardown, and the sweep for leftovers"),
        ("aws/Makefile",    "every AWS task, one make target each"),
        ("gcp/Makefile",    "every GCP task, one make target each"),
    ],
    "contract.html": [
        ("obsero.mjs",                "buildEvent, validateEvent, sendEvent"),
        ("aws/test/adapter.test.mjs", "the AWS adapter checked against the contract"),
        ("gcp/test/adapter.test.mjs", "the GCP adapter checked against the contract"),
    ],
    "aws.html": [
        ("aws/ingestion/main.tf",                 "the pipeline: Firehose, log deliveries, backup bucket"),
        ("aws/ingestion/variables.tf",            "every module input, with its validation"),
        ("aws/ingestion/lambda/adapter/index.mjs", "the adapter Lambda"),
        ("aws/site/terraform/main.tf",            "the demo stack: mock site plus one module block"),
        ("aws/NOTES.md",                          "behaviour measured on live deployments"),
        ("aws/AGENTS.md",                         "the AWS playbook for coding agents"),
    ],
    "gcp.html": [
        ("gcp/ingestion/main.tf",           "the pipeline: sink, Pub/Sub, Cloud Run adapter"),
        ("gcp/ingestion/variables.tf",      "every module input, with its validation"),
        ("gcp/ingestion/adapter/index.mjs", "the Cloud Run adapter"),
        ("gcp/site/terraform/main.tf",      "the demo stack: mock site plus one module block"),
        ("gcp/PERMISSIONS.md",              "the IAM roles, and why Editor is not enough"),
        ("gcp/NOTES.md",                    "behaviour measured on live deployments"),
    ],
    "troubleshooting.html": [
        ("aws/NOTES.md",  "AWS behaviour measured on live deployments"),
        ("gcp/NOTES.md",  "GCP behaviour measured on live deployments"),
        ("destroy.sh",    "what --check and --sweep look for"),
    ],
}

# Relative paths in a cloud page's prose (ingestion/README.md) resolve against
# that cloud's directory first.
PATH_CONTEXT = {"aws.html": "aws/", "gcp.html": "gcp/"}

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
         or re.search(r'      </nav>\n\n(.*?)\n\n      <(?:section class="srcbox"|div class="helpful")', s, re.S))
    if not m:
        raise SystemExit("could not find the article body in " + path)
    # Source links are re-derived on every build, like heading anchors.
    return re.sub(r'<a class="src" href="[^"]*">(<code>.*?</code>)</a>', r"\1", m.group(1), flags=re.S)


# --- links to the code on GitHub ---------------------------------------------

def repo_paths():
    """Files and directories in the repo, as git sees them.

    Tracked plus untracked-but-not-ignored, so a new file links before it is
    committed and a gitignored one (terraform.tfvars) never does -- the result
    is the same on a dev machine and in CI.
    """
    try:
        out = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard"],
                             capture_output=True, text=True, check=True).stdout.split("\n")
    except (OSError, subprocess.CalledProcessError):
        raise SystemExit("docs/build.py needs git, run from the repo root")
    files = {f for f in out if f}
    # Generated below; list them now so the first build links them like the second.
    files |= {"docs/llms.txt", "docs/llms-full.txt"} | {"docs/" + f[:-5] + ".md" for f, *_ in PAGES}
    dirs = set()
    for f in files:
        parts = f.split("/")
        for i in range(1, len(parts)):
            dirs.add("/".join(parts[:i]))
    return files, dirs


FILES, DIRS = repo_paths()


def github_url(path):
    path = path.rstrip("/")
    kind = "tree" if path in DIRS else "blob"
    return "%s/%s/%s/%s" % (REPO, kind, BRANCH, path)


def resolve_path(text, page):
    """The repo path a <code> span names, or None if it is not one."""
    text = html.unescape(text).strip()
    if text.startswith("../"):
        text = text[3:]
    for cand in [PATH_CONTEXT.get(page, "") + text, text]:
        c = cand.rstrip("/")
        if c and (c in FILES or c in DIRS):
            return c
    return None


def link_paths(body, page):
    """<code>aws/NOTES.md</code> -> the same, linked to the file on GitHub.

    Leaves code blocks and code that is already inside a link alone.
    """
    def repl(m):
        path = resolve_path(m.group(1), page)
        if not path:
            return m.group(0)
        return '<a class="src" href="%s"><code>%s</code></a>' % (github_url(path), m.group(1))

    parts = re.split(r"(<pre>.*?</pre>|<a [^>]*>.*?</a>)", body, flags=re.S)
    return "".join(p if p.startswith(("<pre>", "<a ")) else re.sub(r"<code>([^<]+)</code>", repl, p)
                   for p in parts)


def srcbox(f):
    items = SOURCES.get(f, [])
    for path, _ in items:
        if path not in FILES:
            raise SystemExit("SOURCES[%r] names %s, which is not in the repo" % (f, path))
    lis = "\n".join('          <li><a href="%s"><code>%s</code></a> <span>%s</span></li>'
                    % (github_url(path), html.escape(path), html.escape(note)) for path, note in items)
    md = f[:-5] + ".md"
    return ('      <section class="srcbox" aria-label="Source on GitHub">\n'
            '        <p class="srcbox-title">Code on this page</p>\n'
            '        <ul>\n%s\n        </ul>\n'
            '        <p class="srcbox-links">'
            '<a href="%s/edit/%s/docs/%s">Edit this page on GitHub</a>'
            '<a href="%s">View as Markdown</a>'
            '<a href="llms.txt">llms.txt for agents</a></p>\n'
            '      </section>\n' % (lis, REPO, BRANCH, f, md))


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
    body = link_paths(add_anchors(to_asides(bodies[f])), f)

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
<link rel="alternate" type="text/markdown" href="{f[:-5]}.md" title="This page as Markdown">
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

{srcbox(f)}
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


# --- Markdown for agents ------------------------------------------------------
#
# Every page again as Markdown, plus llms.txt (an index) and llms-full.txt (all
# of it in one file). Generated from the same bodies, so it cannot drift from
# the HTML. A small tree walk, not a general converter: it knows exactly the
# markup these pages use, and anything else falls back to its text.

VOID = {"br", "hr", "img", "meta", "link", "input", "path"}
BLOCK = {"p", "pre", "h1", "h2", "h3", "h4", "ul", "ol", "table", "div", "figure", "blockquote", "section"}


class Node:
    def __init__(self, tag, attrs):
        self.tag, self.attrs, self.children = tag, dict(attrs), []

    def cls(self):
        return self.attrs.get("class") or ""


class TreeBuilder(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("root", [])
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        node = Node(tag, attrs)
        self.stack[-1].children.append(node)
        if tag not in VOID:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.stack[-1].children.append(Node(tag, attrs))

    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                return

    def handle_data(self, data):
        self.stack[-1].children.append(data)


def raw_text(n):
    if isinstance(n, str):
        return n
    if n.tag == "svg":
        return ""
    return "".join(raw_text(c) for c in n.children)


def md_href(href):
    m = re.match(r"^([a-z]+)\.html(#.*)?$", href)
    if m:
        return m.group(1) + ".md" + (m.group(2) or "")
    return href


def md_inline(nodes):
    out = []
    for n in nodes:
        if isinstance(n, str):
            out.append(re.sub(r"\s+", " ", n))
        elif n.tag in ("svg",) or n.cls() == "anchor":
            continue
        elif n.tag == "code":
            t = raw_text(n)
            fence = "``" if "`" in t else "`"
            out.append(fence + t + fence)
        elif n.tag == "a":
            out.append("[%s](%s)" % (md_inline(n.children).strip(), md_href(n.attrs.get("href", ""))))
        elif n.tag in ("strong", "b"):
            out.append("**%s**" % md_inline(n.children).strip())
        elif n.tag == "em":
            out.append("*%s*" % md_inline(n.children).strip())
        elif n.tag == "br":
            out.append("  \n")
        else:
            out.append(md_inline(n.children))
    return "".join(out)


def md_fence(text):
    text = text.strip("\n")
    fence = "````" if "```" in text else "```"
    return "%s\n%s\n%s" % (fence, text, fence)


def md_table(table):
    rows = []
    def walk(n):
        for c in n.children:
            if isinstance(c, Node):
                if c.tag == "tr":
                    rows.append([md_inline(td.children).strip().replace("|", "\\|")
                                 for td in c.children if isinstance(td, Node) and td.tag in ("td", "th")])
                else:
                    walk(c)
    walk(table)
    if not rows:
        return ""
    width = max(len(r) for r in rows)
    rows = [r + [""] * (width - len(r)) for r in rows]
    lines = ["| " + " | ".join(rows[0]) + " |", "|" + "---|" * width]
    lines += ["| " + " | ".join(r) + " |" for r in rows[1:]]
    return "\n".join(lines)


def md_list(n):
    items = [c for c in n.children if isinstance(c, Node) and c.tag == "li"]
    out = []
    for i, li in enumerate(items):
        marker = "%d. " % (i + 1) if n.tag == "ol" else "- "
        lines = md_blocks(li.children).split("\n")
        pad = " " * len(marker)
        out.append("\n".join([marker + lines[0]] + [(pad + l) if l else "" for l in lines[1:]]))
    return "\n".join(out)


def md_block(n):
    tag, cls = n.tag, n.cls()
    if tag in ("h1", "h2", "h3", "h4"):
        return "#" * int(tag[1]) + " " + md_inline(n.children).strip()
    if tag == "p":
        return md_inline(n.children).strip()
    if tag == "pre" or cls == "flow":
        return md_fence(raw_text(n))
    if tag in ("ul", "ol"):
        return md_list(n)
    if tag == "table":
        return md_table(n)
    if tag == "figure":
        cap = [c for c in n.children if isinstance(c, Node) and c.tag == "figcaption"]
        rest = [c for c in n.children if not (isinstance(c, Node) and c.tag == "figcaption")]
        head = "*%s*\n\n" % md_inline(cap[0].children).strip() if cap else ""
        return head + md_blocks(rest)
    if "aside" in cls.split():
        kind = cls.split()[1] if len(cls.split()) > 1 else "note"
        body = next((c for c in n.children if isinstance(c, Node) and c.cls() == "body"), n)
        label = ""
        kids = []
        for c in body.children:
            if isinstance(c, Node) and c.tag == "p" and any(
                    isinstance(x, Node) and x.cls() == "label" for x in c.children):
                label = raw_text(c).strip()
            else:
                kids.append(c)
        head = "**%s%s**" % (kind.capitalize(), ": " + label if label else "")
        inner = head + "\n\n" + md_blocks(kids)
        return "\n".join(("> " + l) if l else ">" for l in inner.split("\n"))
    if cls == "cards":
        out = []
        for a in n.children:
            if isinstance(a, Node) and a.tag == "a":
                h = next((c for c in a.children if isinstance(c, Node) and c.tag == "h3"), None)
                p = next((c for c in a.children if isinstance(c, Node) and c.tag == "p"), None)
                title = md_inline(h.children).strip().rstrip("→").strip() if h else ""
                out.append("- [%s](%s)%s" % (title, md_href(a.attrs.get("href", "")),
                                             " -- " + md_inline(p.children).strip() if p else ""))
        return "\n".join(out)
    return md_blocks(n.children)


def md_blocks(nodes):
    """Block-level Markdown for a run of nodes. Loose inline content between
    blocks (text directly inside an <li>) becomes its own paragraph."""
    out, run = [], []

    def flush():
        t = md_inline(run).strip()
        if t:
            out.append(t)
        run.clear()

    for n in nodes:
        if isinstance(n, Node) and n.tag in BLOCK:
            flush()
            b = md_block(n)
            if b.strip():
                out.append(b)
        elif isinstance(n, Node) and n.tag in ("svg",):
            continue
        else:
            run.append(n)
    flush()
    return "\n\n".join(out)


def to_markdown(f):
    tb = TreeBuilder()
    tb.feed(to_asides(bodies[f]))
    md = md_blocks(tb.root.children)
    items = SOURCES.get(f, [])
    if items:
        md += "\n\n## Code on this page\n\n" + "\n".join(
            "- [`%s`](%s) -- %s" % (p, github_url(p), note) for p, note in items)
    return ("<!-- Generated by docs/build.py from %s. Edit the HTML, not this file. -->\n\n%s\n"
            % (f, md.strip()))


def llms_txt(markdown):
    lines = ["# Obsero ingestion", "",
             "> " + PAGES[0][3], "",
             "Reference implementations that stream every CDN request (AWS CloudFront, Google Cloud load "
             "balancers) to Obsero so AI agent traffic can be classified on request headers. If you are a "
             "coding agent working in the repository, read AGENTS.md first: it has the contract, the setup "
             "order and the things that must not be \"cleaned up\".", "",
             "## Docs", ""]
    for f, t, g, d in PAGES:
        lines.append("- [%s](%s%s): %s" % (t, SITE, f[:-5] + ".md", d))
    lines += ["", "## Instructions for agents", "",
              "- [AGENTS.md](%s): the contract, setup order and rules for the whole repo" % github_url("AGENTS.md"),
              "- [aws/AGENTS.md](%s): AWS playbook, symptom -> cause -> fix" % github_url("aws/AGENTS.md"),
              "- [gcp/AGENTS.md](%s): GCP playbook, symptom -> cause -> fix" % github_url("gcp/AGENTS.md"),
              "", "## Code", ""]
    seen = []
    for f, *_ in PAGES:
        for p, note in SOURCES.get(f, []):
            if p not in seen:
                seen.append(p)
                lines.append("- [%s](%s): %s" % (p, github_url(p), note))
    lines += ["", "## Optional", "",
              "- [llms-full.txt](%sllms-full.txt): every page above in one file" % SITE]
    return "\n".join(lines) + "\n"


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

MARKDOWN = {}
for f, *_rest in PAGES:
    MARKDOWN[f] = to_markdown(f)
    name = f[:-5] + ".md"
    with open(os.path.join(DOCS, name), "w", encoding="utf-8") as fh:
        fh.write(MARKDOWN[f])
    print("wrote %-22s %6d bytes" % (name, len(MARKDOWN[f])))

for name, text in (("llms.txt", llms_txt(MARKDOWN)),
                   ("llms-full.txt", "\n\n---\n\n".join(MARKDOWN[f] for f, *_ in PAGES))):
    with open(os.path.join(DOCS, name), "w", encoding="utf-8") as fh:
        fh.write(text)
    print("wrote %-22s %6d bytes" % (name, len(text)))
