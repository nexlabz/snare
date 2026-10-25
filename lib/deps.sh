# shellcheck shell=bash
# deps.sh — known-malicious package versions, in every ecosystem snare reads.
#
# The list: github.com/ossf/malicious-packages, condensed every six hours by
# .github/workflows/intel.yml into one small file published on snare's own
# `intel` release. Every snare downloads that SAME file and matches it against
# its own lockfiles and installs — nothing about the machine is ever sent, so
# there is nothing to track and nothing to leak. (The one exception is
# deliberate and visible: before an unpinned install of a package that has
# SOME known-bad versions, the gate asks the registry which version would
# install — the request the install itself was about to make.)

INTEL_DIR="${SNARE_INTEL_DIR:-$SNARE_HOME/intel}"
INTEL_LIST="$INTEL_DIR/malicious.tsv.gz"
INTEL_META="$INTEL_DIR/intel.json"
INTEL_URL="${SNARE_INTEL_URL:-https://github.com/nexlabz/snare/releases/download/intel}"
INTEL_MAX_AGE="${SNARE_INTEL_MAX_AGE:-86400}"

# Age of the local list in seconds, or empty when there is none.
snare_intel_age(){
  [ -s "$INTEL_LIST" ] || return 1
  local m now; now="$(date +%s)"
  m="$(stat -f %m "$INTEL_LIST" 2>/dev/null || stat -c %Y "$INTEL_LIST" 2>/dev/null)" || return 1
  echo $((now - m))
}

# Download the list. Both files, then the checksum: a list cut short mid-way
# (or swapped between the two uploads) is refused and the old one is kept,
# because a truncated list reads as "nothing is known-malicious".
snare_intel_refresh(){
  local tmp; mkdir -p "$INTEL_DIR" 2>/dev/null
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/snareintel.XXXXXX")" || return 1
  if ! curl -fsSL --max-time 60 -o "$tmp/intel.json" "$INTEL_URL/intel.json" 2>/dev/null \
     || ! curl -fsSL --max-time 120 -o "$tmp/malicious.tsv.gz" "$INTEL_URL/malicious.tsv.gz" 2>/dev/null; then
    rm -rf "$tmp"; return 1
  fi
  local want got
  want="$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["sha256"])' "$tmp/intel.json" 2>/dev/null)"
  got="$(shasum -a 256 "$tmp/malicious.tsv.gz" 2>/dev/null | cut -d' ' -f1)"
  [ -n "$got" ] || got="$(sha256sum "$tmp/malicious.tsv.gz" 2>/dev/null | cut -d' ' -f1)"
  if [ -z "$want" ] || [ "$want" != "$got" ]; then rm -rf "$tmp"; return 1; fi
  mv -f "$tmp/malicious.tsv.gz" "$INTEL_LIST" && mv -f "$tmp/intel.json" "$INTEL_META"
  rm -rf "$tmp"
}

# Never blocks: refresh in the background when the list is stale or missing.
snare_intel_nudge(){
  local age; age="$(snare_intel_age)" || age=999999999
  [ "$age" -lt "$INTEL_MAX_AGE" ] && return 0
  [ -f "$INTEL_DIR/.refreshing" ] && [ -n "$(find "$INTEL_DIR/.refreshing" -mmin -10 2>/dev/null)" ] && return 0
  mkdir -p "$INTEL_DIR" 2>/dev/null; : > "$INTEL_DIR/.refreshing" 2>/dev/null
  ( "$SNARE_ROOT/bin/snare" _intel-refresh >/dev/null 2>&1 & ) >/dev/null 2>&1
}

