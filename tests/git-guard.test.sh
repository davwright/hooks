#!/bin/bash
# Tests for git-guard.sh (the canonical judge). Runs the real script against
# throwaway git repos. pre-push gets argv; pre-commit reads the repo's remotes.
#
# Run: bash git-guard.test.sh   (exit 0 = all pass)

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/src/git-guard.sh"
[ -f "$GUARD" ] || { echo "FATAL: git-guard.sh not found at $GUARD" >&2; exit 2; }

TMP=$(mktemp -d); trap "rm -rf '$TMP'" EXIT
# Neutralize the self-update path: point HOME at an empty dir so there's no
# template to sync from (we're testing the JUDGE, not the stub refresh).
export HOME="$TMP/home"; mkdir -p "$HOME"

WL="$TMP/wl"; CUST="$TMP/cust"; NOREMOTE="$TMP/nr"; MULTI="$TMP/multi"
git init -q "$WL";   git -C "$WL"   remote add origin 'https://evolx@dev.azure.com/evolx/test/_git/test'
git init -q "$CUST"; git -C "$CUST" remote add origin 'https://oebb-azure-platform@dev.azure.com/oebb/customer/_git/customer'
git init -q "$NOREMOTE"
git init -q "$MULTI"; git -C "$MULTI" remote add origin 'https://github.com/me/x.git'
git -C "$MULTI" remote add cust 'https://oebb-azure-platform@dev.azure.com/oebb/c/_git/c'

PASS=0; FAIL=0
# run_commit <repo>; run_push <url> -> echo exit code
run_commit() { ( cd "$1" && bash "$GUARD" pre-commit ) >/dev/null 2>"$TMP/err"; echo $?; }
run_push()   { bash "$GUARD" pre-push origin "$1" </dev/null >/dev/null 2>"$TMP/err"; echo $?; }
check() {
  local expected="$1" actual="$2" label="$3"
  if [ "$actual" = "$expected" ]; then PASS=$((PASS+1)); printf "  ok   %s\n" "$label"
  else FAIL=$((FAIL+1)); printf "  FAIL %s (exp=%s got=%s) %s\n" "$label" "$expected" "$actual" "$(cat "$TMP/err")"; fi
}

echo "== pre-commit (strict at commit) =="
check 0 "$(run_commit "$WL")"       'commit: whitelisted ADO evolx remote'
check 1 "$(run_commit "$CUST")"     'commit: customer remote -> blocked'
check 0 "$(run_commit "$NOREMOTE")" 'commit: no remote -> allowed (local-only)'
check 1 "$(run_commit "$MULTI")"    'commit: one whitelisted + one customer -> blocked'

echo "== pre-push (clean URL from argv) =="
check 0 "$(run_push 'https://github.com/me/x.git')"                          'push: github -> allowed'
check 0 "$(run_push 'https://evolx@dev.azure.com/evolx/p/_git/r')"           'push: ADO evolx -> allowed'
check 1 "$(run_push 'https://oebb-azure-platform@dev.azure.com/oebb/c')"     'push: customer -> blocked'
check 1 "$(run_push 'https://dev.azure.com/oebb/p/_git/r')"                  'push: non-evolx ADO org -> blocked'
check 0 "$(run_push 'https://GitHub.com/Me/X.git')"                          'push: github mixed-case -> allowed'

echo "== bad mode =="
check 1 "$(bash "$GUARD" frobnicate </dev/null >/dev/null 2>"$TMP/err"; echo $?)" 'unknown mode -> blocked'

echo ""
echo "=== git-guard: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
