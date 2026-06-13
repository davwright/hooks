# hooks — two-layer git-write guard

Stops an AI agent (Claude Code) from accidentally committing or pushing to a
**non-whitelisted** git repo (customer repos), while letting whitelisted repos
through. Whitelist: `github.com` and `dev.azure.com/evolx/`.

## Why two layers

A Claude Code `PreToolUse` hook only ever sees the raw **shell string** of a
command. Judging git safety from a string means regex-parsing, quote-stripping,
and chasing `cd` / `git -C` / `GIT_DIR=` redirects — fragile, and the source of
every false-positive this guard has ever had (e.g. the path segment `git` in
`c:\git\...` read as the `git` command).

So the real judging moved to where the data is clean:

```
Claude runs a git command
   │
   ▼
claude-git-guard.sh   (global Claude PreToolUse hook, THIN)
   • block --no-verify/-n on commit|push   ← git hooks can't catch this
   • block GIT_DIR=/--git-dir redirects, remote-mutation, config remote.*
   • allow `remote add <whitelisted-url>`  ← fresh-init flow
   • ensure target repo has the guard hook installed (self-heal); else block
   • otherwise: get out of the way
   │
   ▼
.git/hooks/pre-commit, pre-push   →  exec  git-guard.sh   (per-repo, REAL JUDGE)
   • pre-push:   whitelist-check the destination URL git hands it in argv
   • pre-commit: whitelist-check the repo's configured push remote (strict)
   • exit nonzero → git aborts
```

The git layer sees **exact, unobfuscated arguments from git itself** — `pre-push`
is literally handed the destination URL. No string parsing.

## Files

| File | Role |
|---|---|
| `git-guard.sh` | **Canonical judge.** `git-guard.sh pre-commit\|pre-push <args>`. Holds the whitelist + `is_whitelisted`. |
| `templates/hooks/pre-commit`, `pre-push` | Thin stubs that `exec` the canonical. Carry a `git-guard-stub vN` marker. |
| `claude-git-guard.sh` | Thin Claude PreToolUse hook (belt + self-heal). |
| `Install.ps1` | Idempotent installer (see below). |
| `*.test.sh` | Offline test suites. `bash git-guard.test.sh`, `bash claude-git-guard.test.sh`. |

## How updates propagate (no drift)

The stub is **near-static** — it just `exec`s `$HOME/.githooks/git-guard.sh`.
All the logic is in that one canonical file, which every repo's stub calls. So:

- **Edit the logic** → edit `git-guard.sh`, re-run `Install.ps1`. Every repo
  picks it up on its next commit/push, because they all `exec` the same file.
  No re-copying repos, no sweep.
- **Self-update**: the canonical refreshes a repo's stub from the template if
  the stub's version marker is stale (local only — never touches the network).
- **Self-heal**: the Claude hook installs the stub the first time it sees a
  commit/push in an un-armed repo. It will **not** clobber a foreign hook
  (husky etc.) — it blocks and warns instead.

New repos are armed automatically: `Install.ps1` sets
`git config --global init.templateDir`, so every future `git init` / `git clone`
copies the stubs into `.git/hooks/`. Git never runs repo-committed hooks on
clone (a security guarantee), so a machine-global template is the only way to
arm fresh clones with zero per-repo action.

## Install

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -WhatIf  # preview
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

It deploys the canonical to `$HOME\.githooks\`, the template stubs to
`$HOME\.git-template\hooks\` (+ sets `init.templateDir`), the thin hook to
`~\.claude\hooks\`, and swaps the old `block-git-write.sh` entry in
`~\.claude\settings.json` for `claude-git-guard.sh`. Restart open Claude Code
sessions afterward.

## Known limits

- **`--no-verify` is caught only at the Claude layer** — it skips git hooks
  entirely, so the git layer is blind to it. A `--no-verify` commit typed
  manually in a terminal (outside Claude) is not guarded.
- **A repo Claude has never touched is unarmed** until its first Claude
  commit/push (self-heal) or its next `git init`/`clone` (template). This is the
  accepted threat model: the *agent* is what's guarded, and the agent always
  passes through the Claude hook.
- **Whitelist** lives in two places kept in sync: `git-guard.sh` (the judge) and
  a small mirror in `claude-git-guard.sh` (only for the `remote add` exception).