# Every Python snare starts runs with -I -S. -S: a .pth file in site-packages
# runs at interpreter start — the payload this file looks for — so snare must
# not start an interpreter that would execute it while checking for it. -I:
# `python -c` otherwise puts the CURRENT directory first on the import path,
# and snare runs from inside the repository it checks — a planted json.py or
# re.py at its root would run on the first import. (-I applies everywhere in
# snare for that reason, the gate's own classifier included.)
_deps_py(){
  cat <<'PYDEPS'
import gzip, hashlib, json, os, re, subprocess, sys

mode, index = sys.argv[1], sys.argv[2]
args = sys.argv[3:]

def pynorm(n): return re.sub(r"[-_.]+", "-", n).lower()
def norm(eco, n):
    if eco == "pypi": return pynorm(n)
    if eco in ("npm", "crates.io", "nuget", "packagist", "rubygems"): return n.lower()
    return n

def load(want=None):
    idx = {}
    try:
        fh = gzip.open(index, "rt", errors="replace")
    except OSError:
        return None
    with fh:
        for ln in fh:
            p = ln.rstrip("\n").split("\t")
            if len(p) < 4: continue
            if want is not None and (p[0], p[1]) not in want: continue
            idx[(p[0], p[1])] = (p[2], p[3])
    return idx

def vkey(v):
    return [(0, int(t)) if t.isdigit() else (1, t) for t in re.findall(r"\d+|[A-Za-z]+", v or "")]

def pep440_eq(a, b):
    """1.107 == 1.107.0 to pip: release segments compare zero-padded."""
    ka, kb = vkey(a), vkey(b)
    while ka and ka[-1] == (0, 0): ka = ka[:-1]
    while kb and kb[-1] == (0, 0): kb = kb[:-1]
    return ka == kb

# What each package manager installs as ONE exact version. Anything else — a
# partial version (npm's `0.7` is 0.7.x), a range, a tag, cargo's `1.2.3`
# (which means ^1.2.3) — goes to the resolver.
SEMVER = re.compile(r"^v?\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$")
def exact(eco, ver):
    if eco in ("npm", "go"): return bool(SEMVER.fullmatch(ver))
    if eco == "pypi": return bool(re.fullmatch(r"\d+(\.\d+)*((a|b|rc)\d+)?(\.post\d+)?(\.dev\d+)?", ver))
    # cargo: only `=x.y.z` is one version (`=1.2` is every 1.2.x, `1.2.3` is ^1.2.3)
    if eco == "crates.io": return bool(re.fullmatch(r"=\s*\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?", ver))
    return bool(re.fullmatch(r"\d+(\.\d+){2,}", ver))

def matches(spec, ver):
    """True when this version is known-malicious; None when unversioned and
    only some versions are bad (the caller decides)."""
    if spec == "*": return True
    if not ver: return None
    v = ver.lstrip("=v").strip()
    for part in spec.split("|"):
        if not part: continue
        if part.startswith("R:"):
            _, intro, fixed = (part.split(":", 2) + ["", ""])[:3]
            if vkey(v) < vkey(intro): continue
            if not fixed: return True
            if fixed.startswith("<="):
                if vkey(v) <= vkey(fixed[2:]): return True
            elif vkey(v) < vkey(fixed): return True
        elif v in {x.lstrip("v") for x in part.split(",")} \
                or any(pep440_eq(v, x.lstrip("v")) for x in part.split(",") if x):
            return True
    return False

# ---------------------------------------------------------------- collectors
# Each yields (eco, name, version or None, where). `where` is a path, with a
# line where one helps, relative to the root being scanned.
TOMLPKG = re.compile(r'^\[\[package\]\]\s*$')
def toml_packages(text):
    name = ver = None; line = 0
    for n, ln in enumerate(text.split("\n"), 1):
        if TOMLPKG.match(ln):
            if name: yield name, ver, line
            name = ver = None; line = n; continue
        m = re.match(r'^name\s*=\s*"([^"]+)"', ln)
        if m and name is None: name = m.group(1); continue
        m = re.match(r'^version\s*=\s*"([^"]+)"', ln)
        if m and ver is None: ver = m.group(1)
    if name: yield name, ver, line

def npm_lock(rp, data):
    try: d = json.loads(data)
    except Exception: return
    for k, v in (d.get("packages") or {}).items():
        if not k or not isinstance(v, dict) or v.get("link"): continue
        name = v.get("name") or k.rsplit("node_modules/", 1)[-1]
        if v.get("version"): yield ("npm", name, v["version"], rp)
    def walk(deps):
        for name, v in (deps or {}).items():
            if isinstance(v, dict):
                if v.get("version"): yield ("npm", name, v["version"], rp)
                yield from walk(v.get("dependencies"))
    if not d.get("packages"):
        yield from walk(d.get("dependencies"))

PNPM = re.compile(r"""^\s{2,4}['"]?/?((?:@[^/@\s'"]+/)?[^@/\s:'"()]+)[@/](\d[^:('"\s]*)""")
def pnpm_lock(rp, text):
    for n, ln in enumerate(text.split("\n"), 1):
        m = PNPM.match(ln)
        if m: yield ("npm", m.group(1), m.group(2), "%s:%d" % (rp, n))

def yarn_lock(rp, text):
    names, line = [], 0
    for n, ln in enumerate(text.split("\n"), 1):
        if ln and not ln[0].isspace() and ln.rstrip().endswith(":") and not ln.startswith("#"):
            names, line = [], n
            for spec in ln.rstrip()[:-1].split(","):
                s = spec.strip().strip('"')
                if not s or s == "__metadata": continue
                i = s.find("@", 1) if s.startswith("@") else s.find("@")
                if i > 0: names.append(s[:i])
            continue
        m = re.match(r'^\s+version:?\s+"?([^"\s]+)"?', ln)
        if m and names:
            for nm in dict.fromkeys(names): yield ("npm", nm, m.group(1), "%s:%d" % (rp, line))
            names = []

BUN = re.compile(r'"((?:@[^/"]+/)?[^@"/]+)@(\d[^"]*)"')
def bun_lock(rp, text):
    for n, ln in enumerate(text.split("\n"), 1):
        for m in BUN.finditer(ln): yield ("npm", m.group(1), m.group(2), "%s:%d" % (rp, n))

REQ = re.compile(r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*(?:\[[^\]]*\])?\s*(===?\s*([^\s;#,]+)|[<>~!=]=?[^;#]*)?")
def requirements(rp, text):
    for n, ln in enumerate(text.split("\n"), 1):
        s = ln.strip()
        if not s or s.startswith(("#", "-", "git+", "http:", "https:", ".", "/")): continue
        m = REQ.match(s)
        if m: yield ("pypi", m.group(1), m.group(3), "%s:%d" % (rp, n))

def pipfile_lock(rp, data):
    try: d = json.loads(data)
    except Exception: return
    for sect in ("default", "develop"):
        for name, v in (d.get(sect) or {}).items():
            ver = (v.get("version") or "").lstrip("=") if isinstance(v, dict) else None
            yield ("pypi", name, ver or None, rp)

def toml_lock(eco):
    def f(rp, text):
        for name, ver, line in toml_packages(text): yield (eco, name, ver, "%s:%d" % (rp, line))
    return f

def go_sum(rp, text):
    for n, ln in enumerate(text.split("\n"), 1):
        p = ln.split()
        if len(p) >= 2 and not p[0].startswith("//"):
            v = p[1].replace("/go.mod", "")
            if p[0] not in ("require", "module", "go", ")", "(", "replace", "exclude", "toolchain"):
                yield ("go", p[0], v, "%s:%d" % (rp, n))

def gemfile_lock(rp, text):
    for n, ln in enumerate(text.split("\n"), 1):
        m = re.match(r"^    ([A-Za-z0-9_.-]+) \(([^)\s]+)\)", ln)
        if m: yield ("rubygems", m.group(1), m.group(2).split("-")[0], "%s:%d" % (rp, n))

def composer_lock(rp, data):
    try: d = json.loads(data)
    except Exception: return
    for sect in ("packages", "packages-dev"):
        for p in d.get(sect) or []:
            if p.get("name"): yield ("packagist", p["name"], str(p.get("version", "")).lstrip("v") or None, rp)

def nuget_lock(rp, data):
    try: d = json.loads(data)
    except Exception: return
    for fw in (d.get("dependencies") or {}).values():
        for name, v in (fw or {}).items():
            if isinstance(v, dict) and v.get("resolved"): yield ("nuget", name, v["resolved"], rp)

LOCKS = {
    "package-lock.json": ("json", npm_lock), "npm-shrinkwrap.json": ("json", npm_lock),
    "pnpm-lock.yaml": ("text", pnpm_lock), "yarn.lock": ("text", yarn_lock),
    "bun.lock": ("text", bun_lock),
    "poetry.lock": ("text", toml_lock("pypi")), "uv.lock": ("text", toml_lock("pypi")),
    "pdm.lock": ("text", toml_lock("pypi")), "pylock.toml": ("text", toml_lock("pypi")),
    "Pipfile.lock": ("json", pipfile_lock),
    "Cargo.lock": ("text", toml_lock("crates.io")),
    "go.sum": ("text", go_sum), "Gemfile.lock": ("text", gemfile_lock),
    "composer.lock": ("json", composer_lock), "packages.lock.json": ("json", nuget_lock),
}
def lock_kind(f):
    if f in LOCKS: return LOCKS[f]
    if re.match(r"^requirements.*\.txt$|^constraints.*\.txt$", f): return ("text", requirements)
    return None

PRUNE = {"node_modules", ".git", ".next", ".nuxt", ".turbo", ".svelte-kit", ".output",
         ".vercel", ".cache", "coverage", ".parcel-cache", ".yarn", "bower_components",
         "Pods", ".gradle", "__pycache__", "target", ".terraform", "vendor"}

def site_packages(env):
    seen = set()          # lib/ and Lib/ are one directory on macOS and Windows
    for sp in _site_packages(env):
        try: st = os.stat(sp); r = (st.st_dev, st.st_ino)
        except OSError: continue
        if r not in seen:
            seen.add(r); yield sp

def _site_packages(env):
    for pat in ("lib", "Lib", "lib64"):
        base = os.path.join(env, pat)
        if not os.path.isdir(base): continue
        if pat == "Lib" and os.path.isdir(os.path.join(base, "site-packages")):
            yield os.path.join(base, "site-packages")
        for d in sorted(os.listdir(base)):
            sp = os.path.join(base, d, "site-packages")
            if d.startswith("python") and os.path.isdir(sp): yield sp

def installed_python(sp):
    try: names = os.listdir(sp)
    except OSError: return
    for d in names:
        if d.endswith((".dist-info", ".egg-info")):
            meta = os.path.join(sp, d, "METADATA" if d.endswith(".dist-info") else "PKG-INFO")
            try:
                head = open(meta, errors="replace").read(4000)
            except OSError: continue
            n = re.search(r"^Name:\s*(.+)$", head, re.M); v = re.search(r"^Version:\s*(.+)$", head, re.M)
            if n: yield ("pypi", n.group(1).strip(), v.group(1).strip() if v else None, "installed in " + sp)

def installed_node(nm, budget=[20000]):
    stack = [nm]
    while stack and budget[0] > 0:
        d = stack.pop()
        try: ents = os.listdir(d)
        except OSError: continue
        for e in ents:
            p = os.path.join(d, e)
            if e.startswith("@") and os.path.isdir(p):
                stack.append(p); continue
            pj = os.path.join(p, "package.json")
            if e.startswith(".") or not os.path.isfile(pj): continue
            budget[0] -= 1
            try:
                j = json.load(open(pj))
                if j.get("name") and j.get("version"):
                    yield ("npm", j["name"], j["version"], "installed in " + p)
            except Exception: pass
            sub = os.path.join(p, "node_modules")
            if os.path.isdir(sub): stack.append(sub)

# A .pth file in site-packages runs its `import` lines at EVERY Python start —
# the LiteLLM 1.107.0 payload (Oct 2026) lived in one. Legitimate ones import
# a module and stop; a payload decodes, downloads or spawns.
PTHBAD = re.compile(r"exec\(|eval\(|b64decode|base64|subprocess|urllib|socket|os\.system|compile\(|marshal|zlib\.decompress|requests\.(get|post)|urlopen|popen", re.I)
PTH_OK = {"distutils-precedence.pth"}
def startup_files(sp):
    try: names = os.listdir(sp)
    except OSError: return
    for f in names:
        p = os.path.join(sp, f)
        if f.endswith(".pth") and f not in PTH_OK:
            try: lines = open(p, errors="replace").read(200000).split("\n")
            except OSError: continue
            for n, ln in enumerate(lines, 1):
                if ln.lstrip().startswith("import") and PTHBAD.search(ln):
                    yield ("startup", p, n, "a .pth file that decodes, downloads or spawns code at every Python start", ln.strip()[:120])
                    break
        elif f in ("sitecustomize.py", "usercustomize.py"):
            try: txt = open(p, errors="replace").read(400000)
            except OSError: continue
            m = PTHBAD.search(txt)
            if m:
                line = txt[:m.start()].count("\n") + 1
                yield ("startup", p, line, "%s runs at every Python start and decodes, downloads or spawns code" % f,
                       txt.split("\n")[line - 1].strip()[:120])

def find_locks(root):
    locks, envs, nms = [], [], []
    for dirpath, dirnames, filenames in os.walk(root):
        rel = os.path.relpath(dirpath, root)
        depth = 0 if rel == "." else rel.count(os.sep) + 1
        if "pyvenv.cfg" in filenames:
            envs.append(dirpath); dirnames[:] = []; continue
        if "node_modules" in dirnames: nms.append(os.path.join(dirpath, "node_modules"))
        dirnames[:] = [d for d in dirnames if d not in PRUNE and depth < 6 and not os.path.islink(os.path.join(dirpath, d))]
        for f in filenames:
            if lock_kind(f): locks.append(os.path.join(dirpath, f))
    return locks, envs, nms

def collect(root, installed, system, found=None):
    pkgs, startup = [], []
    locks, envs, nms = found or find_locks(root)
    for p in locks:
        k = lock_kind(os.path.basename(p)); rp = os.path.relpath(p, root)
        try:
            if os.path.getsize(p) > 64 * 1024 * 1024: continue
            raw = open(p, "rb").read()
        except OSError: continue
        text = raw.decode("utf-8", "replace")
        pkgs.extend(k[1](rp, text if k[0] == "text" else raw))
    if installed:
        for nm in nms: pkgs.extend(installed_node(nm))
        for env in envs:
            for sp in site_packages(env):
                pkgs.extend(installed_python(sp)); startup.extend(startup_files(sp))
    if system:
        for py in ("python3", "python"):
            try:
                # -S: do not run that interpreter's own .pth files to find them
                r = subprocess.run([py, "-I", "-S", "-c", "import site,sys,json;print(json.dumps(site.getsitepackages()+[site.getusersitepackages()]))"],
                                   capture_output=True, text=True, timeout=10)
                for sp in json.loads(r.stdout or "[]"):
                    if os.path.isdir(sp): pkgs.extend(installed_python(sp)); startup.extend(startup_files(sp))
            except Exception: pass
        for base in (os.path.expanduser("~/.local/pipx/venvs"), os.path.expanduser("~/.local/share/pipx/venvs")):
            if os.path.isdir(base):
                for v in os.listdir(base):
                    for sp in site_packages(os.path.join(base, v)):
                        pkgs.extend(installed_python(sp)); startup.extend(startup_files(sp))
        try:
            r = subprocess.run(["npm", "root", "-g"], capture_output=True, text=True, timeout=15)
            g = r.stdout.strip()
            if g and os.path.isdir(g): pkgs.extend(installed_node(g))
        except Exception: pass
        c2 = os.path.expanduser("~/.cargo/.crates2.json")
        try:
            for k in json.load(open(c2)).get("installs", {}):
                p = k.split()
                if len(p) >= 2: pkgs.append(("crates.io", p[0], p[1], "installed by cargo install"))
        except Exception: pass
    return pkgs, startup

def judge(pkgs, idx):
    seen, hits = set(), []
    for eco, name, ver, where in pkgs:
        key = (eco, norm(eco, name)); e = idx.get(key)
        if not e: continue
        m = matches(e[0], ver)
        file = where.rsplit(":", 1)[0] if re.search(r":\d+$", where) else where
        if m and (key, ver, file) not in seen:    # go.sum lists a version twice
            seen.add((key, ver, file)); hits.append((eco, name, ver or "", where, e[1], e[0]))
    return hits

def fp(rp, what, root):
    try: data = open(os.path.join(root, rp.split(":")[0]), "rb").read()
    except OSError: data = rp.encode()
    return hashlib.sha256(("%s\0%s\0%s" % (rp.split(":")[0], what, hashlib.sha256(data).hexdigest())).encode()).hexdigest()[:16]

if mode in ("scan", "gate"):
    root = os.path.realpath(args[0]); installed = "--installed" in args; system = "--system" in args
    allowf = next((a.split("=", 1)[1] for a in args if a.startswith("--allow=")), "")
    cachef = next((a.split("=", 1)[1] for a in args if a.startswith("--cache=")), "")
    found = find_locks(root)
    if mode == "gate" and not found[0]:
        sys.exit(0)                     # no lockfile: nothing for this check to read
    key = None
    if mode == "gate" and cachef:
        # A clean verdict holds until a lockfile, the list or an approval changes.
        src = [root]
        for p in sorted(found[0]):
            try: st = os.stat(p); src.append("%s %d %d" % (p, st.st_mtime_ns, st.st_size))
            except OSError: pass
        for f in (index, allowf):
            try: src.append(str(os.stat(f).st_mtime_ns))
            except (OSError, TypeError): pass
        key = "deps-" + hashlib.sha256("\n".join(src).encode()).hexdigest()[:24]
        try:
            if any(ln.split()[0] == key for ln in open(cachef) if ln.strip()):
                sys.exit(0)
        except OSError: pass
    pkgs, startup = collect(root, installed or system, system, found)
    want = {(e, norm(e, n)) for e, n, _, _ in pkgs}
    idx = load(want) if want else {}
    if idx is None:
        print("NOLIST"); sys.exit(4)
    hits = judge(pkgs, idx)
    if mode == "scan":
        for eco, name, ver, where, ids, spec in hits:
            # "-" for an empty field: bash's `read` collapses consecutive tabs,
            # so an empty column shifted every one after it.
            print("\t".join(["pkg", eco, name, ver or "-", where, ids or "-", "every version" if spec == "*" else "this version"]))
        for _, p, n, what, ex in startup:
            print("\t".join(["startup", "pypi", os.path.basename(p), "-", "%s:%d" % (p, n), what, ex or "-"]))
        sys.exit(1 if hits or startup else 0)
    # gate: the route check's format, so `snare gate allow` can approve one
    allowed = set()
    if allowf and os.path.exists(allowf):
        allowed = {ln.split()[0] for ln in open(allowf) if ln.strip() and not ln.startswith("#")}
    n = 0
    for eco, name, ver, where, ids, spec in hits:
        what = "%s %s%s is known malware (%s)" % (eco, name, ("@" + ver) if ver else "", ids.split(",")[0])
        rp = where.split(":")[0]; line = where.split(":")[1] if ":" in where else "0"
        f = fp(where, what, root)
        if f in allowed: continue
        print("\t".join([rp or "-", line, what, "%s — https://osv.dev/vulnerability/%s" % ("every version is malicious" if spec == "*" else "this exact version", ids.split(",")[0]), f]))
        n += 1
    if not n and key:
        try:
            old = [l for l in open(cachef)][-300:] if os.path.exists(cachef) else []
            with open(cachef + ".dtmp", "w") as fh:
                fh.writelines(old); fh.write("%s 0\n" % key)
            os.replace(cachef + ".dtmp", cachef)
        except OSError: pass
    sys.exit(1 if n else 0)

if mode == "gatefile":
    # One requirements or lock file named on a command (`pip install -r f`).
    path = os.path.realpath(args[0]); allowf = args[1] if len(args) > 1 else ""
    k = lock_kind(os.path.basename(path)) or ("text", requirements)
    try: raw = open(path, "rb").read(64 * 1024 * 1024)
    except OSError: sys.exit(0)
    root = os.path.dirname(path); rp = os.path.basename(path)
    pkgs = list(k[1](rp, raw.decode("utf-8", "replace") if k[0] == "text" else raw))
    idx = load({(e, norm(e, n)) for e, n, _, _ in pkgs}) if pkgs else {}
    if idx is None: sys.exit(4)
    allowed = {ln.split()[0] for ln in open(allowf) if ln.strip()} if allowf and os.path.exists(allowf) else set()
    n = 0
    for eco, name, ver, where, ids, spec in judge(pkgs, idx):
        what = "%s %s%s is known malware (%s)" % (eco, name, ("@" + ver) if ver else "", ids.split(",")[0])
        f = fp(where, what, root)
        if f in allowed: continue
        line = where.split(":")[1] if ":" in where else "0"
        print("  %s:%s — %s" % (path, line, what)); n += 1
    sys.exit(1 if n else 0)

if mode == "pkgs":
    # eco name version, repeated. Exit 1: known malware. Exit 5: some versions
    # of an UNPINNED package are malware — the caller resolves what would install.
    trip = [args[i:i + 3] for i in range(0, len(args) - 2, 3)]
    want = {(e, norm(e, n)) for e, n, _ in trip}
    idx = load(want)
    if idx is None: print("NOLIST"); sys.exit(4)
    rc = 0
    for eco, name, ver in trip:
        ver = "" if ver == "-" else ver
        e = idx.get((eco, norm(eco, name)))
        if not e: continue
        if eco == "crates.io" and exact(eco, ver): ver = ver.lstrip("= ")
        elif ver and not exact(eco, ver) and e[0] != "*":
            # a range or a tag: the caller resolves what it would install
            print("SOME\t%s\t%s\t%s\t%s\t%s" % (eco, name, ver, e[1], e[0])); rc = max(rc, 5) if rc != 1 else 1
            continue
        m = matches(e[0], ver)
        if m:
            print("BAD\t%s\t%s\t%s\t%s\t%s" % (eco, name, ver, e[1], "every version" if e[0] == "*" else "this version")); rc = 1
        elif m is None:
            print("SOME\t%s\t%s\t-\t%s\t%s" % (eco, name, e[1], e[0])); rc = max(rc, 5) if rc != 1 else 1
    sys.exit(rc)

if mode == "pick":
    # spec candidate... -> the newest candidate a PEP 440-style spec allows
    # (what pip would pick): comma-joined clauses of ==, !=, >=, <=, >, <, ~=.
    spec, cands = args[0], args[1:]
    def ok(v):
        for cl in [c.strip() for c in spec.split(",") if c.strip()]:
            m = re.match(r"^(~=|===|==|!=|>=|<=|>|<)\s*(.+)$", cl)
            if not m: return False
            op, w = m.groups(); a, b = vkey(v), vkey(w.rstrip(".*"))
            if op in ("==", "===") and not (a == b or (w.endswith(".*") and a[:len(b)] == b)): return False
            if op == "!=" and a == b: return False
            if op == ">=" and a < b: return False
            if op == "<=" and a > b: return False
            if op == ">" and a <= b: return False
            if op == "<" and a >= b: return False
            if op == "~=" and not (a >= b and a[:len(b) - 1] == b[:len(b) - 1]): return False
        return True
    pre = re.compile(r"(a|b|rc|dev|alpha|beta|pre)\d*", re.I)
    good = [c for c in cands if ok(c) and (pre.search(spec) or not pre.search(c))]
    if good: print(sorted(good, key=vkey)[-1]); sys.exit(0)
    sys.exit(1)

if mode == "quarantine":
    # Remove an installed Python package WITHOUT running that environment's
    # Python: `pip uninstall` would start it, and its .pth files — the payload
    # — would run first. Moves every file the package's RECORD lists (only
    # inside site-packages) and its dist-info into a quarantine directory.
    sp, name, ver, dest = args[0], args[1], args[2], args[3]
    sp = os.path.realpath(sp); n0 = pynorm(name)
    di = None
    for d in os.listdir(sp):
        if d.endswith(".dist-info"):
            base = d[:-len(".dist-info")]
            dn, _, dv = base.rpartition("-")
            if pynorm(dn) == n0 and (not ver or dv == ver): di = d; break
    if not di:
        print("no installed %s found in %s" % (name, sp)); sys.exit(1)
    files = [di]
    try:
        for ln in open(os.path.join(sp, di, "RECORD"), errors="replace"):
            rel = ln.split(",")[0].strip()
            if rel: files.append(rel)
    except OSError:
        pass
    import shutil
    moved = 0
    for rel in dict.fromkeys(files):
        src = os.path.realpath(os.path.join(sp, rel))
        if not (src == sp or src.startswith(sp + os.sep)) or not os.path.lexists(src): continue
        dst = os.path.join(dest, os.path.relpath(src, sp))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        try: shutil.move(src, dst); moved += 1
        except OSError: continue
        # the package's own directories, once emptied (never site-packages itself)
        d = os.path.dirname(src)
        while d != sp and d.startswith(sp + os.sep):
            try: os.rmdir(d)
            except OSError: break
            d = os.path.dirname(d)
    print("moved %d files to %s" % (moved, dest)); sys.exit(0)

if mode == "safe":
    # eco name candidate... -> the newest candidate that is not known-malicious
    eco, name, cands = args[0], args[1], args[2:]
    idx = load({(eco, norm(eco, name))}) or {}
    e = idx.get((eco, norm(eco, name)))
    ok = [c for c in cands if not e or not matches(e[0], c)]
    ok = [c for c in ok if not re.search(r"(alpha|beta|rc|dev|pre|canary|next)", c, re.I)] or ok
    if e and e[0] == "*": sys.exit(1)
    if ok:
        print(sorted(ok, key=vkey)[-1]); sys.exit(0)
    sys.exit(1)
PYDEPS
}

# ---------------------------------------------------------------- the gate's part
# Gate-format findings (path line what excerpt fingerprint) for a directory's
# lockfiles, so a false entry can be approved with `snare gate allow` like any
# other. Exit 0 clean, 1 findings, 4 no list on this machine.
_deps_gate_tree(){ # $1=dir $2=allow file $3=cache file (optional)
  [ -s "$INTEL_LIST" ] || return 4
  python3 -I -S -c "$(_deps_py)" gate "$INTEL_LIST" "$1" "--allow=${2:-}" ${3:+"--cache=$3"}
}

_deps_gate_file(){ # $1=requirements or lock file
  [ -s "$INTEL_LIST" ] || return 0
  python3 -I -S -c "$(_deps_py)" gatefile "$INTEL_LIST" "$1" "$GATE_ALLOW"
}

# What would this install line actually install — no version, a range, or a
# tag? Asked of the registry the install itself was about to contact, the way
# the package manager resolves it. Empty when it cannot tell.
_deps_resolve_latest(){ # $1=eco $2=name $3=spec (may be empty)
  case "$1" in
    npm)
      # As npm picks: the `latest` tag when it satisfies the spec, else the
      # highest version that does. (Highest-only let a malicious version
      # tagged `latest` inside the range be misjudged.)
      local latest sat; latest="$(npm view "$2" dist-tags.latest 2>/dev/null | tail -1)"
      [ -z "${3:-}" ] && { echo "$latest"; return 0; }
      sat="$(npm view "$2@$3" version --json 2>/dev/null)" || return 0
      printf '%s' "$sat" | python3 -I -c '
import json, sys
d = json.load(sys.stdin); v = d if isinstance(d, list) else [d]
l = sys.argv[1]
if l in v: print(l)
elif v: print(v[-1])' "$latest" 2>/dev/null ;;
    pypi)
      local rel; rel="$(curl -fsS --max-time 8 "https://pypi.org/pypi/$2/json" 2>/dev/null)" || return 0
      if [ -z "${3:-}" ]; then
        printf '%s' "$rel" | python3 -I -c 'import json,sys;print(json.load(sys.stdin)["info"]["version"])' 2>/dev/null
      else
        # shellcheck disable=SC2046
        python3 -I -S -c "$(_deps_py)" pick - "$3" $(printf '%s' "$rel" | python3 -I -c 'import json,sys;d=json.load(sys.stdin);print(" ".join(k for k,f in d["releases"].items() if f and not all(x.get("yanked") for x in f)))' 2>/dev/null) 2>/dev/null
      fi ;;
    crates.io)
      [ -z "${3:-}" ] || return 0      # a cargo range: pin it instead
      curl -fsS --max-time 8 -A "snare (github.com/nexlabz/snare)" "https://crates.io/api/v1/crates/$2" 2>/dev/null \
        | python3 -I -c 'import json,sys;print(json.load(sys.stdin)["crate"]["max_stable_version"])' 2>/dev/null ;;
  esac
}

