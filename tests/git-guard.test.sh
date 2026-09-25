#!/bin/bash
# Tests for git-guard.sh — the CONTENT judge.
#
# Contract under test (v2). This hook fires for EVERYONE (user's terminal,
# VSCode SCM panel, Claude alike), so it enforces only the rule that should
# bind everyone: no AI-tool words in a CUSTOMER repo's history. The
# destination rule ("Claude may not push to customer repos") lives in
# claude-git-guard.sh and is NOT tested here.
#
#   1. SCOPE     own repo (github / dev.azure.com/evolx) -> never scanned
#                customer repo (anything else)           -> scanned
#                remote-less repo                        -> never scanned
#                mixed remotes (one foreign)             -> scanned
#   2. ANCHORING a URL merely CONTAINING an own-host string is foreign
#   3. CONTENT   commit message + ADDED diff lines scanned, word-bounded,
#                case-insensitive; removals and context lines ignored
#   4. MODES     pre-commit scans the staged diff; commit-msg scans the FINAL
#                message (the reliable gate — COMMIT_EDITMSG is not final at
#                pre-commit time); pre-push scans the whole pushed range
#
# Run: bash git-guard.test.sh   (exit 0 = all pass)

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/src/git-guard.sh"
[ -f "$GUARD" ] || { echo "FATAL: git-guard.sh not found at $GUARD" >&2; exit 2; }

# Tee everything to a log so the result can be read from disk instead of
# copied out of a terminal. Override with LOG=<path>.
LOG="${LOG:-$ROOT/tests/git-guard.last.log}"
exec > >(tee "$LOG") 2>&1

TMP=$(mktemp -d); trap "rm -rf '$TMP'" EXIT
# Neutralize the self-update path: HOME with no template to sync from. We are
# testing the JUDGE, not the stub refresh.
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

PASS=0; FAIL=0; FAILED=()
check() {
  local expected="$1" actual="$2" label="$3"
  if [ "$actual" = "$expected" ]; then PASS=$((PASS+1)); printf "  ok   %s\n" "$label"
  else
    FAIL=$((FAIL+1))
    local why; why=$(head -2 "$TMP/err" 2>/dev/null | tr '\n' ' ' | cut -c1-90)
    FAILED+=("$label (exp=$expected got=$actual) $why")
    printf "  FAIL %s (exp=%s got=%s) %s\n" "$label" "$expected" "$actual" "$why"
  fi
}

# check_content <expected> <actual> <label>
# Like check, but for cases that must be decided by the CONTENT scan. A block
# is only a pass if stderr shows a content reason — otherwise an implementation
# that blocks every customer repo outright (as v1 did, on destination) would
# score a false pass here. Guards the tests against testing nothing.
check_content() {
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" = "1" ] && [ "$actual" = "1" ]; then
    if grep -qiE "contains '|attribution pattern|AI-tool reference" "$TMP/err" 2>/dev/null; then
      PASS=$((PASS+1)); printf "  ok   %s\n" "$label"
    else
      FAIL=$((FAIL+1))
      local why; why=$(head -1 "$TMP/err" 2>/dev/null | cut -c1-90)
      FAILED+=("$label -- blocked, but NOT by the content scan: $why")
      printf "  FAIL %s (blocked, but NOT by the content scan: %s)\n" "$label" "$why"
    fi
    return
  fi
  check "$expected" "$actual" "$label"
}

# mkrepo <name> <url...> -> path. No url = remote-less.
mkrepo() {
  local n="$1"; shift
  local d="$TMP/$n"; git init -q "$d"
  # Fixtures are LF-only; without this every `git add` prints a CRLF warning
  # that buries the actual results.
  git -C "$d" config core.autocrlf false
  git -C "$d" config core.safecrlf false
  local i=0
  for u in "$@"; do
    if [ $i -eq 0 ]; then git -C "$d" remote add origin "$u"; else git -C "$d" remote add "r$i" "$u"; fi
    i=$((i+1))
  done
  printf '%s' "$d"
}

