#!/usr/bin/env python3
"""assemble.py — build the one-page field manual from the fragments in src/.

Readers told us the split site read badly: nine pages, and no way to know how
much there was to read before committing to it. So everything now lives on one
page, laid out like a field manual: a cover, the full contents with a reading
time for each chapter, then the chapters in order, with a rail that shows where
you are and how much is left.

Each src/<name>.html is still written as its own fragment, with its metadata in
leading comments (<!--#title: ...-->, <!--#desc: ...-->). This script turns
each one into a chapter:

  - its page header (eyebrow, h1, lede) becomes the chapter header;
  - every heading moves down one level, so the cover holds the only <h1>;
  - per-page sidebars and jump bars are dropped (the global rail replaces them);
  - links to other pages (check.html#x) become in-page anchors (#x).

The old page URLs are kept as small redirect stubs, because they are already
linked from GitHub issues, threads and articles.

Usage: assemble.py SITE REPO VERSION   (run from docs/, writes index.html + stubs)
"""
import html
import math
import os
import re
import subprocess
import sys

SITE, REPO, VERSION = sys.argv[1], sys.argv[2], sys.argv[3]

# reading order; (chapter id, source file, short name, what the reader gets)
CHAPTERS = [
    ("attack",    "index.html",     "The attack",
     "How the dropper gets in, why the file looks normal, and how it finds its server."),
    ("check",     "check.html",     "Check your machine",
     "Seven checks you can paste into a terminal. Nothing to install."),
    ("infected",  "infected.html",  "If you're infected",
     "What to do, in the order that matters. Rotate first, repositories last."),
    ("install",   "install.html",   "Install snare",
     "macOS, Linux, Windows and WSL, plus a prompt for your coding agent."),
    ("docs",      "docs.html",      "How snare works",
     "Blocks, updates, authentication, your own patterns, and where state lives."),
    ("commands",  "commands.html",  "Every command",
     "The full reference, and what each command will not do."),
    ("community", "community.html", "Community",
     "Field reports, who found what, and the questions still open."),
    ("security",  "security.html",  "Report a bug",
     "A false clean result is the bug we most want to hear about."),
    ("changelog", "changelog.html", "Changelog",
     "Every release, and what was broken before it."),
]
PAGE_TO_ID = {f: k for k, f, _, _ in CHAPTERS}
WPM = 220  # reading speed for technical prose with code


def gen(mode):
    out = subprocess.run(["python3", "changelog-gen.py", "--" + mode,
                          "../CHANGELOG.md", "../releases"],
                         capture_output=True, text=True)
    if out.returncode:
        sys.exit("changelog-gen --%s failed: %s" % (mode, out.stderr))
    return out.stdout


def meta(src, key):
    m = re.search(r"^<!--#%s: (.*)-->$" % key, src, re.M)
    return m.group(1) if m else ""


def relink(s):
    """Links to other pages become anchors on this page."""
    def sub(m):
        page, frag = m.group(1) + ".html", m.group(2)
        if page not in PAGE_TO_ID:
            return m.group(0)
        return 'href="#%s"' % (frag[1:] if frag else PAGE_TO_ID[page])
    return re.sub(r'href="([a-z]+)\.html(#[\w-]+)?"', sub, s)


def demote(s):
    for n in (5, 4, 3, 2):
        s = re.sub(r"<(/?)h%d\b" % n, r"<\1h%d" % (n + 1), s)
    return s


def words(s):
    # what a reader reads: not code to paste, not the folded older releases
    s = re.sub(r"<pre.*?</pre>|<details class=\"older\">.*?</details>|<table.*?</table>", " ", s, flags=re.S)
    text = re.sub(r"<script.*?</script>|<[^>]+>", " ", s, flags=re.S)
    return len(text.split())