# Check packages named on an install command line. Prints a verdict, exit 0
# clean, 1 malware, 2 could not tell.
_deps_gate_pkgs(){ # eco name version, repeated
  [ -s "$INTEL_LIST" ] || return 0     # no list yet: the other checks still run; doctor says so
  local out rc kind eco name ver ids spec latest worst=0
  out="$(python3 -I -S -c "$(_deps_py)" pkgs "$INTEL_LIST" "$@" 2>/dev/null)"; rc=$?
  [ "$rc" = 0 ] && return 0
  while IFS="$(printf '\t')" read -r kind eco name ver ids spec; do
    [ "$ver" = - ] && ver=""
    case "$kind" in
      BAD)  echo "  $name${ver:+@$ver} ($eco) is known malware — ${spec}: https://osv.dev/vulnerability/${ids%%,*}"
            worst=1 ;;
      SOME) latest="$(_deps_resolve_latest "$eco" "$name" "$ver")"
            if [ -n "$latest" ]; then
              if python3 -I -S -c "$(_deps_py)" pkgs "$INTEL_LIST" "$eco" "$name" "$latest" >/dev/null 2>&1; then
                : # the version that would install is not a bad one
              else
                echo "  $name ($eco): the version that would install now, $latest, is known malware — https://osv.dev/vulnerability/${ids%%,*}"
                worst=1
              fi
            else
              echo "  $name${ver:+@$ver} ($eco) has known-malicious versions, and snare could not tell which"
              echo "    version this would install. Pin an exact version that is not one of them."
              [ "$worst" = 1 ] || worst=2
            fi ;;
    esac
  done <<< "$out"
  return "$worst"
}

