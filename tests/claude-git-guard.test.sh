#!/bin/bash
# Tests for claude-git-guard.sh (the thin Claude PreToolUse hook). Feeds it the
# PreToolUse JSON shape and asserts exit codes + self-heal side effects.
#
# Run: bash claude-git-guard.test.sh   (exit 0 = all pass)

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Which implementation to test. Default: the bash hook, run via `bash`.
# Override to test the NativeAOT C# port — either give a full path, or just
# say `exe` to use the built binary under csharp/:
#   GUARD_CMD=exe bash tests/claude-git-guard.test.sh
#   GUARD_CMD="<path>/claude-git-guard.exe" bash tests/claude-git-guard.test.sh
# GUARD_CMD is invoked directly (the exe needs no interpreter); the default
# bash hook is prefixed with `bash` so it runs the same on Windows.
GUARD_CMD="${GUARD_CMD:-bash $ROOT/src/claude-git-guard.sh}"
[ "$GUARD_CMD" = "exe" ] && GUARD_CMD="$ROOT/csharp/bin/Release/net9.0/win-x64/publish/claude-git-guard.exe"
# Sanity-check the runner resolves to something that exists.
_RUNNER=${GUARD_CMD%% *}
case "$_RUNNER" in
  bash) [ -f "$ROOT/src/claude-git-guard.sh" ] || { echo "FATAL: claude-git-guard.sh not found" >&2; exit 2; } ;;
  *)    [ -x "$_RUNNER" ] || [ -f "$_RUNNER" ] || { echo "FATAL: GUARD_CMD runner not found: $_RUNNER" >&2; exit 2; } ;;
esac
echo "# runner: $GUARD_CMD"

# Root the temp dir on a real drive (under the real $HOME, which Git Bash
# reports as /c/...), NOT /tmp: the NativeAOT exe is a native Win32 process and
# only understands drive-letter paths. /tmp is MSYS-internal and won't resolve
# for the exe. Git Bash maps /c/ -> C:\ for both runners, so bash is unaffected.
_REALHOME="$HOME"
TMP=$(mktemp -d -p "$_REALHOME"); trap "rm -rf '$TMP'" EXIT
# Deploy a fake git template so self-heal has stubs to install from. This also
# becomes the HOME the hook sees, so self-heal reads its stubs from here.
export HOME="$TMP/home"; mkdir -p "$HOME/.git-template/hooks"
cp "$ROOT/templates/hooks/pre-commit" "$HOME/.git-template/hooks/pre-commit"
cp "$ROOT/templates/hooks/commit-msg" "$HOME/.git-template/hooks/commit-msg"
cp "$ROOT/templates/hooks/pre-push"   "$HOME/.git-template/hooks/pre-push"

ALLOWED="$TMP/allowed"; FOREIGN="$TMP/foreign"
git init -q "$ALLOWED"; git -C "$ALLOWED" remote add origin 'https://github.com/me/x.git'
git init -q "$FOREIGN"; git -C "$FOREIGN" remote add origin 'https://github.com/me/y.git'
# Customer repos: the destination rule must block commit AND push here.
CUST="$TMP/cust"; CUST_SSH="$TMP/cust_ssh"; OWN_SSH="$TMP/own_ssh"
git init -q "$CUST"; git -C "$CUST" remote add origin \
  'https://oebb-azure-platform@dev.azure.com/oebb-azure-platform/osis/_git/osis'
git init -q "$CUST_SSH"; git -C "$CUST_SSH" remote add origin \
  'git@ssh.dev.azure.com:v3/oebb-azure-platform/osis/osis-integration'
git init -q "$OWN_SSH"; git -C "$OWN_SSH" remote add origin \
  'git@ssh.dev.azure.com:v3/evolx/p/r'
printf '#!/bin/bash\necho hi\n' > "$FOREIGN/.git/hooks/pre-commit"; chmod +x "$FOREIGN/.git/hooks/pre-commit"

PASS=0; FAIL=0
run() {  # $1=cwd $2=command -> echo exit code
  printf '{"cwd":%s,"tool_input":{"command":%s}}' \
    "$(printf %s "$1" | jq -Rs .)" "$(printf %s "$2" | jq -Rs .)" \
    | $GUARD_CMD >/dev/null 2>"$TMP/err"; echo $?
}
check() {
  local expected="$1" actual="$2" label="$3"
  if [ "$actual" = "$expected" ]; then PASS=$((PASS+1)); printf "  ok   %s\n" "$label"
  else FAIL=$((FAIL+1)); printf "  FAIL %s (exp=%s got=%s) %s\n" "$label" "$expected" "$actual" "$(cat "$TMP/err")"; fi
}

