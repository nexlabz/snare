#!/usr/bin/env python3
"""assemble.py — build the site from the fragments in src/.

Three kinds of page, because content is not all read the same way:

  home   short. The problem, what snare does, how to install, where to go next.
  long   a long read: a header with the reading time, a rail beside the text
         listing every section with its own reading time and a progress bar,
         so the reader knows what they are committing to before they start.
  page   an ordinary page: changelog, report a bug, install, community.

Each src/<name>.html carries its metadata in leading comments
(<!--#title: ...-->, <!--#desc: ...-->) and an optional page header
(<div class="page-head">: eyebrow, h1, lede) that becomes the page's header.

Usage: assemble.py SITE REPO VERSION   (run from docs/)
"""
import hashlib
import html
import math
import os
import re
import subprocess
import sys

SITE, REPO, VERSION = sys.argv[1], sys.argv[2], sys.argv[3]

# out file, kind, sources, short name (nav, cards), one-line pitch for the home cards
PAGES = [
    ("index.html",     "home", ["home.html"],                "Home", ""),
    ("attack.html",    "long", ["attack.html"],              "The attack",
     "How it gets in, why the file looks clean, and where it phones home."),
    ("check.html",     "long", ["check.html"],               "Check",
     "Seven checks to paste into a terminal. Nothing to install."),
    ("infected.html",  "long", ["infected.html"],            "If infected",
     "The four steps, in the order that matters."),
    ("docs.html",      "long", ["docs.html", "commands.html"], "Docs",
     "How snare works, and every command it has."),
    ("install.html",   "page", ["install.html"],             "Install",
     "macOS, Linux, Windows and WSL."),
    ("changelog.html", "page", ["changelog.html"],           "Changelog",
     "Every release, and what was broken before it."),
    ("security.html",  "page", ["security.html"],            "Report a bug",
     "A false clean is the bug we most want to hear about."),
    ("community.html", "page", ["community.html"],           "Community",
     "Field reports, credits and the open questions."),
]
NAV = ["attack.html", "check.html", "infected.html", "docs.html", "changelog.html", "community.html", "security.html"]
# old URLs that no longer have a page of their own
STUBS = {"commands.html": "docs.html#reference"}
WPM = 220

e = html.escape


def gen(mode):
    out = subprocess.run(["python3", "changelog-gen.py", "--" + mode,
                          "../CHANGELOG.md", "../releases"], capture_output=True, text=True)
    if out.returncode:
        sys.exit("changelog-gen --%s failed: %s" % (mode, out.stderr))
    return out.stdout


def asset(path):
    """Content-hashed URL, so a new deploy never serves last week's stylesheet."""
    return "%s?v=%s" % (path, hashlib.sha1(open(path, "rb").read()).hexdigest()[:8])


def meta(src, key):
    m = re.search(r"^<!--#%s: (.*)-->$" % key, src, re.M)
    return m.group(1) if m else ""


def words(s):
    # what a reader reads: not code to paste, not tables, not folded releases
    s = re.sub(r"<pre.*?</pre>|<table.*?</table>|<details class=\"older\">.*?</details>", " ", s, flags=re.S)
    return len(re.sub(r"<script.*?</script>|<[^>]+>", " ", s, flags=re.S).split())


def mins(n):
    return max(1, math.ceil(n / WPM))


def relink(s):
    def sub(m):
        page, frag = m.group(1) + ".html", m.group(2) or ""
        if page in STUBS:
            target = STUBS[page]
            return 'href="%s"' % (target.split("#")[0] + frag if frag else target)
        if page == "index.html":
            return 'href="./%s"' % frag
        return m.group(0)
    return re.sub(r'href="([a-z]+)\.html(#[\w-]+)?"', sub, s)


def expand(body):
    def one(line):
        for marker, mode in (("releases", "releases"), ("reltoc", "toc"),
                             ("reljump", "jump"), ("latest", "latest")):
            if "<!--#%s-->" % marker in line:
                return gen(mode)
        return line
    return "".join(one(l) for l in body.splitlines(True))