# ---------------------------------------------------------------- snare deps
cmd_deps(){
  local sub="${1:-scan}"
  case "$sub" in scan|check|fix|update|refresh|status) shift ;; *) sub=scan ;; esac
  case "$sub" in
    scan|check) _deps_scan "$@" ;;
    fix)        _deps_fix "$@" ;;
    update|refresh)
      if snare_intel_refresh; then _deps_status; else red "  could not download the known-malware list"; return 1; fi ;;
    status)     _deps_status ;;
    *) echo "usage: snare deps [scan [dir] [--system]|fix [dir] [--system]|update|status]"; return 2 ;;
  esac
}

_deps_status(){
  local age; if age="$(snare_intel_age)"; then
    local n; n="$(python3 -I -c 'import json,sys;m=json.load(open(sys.argv[1]));print("%d entries — %s" % (m["entries"], ", ".join("%s %d" % kv for kv in sorted(m["by_ecosystem"].items(), key=lambda x:-x[1]))))' "$INTEL_META" 2>/dev/null)"
    grn "  known-malware list: updated $((age / 3600))h ago — ${n:-?}"
  else
    ylw "  known-malware list: not downloaded yet — run: snare deps update"
  fi
}

_deps_need_list(){
  local age; age="$(snare_intel_age)" || age=999999999
  if [ "$age" -ge "$INTEL_MAX_AGE" ]; then
    dim "  updating the known-malware list…"
    snare_intel_refresh || { [ -s "$INTEL_LIST" ] && ylw "  could not update it; using the copy from $((age / 3600))h ago"; }
  fi
  [ -s "$INTEL_LIST" ] || { red "  no known-malware list on this machine and it could not be downloaded."; return 1; }
}