echo "== fast bail / non-git =="
check 0 "$(run "$ALLOWED" 'ls -la')"               'plain ls'
check 0 "$(run "$ALLOWED" 'echo "git committee"')" 'prose containing git'
check 0 "$(run "$ALLOWED" 'cat c:/git/evolx/foo')" 'path segment /git/'

echo "== belt: destination (the Claude-only rule) =="
check 0 "$(run "$ALLOWED"  'git push')"            'push: own github repo allowed'
check 0 "$(run "$ALLOWED"  'git commit -m x')"     'commit: own github repo allowed'
check 0 "$(run "$OWN_SSH"  'git push')"            'push: own ADO evolx ssh allowed'
check 2 "$(run "$CUST"     'git push')"            'push: customer repo BLOCKED'
check 2 "$(run "$CUST"     'git commit -m x')"     'commit: customer repo BLOCKED'
check 2 "$(run "$CUST"     'git push origin main')" 'push: customer by remote name BLOCKED'
check 2 "$(run "$CUST_SSH" 'git push')"            'push: customer ssh BLOCKED'
# An explicit URL beats the configured remote: pushing a customer URL from
# inside an OWN repo must still be blocked.
check 2 "$(run "$ALLOWED" 'git push https://oebb-azure-platform@dev.azure.com/oebb/c/_git/c main')" \
  'push: explicit customer URL from own repo BLOCKED'
# Spoofed own-host URLs are foreign.
check 2 "$(run "$ALLOWED" 'git push https://github.com.evil.io/x/y.git main')" \
  'push: github.com.evil.io BLOCKED'
# Only the push's own arguments name a destination: a URL used by another
# command on the same line is not where the commit/push lands.
check 0 "$(run "$ALLOWED" 'git commit -m x; curl https://example.com')"   'commit; curl <url>: own repo allowed'
check 0 "$(run "$ALLOWED" "git -C $ALLOWED commit -m x; curl https://example.com")" 'git -C own commit; curl <url> allowed'
check 0 "$(run "$ALLOWED" 'git push; curl https://example.com')"          'push; curl <url>: own repo allowed'
check 0 "$(run "$ALLOWED" 'curl https://example.com && git push origin')" 'curl <url> && push: own repo allowed'
check 2 "$(run "$ALLOWED" 'curl https://github.com/x && git push https://evil.example/x.git main')" \
  'curl <own url> && push <foreign url> BLOCKED'
check 2 "$(run "$CUST" 'git commit -m x; curl https://github.com/me/x')"  'customer commit; curl <own url> still BLOCKED'

echo "== belt: --no-verify =="
check 2 "$(run "$ALLOWED" 'git commit --no-verify -m x')" '--no-verify blocked'
check 2 "$(run "$ALLOWED" 'git commit -n -m x')"          '-n blocked'
check 2 "$(run "$ALLOWED" 'git push --no-verify')"        'push --no-verify blocked'
check 0 "$(run "$ALLOWED" 'git commit -m "note --no-verify in msg"')" '--no-verify inside quoted msg allowed'
# Regression: the shell string-test operator -n is not git's -n. These are
# ordinary scripting and were being blocked.
check 0 "$(run "$ALLOWED" 'if [ -n "$x" ]; then git commit -m ok; fi')" 'shell [ -n ] test not treated as git -n'
check 0 "$(run "$ALLOWED" '[ -n "$x" ] && git push origin main')"       'shell [ -n ] before push allowed'
check 0 "$(run "$ALLOWED" 'if [ -z "$x" ]; then git push; fi')"         'shell [ -z ] test allowed'
# A heredoc BODY is data, not flags. A commit message that merely discusses
# these flags must not be read as using them.
check 0 "$(run "$ALLOWED" 'git commit -F - <<MSG
the -n belt matched the shell string-test operator
MSG')" 'heredoc body mentioning -n allowed'
check 0 "$(run "$ALLOWED" 'git commit -F - <<MSG
do not pass --no-verify here
MSG')" 'heredoc body mentioning --no-verify allowed'
# ...but a real flag on the command line still blocks, heredoc or not.
check 2 "$(run "$ALLOWED" 'git commit -n -F - <<MSG
subject
MSG')" 'real -n with a heredoc still blocked'

echo "== belt: redirect =="
check 2 "$(run "$ALLOWED" 'GIT_DIR=/x git commit -m y')"  'GIT_DIR= redirect blocked'
check 2 "$(run "$ALLOWED" 'git --git-dir=/x commit -m y')" '--git-dir flag blocked'