def load(fname, kind):
    raw = open(os.path.join("src", fname), encoding="utf-8").read()
    body = re.sub(r"^<!--#[a-z]+:.*-->\n", "", raw, flags=re.M)
    if kind == "long":
        # per-page sidebars and chip bars are replaced by the rail
        body = re.sub(r'<aside class="toc".*?</aside>\n?', "", body, flags=re.S)
        body = re.sub(r'<div class="jump">.*?</div>\n?', "", body, flags=re.S)
    body = re.sub(r'<section class="stack" id="all">.*?</section>\n?', "", body, flags=re.S)
    head = {"eyebrow": "", "title": "", "lede": ""}
    m = re.search(r'<div class="(?:wrap )?page-head">(.*?)\n\s*</div>\n?', body, re.S)
    if m:
        for k, rx in (("eyebrow", r'<span class="eyebrow">(.*?)</span>'),
                      ("title", r"<h1>(.*?)</h1>"), ("lede", r'<p class="lede">(.*?)</p>')):
            x = re.search(rx, m.group(1), re.S)
            head[k] = x.group(1).strip() if x else ""
        body = body.replace(m.group(0), "")
    return raw, head, expand(body)


def changelog_fold(body):
    """Latest three releases in full; the rest behind one button, still on the page."""
    parts = re.split(r'(?=<section class="stack" id="v\d)', body)
    rels = [i for i, p in enumerate(parts) if re.match(r'<section class="stack" id="v\d', p)]
    if len(rels) <= 3:
        return body
    last = rels[-1]
    m = re.match(r"(.*?</section>\n?)(.*)", parts[last], re.S)
    parts[last] = m.group(1) + "</details>\n" + m.group(2)
    parts[rels[3]] = ('<details class="older"><summary>Show %d older releases</summary>\n'
                      % (len(rels) - 3)) + parts[rels[3]]
    return "".join(parts)


# ---------------------------------------------------------------- shared chrome
FONTS = ("https://fonts.googleapis.com/css2?family=Archivo:wdth,wght@62..125,400..900"
         "&family=Doto:wght@700..900&family=IBM+Plex+Mono:wght@400;500;600&display=swap")
GH = ('<svg viewBox="0 0 16 16" width="15" height="15" fill="currentColor" aria-hidden="true"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z"/></svg>')
SUN = '<svg class="sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>'
MOON = '<svg class="moon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8Z"/></svg>'
MENU = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><line x1="3" y1="7" x2="21" y2="7"/><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="17" x2="21" y2="17"/></svg>'
SHORT = {p[0]: p[3] for p in PAGES}
CSS, JS = asset("assets/site.css"), asset("assets/site.js")

STRUCTURED = {
    "index.html": """{"@context":"https://schema.org","@type":"SoftwareApplication","name":"snare",
 "applicationCategory":"SecurityApplication","operatingSystem":"macOS, Linux, Windows, WSL",
 "softwareVersion":"%(v)s","url":"%(s)s","codeRepository":"%(r)s",
 "license":"https://opensource.org/licenses/MIT",
 "description":"Command-line tool that detects and kills supply-chain malware loaders, scans every Git repository you can reach, removes the payload including from history, and notifies collaborators.",
 "offers":{"@type":"Offer","price":"0","priceCurrency":"USD"}}""",
    "attack.html": """{"@context":"https://schema.org","@type":"TechArticle",
 "headline":"How a dropper hides in your own repository","url":"%(s)sattack.html",
 "author":{"@type":"Person","name":"AviOfLagos"}}""",
    "infected.html": """{"@context":"https://schema.org","@type":"HowTo",
 "name":"Remove a committed supply-chain dropper from your repositories","url":"%(s)sinfected.html",
 "totalTime":"PT30M","tool":[{"@type":"HowToTool","name":"snare"}],
 "step":[
  {"@type":"HowToStep","position":1,"name":"Rotate your credentials","url":"%(s)sinfected.html#rotate",
   "text":"Stealing credentials is the objective; removing the payload does not un-steal a token. Revoke npm write tokens first, then GitHub tokens, SSH keys and cloud keys."},
  {"@type":"HowToStep","position":2,"name":"Clean the machine you push from","url":"%(s)sinfected.html#machine",
   "text":"This family injects into commits as they leave an already-infected machine, so cleaning a repository first is wasted work."},
  {"@type":"HowToStep","position":3,"name":"Clean the repositories","url":"%(s)sinfected.html#repos",
   "text":"snare fix is a dry run by default and always backs up first. Purging history rewrites every commit SHA, so every clone must be re-cloned rather than pulled."},
  {"@type":"HowToStep","position":4,"name":"Tell your collaborators","url":"%(s)sinfected.html#notify",
   "text":"They may be infected from the same source, and a rewritten history breaks their clones without explanation."}]}""",
    "check.html": """{"@context":"https://schema.org","@type":"FAQPage","mainEntity":[
 {"@type":"Question","name":"How do I know if my machine is infected with this malware?",
  "acceptedAnswer":{"@type":"Answer","text":"Look for a node process running inline code with obfuscated globals, any file carrying the operator's wallet address, a .vscode/tasks.json task set to runOn folderOpen, and font files whose first four bytes are not a real font magic. A genuine .woff2 begins with wOF2."}},
 {"@type":"Question","name":"Does npm audit detect this?",
  "acceptedAnswer":{"@type":"Answer","text":"No. The dropper is committed into the repository itself rather than pulled from the registry, so there is no malicious dependency for npm audit, the lockfile or Dependabot to report."}},
 {"@type":"Question","name":"My process check came back clean. Am I safe?",
  "acceptedAnswer":{"@type":"Answer","text":"Not necessarily. The loader runs when a build runs or an editor opens the folder, then exits. A clean process check alongside infected repositories is the expected result, not a contradiction."}}]}""",
}
KEYWORDS = ("npm supply chain attack, supply chain malware, npm malware, compromised repository, "
            "repository malware scanner, malicious postcss.config.js, vscode tasks.json malware, "
            "folderOpen exploit, EtherHiding, blockchain C2, fake woff2 payload, git history malware, "
            "npm audit missed, developer security, open source security tool")


