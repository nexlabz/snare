# shellcheck shell=bash
# update.sh — keep snare current. Closes #4.
#
# Users clone snare once and never again. Four false-clean defects shipped
# this way, so an update path is a security feature, not a convenience.

# Version string of the checkout at $1 (default: SNARE_ROOT), without sourcing it.
snare_version_at(){
  local d="${1:-$SNARE_ROOT}"
  grep -m1 '^SNARE_VERSION=' "$d/bin/snare" 2>/dev/null | cut -d'"' -f2
}

# Remote HEAD version, via the raw file. Empty on any failure — never fatal.
snare_remote_version(){
  local url="https://raw.githubusercontent.com/nexlabz/snare/main/bin/snare"
  curl -fsSL --max-time 10 "$url" 2>/dev/null \
    | grep -m1 '^SNARE_VERSION=' | cut -d'"' -f2
}

# Is $1 strictly newer than $2? Used so an OLDER remote never triggers an
# "update available" nudge — comparing for inequality once told a 1.1.0 user
# that 1.0.0 was newer.
ver_gt(){
  [ "$1" = "$2" ] && return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]
}

# How many commits is this checkout behind its upstream? Empty if unknown.
# Version strings alone are not enough: 1.0.0 stood still for 33 commits, so
# 'update --check' told people carrying known-broken code that they were up to
# date. Commit distance is the honest signal between releases.
snare_commits_behind(){
  [ -d "$SNARE_ROOT/.git" ] || return 1
  # Always against main: that is where releases land and what `snare update`
  # moves to. Comparing against the checkout's own branch once let a work
  # branch report "up to date" while the passive notice said "behind".
  git -C "$SNARE_ROOT" fetch --quiet origin main 2>/dev/null || return 1
  git -C "$SNARE_ROOT" rev-list --count "HEAD..origin/main" 2>/dev/null
}

# The repository moved to the nexlabz organisation. GitHub redirects the old
# path, so clones keep working and nothing looks broken — but a redirect holds
# only while no repository sits at that name. Whoever creates one there owns
# the update channel of a malware scanner: they decide what version you are
# told you are on, and what `snare update` pulls.
#
# So this runs wherever snare talks to its own remote, not only in
# `cmd_update` — the refresh that feeds the "you are behind" notice reaches the
# network first, and a notice sourced from a hijacked remote is worse than no
# notice at all.
#
# Matched case-insensitively, because GitHub treats owner and repository names
# that way and `git clone github.com/avioflagos/snare` produces a remote that
# works and would not match a case-sensitive glob.
#
# $1 = quiet (no output); anything else announces the change.
snare_fix_stale_remote(){
  [ -d "$SNARE_ROOT/.git" ] || return 0
  local ru lower
  ru="$(git -C "$SNARE_ROOT" remote get-url origin 2>/dev/null)" || return 0
  [ -n "$ru" ] || return 0
  lower="$(printf '%s' "$ru" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *avioflagos/snare*) ;;
    *) return 0 ;;
  esac
  git -C "$SNARE_ROOT" remote set-url origin \
    "https://github.com/nexlabz/snare.git" 2>/dev/null || return 0
  [ "${1:-}" = quiet ] && return 0
  ylw "  the repository moved; origin repointed to github.com/nexlabz/snare"
  dim "  (the old path only redirects while no repository sits at that name)"
  return 0
}

# Cheap, quiet check used by `snare version`. Prints a nudge or nothing.
snare_update_hint(){
  # Prefer the cache. `snare version` used to run a live git fetch here, which
  # made a command that prints one line take about five seconds on a slow link.
  # `update --check` still does the live check, because there waiting is the
  # point.
  if _snare_update_cache_current; then
    local cb; cb="$(grep -m1 '^behind=' "$UPDATE_CACHE" 2>/dev/null | cut -d= -f2)"
    if [ -n "$cb" ] && [ "$cb" -gt 0 ] 2>/dev/null; then
      ylw "  $cb commit(s) behind — run: snare update"
      return 0
    fi
    [ -n "$cb" ] && return 0
  fi
  local behind; behind="$(snare_commits_behind 2>/dev/null)"
  # Keep what the live check learned, so the next command need not repeat it.
  [ -n "$behind" ] && _snare_update_write "$behind" ""
  if [ -n "$behind" ] && [ "$behind" -gt 0 ] 2>/dev/null; then
    ylw "  $behind commit(s) behind — run: snare update"
    return 0
  fi
  [ -n "$behind" ] && return 0
  local r; r="$(snare_remote_version)"
  [ -z "$r" ] && return 0
  ver_gt "$r" "$SNARE_VERSION" || return 0
  ylw "  a newer version is available: $r (you have $SNARE_VERSION)"
  dim "  run: snare update"
}