echo "== belt: remote mutation (fresh-init exception) =="
check 0 "$(run "$ALLOWED" 'git remote add origin https://github.com/me/z.git')"           'remote add whitelisted -> allowed'
check 0 "$(run "$ALLOWED" 'git remote add origin https://evolx@dev.azure.com/evolx/p/_git/r')" 'remote add ADO evolx -> allowed'
check 2 "$(run "$ALLOWED" 'git remote add evil https://evil.example/x.git')"              'remote add non-whitelisted -> blocked'
check 2 "$(run "$ALLOWED" 'git remote remove origin')"                                    'remote remove -> blocked'
check 2 "$(run "$ALLOWED" 'git remote set-url origin https://evil/x')"                    'remote set-url non-whitelisted -> blocked'
# URL is read as the LAST token, so a whitelisted URL followed by a chain/flag
# still blocks (fail-safe). The message tells the user to run it unchained.
check 2 "$(run "$ALLOWED" 'git remote set-url origin https://github.com/me/z.git && git fetch')" 'remote set-url whitelisted but chained -> blocked'

echo "== belt: config remote.* =="
check 2 "$(run "$ALLOWED" 'git config remote.origin.url https://evil/x')"  'config remote.url write -> blocked'
check 0 "$(run "$ALLOWED" 'git config --get remote.origin.url')"           'config --get remote.url read -> allowed'
check 0 "$(run "$ALLOWED" 'git config user.email me@x.com')"               'config user.email -> allowed'

echo "== self-heal on commit/push =="
# ALLOWED has no hook yet; a commit attempt should install the stub then exit 0.
rm -f "$ALLOWED/.git/hooks/pre-commit"
check 0 "$(run "$ALLOWED" 'git commit -m x')" 'commit in unarmed repo -> allowed (self-heal)'
if [ -f "$ALLOWED/.git/hooks/pre-commit" ] && grep -q 'git-guard-stub' "$ALLOWED/.git/hooks/pre-commit"; then
  PASS=$((PASS+1)); printf "  ok   self-heal installed the stub\n"
else
  FAIL=$((FAIL+1)); printf "  FAIL self-heal did NOT install the stub\n"
fi
# FOREIGN has a non-stub pre-commit; must block+warn, not clobber.
check 2 "$(run "$FOREIGN" 'git commit -m x')" 'commit in repo with foreign hook -> blocked'
if grep -q 'echo hi' "$FOREIGN/.git/hooks/pre-commit"; then
  PASS=$((PASS+1)); printf "  ok   foreign hook left intact\n"
else
  FAIL=$((FAIL+1)); printf "  FAIL foreign hook was clobbered\n"
fi

# Customer checkouts as the user has them: a worktree on its own branch, and a
# mirror checked out on the remote's default branch. origin/HEAD is what clone
# records; set it with plumbing (no fetch needed).
CUST_URL='https://oebb-azure-platform@dev.azure.com/oebb-azure-platform/osis/_git/osis'
CUST_WT="$TMP/cust_wt"; MIRROR="$TMP/mirror"; NOREMOTE="$TMP/noremote"
for d in "$CUST_WT" "$MIRROR"; do
  git init -q "$d"; git -C "$d" remote add origin "$CUST_URL"
  git -C "$d" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  printf 'x\n' > "$d/f.txt"
done
git -C "$CUST_WT" symbolic-ref HEAD refs/heads/fixes
git -C "$MIRROR"  symbolic-ref HEAD refs/heads/main
git init -q "$NOREMOTE"
git -C "$CUST" symbolic-ref HEAD refs/heads/fixes   # customer repo with no origin/HEAD

# check_err <expected> <actual> <label> <stderr-substring>: exit code AND the
# block came from the rule under test.
check_err() {
  if [ "$1" = "$2" ] && grep -q -- "$4" "$TMP/err"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$3"
  else FAIL=$((FAIL+1)); printf "  FAIL %s (exp=%s got=%s, want '%s') %s\n" "$3" "$1" "$2" "$4" "$(cat "$TMP/err")"; fi
}

echo "== belt: working-tree writes in a repo that is not ours =="
for c in 'git checkout -b feat' 'git checkout -B feat' 'git switch main' 'git switch -c feat' \
         'git checkout main' 'git branch feat' 'git branch -D feat' 'git branch -m a b' \
         'git stash' 'git stash -u' 'git stash pop' \
         'git add -A' 'git add .' 'git add --all' 'git add -u' 'git add -Av' \
         'git reset --hard' 'git reset --hard origin/main' 'git clean -fd' 'git clean -f' 'git clean -xdf' \
         'git worktree add ../other fixes2' \
         'git status && git stash' 'git add f.txt;git stash' 'if [ -n "$x" ]; then git stash; fi'; do
  check_err 2 "$(run "$CUST_WT" "$c")" "customer worktree: $c BLOCKED" 'in a repo that is not ours'
