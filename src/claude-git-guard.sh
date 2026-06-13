#!/bin/bash
# claude-git-guard.sh — THIN Claude Code PreToolUse hook (Bash matcher).
# Replaces the old fat block-git-write.sh. It no longer judges the whitelist;
# that moved to the per-repo git hooks (git-guard.sh), which see clean data.
#
# This layer does only what the git layer CAN'T:
#   1. Belt: block the shapes git hooks are blind to or that bypass them —
#        - --no-verify / -n on commit|push  (skips git hooks entirely)
#        - GIT_DIR= / --git-dir / --work-tree / --namespace redirect
#        - git remote add|set-url|... to a NON-whitelisted URL  (set-url could
#          repoint a remote past the git-layer check; add to a whitelisted URL
#          is the benign fresh-init case and is allowed)
#        - git config remote.* writes  (back-door set-url)
#   2. Self-heal: before a commit|push, ensure the target repo has our git
#      hook installed. Missing/stale -> install the stub. Foreign hook present
#      -> block+warn (don't clobber). Then let the command through; the git
#      hook does the real judging.
#
# Everything else exits 0 fast. Pure-bash matching (no grep/sed forks) on the
# hot path, since this fires on EVERY Bash command.

GUARD_STUB_VERSION=1
TEMPLATE_HOOKS="$HOME/.git-template/hooks"

_GIT='(^|[^[:alnum:]_/\\])git[[:space:]]+([^[:space:]]+[[:space:]]+)*'