def head(out, title, desc):
    url = SITE + ("" if out == "index.html" else out)
    ld = STRUCTURED.get(out)
    crumbs = "" if out == "index.html" else (
        '<script type="application/ld+json">{"@context":"https://schema.org","@type":"BreadcrumbList",'
        '"itemListElement":[{"@type":"ListItem","position":1,"name":"snare","item":"%s"},'
        '{"@type":"ListItem","position":2,"name":"%s","item":"%s"}]}</script>\n' % (SITE, e(SHORT[out]), url))
    return """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>%(t)s</title>
<meta name="description" content="%(d)s">
%(kw)s<meta name="author" content="AviOfLagos">
<meta name="robots" content="index,follow">
<link rel="canonical" href="%(u)s">
<meta property="og:type" content="website">
<meta property="og:site_name" content="snare">
<meta property="og:title" content="%(t)s">
<meta property="og:description" content="%(d)s">
<meta property="og:url" content="%(u)s">
<meta property="og:image" content="%(og)s">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="snare: malware that runs the moment you open the project.">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="%(t)s">
<meta name="twitter:description" content="%(d)s">
<meta name="twitter:image" content="%(og)s">
<meta name="theme-color" content="#121311">
<link rel="icon" href="data:image/svg+xml,<svg xmlns=%%22http://www.w3.org/2000/svg%%22 viewBox=%%220 0 100 100%%22><text y=%%22.9em%%22 font-size=%%2290%%22>🪤</text></svg>">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="%(f)s">
<link rel="stylesheet" href="%(css)s">
<script>/* dark unless the reader picked light; set before first paint so nothing flashes */
var t="dark";try{t=localStorage.getItem("snare-theme")||"dark";}catch(e){}document.documentElement.dataset.theme=t;</script>
%(ld)s%(crumbs)s</head>
""" % {"t": e(title), "d": e(desc), "u": url, "og": SITE + "assets/og.png", "f": FONTS, "css": CSS,
       "kw": ('<meta name="keywords" content="%s">\n' % KEYWORDS) if out == "index.html" else "",
       "ld": ('<script type="application/ld+json">\n%s\n</script>\n'
              % (ld % {"v": VERSION, "s": SITE, "r": REPO})) if ld else "",
       "crumbs": crumbs}


def bar(out):
    links = "\n".join(
        '      <a href="%s"%s>%s</a>' % (p, ' aria-current="page"' if p == out else "", e(SHORT[p]))
        for p in NAV)
    return """<header class="bar">
  <div class="bar-in">
    <a class="brand" href="./"><span class="brand-mark" aria-hidden="true"></span>snare</a>
    <a class="bar-ver" href="changelog.html">v%(v)s</a>
    <nav class="bar-nav" id="bar-nav" aria-label="Primary">
%(links)s
      <a class="bar-cta" href="install.html"%(cur)s>Install</a>
    </nav>
    <div class="bar-tools">
      <a class="icon-btn" href="%(r)s" aria-label="snare on GitHub">%(gh)s</a>
      <button class="icon-btn theme-toggle" type="button" aria-label="Switch theme">%(sun)s%(moon)s</button>
      <button class="icon-btn nav-toggle" type="button" aria-expanded="false" aria-controls="bar-nav" aria-label="Open menu">%(menu)s</button>
    </div>
  </div>
</header>
""" % {"v": VERSION, "links": links, "r": REPO, "gh": GH, "sun": SUN, "moon": MOON, "menu": MENU,
       "cur": ' aria-current="page"' if out == "install.html" else ""}