done
for c in 'git checkout -- f.txt' 'git checkout' 'git branch' 'git branch -vv' 'git branch --show-current' \
         'git stash list' 'git stash show' 'git add f.txt' 'git add "f.txt"' 'git reset HEAD f.txt' \
         'git clean -n' 'git worktree list' 'git log --grep stash' 'git diff --cached --stat' \
         'echo "git stash"' "printf '{\"command\":\"git add -A\"}' | cat" 'git log --grep "reset --hard"'; do
  check 0 "$(run "$CUST_WT" "$c")" "customer worktree: $c allowed"
done
# The target is the repo the command names, not the hook's cwd.
check_err 2 "$(run "$ALLOWED" "git -C $CUST_WT stash")" 'git -C <customer> stash from own cwd BLOCKED' 'not ours'
check_err 2 "$(run "$ALLOWED" "cd $CUST_WT && git checkout -b x")" 'cd <customer> && checkout -b BLOCKED' 'not ours'
# PowerShell tool: same JSON shape, PowerShell syntax.
check_err 2 "$(run "$ALLOWED" "git -C '$CUST_WT' stash; if (\$?) { git status }")" 'PowerShell: git -C quoted stash BLOCKED' 'not ours'
check 0 "$(run "$ALLOWED" "git -C '$CUST_WT' status; if (\$?) { git log -1 }")" 'PowerShell: read-only chain allowed'
# Our own repos and remote-less repos are not policed by this belt.
for c in 'git stash' 'git checkout -b feat' 'git add -A' 'git reset --hard' 'git worktree add ../w'; do
  check 0 "$(run "$ALLOWED"  "$c")" "own repo: $c allowed"
  check 0 "$(run "$NOREMOTE" "$c")" "remote-less repo: $c allowed"
done

echo "== read-only mirror: default-branch checkout of a repo that is not ours =="
run_file() {  # $1=tool $2=key $3=path -> exit code
  printf '{"cwd":%s,"tool_name":"%s","tool_input":{"%s":%s,"content":"x"}}' \
    "$(printf %s "$ALLOWED" | jq -Rs .)" "$1" "$2" "$(printf %s "$3" | jq -Rs .)" \
    | $GUARD_CMD >/dev/null 2>"$TMP/err"; echo $?
}
check_err 2 "$(run "$MIRROR" 'git add f.txt')"                 'mirror: git add <path> BLOCKED' 'read-only mirror'
check_err 2 "$(run_file Edit file_path "$MIRROR/f.txt")"        'mirror: Edit BLOCKED' 'read-only mirror'
check_err 2 "$(run_file MultiEdit file_path "$MIRROR/f.txt")"   'mirror: MultiEdit BLOCKED' 'read-only mirror'
check_err 2 "$(run_file Write file_path "$MIRROR/new/dir/g.txt")" 'mirror: Write into a new subdir BLOCKED' 'read-only mirror'
check_err 2 "$(run_file NotebookEdit notebook_path "$MIRROR/n.ipynb")" 'mirror: NotebookEdit BLOCKED' 'read-only mirror'
check_err 2 "$(run_file Edit file_path "$(cygpath -w "$MIRROR/f.txt")")" 'mirror: Windows-form path BLOCKED' 'read-only mirror'
check 0 "$(run_file Edit file_path "$CUST_WT/f.txt")"           'customer worktree on its own branch: Edit allowed'
check 0 "$(run_file Edit file_path "$ALLOWED/f.txt")"           'own repo: Edit allowed'
check 0 "$(run_file Write file_path "$NOREMOTE/f.txt")"         'remote-less repo: Write allowed'
mkdir -p "$TMP/loose"
check 0 "$(run_file Write file_path "$TMP/loose/f.txt")"        'outside any repo: Write allowed'
check_err 2 "$(run_file Edit file_path "$CUST/f.txt")"          'customer repo without origin/HEAD: fail closed' 'remote set-head'
# Detached HEAD is not a checkout of the default branch.
DETACHED="$TMP/detached"; git init -q "$DETACHED"; git -C "$DETACHED" remote add origin "$CUST_URL"
git -C "$DETACHED" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$DETACHED" -c user.name=t -c user.email=t@t commit-tree "$(git -C "$DETACHED" mktree </dev/null)" -m s >"$TMP/sha"
printf '%s\n' "$(cat "$TMP/sha")" > "$DETACHED/.git/HEAD"
check 0 "$(run_file Edit file_path "$DETACHED/f.txt")"          'customer detached HEAD: Edit allowed'

echo "== read-only git -> allowed =="
check 0 "$(run "$ALLOWED" 'git status')"      'git status'
check 0 "$(run "$ALLOWED" 'git log --oneline')" 'git log'

echo ""
echo "=== claude-git-guard: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
