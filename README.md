# git-write guard for Claude Code

Stops an AI coding agent (Claude Code) from **accidentally committing or pushing
to the wrong git repo** — typically a customer's repo you have checked out
locally. Commits and pushes to repos you've whitelisted go through untouched;
everything else is blocked with a clear message.

Whitelisted by default: **`github.com`** and **`dev.azure.com/evolx/`**.
Everything else is refused.

---

## Quick start

From a PowerShell prompt, in this folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

That's it. The installer is idempotent — safe to re-run any time. Then **restart
any open Claude Code sessions** so they pick up the hook.

Preview first without changing anything:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -WhatIf
```

### What the installer does

1. Installs the **whitelist judge** to `~\.githooks\git-guard.sh`.
2. Installs a **git template** to `~\.git-template\hooks\` and points
   `git config --global init.templateDir` at it — so every future
   `git init` / `git clone` is guarded automatically, with zero extra steps.
3. Installs the **Claude Code hook** to `~\.claude\hooks\` and registers it in
   `~\.claude\settings.json`. By default it installs the fast native build (see
   [Native vs bash](#native-vs-bash)); if your machine can't build it, it
   silently falls back to the shell version.

---

## Does it work? (verify in 10 seconds)

Open a Claude Code session and ask it to run these. The first is allowed, the
second is blocked:

```bash
git status                       # allowed — read-only
git commit --no-verify -m test   # BLOCKED — --no-verify bypasses the guard
```

A blocked command prints a one-line reason and Claude sees it as a refusal.

---

## Changing the whitelist

Edit the `WHITELIST` array near the top of `~\.githooks\git-guard.sh` (the
deployed copy) and the small mirror in the Claude hook. The patterns are
case-insensitive regexes matched against the remote URL, e.g.:

```bash
WHITELIST=(
  'github\.com'
  'dev\.azure\.com/evolx/'
  'gitlab\.com/myorg/'      # <- add your own
)
```

The source of truth lives in this repo at [`src/git-guard.sh`](src/git-guard.sh);
edit there, re-run `Install.ps1`, and every repo picks it up on its next
commit/push (they all call the one deployed file — no per-repo updates needed).

---

## How it works (two layers)

A Claude Code hook only ever sees the **raw shell string** of a command. Judging
git safety from a string alone is fragile (the path `c:\git\...` contains the
word `git`, quotes and `cd` and `GIT_DIR=` have to be chased, …) — that fragility
was the source of every false alarm this guard ever had.

So the real decision moved to where the data is clean — git's own hooks:

```
Claude runs a git command
   │
   ▼
claude-git-guard  (Claude PreToolUse hook — THIN)
   • blocks --no-verify / -n          ← git hooks can't catch this; it skips them
   • blocks GIT_DIR= / --git-dir redirects, remote re-pointing, config remote.*
   • allows `remote add <whitelisted-url>`   ← fresh-init flow
   • installs the guard into the target repo if missing (self-heal); else blocks
   • in a repo that is NOT ours (same whitelist): blocks branch create/switch,
     stash, add -A / . / -u, reset --hard, clean -f, worktree add
   • there, a checkout of the remote's default branch is a read-only mirror:
     blocks Edit/Write/MultiEdit/NotebookEdit into it and any git add
   • otherwise gets out of the way
   │
   ▼
.git/hooks/pre-commit & pre-push  →  git-guard.sh  (per-repo — the REAL judge)
   • pre-push:   whitelist-checks the destination URL git hands it directly
   • pre-commit: whitelist-checks the repo's configured push remote
   • commit-msg / pre-push: in a repo that is not ours, also refuses private
     Pulse ids (PS-<n>, pulse<n>) in commit messages
   • refuses (non-zero) → git aborts the operation
```

The Claude hook is registered for the Bash, PowerShell and file-edit tools
(`Install.ps1` does this).

The git layer is handed **exact, unobfuscated arguments by git itself** — no
string guessing.

---

## Native vs bash

The Claude hook fires on **every** Bash command Claude runs, so its startup cost
is recurring latency. On Windows the shell version pays the MSYS `bash.exe`
startup tax (~0.5 s) on every call. The repo ships a **NativeAOT C# port** with
an identical contract that runs ~3–4× faster (measured: 852 → 276 ms on a
non-git command). `Install.ps1` prefers it automatically.

| | |
|---|---|
| Force the native build | `Install.ps1 -HookImpl native` |
| Force the shell build | `Install.ps1 -HookImpl bash` |
| Default | `auto` — native if buildable, else bash |

Building native needs the **.NET SDK** and the **VS C++ build tools** (MSVC).
Without them, `auto` just uses bash — no error.

---

## Repo layout

```
README.md            you are here
Install.ps1          idempotent installer
src/                 the two hook scripts (edit these)
  git-guard.sh         canonical whitelist judge (holds the WHITELIST)
  claude-git-guard.sh  thin Claude PreToolUse hook
templates/hooks/     thin stubs copied into each repo's .git/hooks
  pre-commit  pre-push
csharp/              NativeAOT port of the Claude hook (+ bench.sh)
tests/               offline test suites
  git-guard.test.sh  claude-git-guard.test.sh
```

### Running the tests

```bash
bash tests/git-guard.test.sh                 # the judge
bash tests/claude-git-guard.test.sh          # the Claude hook (bash build)
GUARD_CMD=exe bash tests/claude-git-guard.test.sh   # same suite, native build
```

All green = the two implementations behave identically.

---

## Known limits

- **`--no-verify` is caught only at the Claude layer.** It skips git hooks
  entirely, so the git layer is blind to it. A `--no-verify` commit typed by hand
  in a terminal (outside Claude) is not guarded — that's by design: the *agent*
  is what's being guarded.
- **A repo Claude has never touched is unarmed** until its first Claude
  commit/push (self-heal installs the guard then) or its next `git init` / clone
  (the template arms it). Git deliberately never runs a cloned repo's committed
  hooks, so a machine-global template is the only way to arm fresh clones with no
  manual step.
- **The whitelist has two classes: ours and not ours.** A shared repo of ours
  (colleagues on its `main`) is "ours", so the branch/stash/mirror rules and
  the Pulse-id rule don't apply there. File writes made through shell commands
  (not the Edit/Write tools) are not judged by the mirror rule.
- **The whitelist lives in two synced places**: `src/git-guard.sh` (the judge)
  and a small mirror in `src/claude-git-guard.sh` (only for the `remote add`
  exception). Keep them in step.
