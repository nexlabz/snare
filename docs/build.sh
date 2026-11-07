#!/usr/bin/env bash
# build.sh — build the site from the fragments in src/.
#
# assemble.py does the pages (a short home, long reads with a progress rail,
# and ordinary pages; see its docstring). This script adds the sitemap,
# robots.txt and llms.txt.
set -euo pipefail
cd "$(dirname "$0")"

SITE="https://nexlabz.github.io/snare/"
REPO="https://github.com/nexlabz/snare"
VERSION="$(sed -n 's/^## \[\([0-9.]*\)\].*/\1/p' ../CHANGELOG.md | head -1)"
[ -n "$VERSION" ] || { echo "could not read version from ../CHANGELOG.md" >&2; exit 1; }

python3 assemble.py "$SITE" "$REPO" "$VERSION"

# ---- sitemap + robots ----
# One URL per page. commands.html is a noindex stub; it lives in docs.html now.
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
  for page in index.html attack.html check.html infected.html install.html docs.html changelog.html security.html community.html; do
    [ -f "$page" ] || continue
    case "$page" in
      index.html) loc="$SITE"; pri="1.0" ;;
      check.html|infected.html|install.html|attack.html) loc="$SITE$page"; pri="0.9" ;;
      docs.html) loc="$SITE$page"; pri="0.8" ;;
      *) loc="$SITE$page"; pri="0.6" ;;
    esac
    lm="$(date -u -r "$page" '+%Y-%m-%d' 2>/dev/null || date -u '+%Y-%m-%d')"
    printf '  <url><loc>%s</loc><lastmod>%s</lastmod><priority>%s</priority></url>
' "$loc" "$lm" "$pri"
  done
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

## Pages

- [Home](${SITE}): the problem, what snare does, install
- [The attack](${SITE}attack.html): how it gets in, why npm audit misses it
- [Check your machine](${SITE}check.html): seven checks, nothing to install
- [If you are infected](${SITE}infected.html): the response walkthrough
- [Install](${SITE}install.html): every platform, plus a prompt for AI assistants
- [Docs](${SITE}docs.html): how snare works, and the full command reference
- [Changelog](${SITE}changelog.html): every release, and what was broken before it
- [Report a bug](${SITE}security.html): false clean results wanted most of all
- [Community](${SITE}community.html): field reports and the open questions
- [Source](${REPO})
LLMS
} > llms.txt

echo "built pages + sitemap.xml, robots.txt, llms.txt (v$VERSION)"
