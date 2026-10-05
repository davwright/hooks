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

0. Builds `csharp/` (NativeAOT; needs the **.NET SDK** and the **VS C++ build
   tools**). One exe serves both layers. If it can't be built, the install fails.
1. Installs the **content judge** to `~\.githooks\git-guard.exe`.
2. Installs a **git template** to `~\.git-template\hooks\` and points
   `git config --global init.templateDir` at it — so every future
   `git init` / `git clone` is guarded automatically, with zero extra steps.
3. Installs the **Claude Code hook** to `~\.claude\hooks\claude-git-guard.exe`
   and registers it in `~\.claude\settings.json` in exec form (see
   [Hooks must not run through a shell](#hooks-must-not-run-through-a-shell)),
   matcher `Bash|PowerShell|Read|Grep|Glob|Edit|Write|MultiEdit|NotebookEdit|mcp__.*[Aa]tlassian.*|mcp__plugin_.*playwright.*`.

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

The whitelist is the `GithubRe` / `AdoEvolxRe` / `AdoEvolxSshRe` regexes at the
bottom of [`csharp/Program.cs`](csharp/Program.cs), anchored at the URL start and
matched case-insensitively. Both layers use them. Edit, re-run `Install.ps1`,
and every repo picks it up on its next commit/push (they all exec the one
deployed exe).

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
.git/hooks/pre-commit, commit-msg, pre-push  →  git-guard.exe <hook>  (per-repo)
   • pre-push:   whitelist-checks the destination URL git hands it directly
   • pre-commit: whitelist-checks the repo's configured push remote
   • commit-msg / pre-push: in a repo that is not ours, also refuses private
     Pulse ids (PS-<n>, pulse<n>) in commit messages
   • refuses (non-zero) → git aborts the operation
```

The Claude hook is registered for the shell, file and read tools and the
Atlassian / plugin-Playwright MCP tools (`Install.ps1` does this).

### Other guards in the same exe

The same exe runs two more PreToolUse guards after the git checks; the first
block wins:

- **claude-guard** ([`csharp/ClaudeGuard.cs`](csharp/ClaudeGuard.cs)), messages
  prefixed `BLOCKED by claude-guard:` — corrections the user made in many
  sessions: az / PAT / hand-built Basic auth for ADO, the retired
  canvas-app-tester, ad-hoc Playwright, the deprecated DataverseCmdlets, killing
  node by name, direct Jira REST, Pulse data on disk, branches and stash, the
  Python toolchain; shell-form hooks written into settings.json / hooks.json;
  plugin-Playwright and Atlassian MCP tools; Read/Grep/Glob of Pulse data. A
  statement that only searches for a name (grep, rg, Select-String, git
  log/show/diff/commit) or a heredoc body is not a use of it. Cwd under
  `c:/git/extensions/devpulse` may use Jira and Pulse data directly.
- **ev guard** ([`csharp/EvGuard.cs`](csharp/EvGuard.cs)), from EvolxCli — an
  `ev ... --live` clause is checked against `~/.evolx/ev-policy.json`
  (`EV_POLICY_FILE` overrides); fail-closed. Its verb tables
  (`WriteVerbsDv` / `WriteVerbsAdo`) map a verb to the policy section. Only an
  ADO-scoped `--live` clause starts a process (`git remote get-url origin` in
  the hook's cwd).

The git layer is handed **exact, unobfuscated arguments by git itself** — no
string guessing.

---

## Hooks must not run through a shell

On this machine every MSYS process start (Git Bash, `sh`, and each `$(...)`,
pipe, `sed` or `grep` inside a script) costs ~1.4 s idle and 5–12 s under load
(AV/EDR on process creation). Node starts in 0.4–1.2 s, the NativeAOT exe in
~40 ms.

The bash judge forked ~25 MSYS processes per hook, and a commit runs two hooks:
**118 s** for one `git commit --allow-empty` (customer remote: 152 s). As one exe
behind a one-line `exec` stub: **4.5 s** (customer: 6.4 s), under the same load
(`bash -c true` ≈ 5 s). Git for Windows only runs script hooks, so one `sh` per
hook is the floor.

Claude Code cancels a hook at its timeout, and this guard then **fails open**:
the command runs unguarded. So a Claude hook is a native exe, registered in exec
form (`args` present = no shell):

```json
{ "type": "command", "command": "C:/Users/<you>/.claude/hooks/claude-git-guard.exe", "args": [], "timeout": 10 }
```

The old shell form `~/.claude/hooks/claude-git-guard.exe` started bash first;
that was the 0.8–5 s per call, not the exe.

**One exe, no shell, no node per call.** Every PreToolUse guard lives in this
exe: one ~40 ms process per tool call instead of one per guard. A new guard rule
goes into `csharp/` (with a node test in `tests/`), not into a new `.mjs` or
`.sh` hook — node costs 0.4–1.2 s per start here, a shell more.

---

## Repo layout

```
README.md            you are here
Install.ps1          idempotent installer
csharp/              the guard, one exe for both layers
  Program.cs           Claude PreToolUse hook (holds the whitelist)
  ClaudeGuard.cs       claude-guard rules
  EvGuard.cs           ev --live policy guard (verb tables)
  GitHook.cs           content judge: git-guard.exe <hook> ...
src/git-guard.sh     shim: repos armed before v3 exec it; it execs the exe
templates/hooks/     one-line stubs copied into each repo's .git/hooks
  pre-commit  commit-msg  pre-push
tests/               offline test suites
  git-guard.test.sh  claude-git-guard.test.sh  stubs.test.mjs
  claude-guard.test.mjs  ev-guard.test.mjs
```

### Running the tests

```bash
bash tests/git-guard.test.sh          # the content judge
bash tests/claude-git-guard.test.sh   # the Claude hook
node tests/stubs.test.mjs             # stubs stay one exec, no forks
node tests/claude-guard.test.mjs      # claude-guard rules
node tests/ev-guard.test.mjs          # ev --live policy guard
```

All but the stubs test run the exe under `csharp/bin/Release/net9.0/win-x64/publish/`; build it
first (`dotnet publish -r win-x64 -c Release` in `csharp/`).

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
