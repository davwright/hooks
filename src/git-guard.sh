#!/bin/bash
# git-guard.sh — the CONTENT judge. Invoked by a repo's .git/hooks/pre-commit
# and pre-push via a thin stub that execs this file.
#
#   git-guard.sh pre-commit              # scan the staged diff
#   git-guard.sh commit-msg <file>       # scan the FINAL commit message
#   git-guard.sh pre-push <name> <url>   # scan what is about to be published
#
# Exit 0 = allow, nonzero = git aborts the operation.
#
# WHY THIS FILE NO LONGER JUDGES THE PUSH DESTINATION
#
# This hook runs for EVERYONE — the user's terminal, VSCode's Source Control
# panel, any GUI client, and Claude alike. Git hooks cannot tell who invoked
# them, and no environment variable can establish that either: every var in a
# process is writable by that process for any child it spawns, so an env-var
# "am I Claude?" test is spoofable by the one party it exists to constrain.
#
# So the two rules are split by WHO they must bind:
#
#   * DESTINATION ("don't push to customer repos") binds CLAUDE ONLY — the
#     user is trusted to push wherever they like. That rule lives in the
#     PreToolUse hook (claude-git-guard.sh), which fires only for Claude by
#     construction: a separate execution path, not a flag Claude can clear.
#
#   * CONTENT ("no AI-tool words in customer history") binds EVERYONE, the
#     user included — that text must not reach a customer repo regardless of
#     who typed it. That rule is THIS FILE.
#
# This file therefore uses the remote URL only to decide WHETHER TO SCAN: own
# repos are skipped (their history may legitimately discuss Claude — this very
# repo does), customer repos are scanned.
#
# NOTE: --no-verify skips git hooks entirely, so this file cannot stop a
# `--no-verify` commit/push. For Claude that hole is closed one layer up, in
# the PreToolUse hook. A human using --no-verify is doing so deliberately.

GUARD_VERSION=2

# ── Own infrastructure ─────────────────────────────────────────────────────
# Matched case-insensitively against push URLs. A repo whose push remotes are
# ALL ours is skipped; anything else (e.g. oebb-azure-platform customer repos)
# is scanned.
#
# Anchored at the URL start and terminated at the host boundary, so a URL that
# merely CONTAINS one of these strings does not match: 'github.com.evil.io/x'
# and 'https://oebb.example.com/github.com/osis' are both correctly foreign.
# Both ADO forms are listed — the HTTPS form has an optional user@ prefix, and
# the SSH form is ssh.dev.azure.com:v3/evolx/ (no slash after the host, which
# is why a bare 'dev\.azure\.com/evolx/' pattern silently missed it).
OWN_REMOTES=(
  '^(https://|git@|ssh://git@)github\.com[/:]'
  '^https://([^@/]+@)?dev\.azure\.com/evolx/'
  '^(ssh://)?git@ssh\.dev\.azure\.com:(v3/)?evolx/'
)

# ── Content blacklist ──────────────────────────────────────────────────────
# Word-bounded and case-insensitive: 'claude' trips, 'claudel' does not.
AI_WORDS=(
  claude anthropic opus sonnet haiku fable llm gpt copilot
)
# Attribution phrases, tolerant of punctuation and reflowed whitespace.
AI_PHRASES=(
  'co-?authored[-[:space:]]*by:?[[:space:]]*claude'
  'generated[[:space:]]+with[[:space:]]+claude'
)

# ── self-update against the LOCAL canonical ────────────────────────────────
# The stub in this repo's .git/hooks carries a `# git-guard-stub vN` marker.
# If it differs from the template's, re-copy the stub. No network — the
# installer is what refreshes THIS file. We only ever re-copy the tiny stub;
# we never re-exec (this canonical is by definition current, being the running
# file). Crashing is reserved for the stub when THIS file is missing.
self_update_stub() {
  local hookdir="$1"
  local tmpl="$HOME/.git-template/hooks"
  [[ -d $tmpl ]] || return 0          # no template deployed -> nothing to sync
  local h cur want
  for h in pre-commit commit-msg pre-push; do
    [[ -f "$tmpl/$h" ]] || continue
    cur=""
    [[ -f "$hookdir/$h" ]] && cur=$(sed -n 's/.*git-guard-stub v\([0-9]\+\).*/\1/p' "$hookdir/$h" | head -1)
    want=$(sed -n 's/.*git-guard-stub v\([0-9]\+\).*/\1/p' "$tmpl/$h" | head -1)
    # Only refresh a stub we own (has the marker) or that's absent. Never
    # clobber a foreign hook — that's the Claude layer's block-and-warn case,
    # not ours to silently overwrite.
    if [[ -z $cur && -s "$hookdir/$h" ]]; then
      continue
    fi
    if [[ "$cur" != "$want" ]]; then
      cp "$tmpl/$h" "$hookdir/$h" && chmod +x "$hookdir/$h"
    fi
  done
}

# is_own_remote <urls>: 0 iff EVERY (newline-separated, non-empty) URL is ours.
# 1 otherwise, including no URLs. A repo may have several push remotes; it is
# "ours" only if none points anywhere foreign — a single foreign remote among
# many means we cannot tell where a bare push lands, so scan. A URL containing
# '..' is foreign outright: path traversal could walk out of an allowed org.
is_own_remote() {
  local urls="$1"
  [[ -z $urls ]] && return 1
  local url lc pattern matched n=0
  while IFS= read -r url; do
    url=${url%$'\r'}
    [[ -z $url ]] && continue
    n=$((n+1))
    lc=${url,,}
    [[ $lc == *..* ]] && return 1
    matched=0
    for pattern in "${OWN_REMOTES[@]}"; do
      [[ $lc =~ $pattern ]] && { matched=1; break; }
    done
    [[ $matched -eq 0 ]] && return 1
  done <<< "$urls"
  [[ $n -eq 0 ]] && return 1
  return 0
}