# ---------------------------------------------------------------- passive nudge
#
# `snare update --check` only helps someone who already suspects they are
# behind. The people who most need the fixes are the ones who cloned once and
# never thought about it again — several defects made the scanner report clean
# on infected repositories, and a clean result is exactly what stops you
# looking further.
#
# So every command surfaces it, subject to three rules:
#   - it must never block or slow the command down, so the network check runs
#     detached and only a CACHED answer is read on the hot path;
#   - it must be quiet, so it prints one line and at most once a day;
#   - it must send nothing. The check is a git ls-remote against a public
#     repository — no identifiers, no telemetry, no phoning home.
# SNARE_NO_UPDATE_CHECK=1 turns it off entirely.
UPDATE_CACHE="$SNARE_HOME/update-state"

# Modification time in epoch seconds. GNU stat first: on Linux `stat -f` means
# "filesystem", prints text and then fails.
_snare_mtime(){ stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# Refresh the cache. Runs detached; never writes to the terminal.
snare_update_refresh(){
  local remote local_sha behind="" rv=""
  snare_fix_stale_remote quiet
  # A zip or tarball install has no .git, so commit distance does not exist —
  # and this function used to return here, which meant those users were never
  # told anything at all, ever. The version in the remote's bin/snare is the
  # one signal that works without a repository, so it is recorded either way.
  rv="$(snare_remote_version 2>/dev/null)"
  if [ ! -d "$SNARE_ROOT/.git" ]; then
    _snare_update_write "" "$rv"; return 0
  fi
  remote="$(git -C "$SNARE_ROOT" ls-remote origin HEAD 2>/dev/null | cut -f1)"
  [ -z "$remote" ] && { _snare_update_write "" "$rv"; return 0; }
  local_sha="$(git -C "$SNARE_ROOT" rev-parse HEAD 2>/dev/null)"
  if [ "$remote" = "$local_sha" ]; then
    behind=0
  else
    # Different tip. Count how far behind, fetching quietly; if the count is
    # not obtainable, record 1 so the nudge still appears — being told to check
    # when you are current is a smaller harm than never being told at all.
    git -C "$SNARE_ROOT" fetch --quiet origin main 2>/dev/null
    behind="$(git -C "$SNARE_ROOT" rev-list --count HEAD..origin/main 2>/dev/null)"
    [ -z "$behind" ] && behind=1
  fi
  _snare_update_write "$behind" "$rv"
  rm -f "$SNARE_HOME/.update-refreshing" 2>/dev/null
  [ "${behind:-0}" -gt 0 ] 2>/dev/null && _snare_auto_update
  return 0
}

# The commit this install is on; empty without a repository.
_snare_head(){ git -C "$SNARE_ROOT" rev-parse HEAD 2>/dev/null; }

# Does the cached answer describe THIS install? It is a statement about one
# commit. Once the install moves (snare update, a git pull, a reinstall), it
# is about something that no longer exists: the cache once kept telling
# people who had just updated that they were "1 commit(s) behind", for days,
# and where the daily refresh never ran (no terminal, as under a coding
# agent) for good. A cache from before this field existed is not trusted.
_snare_update_cache_current(){
  [ -f "$UPDATE_CACHE" ] || return 1
  local h v
  h="$(grep -m1 '^head=' "$UPDATE_CACHE" 2>/dev/null | cut -d= -f2)"
  v="$(grep -m1 '^version=' "$UPDATE_CACHE" 2>/dev/null | cut -d= -f2)"
  [ "$v" = "$SNARE_VERSION" ] || return 1
  [ "$h" = "$(_snare_head)" ]
}

# One writer, so every path above leaves a usable cache behind.
_snare_update_write(){
  mkdir -p "$SNARE_HOME" 2>/dev/null
  printf 'checked=%s\nbehind=%s\nremote_version=%s\nhead=%s\nversion=%s\n' \
    "$(date +%s)" "${1:-}" "${2:-}" "$(_snare_head)" "$SNARE_VERSION" > "$UPDATE_CACHE.tmp" 2>/dev/null \
    && mv "$UPDATE_CACHE.tmp" "$UPDATE_CACHE" 2>/dev/null
}

# What a given version MISSES. "You are behind" does not tell anyone whether
# it matters; every entry here is a release that fixed a case where snare
# reported a repository clean while it was infected, which is the one failure
# that makes the tool worse than not running it.
snare_update_risk(){
  local v="$SNARE_VERSION"
  if ver_gt 1.6.0 "$v" && ver_gt "$v" 1.4.3; then
    dim "  Before 1.6.0 a repository could plant a Python module that snare's own"
    dim "  checks loaded and ran. And before 1.7.0, an install left on a branch"
    dim "  other than main was told \"up to date\" for good."
  elif ver_gt 1.4.0 "$v"; then
    dim "  Before 1.4.0 a repository could run a payload on every \`npm run dev\`"
    dim "  and re-drop it at every editor session, and snare reported it clean."
  elif ver_gt 1.3.2 "$v"; then
    dim "  Before 1.3.2 false positives could push a real finding past the cap."
  elif ver_gt 1.1.0 "$v"; then
    dim "  Before 1.1.0 four defects could report a repository clean when it was not."
  fi
}

# For callers that print a verdict: a clean result from an outdated scanner is
# the dangerous combination, so this is NOT gated on being a terminal — a
# report written to a file or a CI log needs to carry the caveat too.
snare_update_stale_note(){
  [ -n "${SNARE_NO_UPDATE_CHECK:-}" ] && return 0
  _snare_update_cache_current || return 0
  local b rv
  b="$(grep -m1 '^behind=' "$UPDATE_CACHE" 2>/dev/null | cut -d= -f2)"
  rv="$(grep -m1 '^remote_version=' "$UPDATE_CACHE" 2>/dev/null | cut -d= -f2)"
  if [ -n "$b" ] && [ "$b" -gt 0 ] 2>/dev/null; then
    ylw "  This result came from a snare that is $b commit(s) behind."
  elif [ -n "$rv" ] && ver_gt "$rv" "$SNARE_VERSION"; then
    ylw "  This result came from snare $SNARE_VERSION; $rv is available."
  else
    return 0
  fi
  snare_update_risk
  dim "  Re-check with a current one: snare update && snare scan repo"
}

# Read the cached answer, print at most one line, and kick off a refresh in the
# background when the cache is stale. Never blocks.
snare_update_nudge(){
  [ -n "${SNARE_NO_UPDATE_CHECK:-}" ] && return 0
  [ -n "${CI:-}" ] && return 0
  local mode; mode="$(snare_update_mode)"
  [ "$mode" = off ] && return 0

  local now checked behind age
  now="$(date +%s)"
  checked=0; behind=0
  if _snare_update_cache_current; then
    checked="$(grep -m1 '^checked=' "$UPDATE_CACHE" 2>/dev/null | cut -d= -f2)"
    behind="$(grep -m1 '^behind=' "$UPDATE_CACHE" 2>/dev/null | cut -d= -f2)"
  fi
  [ -z "$checked" ] && checked=0
  [ -z "$behind" ] && behind=0
  age=$(( now - checked ))

  # Stale (or never checked): refresh in the background — at a terminal or
  # not. This used to sit behind the terminal check, so under a coding agent,
  # where most snare commands now run, nothing ever checked. Every 6 hours at
  # most, one at a time, fully detached (stdin included: a child still holding
  # the terminal keeps the parent waiting). No setsid: macOS does not ship it.
  # nohup so it survives the terminal closing on a short command.
  local mark="$SNARE_HOME/.update-refreshing"
  if [ "$age" -gt 21600 ] 2>/dev/null \
     && { [ ! -f "$mark" ] || [ $(( now - $(_snare_mtime "$mark") )) -gt 600 ]; }; then
    mkdir -p "$SNARE_HOME" 2>/dev/null; : > "$mark" 2>/dev/null
    ( nohup "$SNARE_ROOT/bin/snare" _update-refresh </dev/null >/dev/null 2>&1 & ) </dev/null >/dev/null 2>&1
  fi

  [ -t 1 ] || return 0            # what follows is for a person: stay out of pipes and logs

  # Auto mode installed something since the last command: say so, once.
  if [ -s "$AUTO_UPDATED" ]; then
    local f t sha
    IFS="$(printf '\t')" read -r f t sha < "$AUTO_UPDATED"
    rm -f "$AUTO_UPDATED"
    echo
    grn "  snare updated itself: $f -> $t"
    dim "    what changed: git -C $SNARE_ROOT log --oneline $sha..HEAD   (log: $SNARE_LOGS/auto-update.log)"
    return 0
  fi

  local rv=""
  [ "$checked" != 0 ] && rv="$(grep -m1 '^remote_version=' "$UPDATE_CACHE" 2>/dev/null | cut -d= -f2)"
  if [ -n "$rv" ] && ver_gt "$rv" "$SNARE_VERSION"; then
    echo
    ylw "  snare $rv is out (you have $SNARE_VERSION) — update: snare update"
    snare_update_risk
    [ "$mode" = notify ] && dim "  or let snare install updates itself: snare update --mode auto"
  elif [ "$behind" -gt 0 ] 2>/dev/null; then
    echo
    ylw "  snare is $behind commit(s) behind — update: snare update"
    snare_update_risk
  fi
  return 0
}

# Absolute path for something that need not exist yet. macOS has no
# `readlink -f`, and `realpath` is not everywhere either.
_snare_abspath(){
  local d b
  d="$(dirname -- "$1")"; b="$(basename -- "$1")"
  ( cd "$d" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$b" ) || printf '%s\n' "$1"
}

# Keep the launcher in ~/.local/bin pointing at the install it belongs to.
#
# This used to relink unconditionally, which meant `snare update` run from ANY
# checkout — a fork, a worktree, a throwaway clone in /tmp — silently pointed
# the global launcher at that checkout. Delete the clone afterwards and
# `snare` is a dangling symlink, with nothing having said so. Found exactly
# that way while testing.
#
# The launcher is only touched when it already refers to this checkout
# (nothing to do), when it is broken (pointing at something that no longer
# exists, so any working snare is an improvement), or when --relink says to.
# A launcher pointing at a different, working install is left alone and
# reported, because that is someone else's install and this is not it.
#
# $1 = 1 when --relink was passed.
_snare_relink(){
  local force="${1:-0}"
  local bin="${SNARE_BIN:-$HOME/.local/bin}"
  local link="$bin/snare" want="$SNARE_ROOT/bin/snare"
  chmod +x "$want" 2>/dev/null
  [ -e "$link" ] || [ -L "$link" ] || return 0

  # Where does it point now? A symlink has a target; the Windows launcher stub
  # names the path it execs.
  local cur=""
  if [ -L "$link" ]; then
    cur="$(readlink "$link" 2>/dev/null)"
    case "$cur" in
      "" ) ;;
      /* ) ;;
      *  ) cur="$(dirname -- "$link")/$cur" ;;   # relative target
    esac
  elif [ -f "$link" ]; then
    cur="$(grep -m1 -oE '/[^"'"'"' ]*/bin/snare' "$link" 2>/dev/null)"
  fi

  if [ -n "$cur" ] && [ "$(_snare_abspath "$cur")" = "$(_snare_abspath "$want")" ]; then
    return 0                                     # already us; say nothing
  fi

  if [ "$force" = 1 ] || { [ -n "$cur" ] && [ ! -e "$cur" ]; }; then
    if ln -sf "$want" "$link" 2>/dev/null; then
      dim "  relinked $link -> $want"
    else
      ylw "  could not relink $link (no symlink support?) — rerun ./install.sh here"
    fi
    return 0
  fi

  if [ -n "$cur" ]; then
    echo
    ylw "  $link still points at another install and was left alone:"
    dim  "      $cur"
    dim  "  you updated $SNARE_ROOT. To point the launcher here: snare update --relink"
  fi
  return 0
}

# Move a checkout that is not on main (detached at a tag, or left on a work
# branch) onto main, without losing anything. A checkout whose commits are all
# already in origin/main is safe to move; one carrying commits main does not
# have is someone's work, so it is refused with the exact command instead.
# $1 = current branch ("HEAD" or empty when detached), $2 = 1 under --force.
_snare_land_on_main(){
  local from="${1:-HEAD}" force="${2:-0}" label f=""
  if [ "$from" = HEAD ] || [ -z "$from" ]; then label="a detached checkout"
  else label="branch '$from'"; fi
  [ "$force" = 1 ] && f="-f"
  git -C "$SNARE_ROOT" rev-parse -q --verify origin/main >/dev/null 2>&1 || {
    red "  origin/main not found — cannot tell what the latest release is"; return 1; }
  if ! git -C "$SNARE_ROOT" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
    red "  this install is on $label, which has commits that are not on main"
    dim "  snare updates from main. Keep your work and switch:"
    dim "      cd $SNARE_ROOT && git checkout main && snare update"
    return 1
  fi
  ylw "  this install was on $label — switching to main, where releases are published"
  if git -C "$SNARE_ROOT" rev-parse -q --verify refs/heads/main >/dev/null 2>&1; then
    git -C "$SNARE_ROOT" checkout -q $f main 2>/dev/null || {
      red "  could not check out main"; return 1; }
  else
    git -C "$SNARE_ROOT" checkout -q $f -b main origin/main 2>/dev/null || {
      red "  could not create main from origin/main"; return 1; }
  fi
  git -C "$SNARE_ROOT" branch -q --set-upstream-to=origin/main main >/dev/null 2>&1 || true
  return 0
}

# ------------------------------------------------------------- update mode
# How snare keeps itself current, chosen with `snare update --mode`:
#   notify  (default) check in the background and say when a new version is
#           out, with the one command to run;
#   auto    the same check, but install it too: fast-forward from main, restart
#           the guard, refresh what snare installed — then say once what changed;
#   off     never check (SNARE_NO_UPDATE_CHECK=1 does the same, per process).
UPDATE_MODE_FILE="$SNARE_HOME/update-mode"
AUTO_UPDATED="$SNARE_HOME/auto-updated"
snare_update_mode(){
  local m; m="$(head -1 "$UPDATE_MODE_FILE" 2>/dev/null)"
  case "$m" in auto|off) echo "$m" ;; *) echo notify ;; esac
}
_snare_update_set_mode(){
  case "${1:-}" in
    "") echo "update mode: $(snare_update_mode)"
        dim "  change it:  snare update --mode notify|auto|off" ; return 0 ;;
    notify|auto|off) ;;
    *) red "  unknown mode: $1 (notify, auto or off)"; return 2 ;;
  esac
  mkdir -p "$SNARE_HOME" 2>/dev/null
  echo "$1" > "$UPDATE_MODE_FILE" || return 1
  case "$1" in
    notify) grn "  snare will tell you when a new version is out" ;;
    auto)   grn "  snare will install new versions itself, and tell you once what changed"
            dim "  it only fast-forwards from main, and never touches an install with local edits" ;;
    off)    ylw "  snare will not check for new versions — run 'snare update' yourself" ;;
  esac
}

