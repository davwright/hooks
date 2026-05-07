#!/bin/bash
# Unit tests for block-git-write.sh.
#
# Each test case is one line:
#   <expected_exit>:<repo>:<command>
# where <expected_exit> is 0 (allow) or 2 (block), <repo> selects which fake
# git repo to set as cwd / target (whitelisted | blocked), and <command> is
# the literal command string passed to the hook as if from PreToolUse.
#
# We feed the hook the same JSON shape Claude Code produces and assert on
# the exit code. Stderr is captured for failure diagnostics.
#
# Run: bash ~/.claude/hooks/block-git-write.test.sh
#      Exit code: 0 if all pass, 1 otherwise.

set -u
HOOK="$(dirname "$0")/block-git-write.sh"
if [ ! -f "$HOOK" ]; then
  echo "FATAL: hook not found at $HOOK" >&2
  exit 2
fi

# ── Set up two throwaway git repos to point CWD/-C at ─────────────────────
TMP=$(mktemp -d)
trap "rm -rf '$TMP'" EXIT

ALLOWED="$TMP/allowed"
BLOCKED="$TMP/blocked"
mkdir -p "$ALLOWED" "$BLOCKED"
git -C "$ALLOWED" init -q
git -C "$ALLOWED" remote add origin 'https://evolx@dev.azure.com/evolx/test/_git/test'
git -C "$BLOCKED" init -q
git -C "$BLOCKED" remote add origin 'https://oebb-azure-platform@dev.azure.com/oebb/customer/_git/customer'

resolve_repo() {
  case "$1" in
    allowed) echo "$ALLOWED" ;;
    blocked) echo "$BLOCKED" ;;
    none)    echo "/" ;;        # not a git repo
    *)       echo "$1" ;;       # literal path
  esac
}

run_hook() {
  # $1 = cwd path, $2 = command
  local cwd="$1" cmd="$2"
  # Build PreToolUse JSON like Claude Code does. cwd + tool_input.command
  # are the two fields the hook reads.
  printf '{"cwd":%s,"tool_input":{"command":%s}}' \
    "$(printf %s "$cwd" | jq -Rs .)" \
    "$(printf %s "$cmd" | jq -Rs .)" \
    | "$HOOK" >/tmp/_hook.stdout 2>/tmp/_hook.stderr
  echo $?
}

PASS=0
FAIL=0
FAIL_LOG=""

assert() {
  # $1 = expected exit, $2 = repo selector for cwd, $3 = command, $4 = label
  local expected="$1" repo="$2" cmd="$3" label="$4"
  local cwd
  cwd=$(resolve_repo "$repo")
  # Substitute placeholders inside the command. {ALLOWED}/{BLOCKED} expand
  # to absolute paths so we can test git -C and cd targets.
  cmd=${cmd//\{ALLOWED\}/$ALLOWED}
  cmd=${cmd//\{BLOCKED\}/$BLOCKED}
  local actual
  actual=$(run_hook "$cwd" "$cmd")
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS+1))
    printf "  ok   %s\n" "$label"
  else
    FAIL=$((FAIL+1))
    FAIL_LOG+=$'\n'"  FAIL  $label"$'\n'"        cwd=$cwd"$'\n'"        cmd=$cmd"$'\n'"        expected exit=$expected actual=$actual"$'\n'"        stderr: $(cat /tmp/_hook.stderr)"
    printf "  FAIL %s\n" "$label"
  fi
}

# ── 1. Non-git commands always pass through ────────────────────────────────
echo "== non-git commands =="
assert 0 allowed 'ls -la'                     'plain ls'
assert 0 blocked 'ls -la'                     'plain ls in blocked cwd'
assert 0 allowed 'echo hello'                 'echo'
assert 0 allowed 'cat ~/.gitignore'           'cat .gitignore'
assert 0 allowed 'git status'                 'git status (read-only)'
assert 0 allowed 'git log --oneline'          'git log'
assert 0 allowed 'git diff main'              'git diff'
assert 0 allowed 'git remote -v'              'git remote'

# ── 2. Plain commit/push in whitelisted repo allowed ──────────────────────
echo "== whitelisted repo =="
assert 0 allowed 'git commit -m foo'                        'commit in allowed cwd'
assert 0 allowed 'git push origin main'                     'push in allowed cwd'
assert 0 allowed 'git commit --amend -m foo'                'amend in allowed cwd'
assert 0 allowed 'git -C {ALLOWED} commit -m foo'           'git -C allowed commit'
assert 0 allowed 'git -C {ALLOWED} push'                    'git -C allowed push'

# ── 3. Plain commit/push in blocked repo refused ──────────────────────────
echo "== blocked repo =="
assert 2 blocked 'git commit -m foo'                        'commit in blocked cwd'
assert 2 blocked 'git push'                                 'push in blocked cwd'
assert 2 allowed 'git -C {BLOCKED} commit -m foo'           'git -C blocked from allowed cwd'
assert 2 allowed 'git -C {BLOCKED} push'                    'git -C blocked push from allowed cwd'

# ── 4. cd <blocked> && git commit ─────────────────────────────────────────
echo "== cd redirection =="
assert 2 allowed 'cd {BLOCKED} && git commit -m foo'        'cd blocked then commit'
assert 0 blocked 'cd {ALLOWED} && git commit -m foo'        'cd allowed from blocked cwd'