# scan_text <label> <text>: report each blacklist hit on stderr.
# 0 = clean, 1 = something matched.
scan_text() {
  local label="$1" text="$2" hits=0 w p lc
  [[ -z $text ]] && return 0
  lc=${text,,}
  for w in "${AI_WORDS[@]}"; do
    # Word-bounded: the char before and after must not be alphanumeric.
    # Underscore counts as a boundary in prose but NOT here — 'sonnets_are_fine'
    # must pass, so only [a-z0-9] continues a word.
    if [[ $lc =~ (^|[^a-z0-9])$w([^a-z0-9]|$) ]]; then
      echo "  $label: contains '$w'" >&2
      hits=1
    fi
  done
  for p in "${AI_PHRASES[@]}"; do
    if [[ $lc =~ $p ]]; then
      echo "  $label: matches attribution pattern" >&2
      hits=1
    fi
  done
  [[ $hits -eq 0 ]]
}

report_and_die() {
  echo "git-guard: BLOCKED — AI-tool reference in $1." >&2
  echo "This repo's push remote is not github/evolx, so AI-tool references must" >&2
  echo "not enter its history. Blacklisted (word-bounded, case-insensitive):" >&2
  echo "  ${AI_WORDS[*]}" >&2
  echo "Reword and retry." >&2
  exit 1
}

# added_lines <git-show-or-diff args...>: the '+' side of a diff, minus the
# +++ file headers. -U0 keeps context lines out, so a pre-existing dirty line
# near an edit does not trip, and a commit that REMOVES a dirty word is clean
# (otherwise you could never clean one up).
added_lines() {
  git "$@" --no-color -U0 --diff-filter=d 2>/dev/null \
    | grep '^+' | grep -v '^+++'
}

mode="$1"; shift

# `git rev-parse --git-path hooks` gives the real hooks dir even in worktrees
# and submodules, where .git is a file pointing elsewhere.
HOOKDIR=$(git rev-parse --git-path hooks 2>/dev/null)
[[ -n $HOOKDIR ]] && self_update_stub "$HOOKDIR"

# Reject an unknown mode before doing any work — fail closed.
case "$mode" in
  pre-commit|commit-msg|pre-push) ;;
  *)
    echo "git-guard: unknown mode '$mode' (expected pre-commit or pre-push) — refusing (fail closed)." >&2
    exit 1 ;;
esac

# ── Scope: only customer repos are scanned ─────────────────────────────────
# On pre-push, git hands us the ACTUAL destination URL in argv ($2) — that is
# where this push lands, which is not necessarily any configured remote:
# `git push https://host/x.git main` names a URL directly. Judge that, not
# `git remote -v`, or an ad-hoc push is scoped against the wrong destination.
#
# On pre-commit git gives no remote info, so fall back to the repo's configured
# push remotes. A remote-less repo is skipped: nothing can be published from it
# yet and the gate re-applies the moment a remote exists, which keeps a fresh
# `git init` working.
# argv after the mode shift: $1 = remote name, $2 = remote URL.
if [[ $mode == pre-push && -n ${2:-} ]]; then
  push_urls="$2"
else
  push_urls=$(git remote -v 2>/dev/null | awk '$3=="(push)"{print $2}')
fi
[[ -z $push_urls ]] && exit 0
is_own_remote "$push_urls" && exit 0

case "$mode" in
  pre-commit)
    # Content only. The message is NOT judged here: git has not necessarily
    # composed it yet at pre-commit time (COMMIT_EDITMSG can still hold the
    # previous message), so scanning it here is unreliable in both directions.
    # commit-msg below is where git guarantees the final message.
    fail=0
    scan_text "staged diff" "$(added_lines diff --cached)" || fail=1
    [[ $fail -eq 1 ]] && report_and_die "the staged changes"
    exit 0
    ;;
  commit-msg)
    # argv after the shift: $1 = path to the file holding the FINAL message.
    # Git guarantees this runs with the message the commit will actually carry,
    # which makes it the reliable place to catch attribution trailers.
    msg_path="${1:-}"
    [[ -n $msg_path && -f $msg_path ]] || exit 0
    # Drop git's own comment lines (and the scissors section from --verbose,
    # which contains the whole diff and would double-report it).
    msg=$(sed '/^# ------------------------ >8 ------------------------$/,$d' "$msg_path" \
          | grep -v '^#')
    scan_text "commit message" "$msg" || report_and_die "the commit message"
    exit 0
    ;;
  pre-push)
    # stdin carries one line per ref:
    #   <local ref> <local sha> <remote ref> <remote sha>
    fail=0
    while read -r lref lsha rref rsha; do
      [[ -z ${lsha:-} ]] && continue
      # All-zero local sha = branch deletion; nothing to scan.
      [[ $lsha =~ ^0+$ ]] && continue
      if [[ ${rsha:-} =~ ^0+$ ]]; then
        # New branch on the remote: scan only commits not already published
        # elsewhere, rather than the whole branch history.
        range=$(git rev-list "$lsha" --not --remotes 2>/dev/null)
      else
        range=$(git rev-list "$rsha..$lsha" 2>/dev/null)
      fi
      [[ -z $range ]] && continue
      while read -r sha; do
        [[ -z $sha ]] && continue
        short=$(git rev-parse --short "$sha" 2>/dev/null)
        scan_text "commit $short message" "$(git log -1 --format=%B "$sha")" || fail=1
        scan_text "commit $short diff" "$(added_lines show "$sha" --format=)" || fail=1
      done <<< "$range"
    done
    [[ $fail -eq 1 ]] && report_and_die "the commits being pushed"
    exit 0
    ;;
esac