# What an update leaves behind that no longer means anything.
_snare_update_tidy(){
  local n=0
  # The gate's clean verdicts are keyed by version, so the old version's can
  # never be used again; they only crowd out new ones.
  [ -f "${GATE_CACHE:-$SNARE_HOME/gate-cache}" ] && rm -f "${GATE_CACHE:-$SNARE_HOME/gate-cache}" && n=$((n+1))
  # Blocks waiting for `snare respond` in repositories that no longer exist.
  local gp="$SNARE_LOGS/gate-pending"
  if [ -s "$gp" ]; then
    local keep k w c d r dropped=0
    keep="$(mktemp "${TMPDIR:-/tmp}/snaregp.XXXXXX")" || keep=""
    if [ -n "$keep" ]; then
      while IFS="$(printf '\t')" read -r k w c d r; do
        [ -z "$k" ] && continue
        if [ "$d" != - ] && [ -n "$d" ] && [ ! -d "$d" ]; then dropped=$((dropped+1)); continue; fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$k" "$w" "$c" "$d" "$r"
      done < "$gp" > "$keep"
      if [ "$dropped" -gt 0 ]; then mv "$keep" "$gp"; n=$((n+dropped)); else rm -f "$keep"; fi
    fi
  fi
  # Logs that only grow: keep the most recent part.
  local f
  for f in "$SNARE_LOGS/gate.log" "$SNARE_LOGS/guard.log" "$SNARE_LOGS/guard.out" "$SNARE_LOGS/auto-update.log"; do
    if [ -f "$f" ] && [ "$(wc -c < "$f" 2>/dev/null)" -gt 1048576 ] 2>/dev/null; then
      tail -n 5000 "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" && n=$((n+1))
    fi
  done
  # Refresh markers a killed process left behind.
  rm -f "$SNARE_HOME/intel/.refreshing" "$SNARE_HOME/.update-refreshing" 2>/dev/null
  [ "$n" -gt 0 ] && dim "  cleared $n leftover(s) from the previous version"
  return 0
}