def chapter(cid, fname, short):
    raw = open(os.path.join("src", fname), encoding="utf-8").read()
    body = re.sub(r"^<!--#[a-z]+:.*-->\n", "", raw, flags=re.M)

    extracted = {}
    # sidebars and chip bars are replaced by the global rail
    body = re.sub(r'<aside class="toc".*?</aside>\n?', "", body, flags=re.S)
    body = re.sub(r'<div class="jump">.*?</div>\n?', "", body, flags=re.S)
    # "every page on this site" means nothing on a site with one page
    body = re.sub(r'<section class="stack" id="all">.*?</section>\n?', "", body, flags=re.S)
    # the home hero becomes the cover; its "what's new" moves under the contents
    if fname == "index.html":
        body = re.sub(r'<div class="wrap hero stack">.*?\n</div>\n', "", body, count=1, flags=re.S)
        m = re.search(r'<section class="stack whats-new" id="whats-new">.*?</section>\n?', body, re.S)
        if m:
            extracted["whatsnew"] = m.group(0)
            body = body.replace(m.group(0), "")

    head = {"eyebrow": "", "title": "", "lede": ""}
    m = re.search(r'<div class="(?:wrap )?page-head">(.*?)\n\s*</div>\n?', body, re.S)
    if m:
        ph = m.group(1)
        t = re.search(r"<h1>(.*?)</h1>", ph, re.S)
        l = re.search(r'<p class="lede">(.*?)</p>', ph, re.S)
        head["title"] = t.group(1).strip() if t else ""
        head["lede"] = l.group(1).strip() if l else ""
        body = body.replace(m.group(0), "")

    def expand(line):
        for marker, mode in (("releases", "releases"), ("reltoc", "toc"),
                             ("reljump", "jump"), ("latest", "latest")):
            if "<!--#%s-->" % marker in line:
                return gen(mode)
        return line
    body = "".join(expand(l) for l in body.splitlines(True))
    if "whatsnew" in extracted:
        extracted["whatsnew"] = "".join(expand(l) for l in extracted["whatsnew"].splitlines(True))

    if fname == "changelog.html":
        # the latest three in full; the rest folded, still on the page and searchable
        parts = re.split(r'(?=<section class="stack" id="v\d)', body)
        rels = [i for i, p in enumerate(parts) if re.match(r'<section class="stack" id="v\d', p)]
        if len(rels) > 3:
            first_old, last = rels[3], rels[-1]
            tail_m = re.match(r"(.*?</section>\n?)(.*)", parts[last], re.S)
            parts[last] = tail_m.group(1)
            rest = tail_m.group(2)
            older = len(rels) - 3
            parts[first_old] = ('<details class="older"><summary>Show %d older releases</summary>\n'
                                % older) + parts[first_old]
            parts[last] += "</details>\n" + rest
        body = "".join(parts)

    if not head["title"]:
        head["title"] = {
            "index.html": "How the attack works",
        }.get(fname, short)

    body = demote(relink(body))
    for k in extracted:
        extracted[k] = demote(relink(extracted[k]))
    return {"id": cid, "short": short, "head": head, "body": body,
            "title_meta": meta(raw, "title"), "desc": meta(raw, "desc"),
            "words": words(body) + words(head["lede"]), **extracted}


def mins(w):
    return max(1, math.ceil(w / WPM))


chs = []
for cid, fname, short, blurb in CHAPTERS:
    c = chapter(cid, fname, short)
    c["blurb"] = blurb
    c["min"] = mins(c["words"])
    chs.append(c)
total_min = sum(c["min"] for c in chs)
whatsnew = next((c["whatsnew"] for c in chs if "whatsnew" in c), "")

changelog = open("../CHANGELOG.md", encoding="utf-8").read()
m = re.search(r"^## \[%s\]\s+[—–-]\s+(\d{4})-(\d\d)-(\d\d)" % re.escape(VERSION), changelog, re.M)
MONTHS = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split()
rel_date = "%d %s %s" % (int(m.group(3)), MONTHS[int(m.group(2)) - 1], m.group(1)) if m else ""

TITLE = "snare — the supply-chain attack npm audit cannot see"
DESC = ("A dropper committed straight into the repository, not into a dependency. It runs when "
        "you start the dev server or open the folder — no npm install needed. The whole field "
        "manual on one page: how it works, how to check, what to do, and a free open-source scanner.")
KEYWORDS = ("npm supply chain attack, supply chain malware, supply chain attack detection, npm malware, "
            "malicious npm package, compromised repository, repository malware scanner, shai-hulud, "
            "malicious postcss.config.js, vscode tasks.json malware, folderOpen exploit, EtherHiding, "
            "blockchain C2, fake woff2 payload, clipboard stealer, git history malware, npm audit missed, "
            "dependency security, developer security, open source security tool")

FONTS = ("https://fonts.googleapis.com/css2?family=Archivo:wdth,wght@62..125,400..900"
         "&family=Doto:wght@700..900&family=IBM+Plex+Mono:wght@400;500;600&display=swap")