def foot():
    cols = [("Read", ["attack.html", "check.html", "infected.html"]),
            ("Use", ["install.html", "docs.html", "changelog.html"]),
            ("Talk", ["community.html", "security.html"])]
    html_cols = "".join(
        '<div class="fc"><b>%s</b>%s</div>' % (t, "".join('<a href="%s">%s</a>' % (p, e(SHORT[p])) for p in ps))
        for t, ps in cols)
    return """<footer class="foot">
  <div class="foot-in">
    <div class="fc fc-wide"><span class="brand"><span class="brand-mark" aria-hidden="true"></span>snare</span>
      <p>Free and open source, MIT. Findings from a first-hand investigation, August 2026. Payload
      excerpts are truncated and defanged.</p></div>
    %(cols)s
  </div>
  <div class="foot-bar"><span>snare %(v)s</span><a href="%(r)s">github.com/nexlabz/snare</a></div>
</footer>
<script src="%(js)s"></script>
</body>
</html>
""" % {"cols": html_cols, "v": VERSION, "r": REPO, "js": JS}


def explore(minutes):
    cards = []
    for out, kind, _, short, pitch in PAGES:
        if kind == "home":
            continue
        tag = "%d min read" % minutes[out] if kind == "long" else "Page"
        cards.append('<a class="ex" href="%s"><span class="ex-k">%s</span><b>%s</b><span class="ex-p">%s</span></a>'
                     % (out, tag, e(short), e(pitch)))
    return '<div class="explore">\n  ' + "\n  ".join(cards) + "\n</div>\n"


def spec():
    changelog = open("../CHANGELOG.md", encoding="utf-8").read()
    m = re.search(r"^## \[%s\]\s+[—–-]\s+(\d{4})-(\d\d)-(\d\d)" % re.escape(VERSION), changelog, re.M)
    mon = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split()
    date = "%d %s %s" % (int(m.group(3)), mon[int(m.group(2)) - 1], m.group(1)) if m else ""
    return """<dl class="spec" aria-label="snare at a glance">
    <div><dt>Version</dt><dd><a href="changelog.html">%s</a><span class="spec-dim"> / %s</span></dd></div>
    <div><dt>Threat</dt><dd class="spec-hot"><span class="pulse" aria-hidden="true"></span>Campaign active</dd></div>
    <div><dt>Runs on</dt><dd>macOS, Linux, Windows, WSL</dd></div>
    <div><dt>Needs</dt><dd>bash, git, python3, gh</dd></div>
    <div><dt>Licence</dt><dd>MIT, free</dd></div>
  </dl>""" % (VERSION, date)


# ---------------------------------------------------------------- long read
SEC_RX = re.compile(r'<section class="(stack[^"]*)" id="([\w-]+)">(.*?)</section>', re.S)


def long_read(body):
    """Each top-level section with an id becomes a rail entry with its own reading time."""
    entries = []

    def mark(m):
        cls, sid, inner = m.groups()
        label = re.search(r'<span class="eyebrow">(.*?)</span>', inner, re.S)
        if not label:
            label = re.search(r"<h2[^>]*>(.*?)</h2>", inner, re.S)
        text = re.sub(r"<[^>]+>", "", label.group(1)).strip() if label else sid
        w = words(inner)
        n = max(1, round(w / WPM))
        entries.append((sid, text, n, w))
        return '<section class="%s chapter" id="%s" data-min="%d">%s</section>' % (cls, sid, n, inner)
    body = SEC_RX.sub(mark, body)
    return body, entries


def rail(entries):
    total = mins(sum(w for *_, w in entries))
    items = "".join(
        '    <li><a href="#%s"><span class="rl-n">%02d</span><span class="rl-t">%s</span>'
        '<span class="rl-m">%d′</span><i class="rl-p" aria-hidden="true"></i></a></li>\n'
        % (sid, i, e(t), n) for i, (sid, t, n, _) in enumerate(entries, 1))
    return """<nav class="rail" id="rail" aria-label="On this page">
  <button class="rail-now" type="button" aria-expanded="false" aria-controls="rail-list">
    <span class="rn-n" id="rail-n">01</span><span class="rn-t" id="rail-t">%s</span><span class="rn-left" id="rail-left">%d min left</span>
    <span class="rn-bar" aria-hidden="true"><i id="rail-bar"></i></span>
  </button>
  <p class="rail-head">On this page<span>%d min</span></p>
  <ol class="rail-list" id="rail-list">
%s  </ol>
</nav>
""" % (e(entries[0][1]) if entries else "", total, total, items)


def page_head(h, meta_line, kind):
    return """<header class="ph ph-%s">
  %s<h1>%s</h1>
  %s
</header>
""" % (kind, ('<p class="ph-meta">%s</p>\n  ' % meta_line) if meta_line else "", h["title"],
       ('<p class="ph-lede">%s</p>' % h["lede"]) if h["lede"] else "")