# stage <repo> <file> <content> : write + stage, no commit
stage() { printf '%s\n' "$3" > "$1/$2"; git -C "$1" add "$2"; }

# seed <repo> <file> <content> <message> : create a fixture commit on main.
# Uses git PLUMBING (hash-object / mktree / commit-tree / update-ref), which
# does not consult .git/hooks at all. Deliberately NOT `git commit` with hooks
# switched off: no test in this suite may contain a way to disable the guard,
# because such a construct is exactly what an attacker (or a careless future
# edit) would reach for. Plumbing sidesteps the hook machinery instead of
# defeating it. Leaves the worktree file in place and the index matching HEAD.
seed() {
  local r="$1" f="$2" content="$3" msg="$4"
  printf '%s\n' "$content" > "$r/$f"
  local blob tree parent commit
  blob=$(git -C "$r" hash-object -w --path "$f" -- "$r/$f")
  tree=$(printf '100644 blob %s\t%s\n' "$blob" "$f" | git -C "$r" mktree)
  parent=$(git -C "$r" rev-parse --verify -q HEAD 2>/dev/null || true)
  if [ -n "$parent" ]; then
    commit=$(git -C "$r" commit-tree "$tree" -p "$parent" -m "$msg")
  else
    commit=$(git -C "$r" commit-tree "$tree" -m "$msg")
  fi
  git -C "$r" update-ref refs/heads/main "$commit"
  git -C "$r" symbolic-ref HEAD refs/heads/main
  git -C "$r" read-tree "$tree"
  printf '%s' "$commit"
}

# setmsg <repo> <text> : seed COMMIT_EDITMSG as git would
setmsg() { printf '%s\n' "$2" > "$1/.git/COMMIT_EDITMSG"; }

# run_commit <repo> -> exit code
run_commit() { ( cd "$1" && bash "$GUARD" pre-commit ) >/dev/null 2>"$TMP/err"; echo $?; }

# run_msg <repo> <message> -> exit code. Mirrors how git invokes commit-msg:
# argv is the path to the file holding the FINAL message.
run_msg() {
  printf '%s\n' "$2" > "$1/.git/COMMIT_EDITMSG"
  ( cd "$1" && bash "$GUARD" commit-msg .git/COMMIT_EDITMSG ) >/dev/null 2>"$TMP/err"
  echo $?
}

# run_push <repo> <url> <refline> -> exit code  (refline on stdin)
run_push() {
  printf '%s\n' "$3" | ( cd "$1" && bash "$GUARD" pre-push origin "$2" ) >/dev/null 2>"$TMP/err"
  echo $?
}

OWN_GH=$(mkrepo own_gh 'https://github.com/davwright/x.git')
OWN_ADO=$(mkrepo own_ado 'https://evolx@dev.azure.com/evolx/p/_git/r')
OWN_SSH=$(mkrepo own_ssh 'git@ssh.dev.azure.com:v3/evolx/p/r')
CUST=$(mkrepo cust 'https://oebb-azure-platform@dev.azure.com/oebb-azure-platform/osis/_git/osis')
CUST_SSH=$(mkrepo cust_ssh 'git@ssh.dev.azure.com:v3/oebb-azure-platform/osis/osis-integration')
NOREMOTE=$(mkrepo noremote)
MIXED=$(mkrepo mixed 'https://github.com/me/x.git' 'https://oebb-azure-platform@dev.azure.com/oebb/c/_git/c')

echo "== SCOPE: which repos get scanned at all =="
# A dirty word is staged in every repo; only customer repos should object.
for r in "$OWN_GH" "$OWN_ADO" "$OWN_SSH" "$CUST" "$CUST_SSH" "$NOREMOTE" "$MIXED"; do
  stage "$r" f.txt 'this mentions Claude and Opus'
  setmsg "$r" 'Generated with Claude'
