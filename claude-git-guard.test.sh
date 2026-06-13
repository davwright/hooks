#!/bin/bash
# Tests for claude-git-guard.sh (the thin Claude PreToolUse hook). Feeds it the
# PreToolUse JSON shape and asserts exit codes + self-heal side effects.
#
# Run: bash claude-git-guard.test.sh   (exit 0 = all pass)

set -u
HOOK="$(dirname "$0")/claude-git-guard.sh"
[ -f "$HOOK" ] || { echo "FATAL: claude-git-guard.sh not found at $HOOK" >&2; exit 2; }

TMP=$(mktemp -d); trap "rm -rf '$TMP'" EXIT
# Deploy a fake git template so self-heal has stubs to install from.
export HOME="$TMP/home"; mkdir -p "$HOME/.git-template/hooks"
cp "$(dirname "$0")/templates/hooks/pre-commit" "$HOME/.git-template/hooks/pre-commit"
cp "$(dirname "$0")/templates/hooks/pre-push"   "$HOME/.git-template/hooks/pre-push"

ALLOWED="$TMP/allowed"; FOREIGN="$TMP/foreign"
git init -q "$ALLOWED"; git -C "$ALLOWED" remote add origin 'https://github.com/me/x.git'
git init -q "$FOREIGN"; git -C "$FOREIGN" remote add origin 'https://github.com/me/y.git'
printf '#!/bin/bash\necho hi\n' > "$FOREIGN/.git/hooks/pre-commit"; chmod +x "$FOREIGN/.git/hooks/pre-commit"

PASS=0; FAIL=0
run() {  # $1=cwd $2=command -> echo exit code
  printf '{"cwd":%s,"tool_input":{"command":%s}}' \
    "$(printf %s "$1" | jq -Rs .)" "$(printf %s "$2" | jq -Rs .)" \
    | bash "$HOOK" >/dev/null 2>"$TMP/err"; echo $?
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

echo "== belt: --no-verify =="
check 2 "$(run "$ALLOWED" 'git commit --no-verify -m x')" '--no-verify blocked'
check 2 "$(run "$ALLOWED" 'git commit -n -m x')"          '-n blocked'
check 2 "$(run "$ALLOWED" 'git push --no-verify')"        'push --no-verify blocked'
check 0 "$(run "$ALLOWED" 'git commit -m "note --no-verify in msg"')" '--no-verify inside quoted msg allowed'

echo "== belt: redirect =="
check 2 "$(run "$ALLOWED" 'GIT_DIR=/x git commit -m y')"  'GIT_DIR= redirect blocked'
check 2 "$(run "$ALLOWED" 'git --git-dir=/x commit -m y')" '--git-dir flag blocked'

echo "== belt: remote mutation (fresh-init exception) =="
check 0 "$(run "$ALLOWED" 'git remote add origin https://github.com/me/z.git')"           'remote add whitelisted -> allowed'
check 0 "$(run "$ALLOWED" 'git remote add origin https://evolx@dev.azure.com/evolx/p/_git/r')" 'remote add ADO evolx -> allowed'
check 2 "$(run "$ALLOWED" 'git remote add evil https://evil.example/x.git')"              'remote add non-whitelisted -> blocked'
check 2 "$(run "$ALLOWED" 'git remote remove origin')"                                    'remote remove -> blocked'
check 2 "$(run "$ALLOWED" 'git remote set-url origin https://evil/x')"                    'remote set-url non-whitelisted -> blocked'

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

echo "== read-only git -> allowed =="
check 0 "$(run "$ALLOWED" 'git status')"      'git status'
check 0 "$(run "$ALLOWED" 'git log --oneline')" 'git log'

echo ""
echo "=== claude-git-guard: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