# $1 dir, then --system. Prints findings, exit 1 when there are any.
_deps_scan(){
  local dir="." system=""
  for a in "$@"; do case "$a" in --system) system=--system ;; *) dir="$a" ;; esac; done
  _deps_need_list || return 2
  hdr "snare deps — known-malicious packages${system:+ (this machine too)}"
  local out rc
  out="$(python3 -I -S -c "$(_deps_py)" scan "$INTEL_LIST" "$dir" --installed $system 2>/dev/null)"; rc=$?
  if [ "$rc" = 0 ]; then
    grn "  none found in $(cd "$dir" && pwd)${system:+, its environments, or the global installs on this machine}"
    dim "  (lockfiles and installed packages for npm, pnpm, yarn, bun, PyPI, crates.io, Go, RubyGems, Packagist, NuGet)"
    return 0
  fi
  local kind eco name ver where ids spec n=0
  while IFS="$(printf '\t')" read -r kind eco name ver where ids spec; do
    [ -z "$kind" ] && continue; n=$((n + 1)); [ "$ver" = - ] && ver=""; [ "$spec" = - ] && spec=""
    if [ "$kind" = startup ]; then
      red "  $n. $where — $ids"; [ -n "$spec" ] && echo "       ↳ $spec"
    else
      red "  $n. $name${ver:+@$ver} ($eco) — known malware, $spec"
      echo "       where: $where"
      echo "       details: https://osv.dev/vulnerability/${ids%%,*}"
    fi
  done <<< "$out"
  echo
  echo "  Clean up (asks about each one):  snare deps fix ${dir}${system:+ --system}"
  dim  "  If anything was INSTALLED, it may already have run. Credentials on this machine"
  dim  "  are what this kind of package steals: run 'snare rotate'."
  return 1
}