done
check 0 "$(run_commit "$OWN_GH")"   'own github repo: dirty content allowed (not scanned)'
check 0 "$(run_commit "$OWN_ADO")"  'own ADO evolx repo: dirty content allowed'
check 0 "$(run_commit "$OWN_SSH")"  'own ADO evolx ssh repo: dirty content allowed'
check 0 "$(run_commit "$NOREMOTE")" 'remote-less repo: dirty content allowed'
check_content 1 "$(run_commit "$CUST")"     'customer repo: dirty content BLOCKED'
check_content 1 "$(run_commit "$CUST_SSH")" 'customer ssh repo: dirty content BLOCKED'
check_content 1 "$(run_commit "$MIXED")"    'mixed remotes (one foreign): BLOCKED'

echo "== ANCHORING: own-host string must be the real host =="
for u in \
  'https://github.com.evil.io/x/y.git' \
  'https://oebb.example.com/github.com/osis' \
  'https://dev.azure.com/evolx/../oebb-azure-platform/_git/osis' \
  'https://dev.azure.com/evolxevil/_git/x' \
  'https://notgithub.com/x/y.git' ; do
  d=$(mkrepo "spoof$RANDOM" "$u"); stage "$d" f.txt 'Claude'; setmsg "$d" 'x'
  check_content 1 "$(run_commit "$d")" "spoofed own-host treated as customer: $u"
done

echo "== CONTENT: word list, boundaries, case =="
dirty() { # <word-or-phrase> <expected>
  local d; d=$(mkrepo "w$RANDOM" 'https://oebb-azure-platform@dev.azure.com/oebb/c/_git/c')
  stage "$d" f.txt "$1"; setmsg "$d" 'clean subject'
  check_content "$2" "$(run_commit "$d")" "diff content: '$1'"
}
# every blacklisted word must trip
for w in claude anthropic opus sonnet haiku fable llm gpt copilot; do dirty "x $w y" 1; done
# case-insensitive
dirty 'CLAUDE'  1
dirty 'Opus'    1
dirty 'FaBlE'   1
# word-bounded: these must NOT trip
dirty 'claudel'          0
dirty 'opuscule'         0
dirty 'llmnop'           0
dirty 'encyclopedia'     0
dirty 'sonnets_are_fine' 0
# punctuation/delimiters still count as boundaries -> must trip
dirty 'see(claude)'   1
dirty 'ai-opus-model' 1
dirty '[llm]'         1

echo "== CONTENT: attribution phrases (via commit-msg, the reliable gate) =="
phrase() {
  local d; d=$(mkrepo "p$RANDOM" 'https://oebb-azure-platform@dev.azure.com/oebb/c/_git/c')
  check_content "$2" "$(run_msg "$d" "$1")" "commit message: '$1'"
}
phrase 'fix thing'                                  0
phrase 'Co-Authored-By: Claude Opus 5 <x@y>'        1
phrase 'Co-authored-by: claude'                     1
phrase 'Coauthored-by: Claude'                      1
phrase 'Generated with Claude Code'                 1

