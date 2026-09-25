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
#   3. The user's checkout in a repo that is NOT ours (same whitelist): no
#      branch create/switch, stash, whole-tree add, reset --hard, clean -f or
#      worktree add. A checkout of the remote's DEFAULT branch there is a
#      read-only mirror: no Edit/Write into it, no git add. Registered for
#      Bash, PowerShell and the file-edit tools.
#
# Everything else exits 0 fast. Pure-bash matching (no grep/sed forks) on the
# hot path, since this fires on EVERY Bash command.

GUARD_STUB_VERSION=1
TEMPLATE_HOOKS="$HOME/.git-template/hooks"

_GIT='(^|[^[:alnum:]_/\\])git[[:space:]]+([^[:space:]]+[[:space:]]+)*'

# _strip_quotes <s> -> $_STRIPPED with quoted substrings removed (ported from
# block-git-write.sh:116-128). Pure bash, no fork.
# _strip_heredocs <s> -> $_STRIPPED_HD with any heredoc BODY removed, keeping
# the command line itself. A commit message passed as `git commit -F - <<MSG
# ... MSG` is DATA, not flags: without this, a message that merely discusses
# "-n" or "--no-verify" is read as using them and the commit is refused.
_strip_heredocs() {
  local s="$1" out="" line tag="" in_hd=0
  while IFS= read -r line; do
    if [[ $in_hd -eq 1 ]]; then
      [[ ${line%$'\r'} == "$tag" ]] && in_hd=0
      continue
    fi
    if [[ $line =~ \<\<-?[[:space:]]*\'?\"?([A-Za-z_][A-Za-z0-9_]*)\'?\"? ]]; then
      tag="${BASH_REMATCH[1]}"; in_hd=1
    fi
    out+="$line"$'\n'
  done <<< "$s"
  _STRIPPED_HD="$out"
}

# With a 2nd arg, each quoted string leaves that token behind instead of
# vanishing, so it still counts as one argument.
_strip_quotes() {
  local s="$1" mark="${2:-}" out="" i ch q=""
  for (( i=0; i<${#s}; i++ )); do
    ch=${s:i:1}
    if [[ -n $q ]]; then
      [[ $ch == "$q" ]] && q=""
      continue
    fi
    if [[ $ch == "'" || $ch == '"' ]]; then q=$ch; out+=$mark; continue; fi
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
# Own-infrastructure patterns. Anchored at the URL start and terminated at the
# host boundary, so a URL that merely CONTAINS one of these does not match:
# 'github.com.evil.io/x' and 'https://oebb.example.com/github.com/osis' are
# both correctly foreign. Both ADO forms are covered — HTTPS with an optional
# user@ prefix, and SSH as ssh.dev.azure.com:v3/evolx/ (no slash after the
# host, which a bare 'dev\.azure\.com/evolx/' pattern silently missed).
# Keep in sync with OWN_REMOTES in git-guard.sh.
WHITELIST=(
  '^(https://|git@|ssh://git@)github\.com[/:]'
  '^https://([^@/]+@)?dev\.azure\.com/evolx/'
  '^(ssh://)?git@ssh\.dev\.azure\.com:(v3/)?evolx/'
)

is_whitelisted_url() {
  local lc=${1,,} pattern
  [[ -z $lc ]] && return 1
  [[ $lc == *..* ]] && return 1     # path traversal could leave the allowed org
  for pattern in "${WHITELIST[@]}"; do
    [[ $lc =~ $pattern ]] && return 0
  done
  return 1
}

# `git [tokens] push <args to the next shell separator>`. Keep in sync with
# PushArgsRe in Program.cs.
_NL=$'\n'
_PUSH_ARGS_RE='(^|[^[:alnum:]_/\\])git([[:blank:]]+[^[:blank:];&|'$_NL']+)*[[:blank:]]+push(([[:blank:]][^;&|'$_NL']*)?)([;&|'$_NL']|$)'

# resolve_push_urls <dir> <cmd> -> $_PUSH_URLS, newline-separated.
# Asks GIT where a push would land rather than parsing the command string. An
# explicit URL or remote name on the command line wins; otherwise the current
# branch's upstream remote; otherwise every configured push remote (a bare
# `git push` with no upstream could hit any of them).
resolve_push_urls() {
  local dir="$1" cmd="$2" tok url name
  _PUSH_URLS=""

  # Only the push's own arguments can name a destination: a URL elsewhere on
  # the line (`...; curl https://x`) is not where the push lands, and a commit
  # takes no destination argument at all.
  _strip_quotes "$cmd"
  local push_args=""
  [[ $_STRIPPED =~ $_PUSH_ARGS_RE ]] && push_args="push${BASH_REMATCH[3]}"

  # An explicit URL argument is the destination, whatever the remotes say.
  for tok in $push_args; do
    if [[ $tok == *://* || $tok == *@*:* ]]; then
      _PUSH_URLS="$tok"; return
    fi
  done

  # An explicit remote NAME: the first bare word after `push` that resolves.
  if [[ $push_args =~ push[[:space:]]+((-[^[:space:]]+[[:space:]]+)*)([a-zA-Z0-9._-]+) ]]; then
    name="${BASH_REMATCH[3]}"
    url=$(git -C "$dir" remote get-url --push "$name" 2>/dev/null)
    [[ -n $url ]] && { _PUSH_URLS="$url"; return; }
  fi

  # The current branch's upstream remote.
  name=$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)
  name=${name%%/*}
  if [[ -n $name ]]; then
    url=$(git -C "$dir" remote get-url --push "$name" 2>/dev/null)
    [[ -n $url ]] && { _PUSH_URLS="$url"; return; }
  fi

  # Fall back to every push remote: a bare push could reach any of them.
  push_remote_urls "$dir"
}

# push_remote_urls <dir> -> $_PUSH_URLS: every configured push URL, de-duplicated.
push_remote_urls() {
  _PUSH_URLS=$(git -C "$1" remote -v 2>/dev/null | awk '$3=="(push)"{print $2}' | sort -u)
}

# is_foreign <urls>: 0 iff the repo is NOT ours — it has push remotes and not
# all of them are whitelisted. The same classification the destination rule
# and the content judge use. A remote-less repo is not foreign.
is_foreign() {
  [[ -n $1 ]] && ! all_whitelisted "$1"
}

# judge_mirror <dir> <urls> <what>: in a repo that is not ours, a checkout of
# the remote's DEFAULT branch is a read-only mirror of it — work happens in the
# user's worktrees on their own branches. Exits 2 on a block, returns otherwise.
# Fails closed when no remote records its default branch.
judge_mirror() {
  local dir="$1" urls="$2" what="$3" branch r head known=0
  branch=$(git -C "$dir" symbolic-ref -q --short HEAD 2>/dev/null) || return 0   # detached
  [[ -n $branch ]] || return 0
  for r in $(git -C "$dir" remote 2>/dev/null); do
    r=${r%$'\r'}
    head=$(git -C "$dir" symbolic-ref -q --short "refs/remotes/$r/HEAD" 2>/dev/null) || continue
    [[ -n $head ]] || continue
    known=1
    if [[ $head == "$r/$branch" ]]; then
      echo "BLOCKED: $what — this checkout is on $head, the default branch of a repo that is not ours ($(echo $urls | sed 's/ /, /g')). It is a read-only mirror." >&2
      echo "Make the change in a worktree on its own branch." >&2
      exit 2
    fi
  done
  if [[ $known -eq 0 ]]; then
    echo "BLOCKED: $what — cannot tell whether branch '$branch' is the remote's default branch (no refs/remotes/<remote>/HEAD) in a repo that is not ours." >&2
    echo "Ask the user to run: git -C \"$dir\" remote set-head origin --auto" >&2
    exit 2
  fi
}

# judge_file_edit <path>: the Edit/Write/MultiEdit/NotebookEdit rule.
judge_file_edit() {
  local dir="${1//\\//}"
  # A Write may create new directories: judge the nearest existing one.
  while :; do
    dir=$(dirname "$dir")
    [[ -d $dir ]] && break
    [[ $dir == "." || $dir == "/" || $dir =~ ^[A-Za-z]:/?$ ]] && exit 0
  done
  push_remote_urls "$dir"
  is_foreign "$_PUSH_URLS" || exit 0
  judge_mirror "$dir" "$_PUSH_URLS" "$1"
  exit 0
}

# `git [global opts] <verb> <rest-of-segment>`. Only global options may sit
# between git and the verb (so `git log --grep stash` is not a stash); the rest
# runs to the next shell separator. Keep in sync with VerbRe in Program.cs.
_VERB_RE='(^|[^[:alnum:]_/\\])git(([[:blank:]]+-[Cc][[:blank:]]+[^[:blank:];&|]+)|([[:blank:]]+--?[[:alpha:]][^[:blank:];&|]*))*[[:blank:]]+(checkout|switch|branch|stash|add|reset|clean|worktree)(([[:blank:]][^;&|]*)?)([;&|]|$)'

_short_has() { [[ $1 == -[!-]* && $1 == *"$2"* ]]; }

# verb_reason <verb> <tokens...> -> $_REASON (empty = not a write we police,
# except a plain add, which the mirror rule still judges).
verb_reason() {
  local verb="$1" x; shift
  _REASON=""
  case "$verb" in
    checkout)
      for x in "$@"; do [[ $x == -b || $x == -B || $x == --orphan ]] && { _REASON="git checkout -b creates a branch"; return; }; done
      for x in "$@"; do [[ $x == -- ]] && return; done   # restoring named paths
      for x in "$@"; do [[ $x != -* ]] && { _REASON="git checkout <branch> switches the checkout's branch"; return; }; done ;;
    switch) _REASON="git switch changes the checkout's branch" ;;
    branch)
      [[ $# -eq 0 ]] && return
      [[ $1 != -* ]] && { _REASON="git branch <name> creates a branch"; return; }
      for x in "$@"; do
        case "$x" in -d|-D|--delete|-m|-M|--move|-c|-C|--copy|-f|--force|-u|--unset-upstream|--set-upstream-to*)
          _REASON="git branch $x rewrites branches"; return ;;
        esac
      done ;;
    stash) [[ ${1:-} == list || ${1:-} == show ]] || _REASON="git stash moves the user's uncommitted work" ;;
    add)
      for x in "$@"; do
        case "$x" in .|./|:/|--all|--update|--no-ignore-removal) _REASON="git add -A / -u / . stages the whole tree (stage named files only)"; return ;; esac
        if _short_has "$x" A || _short_has "$x" u; then _REASON="git add -A / -u / . stages the whole tree (stage named files only)"; return; fi
      done ;;
    reset) for x in "$@"; do [[ $x == --hard ]] && { _REASON="git reset --hard discards the user's work"; return; }; done ;;
    clean) for x in "$@"; do if [[ $x == --force ]] || _short_has "$x" f; then _REASON="git clean -f deletes untracked files"; return; fi; done ;;
    worktree) [[ ${1:-} == add ]] && _REASON="git worktree add creates a checkout" ;;
  esac
}

# policed_verbs <cmd> -> $_VERB_BLOCK (first reason, or empty); $_VERB_HIT=1 if
# anything matched, a plain `git add <path>` included (the mirror rule judges it).
policed_verbs() {
  local line rest verb toks
  _VERB_BLOCK=""; _VERB_HIT=0
  while IFS= read -r line; do
    line=${line%$'\r'}
    while [[ $line =~ $_VERB_RE ]]; do
      verb="${BASH_REMATCH[5]}"
      rest="${BASH_REMATCH[6]}"
      line=" ${line#*"${BASH_REMATCH[0]}"}"
      read -ra toks <<< "$rest"
      verb_reason "$verb" "${toks[@]}"
      if [[ -n $_REASON ]]; then
        _VERB_HIT=1; [[ -z $_VERB_BLOCK ]] && _VERB_BLOCK="$_REASON"
      elif [[ $verb == add ]]; then
        _VERB_HIT=1
      fi
    done
  done <<< "$1"
}

# all_whitelisted <urls>: 0 iff every non-empty line is whitelisted. No URLs
# at all -> 1 (fail closed: we could not establish the destination).
all_whitelisted() {
  local urls="$1" url n=0
  [[ -z $urls ]] && return 1
  while IFS= read -r url; do
    url=${url%$'\r'}
    [[ -z $url ]] && continue
    n=$((n+1))
    is_whitelisted_url "$url" || return 1
  done <<< "$urls"
  [[ $n -eq 0 ]] && return 1
  return 0
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
  case "$input" in *git*|*'"file_path"'*|*'"notebook_path"'*) ;; *) exit 0 ;; esac   # fast bail: no git, no file tool, no work

  export PATH="$PATH:/c/Users/$USER/bin:/c/ProgramData/chocolatey/bin:/c/Users/$USER/AppData/Local/Microsoft/WinGet/Links"
  command -v jq &>/dev/null || { echo "BLOCKED: jq not found — hook cannot parse input." >&2; exit 2; }

  local cmd cwd
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command') || { echo "BLOCKED: failed to parse hook input." >&2; exit 2; }
  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
  local file
  file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
  # ── File-edit tools (Edit/Write/MultiEdit/NotebookEdit) ──
  [[ -n $file ]] && judge_file_edit "$file"
  [[ -z $cmd || $cmd == null ]] && { echo "BLOCKED: could not extract command from hook input." >&2; exit 2; }

  # ── Belt 1: redirect on a commit/push (bypasses the per-repo git hook) ──
  if [[ $cmd =~ ${_GIT}(commit|push)([^[:alnum:]_]|$) ]]; then
    if _has_redirect "$cmd"; then
      echo "BLOCKED: git redirect (GIT_DIR / --git-dir / --work-tree / --namespace) is not allowed — it points git at a repo whose guard hook may be absent. Use 'git -C <path>' or run it manually." >&2
      exit 2
    fi
    # ── Belt 2: --no-verify / -n skips git hooks, defeating the real judge ──
    # Judge flags on the COMMAND only: heredoc bodies are data (a commit
    # message may legitimately discuss these flags), and quoted strings
    # likewise.
    _strip_heredocs "$cmd"
    _strip_quotes "$_STRIPPED_HD"
    # `-n` must be an argument to git commit/push, not the shell's string-test
    # operator: `if [ -n "$x" ]; then git commit ...` is ordinary scripting and
    # was being blocked. Require -n to follow `git [opts] commit|push`.
    if [[ $_STRIPPED =~ (^|[[:space:]])--no-verify([[:space:]]|=|$) ]] \
       || [[ $_STRIPPED =~ git([[:space:]]+-[^[:space:]]+)*[[:space:]]+(commit|push)([[:space:]]+[^[:space:]]+)*[[:space:]]+-n([[:space:]]|$) ]]; then
      echo "BLOCKED: --no-verify / -n is not allowed on commit/push — it bypasses the git-guard hook that judges the destination. Run it manually if you truly intend to skip the guard." >&2
      exit 2
    fi
    resolve_target "$cmd" "$cwd"
    [[ -z $_TARGET ]] && { echo "BLOCKED: could not determine target directory for git command." >&2; exit 2; }

    # ── Belt 3: DESTINATION. This is the rule that binds Claude and only
    # Claude — the user is trusted to push wherever they like. It lives here,
    # not in the per-repo git hook, because a git hook fires for everyone and
    # cannot tell who invoked it (and no env var can establish that either:
    # Claude could clear any flag for a child process it spawns). This hook is
    # a separate execution path that only ever runs for Claude, so there is
    # nothing here for Claude to unset. ──
    resolve_push_urls "$_TARGET" "$_STRIPPED_HD"
    if ! all_whitelisted "$_PUSH_URLS"; then
      echo "BLOCKED: this would commit/push to a repo that is not ours." >&2
      if [[ -n $_PUSH_URLS ]]; then
        echo "Destination:" >&2
        printf '  %s\n' $_PUSH_URLS >&2
      else
        echo "Destination could not be determined (no push remote resolved)." >&2
      fi
      echo "Allowed: github.com, dev.azure.com/evolx/ (incl. ssh form)." >&2
      echo "If this is a customer repo the block is intended — run it yourself in a terminal." >&2
      exit 2
    fi

    # ── Self-heal the target repo, then defer to its git hook for CONTENT ──
    local verdict; verdict=$(ensure_hook "$_TARGET")
    case "$verdict" in
      foreign)
        echo "BLOCKED: $_TARGET/.git/hooks already has a non-git-guard hook. Refusing to overwrite it. Install git-guard manually (chain it) or run the command yourself." >&2
        exit 2 ;;
    esac
    exit 0   # destination is ours; the git hook now judges CONTENT
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

  # ── Belt 5: working-tree writes in a repo that is not ours ──
  # Quoted strings are data (a message, a JSON payload), not commands.
  _strip_heredocs "$cmd"
  _strip_quotes "$_STRIPPED_HD" Q
  policed_verbs "$_STRIPPED"
  if [[ $_VERB_HIT -eq 1 ]]; then
    resolve_target "$cmd" "$cwd"
    [[ -z $_TARGET ]] && { echo "BLOCKED: could not determine target directory for git command." >&2; exit 2; }
    push_remote_urls "$_TARGET"
    is_foreign "$_PUSH_URLS" || exit 0
    if [[ -n $_VERB_BLOCK ]]; then
      echo "BLOCKED: $_VERB_BLOCK, in a repo that is not ours ($(echo $_PUSH_URLS | sed 's/ /, /g'))." >&2
      echo "That checkout is the user's: hand them the command instead of running it." >&2
      exit 2
    fi
    # Only plain `git add <path>` is left: allowed unless this is the mirror.
    judge_mirror "$_TARGET" "$_PUSH_URLS" "git add in $_TARGET"
  fi

  exit 0   # not a git write we police — let it through
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
fi