GH_ICON = ('<svg viewBox="0 0 16 16" width="15" height="15" fill="currentColor" aria-hidden="true"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z"/></svg>')
SUN = '<svg class="sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>'
MOON = '<svg class="moon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8Z"/></svg>'

import hashlib
def asset(path):
    """Content-hashed URL, so a new deploy never serves last week's stylesheet."""
    h = hashlib.sha1(open(path, "rb").read()).hexdigest()[:8]
    return "%s?v=%s" % (path, h)

e = html.escape
out = []
w = out.append

w("""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>%(t)s</title>
<meta name="description" content="%(d)s">
<meta name="keywords" content="%(k)s">
<meta name="author" content="AviOfLagos">
<meta name="robots" content="index,follow">
<link rel="canonical" href="%(site)s">
<meta property="og:type" content="website">
<meta property="og:site_name" content="snare">
<meta property="og:title" content="%(t)s">
<meta property="og:description" content="%(d)s">
<meta property="og:url" content="%(site)s">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="%(t)s">
<meta name="twitter:description" content="%(d)s">
<meta name="theme-color" content="#121311">
<link rel="icon" href="data:image/svg+xml,<svg xmlns=%%22http://www.w3.org/2000/svg%%22 viewBox=%%220 0 100 100%%22><text y=%%22.9em%%22 font-size=%%2290%%22>🪤</text></svg>">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="%(fonts)s">
<link rel="stylesheet" href="%(css)s">
<script>/* dark unless the reader picked light; set before first paint so nothing flashes */
var t="dark";try{t=localStorage.getItem("snare-theme")||"dark";}catch(e){}document.documentElement.dataset.theme=t;</script>
""" % {"t": e(TITLE), "d": e(DESC), "k": KEYWORDS, "site": SITE, "fonts": FONTS, "css": asset("assets/site.css")})

# structured data: everything the separate pages used to carry, now on one URL
w("""<script type="application/ld+json">
{"@context":"https://schema.org","@graph":[
 {"@type":"SoftwareApplication","name":"snare","applicationCategory":"SecurityApplication",
  "operatingSystem":"macOS, Linux, Windows, WSL","softwareVersion":"%(v)s",
  "description":"Command-line tool that detects and kills supply-chain malware loaders, scans every Git repository you can reach, removes the payload including from history, and notifies collaborators.",
  "url":"%(s)s","codeRepository":"%(r)s","license":"https://opensource.org/licenses/MIT",
  "offers":{"@type":"Offer","price":"0","priceCurrency":"USD"}},
 {"@type":"TechArticle","headline":"Malware that runs the moment you open the project",
  "description":%(dj)s,"url":"%(s)s","author":{"@type":"Person","name":"AviOfLagos"}},
 {"@type":"HowTo","name":"Remove a committed supply-chain dropper from your repositories",
  "url":"%(s)s#infected","totalTime":"PT30M","tool":[{"@type":"HowToTool","name":"snare"}],
  "step":[
   {"@type":"HowToStep","position":1,"name":"Rotate your credentials","url":"%(s)s#rotate",
    "text":"Stealing credentials is the objective; removing the payload does not un-steal a token. Revoke npm write tokens first, then GitHub tokens, SSH keys and cloud keys."},
   {"@type":"HowToStep","position":2,"name":"Clean the machine you push from","url":"%(s)s#machine",
    "text":"This family injects into commits as they leave an already-infected machine, so cleaning a repository first is wasted work."},
   {"@type":"HowToStep","position":3,"name":"Clean the repositories","url":"%(s)s#repos",
    "text":"snare fix is a dry run by default and always backs up first. Purging history rewrites every commit SHA, so every clone must be re-cloned rather than pulled."},
   {"@type":"HowToStep","position":4,"name":"Tell your collaborators","url":"%(s)s#notify",
    "text":"They may be infected from the same source, and a rewritten history breaks their clones without explanation."}]},
 {"@type":"FAQPage","mainEntity":[
  {"@type":"Question","name":"How do I know if my machine is infected with this malware?",
   "acceptedAnswer":{"@type":"Answer","text":"Look for a node process running inline code with obfuscated globals, any file carrying the operator's wallet address, a .vscode/tasks.json task set to runOn folderOpen, and font files whose first four bytes are not a real font magic. A genuine .woff2 begins with wOF2."}},
  {"@type":"Question","name":"Does npm audit detect this?",
   "acceptedAnswer":{"@type":"Answer","text":"No. The dropper is committed into the repository itself rather than pulled from the registry, so there is no malicious dependency for npm audit, the lockfile or Dependabot to report."}},
  {"@type":"Question","name":"My process check came back clean. Am I safe?",
   "acceptedAnswer":{"@type":"Answer","text":"Not necessarily. The loader runs when a build runs or an editor opens the folder, then exits. A clean process check alongside infected repositories is the expected result, not a contradiction."}}]}
]}
</script>
</head>
<body data-page="index">
<a class="skip" href="#contents">Skip to the contents</a>
""" % {"v": VERSION, "s": SITE, "r": REPO, "dj": '"%s"' % DESC.replace('"', '\\"')})