# The background half of `--mode auto`: install what the refresh just found.
# Never at a dirty install, never off main, never two at once.
_snare_auto_update(){
  [ "$(snare_update_mode)" = auto ] || return 0
  [ -d "$SNARE_ROOT/.git" ] || return 0
  [ -z "$(git -C "$SNARE_ROOT" status --porcelain 2>/dev/null)" ] || return 0
  [ "$(git -C "$SNARE_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)" = main ] || return 0
  local lock="$SNARE_HOME/.auto-updating"
  mkdir "$lock" 2>/dev/null || return 0
  local from="$SNARE_VERSION" fromsha to
  fromsha="$(git -C "$SNARE_ROOT" rev-parse --short HEAD 2>/dev/null)"
  mkdir -p "$SNARE_LOGS" 2>/dev/null
  { echo "== $(date '+%F %T') auto-update from $from ($fromsha)"
    "$SNARE_ROOT/bin/snare" update --auto-run 2>&1; } >> "$SNARE_LOGS/auto-update.log" 2>&1
  to="$(snare_version_at "$SNARE_ROOT")"
  if [ "$(git -C "$SNARE_ROOT" rev-parse --short HEAD 2>/dev/null)" != "$fromsha" ]; then
    printf '%s\t%s\t%s\n' "$from" "${to:-?}" "$fromsha" > "$AUTO_UPDATED"
  fi
  rmdir "$lock" 2>/dev/null
  return 0
}