def next_up(out):
    order = [p[0] for p in PAGES if p[1] != "home"]
    nxt = order[(order.index(out) + 1) % len(order)]
    return '<a class="next-up" href="%s"><span>Next</span><b>%s</b></a>\n' % (nxt, e(SHORT[nxt]))


# ---------------------------------------------------------------- build
built, minutes, loaded = {}, {}, {}
for out, kind, srcs, short, _ in PAGES:
    loaded[out] = [load(f, kind) for f in srcs]

for out, kind, srcs, short, _ in PAGES:
    if kind != "long":
        continue
    raw, h, body = loaded[out][0]
    # later sources are further parts of the same read; their page header
    # becomes the opening section of that part
    for raw2, h2, b2 in loaded[out][1:]:
        body += ('\n<section class="stack part" id="reference">\n  <span class="eyebrow">Command reference</span>\n'
                 '  <h2>%s</h2>\n  <p class="lede">%s</p>\n</section>\n%s' % (h2["title"], h2["lede"], b2))
    body, entries = long_read(relink(body))
    loaded[out] = (raw, h, body, entries)
    minutes[out] = mins(sum(w for *_, w in entries))

for out, kind, srcs, short, _ in PAGES:
    if kind == "long":
        raw, h, body, entries = loaded[out]
    else:
        raw, h, body = loaded[out][0]
    title, desc = meta(raw, "title"), meta(raw, "desc")
    doc = [head(out, title, desc), '<body data-page="%s">\n' % out[:-5],
           '<a class="skip" href="#main">Skip to content</a>\n']
    if kind == "home":
        doc.append(relink(gen("announce")))
    doc.append(bar(out))
    doc.append('<main id="main">\n')

    if kind == "home":
        body = body.replace("<!--#spec-->", spec()).replace("<!--#explore-->", explore(minutes))
        doc.append('<div class="home">\n%s</div>\n' % relink(body))
    elif kind == "long":
        doc.append(page_head(h, "%s <span>/</span> %d min read <span>/</span> %d sections"
                             % (h["eyebrow"] or e(short), minutes[out], len(entries)), "long"))
        doc.append('<div class="manual">\n%s<div class="chapters ch-body">\n%s\n%s</div>\n</div>\n'
                   % (rail(entries), body, next_up(out)))
    else:
        if out == "changelog.html":
            body = changelog_fold(body)
        doc.append(page_head(h, h["eyebrow"], "page"))
        doc.append('<div class="page-body ch-body">\n%s\n%s</div>\n' % (relink(body), next_up(out)))

    doc.append("</main>\n")
    doc.append(foot())
    text = "".join(doc)

    ids = re.findall(r'\bid="([^"]+)"', text)
    dups = sorted({i for i in ids if ids.count(i) > 1})
    if dups:
        sys.exit("assemble.py: %s: duplicate ids: %s" % (out, ", ".join(dups)))
    built[out] = text

# every link to a page on this site must land on a real id
for out, text in built.items():
    for page, frag in re.findall(r'href="([\w./-]*?)(#[\w-]+)?"', text):
        if page.startswith(("http", "assets/", "data:")) or (page and not page.endswith(".html") and page != "./"):
            continue
        target = out if page == "" else ("index.html" if page == "./" else page)
        if target not in built:
            if target not in STUBS:
                sys.exit("assemble.py: %s links to missing page %s" % (out, target))
            continue
        if frag and 'id="%s"' % frag[1:] not in built[target]:
            sys.exit("assemble.py: %s links to %s%s, which does not exist" % (out, target, frag))

for out, text in built.items():
    open(out, "w", encoding="utf-8").write(text)
    print("  %-16s %7d bytes%s" % (out, len(text.encode()),
                                     "  (%d min read)" % minutes[out] if out in minutes else ""))

for old, new in STUBS.items():
    page, _, frag = new.partition("#")
    open(old, "w", encoding="utf-8").write("""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>Moved — snare</title>
<meta name="robots" content="noindex,follow">
<link rel="canonical" href="%(s)s%(n)s">
<meta http-equiv="refresh" content="0; url=%(n)s">
<script>location.replace("%(p)s" + (location.hash || "#%(f)s"));</script>
</head><body><p>This page moved to <a href="%(n)s">%(n)s</a>.</p></body></html>
""" % {"s": SITE, "n": new, "p": page, "f": frag})
print("  %d redirect stub(s): %s" % (len(STUBS), ", ".join(STUBS)))