# The newest version the registry has that is not known-malicious.
_deps_safe_version(){ # $1=eco $2=name
  local cands
  case "$1" in
    npm)  cands="$(npm view "$2" versions --json 2>/dev/null | python3 -I -c 'import json,sys;v=json.load(sys.stdin);print(" ".join(v if isinstance(v,list) else [v]))' 2>/dev/null)" ;;
    pypi) cands="$(curl -fsS --max-time 10 "https://pypi.org/pypi/$2/json" 2>/dev/null | python3 -I -c 'import json,sys;d=json.load(sys.stdin);print(" ".join(k for k,f in d["releases"].items() if f and not all(x.get("yanked") for x in f)))' 2>/dev/null)" ;;
    *) return 1 ;;
  esac
  [ -n "$cands" ] || return 1
  # shellcheck disable=SC2086
  python3 -I -S -c "$(_deps_py)" safe "$INTEL_LIST" "$1" "$2" $cands 2>/dev/null
}

_deps_fix(){
  local dir="." system=""
  for a in "$@"; do case "$a" in --system) system=--system ;; *) dir="$a" ;; esac; done
  _gate_person_only "snare deps fix" || return 1
  _deps_need_list || return 2
  dir="$(cd "$dir" && pwd -P)" || return 2
  local out; out="$(python3 -I -S -c "$(_deps_py)" scan "$INTEL_LIST" "$dir" --installed $system 2>/dev/null)"
  [ -n "$out" ] || { grn "  nothing to fix — no known-malicious packages found"; return 0; }
  hdr "snare deps fix — $dir"
  dim "  For each one: remove it, or replace it with the newest version that is not"
  dim "  known-malicious. Installs run with scripts OFF (npm --ignore-scripts, pip"
  dim "  --only-binary), so a replacement cannot run code while it installs."
  local kind eco name ver where ids spec ans safe n=0 ran=0 installed=0
  while IFS="$(printf '\t')" read -r kind eco name ver where ids spec <&3; do
    [ -z "$kind" ] && continue; n=$((n + 1)); echo
    [ "$ver" = - ] && ver=""
    if [ "$kind" = startup ]; then
      [ "$spec" = - ] && spec=""
      red "  $n. $where — $ids"; [ -n "$spec" ] && echo "       ↳ $spec"
      local f="${where%:*}"
      echo "     d  move it aside (to $SNARE_BACKUPS) — Python stops running it at once"
      echo "     s  skip"
      printf '     Choose [d/S] '; IFS= read -r ans
      if [ "$ans" = d ] || [ "$ans" = D ]; then
        mkdir -p "$SNARE_BACKUPS" 2>/dev/null
        mv "$f" "$SNARE_BACKUPS/$(basename "$f").$(date +%s).quarantined" && { grn "     moved aside"; installed=1; ran=1; }
      fi
      continue
    fi
    red "  $n. $name${ver:+@$ver} ($eco) — known malware, $spec"
    echo "       where: $where   details: https://osv.dev/vulnerability/${ids%%,*}"
    case "$where" in "installed in"*) installed=1 ;; esac
    safe=""
    [ "$spec" = "this version" ] && safe="$(_deps_safe_version "$eco" "$name")"
    local cmds=()
    case "$eco" in
      npm)
        local pm=npm; [ -f "$dir/pnpm-lock.yaml" ] && pm=pnpm; [ -f "$dir/yarn.lock" ] && pm=yarn
        local rm_=("$pm" remove "$name"); [ "$pm" = npm ] && rm_=(npm uninstall --ignore-scripts "$name")
        if [ -n "$safe" ]; then
          case "$pm" in npm) cmds=(npm install --ignore-scripts "$name@$safe") ;; pnpm) cmds=(pnpm add --ignore-scripts "$name@$safe") ;; yarn) cmds=(yarn add --ignore-scripts "$name@$safe") ;; esac
        fi ;;
      pypi)
        local rm_=()
        case "$where" in
          "installed in "*)
            # Never `pip uninstall`: that starts the environment's Python, and
            # the package's .pth payload runs first. snare moves its files
            # out itself, without running anything from that environment.
            local sp="${where#installed in }"
            rm_=(python3 -I -S -c "$(_deps_py)" quarantine - "$sp" "$name" "$ver" "$SNARE_BACKUPS/quarantine-$name-$(date +%s)")
            [ -n "$safe" ] && dim "     afterwards, to put a clean version back:  pip install --only-binary :all: '$name==$safe'" ;;
          *)
            echo "     fix: change the pin in ${where%%:*} to a version that is not listed${safe:+ — e.g. $name==$safe}"
            continue ;;
        esac ;;
      *) local rm_=() ;;
    esac
    if [ "${#rm_[@]}" -eq 0 ]; then
      case "$eco" in
        crates.io) echo "     fix: remove it from Cargo.toml (or pin another version), then: cargo update -p $name" ;;
        go)        echo "     fix: go get $name@<a version not listed>   or drop the import, then: go mod tidy" ;;
        rubygems)  echo "     fix: remove it from the Gemfile (or pin another version), then: bundle update $name" ;;
        packagist) echo "     fix: composer remove $name   (or require another version)" ;;
        nuget)     echo "     fix: dotnet remove package $name   (or pin another version)" ;;
      esac
      continue
    fi
    if [ -n "$safe" ] && [ "${#cmds[@]}" -gt 0 ]; then
      echo "     u  replace it with $name@$safe, the newest version that is not known-malicious"
    elif [ "$spec" = "every version" ]; then
      dim "     every version of $name is malicious. If you meant a package with a similar"
      dim "     name, check the spelling — a lookalike name is how these get installed."
    fi
    if [ "$eco" = pypi ]; then echo "     r  remove it — snare moves its files to quarantine, running nothing from that environment"
    else echo "     r  remove it"; fi
    echo "     s  skip"
    local uopt=""; [ -n "$safe" ] && [ "${#cmds[@]}" -gt 0 ] && uopt="u/"
    printf '     Choose [%sr/S] ' "$uopt"; IFS= read -r ans
    case "$ans" in
      u|U) [ -n "$uopt" ] || { echo "     no replacement offered here"; continue; }
           echo "     running: ${cmds[*]}"; ( cd "$dir" && "${cmds[@]}" ) 2>&1 | tail -3 | sed 's/^/       /'; ran=1 ;;
      r|R) echo "     running: ${rm_[*]}"; ( cd "$dir" && "${rm_[@]}" ) 2>&1 | tail -3 | sed 's/^/       /'; ran=1 ;;
      *)   dim "     skipped — still present" ;;
    esac
  done 3<<< "$out"
  echo
  if [ "$ran" = 1 ]; then
    dim "  Checking again…"
    python3 -I -S -c "$(_deps_py)" scan "$INTEL_LIST" "$dir" --installed $system >/dev/null 2>&1 \
      && grn "  clean now" || ylw "  some are still present — run 'snare deps scan' to see which"
  fi
  if [ "$installed" = 1 ]; then
    red "  Something malicious was INSTALLED here, so it may already have run."
    red "  Rotate the credentials on this machine next:  snare rotate"
  fi
}
