#!/bin/bash
# Benchmark: per-invocation latency of the bash hook vs the NativeAOT exe on the
# two hot-path cases (non-git fast-bail, and a git command that self-heals).
# Method: wall-clock over N invocations via date +%s%N, same as the prior session.
set -u
cd "$(dirname "$0")/.."
BASH_HOOK="claude-git-guard.sh"
EXE="csharp/bin/Release/net9.0/win-x64/publish/claude-git-guard.exe"
N=30

# A throwaway armed repo so the git-command case has a real target.
TMP=$(mktemp -d -p "$HOME"); trap "rm -rf '$TMP'" EXIT
REPO="$TMP/repo"; git init -q "$REPO"; git -C "$REPO" remote add origin 'https://github.com/me/x.git'

NONGIT=$(printf '{"cwd":"/tmp","tool_input":{"command":"ls -la"}}')
GITCMD=$(printf '{"cwd":%s,"tool_input":{"command":"git status"}}' "$(printf %s "$REPO" | jq -Rs .)")

bench() {  # $1=label $2=runner-cmd $3=input
  local start end
  start=$(date +%s%N)
  for ((i=0;i<N;i++)); do printf '%s' "$3" | $2 >/dev/null 2>&1; done
  end=$(date +%s%N)
  printf "  %-28s %6d ms/call  (%d iters)\n" "$1" $(( (end-start)/1000000/N )) "$N"
}

echo "== hot path: non-git (fast bail) =="
bench "bash hook"  "bash $BASH_HOOK" "$NONGIT"
bench "C# exe"     "$EXE"            "$NONGIT"

echo "== git command (status, armed repo) =="
bench "bash hook"  "bash $BASH_HOOK" "$GITCMD"
bench "C# exe"     "$EXE"            "$GITCMD"
