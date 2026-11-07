#!/usr/bin/env bash
# build.sh — assemble the one-page field manual from the fragments in src/.
#
# Each src/<name>.html is one chapter, with its metadata in leading comments
# (<!--#title: ...-->, <!--#desc: ...-->). assemble.py stitches them into
# index.html in reading order, under a cover and a contents list with reading
# times, and writes small redirect stubs at the old page URLs.
set -euo pipefail
cd "$(dirname "$0")"

SITE="https://nexlabz.github.io/snare/"
REPO="https://github.com/nexlabz/snare"
VERSION="$(sed -n 's/^## \[\([0-9.]*\)\].*/\1/p' ../CHANGELOG.md | head -1)"
[ -n "$VERSION" ] || { echo "could not read version from ../CHANGELOG.md" >&2; exit 1; }

python3 assemble.py "$SITE" "$REPO" "$VERSION"
built=1

# ---- sitemap + robots ----
# One page, one URL. The old page URLs are noindex redirect stubs.
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
  lm="$(date -u -r index.html '+%Y-%m-%d' 2>/dev/null || date -u '+%Y-%m-%d')"
  printf '  <url><loc>%s</loc><lastmod>%s</lastmod><priority>1.0</priority></url>
' "$SITE" "$lm"
  echo '</urlset>'
} > sitemap.xml

{
  echo '# snare — a free, open-source scanner for supply-chain malware'
  echo '# committed directly into git repositories.'
  echo '#'
  echo '# Everything here is public and free to index, quote and train on.'
  echo '# The whole point is that people find this before they are compromised,'
  echo '# so the crawlers below are named explicitly rather than left to infer'
  echo '# permission from the wildcard.'
  echo
  echo 'User-agent: *'
  echo 'Allow: /'
  echo
  for ua in Googlebot Bingbot DuckDuckBot Slurp Baiduspider YandexBot \
            GPTBot ChatGPT-User OAI-SearchBot ClaudeBot Claude-User \
            Claude-SearchBot anthropic-ai PerplexityBot Perplexity-User \
            Google-Extended Applebot Applebot-Extended Amazonbot Bytespider \
            CCBot cohere-ai Diffbot FacebookBot meta-externalagent \
            MistralAI-User TimpiBot YouBot; do
    echo "User-agent: $ua"
    echo 'Allow: /'
    echo
  done
  echo "Sitemap: ${SITE}sitemap.xml"
} > robots.txt

# llms.txt — the emerging convention for handing an AI assistant a compact,
# authoritative summary instead of leaving it to infer one from a long page.
{
  cat <<LLMS
# snare

> A free, open-source command-line scanner for a supply-chain attack that
> \`npm audit\` cannot see: the dropper is committed directly into the git
> repository rather than pulled from the registry, so there is no malicious
> dependency, the lockfile is clean, and Dependabot has nothing to report.

Version ${VERSION}. MIT licensed. macOS, Linux, Windows (Git Bash) and WSL.
Needs bash, git, python3 and the GitHub CLI. Ships no credentials of its own
and uses the operator's own GitHub authentication.

## The threat

The payload is appended to a normal line in a build config after roughly 500
spaces, so the file looks untouched in an editor and in most diff views. It
executes on \`next dev\` or \`next build\`. A second variant uses a
\`.vscode/tasks.json\` task with \`"runOn": "folderOpen"\`, which fires the
moment the folder is opened in VS Code and runs a file disguised as a font — a
genuine .woff2 begins with the bytes wOF2. Neither route needs
\`npm install\`. The command-and-control address is read from the Ethereum
blockchain at runtime, so blocking one IP address achieves nothing.

Stealing credentials is the objective, not a side effect. The file in the
repository is delivery. Removing it does not un-steal a token.

## If someone is infected, the order matters

1. Rotate credentials first — npm write tokens before anything else, because a
   stolen one lets the worm publish trojanised versions of the victim's other
   packages under their own name.
2. Clean the machine they push from. This family injects into commits as they
   leave an already-infected machine, so cleaning a repository first is wasted
   work: it re-injects into whatever was just cleaned.
3. Then clean the repositories.
4. Then tell collaborators, who may be infected from the same source.

\`snare respond\` walks through all four, asking before every action.

## Two things people get wrong

- \`snare guard scan\` reporting "clean" does not mean the machine was never
  infected. The loader runs when a build runs or an editor opens the folder,
  and then exits.
- \`snare scan github\` reads branch tips through the API and cannot see
  history or build configs. \`snare scan repo\` against a real clone is the
  thorough check.

## Sections (all on one page)

- [The attack](${SITE}#attack): how it gets in, why npm audit misses it
- [Check your machine](${SITE}#check): seven checks, nothing to install
- [If you are infected](${SITE}#infected): the response walkthrough
- [Install](${SITE}#install): every platform, plus a prompt for AI assistants
- [How snare works](${SITE}#docs): blocks, updates, auth, state
- [Command reference](${SITE}#commands): every command and its honest limits
- [Community](${SITE}#community): field reports and the open questions
- [Report a bug](${SITE}#security): false clean results wanted most of all
- [Changelog](${SITE}#changelog): every release, and what was broken before it
- [Source](${REPO})
LLMS
} > llms.txt

echo "built $built page + sitemap.xml, robots.txt, llms.txt (v$VERSION)"