echo "== CONTENT: private Pulse ids in commit messages =="
phrase 'Fix the thing (PS-1009)'          1
phrase 'refs ps-12'                       1
phrase 'see pulse123 for details'         1
phrase 'PS-1'                             1
phrase 'Pulse 12 was discussed'           0
phrase 'ups-12 is a part number'          0
phrase 'use PS-style prompts'             0
phrase 'impulse123'                       0
# The id rule is for messages: a diff line mentioning one is not blocked.
dirty 'label PS-1009 in code' 0
# Own repos are never scanned, ids included.
OWNID=$(mkrepo ownid 'https://github.com/me/x.git')
check 0 "$(run_msg "$OWNID" 'Fix (PS-1009)')" 'own repo: Pulse id in message allowed'
PPID_REPO=$(mkrepo ppid 'https://oebb-azure-platform@dev.azure.com/oebb/c/_git/c')
PB=$(seed "$PPID_REPO" f.txt 'a' 'clean one')
PT=$(seed "$PPID_REPO" f.txt 'a
b' 'Fix the form (PS-1009)')
check_content 1 "$(run_push "$PPID_REPO" 'https://oebb-azure-platform@dev.azure.com/oebb/c/_git/c' \
  "refs/heads/main $PT refs/heads/main $PB")" 'push: Pulse id in a pushed message BLOCKED'

echo "== commit-msg: scope and mechanics =="
# Own repo -> message never scanned, even a dirty one.
OWNMSG=$(mkrepo ownmsg 'https://github.com/me/x.git')
check 0 "$(run_msg "$OWNMSG" 'Co-Authored-By: Claude Opus 5')" 'own repo: dirty message allowed'
# Git's comment lines must not be scanned: the commented hint mentions Claude
# but is stripped before the commit is made, so it must not block.
CMSG=$(mkrepo cmsg 'https://oebb-azure-platform@dev.azure.com/oebb/c/_git/c')
check 0 "$(run_msg "$CMSG" 'real subject
# this comment mentions claude and is stripped by git')" 'comment lines ignored'
# --verbose puts the whole diff below a scissors line; it is stripped too, so a
# dirty line in the diff preview must not trip commit-msg (pre-commit sees it).
check 0 "$(run_msg "$CMSG" 'real subject
# ------------------------ >8 ------------------------
# Do not modify or remove the line above.
diff --git a/f b/f
+claude in the diff preview')" 'scissors section ignored'
# Missing/absent message file is a no-op, not a crash.
check 0 "$(cd "$CMSG" && bash "$GUARD" commit-msg .git/NOPE >/dev/null 2>"$TMP/err"; echo $?)" \
  'absent message file: no-op'
# Multi-line body, dirty only in a trailer.
check_content 1 "$(run_msg "$CMSG" 'fix the thing

Longer explanation here.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>')" 'dirty trailer in multi-line message'

echo "== CONTENT: only ADDED lines are scanned =="
# A commit that REMOVES a dirty word must be allowed — otherwise you could
# never clean one up.
CLEANUP=$(mkrepo cleanup 'https://oebb-azure-platform@dev.azure.com/oebb/c/_git/c')
seed "$CLEANUP" f.txt 'line with claude in it
keep me' 'seed' >/dev/null
printf 'keep me\n' > "$CLEANUP/f.txt"   # removes the dirty line
git -C "$CLEANUP" add f.txt
setmsg "$CLEANUP" 'remove the reference'
check 0 "$(run_commit "$CLEANUP")" 'removal-only diff: allowed'

# Context lines around an edit must not trip it either.
CTX=$(mkrepo ctx 'https://oebb-azure-platform@dev.azure.com/oebb/c/_git/c')
seed "$CTX" f.txt 'claude line stays
a
b
c' 'seed' >/dev/null
printf 'claude line stays\na\nCHANGED\nc\n' > "$CTX/f.txt"
git -C "$CTX" add f.txt
setmsg "$CTX" 'unrelated edit'
check 0 "$(run_commit "$CTX")" 'pre-existing dirty line as context: allowed'

echo "== CONTENT: binary / no-diff edge cases =="
EMPTY=$(mkrepo emptyc 'https://oebb-azure-platform@dev.azure.com/oebb/c/_git/c')
check 0 "$(run_commit "$EMPTY")" 'nothing staged: allowed'
# pre-commit judges the DIFF only — the message is commit-msg's job, because
# COMMIT_EDITMSG is not reliably final at pre-commit time. A dirty message with
# a clean diff must therefore pass pre-commit and be caught by commit-msg.
setmsg "$EMPTY" 'mentions claude'
check 0 "$(run_commit "$EMPTY")" 'dirty message, clean diff: pre-commit defers to commit-msg'
check_content 1 "$(run_msg "$EMPTY" 'mentions claude')" 'same message: commit-msg BLOCKS'

echo "== pre-push: scans the range being published =="
PP=$(mkrepo pp 'https://oebb-azure-platform@dev.azure.com/oebb/c/_git/c')
BASE=$(seed "$PP" f.txt 'a' 'clean one')
CLEAN_TIP=$(seed "$PP" f.txt 'a
b' 'still clean')
check 0 "$(run_push "$PP" 'https://oebb-azure-platform@dev.azure.com/oebb/c/_git/c' \
  "refs/heads/main $CLEAN_TIP refs/heads/main $BASE")" 'push: clean range allowed'

DIRTY_TIP=$(seed "$PP" f.txt 'a
b
c' 'Co-Authored-By: Claude Opus 5')
check_content 1 "$(run_push "$PP" 'https://oebb-azure-platform@dev.azure.com/oebb/c/_git/c' \
  "refs/heads/main $DIRTY_TIP refs/heads/main $CLEAN_TIP")" 'push: dirty commit message BLOCKED'

# Same dirty range, but pushed to an OWN remote -> scope skips it.
check 0 "$(run_push "$PP" 'https://github.com/me/x.git' \
  "refs/heads/main $DIRTY_TIP refs/heads/main $CLEAN_TIP")" 'push: dirty range to own remote allowed'

# Branch deletion (all-zero local sha) has nothing to scan.
check 0 "$(run_push "$PP" 'https://oebb-azure-platform@dev.azure.com/oebb/c/_git/c' \
  "(delete) 0000000000000000000000000000000000000000 refs/heads/gone $CLEAN_TIP")" \
  'push: branch deletion allowed'

# Empty stdin (nothing to push) must not hang or fail.
check 0 "$(run_push "$PP" 'https://oebb-azure-platform@dev.azure.com/oebb/c/_git/c' '')" \
  'push: empty ref list allowed'

echo "== modes =="
check 1 "$(bash "$GUARD" frobnicate </dev/null >/dev/null 2>"$TMP/err"; echo $?)" 'unknown mode -> blocked (fail closed)'

echo "== regression: script must define everything it calls =="
# The v2 rewrite dropped self_update_stub while still calling it. Catch that
# class of error: no "command not found" on any normal path.
D=$(mkrepo sanity 'https://github.com/me/x.git'); stage "$D" f.txt ok; setmsg "$D" ok
( cd "$D" && bash "$GUARD" pre-commit ) >/dev/null 2>"$TMP/err2"
check 0 "$(grep -ci 'command not found' "$TMP/err2" || true)" 'no undefined-function errors on pre-commit'
printf '' | ( cd "$D" && bash "$GUARD" pre-push origin 'https://github.com/me/x.git' ) >/dev/null 2>"$TMP/err3"
check 0 "$(grep -ci 'command not found' "$TMP/err3" || true)" 'no undefined-function errors on pre-push'
setmsg "$D" ok
( cd "$D" && bash "$GUARD" commit-msg .git/COMMIT_EDITMSG ) >/dev/null 2>"$TMP/err4"
check 0 "$(grep -ci 'command not found' "$TMP/err4" || true)" 'no undefined-function errors on commit-msg'

echo "== stub templates cover every mode =="
for h in pre-commit commit-msg pre-push; do
  check 0 "$([ -f "$ROOT/templates/hooks/$h" ] && echo 0 || echo 1)" "template stub exists: $h"
  check 0 "$(grep -q "git-guard.sh\|\$CANON\" $h" "$ROOT/templates/hooks/$h" 2>/dev/null && echo 0 || echo 1)" \
    "stub $h execs the canonical with mode $h"
done

echo ""
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "--- failures only ---"
  printf '  %s\n' "${FAILED[@]}"
  echo ""
fi
echo "=== git-guard: $PASS passed, $FAIL failed ==="
echo "log: $LOG"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
