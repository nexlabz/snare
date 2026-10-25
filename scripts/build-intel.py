#!/usr/bin/env python3
"""build-intel.py — condense OpenSSF's malicious-packages database into the
one small file every snare downloads.

    build-intel.py <malicious-packages checkout> <out dir>

Writes:
  malicious.tsv.gz   ecosystem <TAB> name <TAB> versions <TAB> advisory id
                     versions: "*" (every version), a comma list, or
                     R:<introduced>:<fixed> ranges joined by "|"
  intel.json         when, from which commit, counts, and the sha256 of the
                     list, so a client can tell a whole download from a cut one

Every snare downloads the same file and matches it against its own machine.
That is the privacy property: nobody's package list is ever sent anywhere.
"""
import gzip, hashlib, json, os, re, subprocess, sys, time

src, out = sys.argv[1], sys.argv[2]
base = os.path.join(src, "osv", "malicious")
ECO = {"npm": "npm", "pypi": "pypi", "crates.io": "crates.io", "go": "go",
       "rubygems": "rubygems", "packagist": "packagist", "nuget": "nuget",
       "maven": "maven"}

def norm(eco, name):
    if eco == "pypi":
        return re.sub(r"[-_.]+", "-", name).lower()
    if eco in ("npm", "crates.io", "nuget", "packagist", "rubygems"):
        return name.lower()
    return name

rows, counts, skipped = {}, {}, 0
for dirpath, _, files in os.walk(base):
    for f in files:
        if not f.endswith(".json"):
            continue
        try:
            d = json.load(open(os.path.join(dirpath, f)))
        except Exception:
            skipped += 1; continue
        if d.get("withdrawn"):          # a retracted report is not malware
            continue
        for aff in d.get("affected", []):
            pkg = aff.get("package", {})
            eco = ECO.get(str(pkg.get("ecosystem", "")).lower())
            name = pkg.get("name")
            if not eco or not name:
                continue
            spec = set(aff.get("versions") or [])
            for r in aff.get("ranges") or []:
                intro, fixed = None, ""
                for ev in r.get("events", []):
                    if "introduced" in ev:
                        intro = ev["introduced"]
                    elif "fixed" in ev or "last_affected" in ev:
                        fixed = ev.get("fixed") or ("<=" + ev["last_affected"])
                if intro is None:
                    continue
                if intro in ("0", "") and not fixed:
                    spec.add("*")
                else:
                    spec.add("R:%s:%s" % (intro, fixed))
            if not spec:
                spec.add("*")
            key = (eco, norm(eco, name))
            e = rows.setdefault(key, [set(), set()])
            e[0] |= spec; e[1].add(d.get("id", ""))

lines = []
for (eco, name), (spec, ids) in sorted(rows.items()):
    if "*" in spec:
        v = "*"
    else:
        plain = sorted(s for s in spec if not s.startswith("R:"))
        ranges = sorted(s for s in spec if s.startswith("R:"))
        v = ",".join(plain) + ("|" if plain and ranges else "") + "|".join(ranges)
    lines.append("%s\t%s\t%s\t%s\n" % (eco, name.replace("\t", " "), v, ",".join(sorted(i for i in ids if i))[:200]))
    counts[eco] = counts.get(eco, 0) + 1

os.makedirs(out, exist_ok=True)
body = "".join(lines).encode()
with gzip.GzipFile(os.path.join(out, "malicious.tsv.gz"), "wb", mtime=0) as g:
    g.write(body)
gz = open(os.path.join(out, "malicious.tsv.gz"), "rb").read()
try:
    commit = subprocess.run(["git", "-C", src, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
except Exception:
    commit = ""
json.dump({"generated": int(time.time()), "source": "github.com/ossf/malicious-packages",
           "source_commit": commit, "entries": len(lines), "by_ecosystem": counts,
           "unreadable": skipped, "sha256": hashlib.sha256(gz).hexdigest(), "format": 1},
          open(os.path.join(out, "intel.json"), "w"), indent=1)
print("wrote %d entries (%s), %d bytes gzipped" % (len(lines), counts, len(gz)))
