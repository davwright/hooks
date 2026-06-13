#!/bin/bash
# git-guard.sh — the REAL judge. Invoked by a repo's .git/hooks/pre-commit and
# pre-push (via a thin stub that execs this file). Unlike the Claude PreToolUse
# hook, this runs INSIDE git, so it gets clean, unobfuscated data: pre-push is
# handed the destination remote URL in argv. No shell-string parsing, no quote
# stripping, no redirect chasing — git already did the parsing.
#
#   git-guard.sh pre-commit          # judge the repo's configured push remote
#   git-guard.sh pre-push <name> <url>   # judge the actual push destination
#
# Exit 0 = allow, nonzero = git aborts the operation.
#
# NOTE: --no-verify skips git hooks entirely, so neither path here can stop a
# `--no-verify` commit/push. That hole is closed one layer up, in the Claude
# PreToolUse hook (claude-git-guard.sh). This file is the robust judge for
# everything that DOES reach git's hook machinery.

GUARD_VERSION=1

# Whitelist patterns (matched case-insensitively against push URLs). Anything
# else (e.g. oebb-azure-platform@ customer repos) is blocked.
WHITELIST=(
  'github\.com'
  'dev\.azure\.com/evolx/'
)

# is_whitelisted <urls>: 0 iff EVERY (newline-separated, non-empty) URL matches
# the whitelist; 1 otherwise (including no URLs). A repo may have several push
# remotes; it's safe only if none points anywhere un-whitelisted. A single
# un-whitelisted remote among many -> block (can't tell which a bare push hits).
# Ported verbatim from block-git-write.sh:148-164.
is_whitelisted() {
  local urls="$1"
  [[ -z $urls ]] && return 1
  local url lc pattern matched n=0
  while IFS= read -r url; do
    [[ -z $url ]] && continue
    n=$((n+1))
    lc=${url,,}
    matched=0
    for pattern in "${WHITELIST[@]}"; do
      [[ $lc =~ $pattern ]] && { matched=1; break; }
    done
    [[ $matched -eq 0 ]] && return 1
  done <<< "$urls"
  [[ $n -eq 0 ]] && return 1
  return 0
}

# ── self-update against the LOCAL canonical ──────────────────────────────
# The stub in this repo's .git/hooks carries a `# git-guard-stub vN` marker.
# If it's older than GUARD_VERSION, re-copy the current stubs from the local
# template. No network — the installer is what refreshes THIS file from the
# repo. We only ever re-copy the tiny stub; we never re-exec (this canonical
# is, by definition, already current since it is the running file). Crashing
# is reserved for the stub when THIS file is missing/unreadable.
self_update_stub() {
  local hookdir="$1"
  local tmpl="$HOME/.git-template/hooks"
  [[ -d $tmpl ]] || return 0          # no template deployed -> nothing to sync
  local h cur want
  for h in pre-commit pre-push; do
    [[ -f "$tmpl/$h" ]] || continue
    cur=""
    [[ -f "$hookdir/$h" ]] && cur=$(sed -n 's/.*git-guard-stub v\([0-9]\+\).*/\1/p' "$hookdir/$h" | head -1)
    want=$(sed -n 's/.*git-guard-stub v\([0-9]\+\).*/\1/p' "$tmpl/$h" | head -1)
    # Only refresh a stub we own (has the marker) or that's absent. Never
    # clobber a foreign hook (no marker, non-empty) — that's the Claude
    # layer's block-and-warn case, not ours to silently overwrite.
    if [[ -z $cur && -s "$hookdir/$h" ]]; then
      continue
    fi
    if [[ "$cur" != "$want" ]]; then
      cp "$tmpl/$h" "$hookdir/$h" && chmod +x "$hookdir/$h"
    fi
  done
}

mode="$1"; shift

# Where are we? `git rev-parse --git-path hooks` gives the real hooks dir even
# in worktrees/submodules (where .git is a file pointing elsewhere).
HOOKDIR=$(git rev-parse --git-path hooks 2>/dev/null)
[[ -n $HOOKDIR ]] && self_update_stub "$HOOKDIR"

case "$mode" in
  pre-commit)
    # git gives pre-commit NO remote info. Resolve the repo's push destination
    # ourselves and judge it (strict-at-commit). A repo with no remote yet is
    # allowed: committing locally is harmless and the gate re-applies the moment
    # a remote exists. This keeps fresh `git init` working.
    push_urls=$(git remote -v 2>/dev/null | awk '$3=="(push)"{print $2}')
    if [[ -z $push_urls ]]; then
      exit 0   # remote-less repo: nothing to publish to, commit is local-only
    fi
    if ! is_whitelisted "$push_urls"; then
      n=$(printf '%s\n' "$push_urls" | grep -c .)
      if [[ $n -gt 1 ]]; then
        echo "git-guard: BLOCKED — this repo has $n push remotes and at least one is not whitelisted, so a commit here is refused (can't tell where a later push lands)." >&2
      else
        echo "git-guard: BLOCKED — commit refused; push remote is not whitelisted:" >&2
      fi
      printf '%s\n' "$push_urls" >&2
      echo "Whitelisted: ${WHITELIST[*]}. Override with --no-verify if you truly mean it (the Claude layer guards that separately)." >&2
      exit 1
    fi
    exit 0
    ;;
  pre-push)
    # argv: <remote-name> <remote-url>. The URL is exactly where the push will
    # land — the cleanest possible check, no parsing. (stdin carries per-ref
    # lines; we don't need them for a URL whitelist.)
    local_url="$2"
    if ! is_whitelisted "$local_url"; then
      echo "git-guard: BLOCKED — push refused; destination is not whitelisted:" >&2
      echo "  $local_url" >&2
      echo "Whitelisted: ${WHITELIST[*]}. Override with --no-verify if you truly mean it." >&2
      exit 1
    fi
    exit 0
    ;;
  *)
    echo "git-guard: unknown mode '$mode' (expected pre-commit or pre-push) — refusing (fail closed)." >&2
    exit 1
    ;;
esac