w(relink(gen("announce")))

w("""<header class="bar">
  <div class="bar-in">
    <a class="brand" href="#top" aria-label="snare, back to the cover"><span class="brand-mark" aria-hidden="true"></span>snare</a>
    <span class="bar-doc">Field manual <span class="bar-sep">/</span> rev %(v)s</span>
    <div class="bar-tools">
      <a class="bar-link" href="#install">Install</a>
      <a class="bar-link bar-gh" href="%(r)s">%(gh)s<span>GitHub</span></a>
      <button class="icon-btn theme-toggle" type="button" aria-label="Switch theme">%(sun)s%(moon)s</button>
    </div>
  </div>
</header>
""" % {"v": VERSION, "r": REPO, "gh": GH_ICON, "sun": SUN, "moon": MOON})

# ---------------------------------------------------------------- cover
w("""<main id="top">
<section class="cover" aria-labelledby="cover-title">
  <div class="cover-in">
    <div class="cover-main">
      <p class="wordmark" aria-hidden="true">SNARE</p>
      <h1 id="cover-title">Malware that runs the moment you open the project.</h1>
      <p class="cover-lede">A supply-chain attack that <code>npm audit</code> cannot see. The dropper is
      committed straight into the repository, hidden in ordinary config files and fake fonts. It runs
      when you start the dev server, or as soon as your editor opens the folder. No
      <code>npm install</code> needed.</p>
      <p class="cover-lede"><strong>snare</strong> is a free, open-source command-line tool. It kills
      the loader on your machine, scans every Git repository you can reach, cleans what it finds and
      helps you warn your collaborators.</p>
      <div class="cover-actions">
        <a class="cta cta-hot" href="#check">Check your machine</a>
        <a class="cta" href="#install">Install snare</a>
        <a class="cta cta-quiet" href="%(r)s/stargazers">%(gh)s Star on GitHub</a>
      </div>
    </div>
    <dl class="spec" aria-label="About this manual">
      <div><dt>Document</dt><dd>Field manual, one page</dd></div>
      <div><dt>Revision</dt><dd>%(v)s<span class="spec-dim"> / %(date)s</span></dd></div>
      <div><dt>Reading time</dt><dd>%(tot)d min<span class="spec-dim"> / %(n)d chapters</span></dd></div>
      <div><dt>Threat</dt><dd class="spec-hot"><span class="pulse" aria-hidden="true"></span>Campaign active</dd></div>
      <div><dt>Runs on</dt><dd>macOS, Linux, Windows, WSL</dd></div>
      <div><dt>Licence</dt><dd>MIT, free</dd></div>
    </dl>
  </div>
  <a class="cover-urgent" href="#infected">
    <span class="cu-k">Already found something?</span>
    <span class="cu-v">Skip to chapter 03. Rotate your credentials first, not the repositories.</span>
  </a>
</section>
""" % {"r": REPO, "gh": GH_ICON, "v": VERSION, "date": rel_date, "tot": total_min, "n": len(chs)})

# ---------------------------------------------------------------- contents
w("""<section class="contents" id="contents" aria-labelledby="contents-title">
  <div class="contents-head">
    <h2 id="contents-title">Everything is on this page</h2>
    <p>%d chapters, about %d minutes end to end. Read it straight through, or jump to the one you
    need. The rail on the left shows where you are and how much is left.</p>
  </div>
  <ol class="toc-list">
""" % (len(chs), total_min))
for i, c in enumerate(chs, 1):
    w("""    <li><a href="#%s"><span class="tl-n">%02d</span><span class="tl-t">%s</span><span class="tl-b">%s</span><span class="tl-m">%d min</span></a></li>
""" % (c["id"], i, e(c["short"]), e(c["blurb"]), c["min"]))
w("  </ol>\n</section>\n")

