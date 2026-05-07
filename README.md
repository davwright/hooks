# claude-code-githooks

Safety hooks for [Claude Code](https://claude.com/claude-code) that prevent the
agent from accidentally committing, pushing, or rewriting remotes in repos it
shouldn't touch.

## What it blocks

`block-git-write.sh` is a `PreToolUse` hook for the Bash tool. It inspects every
shell command Claude Code is about to run and refuses three families:

| Category | Examples |
|---|---|
| **Commits / pushes to non-whitelisted remotes** | `git commit -m foo`, `git push --force` when the target repo's `origin` URL doesn't match the whitelist |
| **Bypass attempts** that point git at a different repo while the hook reads remotes from CWD | `GIT_DIR=...`, `GIT_WORK_TREE=...`, `--git-dir=`, `--work-tree=`, `--namespace=` |
| **Remote / config mutations** that would silently retarget the URL the whitelist test reads | `git remote add/set-url/remove/rename/...`, `git config remote.<name>.url <value>`, `git config --add remote.*.fetch ...` |

Read-only operations always pass: `git status`, `git log`, `git diff`, `git
remote -v`, `git remote show`, `git remote get-url`, `git config --get`,
`git config --get-regexp`, `git config user.email me@example.com` (non-remote
write).

## Whitelist

The list lives at the top of `block-git-write.sh`:

```bash
WHITELIST=(
  'github\.com'
  '//evolx@'
)
```

Each pattern is a `grep -E` regex matched case-insensitively against every
push-remote URL of the target repo. Edit it for your environment. Anything
not on the whitelist is blocked.

## Install

```powershell
# from the repo root
.\Install.ps1
```

The script copies `block-git-write.sh` to `~\.claude\hooks\` and registers the
`PreToolUse:Bash` hook entry in `~\.claude\settings.json`. Idempotent — re-runs
update the script in place; the settings entry is added only if not present.

To uninstall, delete the file and remove the matching `hooks.PreToolUse` entry
from `settings.json`.

## How it sees the command

Claude Code passes a JSON blob on stdin: `{ "cwd": ..., "tool_input":
{ "command": "..." } }`. The hook reads those two fields with `jq`,
classifies the command against `INTERCEPT_PATTERNS` (a bash array of
labelled regexes — extend by appending), and exits non-zero with a stderr
message to refuse. Exit 0 lets the command through.

To avoid false-positives from the bypass-flag check on commit-message
text, the hook strips single- and double-quoted regions plus heredoc
bodies (`<<EOF ... EOF`) before scanning for `--git-dir`, `GIT_DIR=`,
etc. Quote-stripping is a sed pass, not real shell tokenization, so it
doesn't execute any command substitutions in the input — even on a
crafted `git commit -m "$(rm -rf ~)"` the inner command stays inert.

The classification doesn't try to *run* the command's tokenizer; it
matches command-shape regexes that are tight enough to identify the
intent (`git commit`, `git remote add`, `git config remote.X.url
<value>`) without false-positives on log/status/get reads.

## Dependencies

- `bash` — the hook runs as a `bash` script. On Windows that's the bash
  shipped with Git for Windows (`C:\Program Files\Git\bin\bash.exe`),
  which Claude Code uses for its Bash tool.
- `jq` — used to parse the JSON blob from Claude Code. The hook
  auto-installs `jq` via winget on first run if missing, fail-closed if
  the install fails. Pre-install with `winget install jqlang.jq` to skip
  the runtime install.
- `git` — used to read the target repo's push remotes for the whitelist
  check.

## Tests

```bash
bash block-git-write.test.sh
```

70 unit tests covering the whitelisted-pass cases, every blocked family,
known bypass shapes (including env-var prefix, redirect flags, remote
mutation, and config-remote writes), and false-positive guards
(`echo "register_git_commit"` must pass; `git config --get
remote.origin.url` must pass; `git config core.autocrlf input` must
pass; `git commit -m "explains --git-dir bypass"` must pass — quoted
text in commit messages doesn't trip flag detection).

The test harness creates two throwaway git repos with synthetic
remotes — one whitelisted (`evolx@`), one not (`oebb-azure-platform@`) —
and feeds the hook the same JSON shape Claude Code produces, asserting
on exit code.

## Why a hook instead of permission rules?

Claude Code's permission system gates tools by name (allow / deny `Bash`,
`Edit`, etc.) but can't reason about the ARGUMENTS to a tool call. "Allow git
commit when the remote is whitelisted, deny otherwise" needs to inspect the
command string and the repo's git config. That's what a `PreToolUse` hook is
for.

## Threat model

The hook protects against accidental commits to customer repos by an LLM that
might `cd` somewhere unexpected. It is not a hardened sandbox. A determined
operator (human or model) with shell access can:

- Edit `~/.claude/settings.json` to remove the hook
- Edit `block-git-write.sh` to change the whitelist
- Run `git` from outside Claude Code

For real isolation, run Claude Code under a dedicated OS user account that
lacks write permission to customer repos.