# _strip_quotes <s> -> $_STRIPPED with quoted substrings removed (ported from
# block-git-write.sh:116-128). Pure bash, no fork.
_strip_quotes() {
  local s="$1" out="" i ch q=""
  for (( i=0; i<${#s}; i++ )); do
    ch=${s:i:1}
    if [[ -n $q ]]; then
      [[ $ch == "$q" ]] && q=""
      continue
    fi
    if [[ $ch == "'" || $ch == '"' ]]; then q=$ch; continue; fi
    out+=$ch
  done
  _STRIPPED="$out"
}

# _has_redirect <cmd> (ported from block-git-write.sh:135-140).
_has_redirect() {
  _strip_quotes "$1"
  [[ $_STRIPPED =~ (^|[[:space:]\;\&\|])(GIT_DIR|GIT_WORK_TREE|GIT_COMMON_DIR|GIT_INDEX_FILE)= ]] && return 0
  [[ $_STRIPPED =~ (^|[[:space:]])--(git-dir|work-tree|namespace)(=|[[:space:]]|$) ]] && return 0
  return 1
}

# resolve_target <cmd> <cwd> -> $_TARGET (ported from block-git-write.sh:169-178).
resolve_target() {
  local cmd="$1" target="$2"
  if [[ $cmd =~ (^|[^[:alnum:]_])cd[[:space:]]+[\"\']?([^\"\'\;\&\|[:space:]]+) ]]; then
    target=${BASH_REMATCH[2]}
  fi
  if [[ $cmd =~ git[[:space:]]+-C[[:space:]]+[\"\']?([^\"\'[:space:]]+) ]]; then
    target=${BASH_REMATCH[1]}
  fi
  _TARGET="$target"
}

# is_whitelisted_url <url> -> 0 if matches whitelist. Used only for the
# remote-add/set-url exception (fresh-init). Kept in sync with git-guard.sh.
is_whitelisted_url() {
  local lc=${1,,} pattern
  for pattern in 'github\.com' 'dev\.azure\.com/evolx/'; do
    [[ $lc =~ $pattern ]] && return 0
  done
  return 1
}

# ensure_hook <target_dir> -> echo a verdict for self-heal:
#   ok        - our current stub is installed (or just installed it)
#   foreign   - a non-stub hook exists; do not clobber, caller blocks
#   norepo    - not a git repo / can't resolve hooks dir; caller defers to git
ensure_hook() {
  local dir="$1"
  local hookdir
  hookdir=$(git -C "$dir" rev-parse --git-path hooks 2>/dev/null) || { echo norepo; return; }
  [[ -n $hookdir ]] || { echo norepo; return; }
  # rev-parse --git-path returns a path relative to the repo; make absolute.
  case "$hookdir" in
    /*|[A-Za-z]:*) ;;                 # already absolute
    *) hookdir="$dir/$hookdir" ;;
  esac
  [[ -d $TEMPLATE_HOOKS ]] || { echo ok; return; }   # no template -> nothing to install; git layer absent, defer
  mkdir -p "$hookdir" 2>/dev/null
  local h cur want foreign=0
  for h in pre-commit pre-push; do
    [[ -f "$TEMPLATE_HOOKS/$h" ]] || continue
    cur=""
    if [[ -f "$hookdir/$h" ]]; then
      cur=$(sed -n 's/.*git-guard-stub v\([0-9]\+\).*/\1/p' "$hookdir/$h" | head -1)
      if [[ -z $cur && -s "$hookdir/$h" ]]; then foreign=1; continue; fi
    fi
    want=$(sed -n 's/.*git-guard-stub v\([0-9]\+\).*/\1/p' "$TEMPLATE_HOOKS/$h" | head -1)
    if [[ "$cur" != "$want" ]]; then
      cp "$TEMPLATE_HOOKS/$h" "$hookdir/$h" && chmod +x "$hookdir/$h"
    fi
  done
  [[ $foreign -eq 1 ]] && { echo foreign; return; }
  echo ok
}

main() {
  local input
  input=$(cat)
  case "$input" in *git*) ;; *) exit 0 ;; esac   # fast bail: no git, no work

  export PATH="$PATH:/c/Users/$USER/bin:/c/ProgramData/chocolatey/bin:/c/Users/$USER/AppData/Local/Microsoft/WinGet/Links"
  command -v jq &>/dev/null || { echo "BLOCKED: jq not found — hook cannot parse input." >&2; exit 2; }

  local cmd cwd
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command') || { echo "BLOCKED: failed to parse hook input." >&2; exit 2; }
  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
  [[ -z $cmd || $cmd == null ]] && { echo "BLOCKED: could not extract command from hook input." >&2; exit 2; }

  # ── Belt 1: redirect on a commit/push (bypasses the per-repo git hook) ──
  if [[ $cmd =~ ${_GIT}(commit|push)([^[:alnum:]_]|$) ]]; then
    if _has_redirect "$cmd"; then
      echo "BLOCKED: git redirect (GIT_DIR / --git-dir / --work-tree / --namespace) is not allowed — it points git at a repo whose guard hook may be absent. Use 'git -C <path>' or run it manually." >&2
      exit 2
    fi
    # ── Belt 2: --no-verify / -n skips git hooks, defeating the real judge ──
    _strip_quotes "$cmd"
    if [[ $_STRIPPED =~ (^|[[:space:]])(--no-verify|-n)([[:space:]]|=|$) ]]; then
      echo "BLOCKED: --no-verify / -n is not allowed on commit/push — it bypasses the git-guard hook that judges the destination. Run it manually if you truly intend to skip the guard." >&2
      exit 2
    fi
    # ── Self-heal the target repo, then defer to its git hook ──
    resolve_target "$cmd" "$cwd"
    [[ -z $_TARGET ]] && { echo "BLOCKED: could not determine target directory for git command." >&2; exit 2; }
    local verdict; verdict=$(ensure_hook "$_TARGET")
    case "$verdict" in
      foreign)
        echo "BLOCKED: $_TARGET/.git/hooks already has a non-git-guard pre-commit/pre-push hook. Refusing to overwrite it. Install git-guard manually (chain it) or run the command yourself." >&2
        exit 2 ;;
    esac
    exit 0   # armed (or deferred): the git hook now does the real judging
  fi

  # ── Belt 3: remote mutation. add/set-url to a whitelisted URL is the benign
  # fresh-init case -> allow. Everything else (non-whitelisted URL, or
  # remove/rm/rename/set-branches/set-head/prune) -> block. ──
  if [[ $cmd =~ ${_GIT}remote[[:space:]]+(add|remove|rm|rename|set-url|set-branches|set-head|prune)([^[:alnum:]_]|$) ]]; then
    _strip_quotes "$cmd"
    local sub url
    sub=$(printf '%s' "$_STRIPPED" | sed -n 's/.*remote[[:space:]]\+\([a-z-]\+\).*/\1/p')
    case "$sub" in
      add|set-url)
        # The URL is taken as the LAST token of the command. This breaks if the
        # command is chained (... && other) or has a trailing flag, so the last
        # token isn't the URL — tell the user exactly that instead of the
        # misleading "non-whitelisted URL".
        url=$(printf '%s' "$_STRIPPED" | awk '{print $NF}')
        if [[ -n $url ]] && is_whitelisted_url "$url"; then exit 0; fi
        if [[ $url == *://* || $url == *@*:* ]]; then
          echo "BLOCKED: git remote $sub points at a non-whitelisted URL: '$url'. Whitelisted: github.com, dev.azure.com/evolx/. If it's a customer repo this is intended; run it yourself in a terminal." >&2
        else
          echo "BLOCKED: git remote $sub — couldn't verify the destination URL (the guard reads the LAST word of the command, but here that's '$url'). Run it UNCHAINED with the URL last, e.g. 'git remote $sub origin https://github.com/you/repo.git', then continue." >&2
        fi
        exit 2 ;;
      *)
        echo "BLOCKED: git remote $sub is not allowed (remove/rename/prune/set-* have no automated use and could repoint the guard). Run manually if intended." >&2
        exit 2 ;;
    esac
  fi

  # ── Belt 4: git config remote.* write (back-door set-url) ──
  if [[ $cmd =~ ${_GIT}config[[:space:]]+([^[:space:]]+[[:space:]]+)*(--add|--unset|--unset-all|--replace-all)[[:space:]]+remote\.[^[:space:]]+\.(url|pushurl|fetch|push|mirror)([^[:alnum:]_]|$) ]] \
     || [[ $cmd =~ ${_GIT}config[[:space:]]+([^[:space:]]+[[:space:]]+)*remote\.[^[:space:]]+\.(url|pushurl|fetch|push|mirror)[[:space:]]+[^[:space:]] ]]; then
    echo "BLOCKED: git config of remote.* is not allowed (back-door equivalent of remote set-url). Run manually if intended." >&2
    exit 2
  fi

  exit 0   # not a git write we police — let it through
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
fi