if whatsnew:
    w('<div class="strip">\n' + whatsnew + "</div>\n")

# ---------------------------------------------------------------- body: rail + chapters
w('<div class="manual">\n')
w("""<nav class="rail" id="rail" aria-label="Chapters">
  <button class="rail-now" type="button" aria-expanded="false" aria-controls="rail-list">
    <span class="rn-n" id="rail-n">01</span><span class="rn-t" id="rail-t">%s</span><span class="rn-left" id="rail-left">%d min left</span>
    <span class="rn-bar" aria-hidden="true"><i id="rail-bar"></i></span>
  </button>
  <ol class="rail-list" id="rail-list">
""" % (e(chs[0]["short"]), total_min))
for i, c in enumerate(chs, 1):
    w("""    <li><a href="#%s" data-min="%d"><span class="rl-n">%02d</span><span class="rl-t">%s</span><span class="rl-m">%d′</span><i class="rl-p" aria-hidden="true"></i></a></li>
""" % (c["id"], c["min"], i, e(c["short"]), c["min"]))
w("  </ol>\n</nav>\n<div class=\"chapters\">\n")

for i, c in enumerate(chs, 1):
    h = c["head"]
    w("""<article class="chapter" id="%(id)s" aria-labelledby="%(id)s-t" data-min="%(min)d">
<header class="ch-head">
  <span class="ch-n" aria-hidden="true">%(n)02d</span>
  <div class="ch-meta"><span>Chapter %(n)02d</span><span>%(short)s</span><span>%(min)d min read</span></div>
  <h2 id="%(id)s-t">%(title)s</h2>
  %(lede)s
</header>
<div class="ch-body">
%(body)s
</div>
</article>
""" % {"id": c["id"], "n": i, "short": e(c["short"]), "min": c["min"], "title": h["title"],
       "lede": ('<p class="ch-lede">%s</p>' % relink(h["lede"])) if h["lede"] else "",
       "body": c["body"]})

w("""<div class="end">
  <p class="end-k">End of manual</p>
  <p class="end-v">That is all of it. If snare caught something, or just made you look, a star is how
  the next developer finds it.</p>
  <div class="cover-actions"><a class="cta cta-hot" href="%(r)s/stargazers">%(gh)s Star snare on GitHub</a><a class="cta" href="#top">Back to the cover</a></div>
</div>
</div>
</div>
</main>
<footer class="foot">
  <div class="foot-in">
    <span>snare %(v)s. MIT licence. Findings from a first-hand investigation, August 2026. Payload excerpts are truncated and defanged.</span>
    <span><a href="%(r)s">github.com/nexlabz/snare</a></span>
  </div>
</footer>
<script src="%(js)s"></script>
</body>
</html>
""" % {"r": REPO, "gh": GH_ICON, "v": VERSION, "js": asset("assets/site.js")})

doc = "".join(out)

# every in-page link must land somewhere
ids = set(re.findall(r'\bid="([^"]+)"', doc))
missing = sorted({h for h in re.findall(r'href="#([^"]+)"', doc) if h not in ids})
if missing:
    sys.exit("assemble.py: anchors with no target: " + ", ".join(missing))
dups = sorted({i for i in re.findall(r'\bid="([^"]+)"', doc)
               if len(re.findall(r'\bid="%s"' % re.escape(i), doc)) > 1})
if dups:
    sys.exit("assemble.py: duplicate ids: " + ", ".join(dups))

open("index.html", "w", encoding="utf-8").write(doc)
print("  %-18s %6d bytes  (%d chapters, %d min)" % ("index.html", len(doc.encode()), len(chs), total_min))

# ---------------------------------------------------------------- old URLs
for cid, fname, short, _ in CHAPTERS:
    if fname == "index.html":
        continue
    stub = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>%(short)s — snare</title>
<meta name="robots" content="noindex,follow">
<link rel="canonical" href="%(site)s#%(id)s">
<meta http-equiv="refresh" content="0; url=./#%(id)s">
<script>location.replace("./" + (location.hash || "#%(id)s"));</script>
</head><body><p>snare is one page now. <a href="./#%(id)s">%(short)s</a>.</p></body></html>
""" % {"short": e(short), "site": SITE, "id": cid}
    open(fname, "w", encoding="utf-8").write(stub)
print("  %d redirect stubs for the old page URLs" % (len(CHAPTERS) - 1))