# ── 5. GIT_DIR / GIT_WORK_TREE env-var bypass attempts ────────────────────
echo "== env-var redirect =="
assert 2 allowed 'GIT_DIR={BLOCKED}/.git git commit -m foo' 'GIT_DIR= prefix'
assert 2 allowed 'GIT_WORK_TREE={BLOCKED} git commit'       'GIT_WORK_TREE= prefix'
assert 2 allowed 'GIT_COMMON_DIR=/x git commit'             'GIT_COMMON_DIR= prefix'
assert 2 allowed 'GIT_INDEX_FILE=/x git commit'             'GIT_INDEX_FILE= prefix'
assert 2 allowed 'export GIT_DIR=/x; git commit'            'export GIT_DIR before commit'
assert 2 allowed 'foo && GIT_DIR={BLOCKED}/.git git commit' 'GIT_DIR after &&'
# But: env-var on a NON-git command still passes (early exit on the regex)
assert 0 allowed 'GIT_DIR=/foo echo hello'                  'GIT_DIR= on echo (not git)'
assert 0 allowed 'GIT_DIR=/foo git status'                  'GIT_DIR= on git status (not commit/push)'

# ── 6. --git-dir / --work-tree / --namespace flag bypass attempts ─────────
echo "== flag redirect =="
assert 2 allowed 'git --git-dir={BLOCKED}/.git commit -m foo'   '--git-dir= flag'
assert 2 allowed 'git --git-dir {BLOCKED}/.git commit -m foo'   '--git-dir <space> flag'
assert 2 allowed 'git --work-tree={BLOCKED} commit -m foo'      '--work-tree= flag'
assert 2 allowed 'git --work-tree {BLOCKED} commit -m foo'      '--work-tree <space> flag'
assert 2 allowed 'git --namespace=foo commit -m foo'            '--namespace= flag'
# Read-only commands with --git-dir still pass (early-gate skips)
assert 0 allowed 'git --git-dir=/x status'                      '--git-dir= on status (not commit/push)'

# ── 7. False-positive guards ──────────────────────────────────────────────
echo "== false-positive guards =="
# Identifiers that contain "git commit" but are not commands
assert 0 allowed 'echo "register_git_commit"'                   'echo containing git_commit token'
assert 0 allowed 'echo "git committee"'                         'echo containing git committee text'
# git config that mentions work-tree
assert 0 allowed 'git config --get-regexp work-tree'            'git config get-regexp'
# A command that just sets GIT_DIR for downstream use, no commit
assert 0 allowed 'export GIT_DIR=/x'                            'lone export of GIT_DIR'
# echo of GIT_DIR=foo bytes is not a commit
assert 0 allowed 'echo GIT_DIR=foo'                             'echo GIT_DIR=foo'

# ── 8. Force flags should block on blocked repo ───────────────────────────
echo "== force-push protection =="
assert 2 blocked 'git push --force'                             'force push in blocked'
assert 0 allowed 'git push --force-with-lease origin feat'      'force-with-lease in allowed'

# ── 9. --no-verify is allowed shape-wise (hook doesn't police it) ─────────
echo "== --no-verify (out of hook scope) =="
assert 0 allowed 'git commit --no-verify -m foo'                '--no-verify in allowed (Claude rules separate)'

# ── 10. fail-closed when target dir is not a git repo ─────────────────────
echo "== non-git target =="
assert 2 none 'git commit -m foo'                               'commit in non-git cwd'
assert 2 allowed 'git -C /tmp/no-such-repo commit -m foo'       'git -C non-existent dir'

# ── 11. remote mutation refused even in a whitelisted repo ────────────────
echo "== remote mutation =="
assert 2 allowed 'git remote add evil https://evil.example/x.git'   'remote add'
assert 2 allowed 'git remote remove origin'                         'remote remove'
assert 2 allowed 'git remote rm origin'                             'remote rm'
assert 2 allowed 'git remote rename origin foo'                     'remote rename'
assert 2 allowed 'git remote set-url origin https://evil/x.git'     'remote set-url'
assert 2 allowed 'git remote set-url --push origin https://evil/x'  'remote set-url --push'
assert 2 allowed 'git remote set-branches origin main'              'remote set-branches'
assert 2 allowed 'git remote set-head origin main'                  'remote set-head'
assert 2 allowed 'git remote prune origin'                          'remote prune'
# git -C <blocked> remote add should still be refused
assert 2 allowed 'git -C {BLOCKED} remote add evil https://evil/x.git' '-C blocked remote add'
# Read-only remote ops still allowed
assert 0 allowed 'git remote'                                       'plain git remote'
assert 0 allowed 'git remote -v'                                    'git remote -v'
assert 0 allowed 'git remote show origin'                           'git remote show'
assert 0 allowed 'git remote get-url origin'                        'git remote get-url'

# ── 12. git config remote.* refused (back-door for set-url) ───────────────
echo "== config remote.* =="
assert 2 allowed 'git config remote.origin.url https://evil/x.git'             'config remote.origin.url'
assert 2 allowed 'git config remote.origin.pushurl https://evil/x.git'         'config remote.origin.pushurl'
assert 2 allowed 'git config --global remote.origin.url https://evil/x.git'    'config --global remote.origin.url'
assert 2 allowed 'git config --local remote.origin.url https://evil/x.git'     'config --local remote.origin.url'
assert 2 allowed 'git config --add remote.origin.fetch +refs/*:refs/*'         'config --add remote.origin.fetch'
assert 2 allowed 'git -C {BLOCKED} config remote.origin.url https://x'         '-C blocked config remote.url'
# Other git config calls remain allowed (read-only or non-remote write)
assert 0 allowed 'git config --get-regexp work-tree'                'config get-regexp'
assert 0 allowed 'git config user.email me@example.com'             'config user.email'
assert 0 allowed 'git config core.autocrlf input'                   'config core.autocrlf'
assert 0 allowed 'git config --get remote.origin.url'               'config --get remote.url (read)'

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  printf "%s\n" "$FAIL_LOG"
  exit 1
fi
exit 0