cmd_update(){
  local force=0 check=0 relink=0 auto=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force)  force=1 ;;
      --check)  check=1 ;;
      --relink) relink=1 ;;
      --auto-run) auto=1 ;;                        # internal: the background auto-update
      --mode)   _snare_update_set_mode "${2:-}"; return $? ;;
      *) red "unknown flag: $1"; return 2 ;;
    esac; shift
  done

  hdr "snare update"
  echo "  install: $SNARE_ROOT"
  echo "  version: $SNARE_VERSION"

  if [ "$check" = 1 ]; then
    # Commit distance first — it catches drift that a static version string
    # cannot. A version-only comparison once reported "up to date" to someone
    # 14 commits behind, still carrying known detection bugs.
    local behind; behind="$(snare_commits_behind 2>/dev/null)"
    if [ -n "$behind" ]; then
      if [ "$behind" -gt 0 ] 2>/dev/null; then
        ylw "  $behind commit(s) behind origin"
        local r2; r2="$(snare_remote_version)"
        [ -n "$r2" ] && ver_gt "$r2" "$SNARE_VERSION" && echo "  latest release: $r2"
        dim "  run: snare update"
      else
        grn "  up to date ($SNARE_VERSION, $(git -C "$SNARE_ROOT" rev-parse --short HEAD 2>/dev/null))"
      fi
      return 0
    fi
    # Not a git checkout: fall back to the version string.
    local r; r="$(snare_remote_version)"
    if [ -z "$r" ]; then ylw "  could not reach GitHub"; return 1; fi
    if ver_gt "$r" "$SNARE_VERSION"; then
      ylw "  update available: $r"; dim "  run: snare update"
    else
      grn "  up to date ($SNARE_VERSION)"
      dim "  (comparing release versions only — no upstream to diff against)"
    fi
    return 0
  fi

  if [ ! -d "$SNARE_ROOT/.git" ]; then
    red "  $SNARE_ROOT is not a git checkout"
    dim "  reinstall:  git clone https://github.com/nexlabz/snare ~/snare && cd ~/snare && ./install.sh"
    return 1
  fi

  snare_fix_stale_remote

  # Refuse to discard the user's own edits unless they say so.
  local dirty; dirty="$(git -C "$SNARE_ROOT" status --porcelain 2>/dev/null)"
  if [ -n "$dirty" ] && [ "$force" = 0 ]; then
    red "  local modifications present — refusing to overwrite:"
    echo "$dirty" | sed 's/^/      /' | head -10
    dim "  keep them:     cd $SNARE_ROOT && git stash"
    dim "  discard them:  snare update --force"
    return 1
  fi

  local before; before="$(git -C "$SNARE_ROOT" rev-parse --short HEAD 2>/dev/null)"
  local branch; branch="$(git -C "$SNARE_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"

  echo "  fetching..."
  if ! git -C "$SNARE_ROOT" fetch --quiet origin 2>/dev/null; then
    red "  fetch failed — check your network or remote"
    return 1
  fi

  # Releases are published on main, and only main. This used to update
  # whatever branch the checkout happened to be on: a checkout left on an old
  # work branch fetched that branch, found nothing new, and said "already up
  # to date" forever — while `snare version` compared against main and said
  # "behind". Both were telling the truth about different branches.
  if [ "$branch" != main ]; then
    _snare_land_on_main "$branch" "$force" || return 1
    branch=main
  fi

  if [ "$force" = 1 ] && [ -n "$dirty" ]; then
    ylw "  discarding local modifications (--force)"
    git -C "$SNARE_ROOT" reset -q --hard "origin/$branch" 2>/dev/null
  else
    # Fast-forward only: never create a merge commit in someone's install.
    if ! git -C "$SNARE_ROOT" merge --ff-only -q "origin/$branch" 2>/dev/null; then
      red "  cannot fast-forward $branch (history diverged)"
      dim "  reset to the published version:  snare update --force"
      return 1
    fi
  fi

  local after; after="$(git -C "$SNARE_ROOT" rev-parse --short HEAD 2>/dev/null)"
  local newver; newver="$(snare_version_at "$SNARE_ROOT")"

  # Record what was just established, so no command keeps repeating the
  # "behind" it read before this update.
  local _left; _left="$(git -C "$SNARE_ROOT" rev-list --count HEAD..origin/main 2>/dev/null)"
  SNARE_VERSION="${newver:-$SNARE_VERSION}" _snare_update_write "${_left:-0}" "${newver:-}"

  if [ "$before" = "$after" ]; then
    grn "  already up to date ($SNARE_VERSION, $after)"
  else
    grn "  updated: $SNARE_VERSION ($before) -> ${newver:-?} ($after)"
    echo
    dim "  changes:"
    git -C "$SNARE_ROOT" log --oneline "$before..$after" 2>/dev/null | sed 's/^/      /' | head -15
  fi

  _snare_relink "$relink"

  # Refresh the agent gate from the NEW code. This process still has the old
  # libraries loaded — the first update to a version that has agents.sh has
  # no such function at all — so it runs the updated binary instead. It
  # installs the gate if it never was, refreshes it if it is, and leaves it
  # alone if you uninstalled it (snare agents uninstall).
  # An installed shield is a copy of old code in your shell profile. One
  # version of it broke npm, pnpm, yarn, bun and npx for every coding agent, so
  # an installed block is refreshed from the new code rather than left to rot.
  local _rc; _rc="$(_shield_rc 2>/dev/null)"
  if [ -n "$_rc" ] && grep -qF "$SHIELD_BEGIN" "$_rc" 2>/dev/null; then
    "$SNARE_ROOT/bin/snare" shield install 2>/dev/null | grep -q 'refreshing' \
      && dim "  shell shield refreshed in $_rc — open a new shell to load it"
  fi

  if [ -z "${SNARE_NO_AGENTS:-}" ] && "$SNARE_ROOT/bin/snare" agents sync >/dev/null 2>&1; then
    grep -q 'gate --hook' "$HOME/.claude/settings.json" 2>/dev/null \
      && dim "  agent gate refreshed — clones, pulls, installs and runs are scanned first"
  fi
  # Not on yet and never answered: the person running the update is right
  # here, so ask now rather than on some later command. (Asks only at a
  # terminal; does nothing in CI or under an agent.)
  [ -z "${SNARE_NO_AGENTS:-}" ] && [ "$auto" = 0 ] && "$SNARE_ROOT/bin/snare" agents offer || true
  # The known-malware list, refreshed now so the new version starts current.
  "$SNARE_ROOT/bin/snare" deps update >/dev/null 2>&1 \
    && dim "  known-malware list updated — 'snare deps' checks your projects against it"

  # Updating the checkout does not update anything snare has installed
  # elsewhere. Those copies keep running old code, and in the shield's case an
  # old copy was silently WRONG rather than merely stale — so say what needs
  # refreshing instead of leaving people to assume it was handled.
  local stale=0

  # The background guard is a long-running copy of the OLD code. Restart it on
  # the new code here rather than asking: people were told to run
  # `snare guard stop && snare guard start` after every update, and a guard
  # nobody restarted kept running a version with known gaps.
  if [ -z "${SNARE_NO_GUARD_RESTART:-}" ] && [ "$(guard_state 2>/dev/null)" = running ]; then
    local gv; gv="$(guard_running_version 2>/dev/null)"
    if [ "$before" != "$after" ] || [ "$gv" != "${newver:-$SNARE_VERSION}" ]; then
      if "$SNARE_ROOT/bin/snare" guard restart >/dev/null 2>&1; then
        dim "  background guard restarted on ${newver:-$SNARE_VERSION}"
      else
        echo; ylw "  the background guard could not be restarted on the new version"
        dim "    snare guard restart"
        stale=1
      fi
    fi
  fi

  # Leftovers from the previous version.
  _snare_update_tidy

  # Shield: compare the installed block against what we would write now.
  local rc
  case "$(basename "${SHELL:-/bin/bash}")" in
    zsh)  rc="${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) rc="$HOME/.bashrc"; [ -f "$rc" ] || rc="$HOME/.bash_profile" ;;
    *)    rc="$HOME/.profile" ;;
  esac
  if [ -f "$rc" ] && grep -qF '# >>> snare shield >>>' "$rc" 2>/dev/null; then
    local cur_block new_block
    cur_block="$(sed -n '/^# >>> snare shield >>>$/,/^# <<< snare shield <<<$/p' "$rc" 2>/dev/null)"
    new_block="$(_shield_snippet 2>/dev/null)"
    if [ "$cur_block" != "$new_block" ]; then
      [ "$stale" = 0 ] && echo
      ylw "  the installed shell shield is from an older version"
      dim "    snare shield install     (refreshes it in place)"
      stale=1
    fi
  fi

  # Hooks in this repo, if snare is being run from inside one.
  local hd
  hd="$(git rev-parse --git-path hooks 2>/dev/null)"
  if [ -n "$hd" ] && [ -d "$hd" ]; then
    local h
    for h in pre-push pre-commit; do
      if [ -f "$hd/$h" ] && ! grep -q 'snare-hook-v1' "$hd/$h" 2>/dev/null \
         && grep -qE 'snare"?[[:space:]]+hook[[:space:]]+run' "$hd/$h" 2>/dev/null; then
        [ "$stale" = 0 ] && echo
        ylw "  the $h hook in this repository is from an older version"
        dim "    snare hook install       (upgrades it in place)"
        stale=1
      fi
    done
  fi

  echo
  dim "  verify detection still works:  snare selftest"
}
