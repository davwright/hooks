// claude-git-guard — the THIN Claude Code PreToolUse hook. Contract: PreToolUse
// JSON on stdin, exit 0 = allow, exit 2 = block (message on stderr).
//
// This hook fires ONLY for Claude, by construction — it is a separate execution
// path, not a flag Claude could clear. So it owns the rule that must bind Claude
// and not the user:
//   1. DESTINATION: commit/push may only reach our own repos (github.com,
//      dev.azure.com/evolx/). The user is trusted to push anywhere, so this
//      rule cannot live in a per-repo git hook — those fire for everyone.
//   2. Belt: block shapes git hooks are blind to / that bypass them
//        (--no-verify, GIT_DIR/--git-dir redirect, remote add/set-url to a
//         non-whitelisted URL, git config remote.* writes).
//   3. Self-heal: before commit|push, install our git-hook stub into the target
//      repo (or block if a foreign hook is present).
//   4. The user's checkout in a repo that is NOT ours (classified by the same
//      whitelist): no branch create/switch, stash, whole-tree add, reset
//      --hard, clean -f or worktree add. A checkout of the remote's DEFAULT
//      branch there is a read-only mirror: no Edit/Write into it, no git add.
//      Registered for Bash, PowerShell and the file-edit tools.
// The per-repo git hook (GitHook.cs, same binary) owns the CONTENT rule
// instead: no AI-tool words in a customer repo's history, enforced for everyone.
//
// The same exe also runs the other PreToolUse guards, so one native process
// judges every tool call (node costs 0.4-1.2 s per start here, this ~40 ms):
// the git checks below, then claude-guard (ClaudeGuard.cs), then the ev
// customer-write guard (EvGuard.cs). The first block wins.

using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ClaudeGitGuard;

internal static partial class Program
{
    static string TemplateHooks =>
        Path.Combine(Home, ".git-template", "hooks");

    static string Home =>
        ToWindowsPath(
            Environment.GetEnvironmentVariable("HOME")
            ?? Environment.GetEnvironmentVariable("USERPROFILE")
            ?? "");

    // Git Bash / MSYS hands us POSIX paths (HOME=/c/Users/x, cwd=/c/git/...).
    // We are a native Win32 process, so .NET filesystem APIs need Windows form.
    // Translate a leading "/<drive>/" -> "<DRIVE>:\" and flip slashes. Paths
    // already in Windows form, or MSYS-internal roots like /tmp (no drive
    // letter), are returned unchanged — git itself still accepts those.
    static string ToWindowsPath(string p)
    {
        if (p.Length >= 3 && p[0] == '/' && char.IsLetter(p[1]) && p[2] == '/')
            return char.ToUpperInvariant(p[1]) + ":" + p[2..].Replace('/', '\\');
        return p;
    }

    // No arguments: the Claude PreToolUse hook. A hook name as the first
    // argument: the per-repo git hook, the CONTENT judge (GitHook.cs).
    static int Main(string[] args)
    {
        if (args.Length > 0)
            return RunGitHook(args);

        // Claude Code writes UTF-8 and reads our stderr as UTF-8; the console
        // code page would mangle umlauts in paths and the dashes in messages.
        string input = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false)).ReadToEnd();
        Console.SetError(new StreamWriter(Console.OpenStandardError(), new UTF8Encoding(false)) { AutoFlush = true });

        Hook hook;
        try
        {
            hook = Hook.Parse(input);
        }
        catch (JsonException)
        {
            Console.Error.WriteLine("BLOCKED: failed to parse hook input.");
            return 2;
        }

        int rc = GitGuard(input, hook);
        if (rc == 0) rc = ClaudeGuard(hook);
        if (rc == 0) rc = EvGuard(hook);
        return rc;
    }

    static int GitGuard(string input, Hook hook)
    {
        // The union matcher also sends Read/Grep/Glob and MCP calls; the git
        // checks judge only the tools they were written for (no tool name: the
        // test harness).
        if (hook.Tool is not ("" or "Bash" or "PowerShell" or "Edit" or "Write" or "MultiEdit" or "NotebookEdit"))
            return 0;

        // Fast bail: no "git" substring and no file-tool path -> no work.
        // Mirrors the bash `case "$input" in ...` on the raw JSON.
        if (!input.Contains("git", StringComparison.Ordinal)
            && !input.Contains("\"file_path\"", StringComparison.Ordinal)
            && !input.Contains("\"notebook_path\"", StringComparison.Ordinal))
            return 0;

        string cmd = hook.Command ?? "";
        string cwd = hook.Cwd ?? "";
        string file = hook.FilePath ?? hook.NotebookPath ?? "";

        // ── File-edit tools (Edit/Write/MultiEdit/NotebookEdit) ──
        if (file.Length > 0)
            return JudgeFileEdit(file);

        if (string.IsNullOrEmpty(cmd) || cmd == "null")
        {
            Console.Error.WriteLine("BLOCKED: could not extract command from hook input.");
            return 2;
        }

        // ── Belt 1+2: commit/push — redirect, then --no-verify, then self-heal ──
        if (CommitPushRe().IsMatch(cmd))
        {
            if (HasRedirect(cmd))
            {
                Console.Error.WriteLine("BLOCKED: git redirect (GIT_DIR / --git-dir / --work-tree / --namespace) is not allowed — it points git at a repo whose guard hook may be absent. Use 'git -C <path>' or run it manually.");
                return 2;
            }

            string stripped = StripQuotes(StripHeredocs(cmd));
            if (NoVerifyRe().IsMatch(stripped) || GitDashNRe().IsMatch(stripped))
            {
                Console.Error.WriteLine("BLOCKED: --no-verify / -n is not allowed on commit/push — it bypasses the git-guard hook that judges the content. Run it manually if you truly intend to skip the guard.");
                return 2;
            }

            string target = ResolveTarget(cmd, cwd);
            if (string.IsNullOrEmpty(target))
            {
                Console.Error.WriteLine("BLOCKED: could not determine target directory for git command.");
                return 2;
            }

            // ── DESTINATION: the rule that binds Claude and only Claude. The
            // user is trusted to push where they like, so this cannot live in
            // the per-repo git hook (which fires for everyone and cannot tell
            // who invoked it — and no env var can establish that either, since
            // Claude could clear any flag for a child process). This hook is a
            // separate execution path that only ever runs for Claude. ──
            var urls = ResolvePushUrls(target, stripped);
            if (!AllWhitelisted(urls))
            {
                Console.Error.WriteLine("BLOCKED: this would commit/push to a repo that is not ours.");
                if (urls.Count > 0)
                {
                    Console.Error.WriteLine("Destination:");
                    foreach (var u in urls) Console.Error.WriteLine($"  {u}");
                }
                else
                {
                    Console.Error.WriteLine("Destination could not be determined (no push remote resolved).");
                }
                Console.Error.WriteLine("Allowed: github.com, dev.azure.com/evolx/ (incl. ssh form).");
                Console.Error.WriteLine("If this is a customer repo the block is intended — run it yourself in a terminal.");
                return 2;
            }

            if (EnsureHook(target) == "foreign")
            {
                Console.Error.WriteLine($"BLOCKED: {target}/.git/hooks already has a non-git-guard hook. Refusing to overwrite it. Install git-guard manually (chain it) or run the command yourself.");
                return 2;
            }
            return 0; // destination is ours; the git hook now judges CONTENT
        }

        // ── Belt 3: remote mutation ──
        var remoteMatch = RemoteMutationRe().Match(cmd);
        if (remoteMatch.Success)
        {
            string stripped = StripQuotes(cmd);
            string sub = RemoteSubFrom(stripped);
            if (sub is "add" or "set-url")
            {
                // URL is taken as the LAST token. If the command is chained
                // (... && other) or ends in a flag, that token isn't the URL —
                // say so instead of the misleading "non-whitelisted URL".
                string url = LastToken(stripped);
                if (url.Length > 0 && IsWhitelistedUrl(url))
                    return 0;
                if (url.Contains("://") || (url.Contains('@') && url.Contains(':')))
                    Console.Error.WriteLine($"BLOCKED: git remote {sub} points at a non-whitelisted URL: '{url}'. Whitelisted: github.com, dev.azure.com/evolx/. If it's a customer repo this is intended; run it yourself in a terminal.");
                else
                    Console.Error.WriteLine($"BLOCKED: git remote {sub} -- couldn't verify the destination URL (the guard reads the LAST word of the command, but here that's '{url}'). Run it UNCHAINED with the URL last, e.g. 'git remote {sub} origin https://github.com/you/repo.git', then continue.");
                return 2;
            }
            Console.Error.WriteLine($"BLOCKED: git remote {sub} is not allowed (remove/rename/prune/set-* have no automated use and could repoint the guard). Run manually if intended.");
            return 2;
        }

        // ── Belt 4: git config remote.* write (back-door set-url) ──
        if (ConfigRemoteFlagRe().IsMatch(cmd) || ConfigRemoteBareRe().IsMatch(cmd))
        {
            Console.Error.WriteLine("BLOCKED: git config of remote.* is not allowed (back-door equivalent of remote set-url). Run manually if intended.");
            return 2;
        }

        // ── Belt 5: working-tree writes in a repo that is not ours ──
        // Quoted strings are data (a message, a JSON payload), not commands.
        var hits = PolicedVerbs(StripQuotes(StripHeredocs(cmd), "Q"));
        if (hits.Count > 0)
        {
            string target = ResolveTarget(cmd, cwd);
            if (string.IsNullOrEmpty(target))
            {
                Console.Error.WriteLine("BLOCKED: could not determine target directory for git command.");
                return 2;
            }
            var urls = PushRemoteUrls(target);
            if (!IsForeign(urls)) return 0;

            foreach (var reason in hits)
            {
                if (reason is null) continue;
                Console.Error.WriteLine($"BLOCKED: {reason}, in a repo that is not ours ({string.Join(", ", urls)}).");
                Console.Error.WriteLine("That checkout is the user's: hand them the command instead of running it.");
                return 2;
            }
            // Only plain `git add <path>` is left: allowed unless this is the mirror.
            return JudgeMirror(target, urls, $"git add in {target}");
        }

        return 0; // not a git write we police — let it through
    }

    // A repo is NOT ours when it has push remotes and not all of them are
    // whitelisted — the same classification the destination rule and the
    // content judge use. A remote-less repo is not foreign: nothing in it
    // belongs to anyone else yet.
    static bool IsForeign(List<string> urls) => urls.Count > 0 && !AllWhitelisted(urls);

    static int JudgeFileEdit(string file)
    {
        string dir = ToWindowsPath(file).Replace('/', '\\');
        // A Write may create new directories: judge the nearest existing one.
        do { dir = Path.GetDirectoryName(dir) ?? ""; } while (dir.Length > 0 && !Directory.Exists(dir));
        if (dir.Length == 0) return 0;
        var urls = PushRemoteUrls(dir);
        if (!IsForeign(urls)) return 0;
        return JudgeMirror(dir, urls, file);
    }

    // In a repo that is not ours, a checkout of the remote's DEFAULT branch is
    // a read-only mirror of it: work happens in the user's worktrees on their
    // own branches. Fail closed when no remote records its default branch.
    static int JudgeMirror(string dir, List<string> urls, string what)
    {
        string? branch = Git(dir, "symbolic-ref", "-q", "--short", "HEAD");
        if (branch is null) return 0; // detached: not a checkout of the default branch
        string? remotes = Git(dir, "remote");
        var known = new List<string>();
        foreach (var r in (remotes ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            string? head = Git(dir, "symbolic-ref", "-q", "--short", $"refs/remotes/{r}/HEAD");
            if (head is null) continue;
            known.Add(r);
            if (head == $"{r}/{branch}")
            {
                Console.Error.WriteLine($"BLOCKED: {what} — this checkout is on {head}, the default branch of a repo that is not ours ({string.Join(", ", urls)}). It is a read-only mirror.");
                Console.Error.WriteLine("Make the change in a worktree on its own branch.");
                return 2;
            }
        }
        if (known.Count == 0)
        {
            Console.Error.WriteLine($"BLOCKED: {what} — cannot tell whether branch '{branch}' is the remote's default branch (no refs/remotes/<remote>/HEAD) in a repo that is not ours.");
            Console.Error.WriteLine($"Ask the user to run: git -C \"{dir}\" remote set-head origin --auto");
            return 2;
        }
        return 0;
    }

    // Every `git <verb>` in the command that writes the working tree or its
    // refs. A reason means "blocked in a repo that is not ours"; a null entry
    // is a plain `git add <path>`, allowed there except in the read-only mirror.
    static List<string?> PolicedVerbs(string cmd)
    {
        var hits = new List<string?>();
        foreach (var line in cmd.Split('\n'))
        {
            foreach (Match m in VerbRe().Matches(line.TrimEnd('\r')))
            {
                string verb = m.Groups["verb"].Value;
                var t = m.Groups["rest"].Value
                    .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).ToList();
                string? reason = VerbReason(verb, t);
                if (reason is not null || verb == "add")
                    hits.Add(reason);
            }
        }
        return hits;
    }

    static bool ShortFlagHas(string tok, char c) =>
        tok.Length > 1 && tok[0] == '-' && tok[1] != '-' && tok.Contains(c);

    // null = not a write we police (except a plain add, see PolicedVerbs).
    static string? VerbReason(string verb, List<string> t)
    {
        switch (verb)
        {
            case "checkout":
                if (t.Any(x => x is "-b" or "-B" or "--orphan")) return "git checkout -b creates a branch";
                if (t.Contains("--")) return null; // restoring named paths
                return t.Any(x => !x.StartsWith('-')) ? "git checkout <branch> switches the checkout's branch" : null;
            case "switch":
                return "git switch changes the checkout's branch";
            case "branch":
                if (t.Count == 0) return null;
                if (!t[0].StartsWith('-')) return "git branch <name> creates a branch";
                string? bad = t.FirstOrDefault(x => x is "-d" or "-D" or "--delete" or "-m" or "-M" or "--move" or "-c" or "-C" or "--copy"
                                  or "-f" or "--force" or "-u" or "--unset-upstream" || x.StartsWith("--set-upstream-to"));
                return bad is null ? null : $"git branch {bad} rewrites branches";
            case "stash":
                return t.Count > 0 && t[0] is "list" or "show" ? null : "git stash moves the user's uncommitted work";
            case "add":
                return t.Any(x => x is "." or "./" or ":/" or "--all" or "--update" or "--no-ignore-removal"
                                  || ShortFlagHas(x, 'A') || ShortFlagHas(x, 'u'))
                    ? "git add -A / -u / . stages the whole tree (stage named files only)" : null;
            case "reset":
                return t.Contains("--hard") ? "git reset --hard discards the user's work" : null;
            case "clean":
                return t.Any(x => x == "--force" || ShortFlagHas(x, 'f')) ? "git clean -f deletes untracked files" : null;
            case "worktree":
                return t.Count > 0 && t[0] == "add" ? "git worktree add creates a checkout" : null;
        }
        return null;
    }

    // _strip_quotes: char-by-char removal of single/double quoted substrings,
    // including the quote chars. Direct port of the bash state machine.
    // Remove any heredoc BODY, keeping the command line itself. A commit
    // message passed as `git commit -F - <<MSG ... MSG` is DATA, not flags:
    // without this, a message that merely discusses "-n" or "--no-verify" is
    // read as using them and the commit is refused.
    static string StripHeredocs(string s)
    {
        var sb = new StringBuilder();
        string? tag = null;
        foreach (var raw in s.Split('\n'))
        {
            var line = raw.TrimEnd('\r');
            if (tag is not null)
            {
                if (line == tag) tag = null;
                continue;
            }
            var m = HeredocRe().Match(line);
            if (m.Success) tag = m.Groups[1].Value;
            sb.Append(line).Append('\n');
        }
        return sb.ToString();
    }

    // With a mark, each quoted string leaves that token behind instead of
    // vanishing, so it still counts as one argument.
    static string StripQuotes(string s, string mark = "")
    {
        var sb = new StringBuilder(s.Length);
        char q = '\0';
        foreach (char ch in s)
        {
            if (q != '\0')
            {
                if (ch == q) q = '\0';
                continue;
            }
            if (ch is '\'' or '"') { q = ch; sb.Append(mark); continue; }
            sb.Append(ch);
        }
        return sb.ToString();
    }

    static bool HasRedirect(string cmd)
    {
        string s = StripQuotes(cmd);
        return RedirectEnvRe().IsMatch(s) || RedirectFlagRe().IsMatch(s);
    }

    // resolve_target: cwd, overridden by a leading `cd <path>`, then by `git -C <path>`.
    static string ResolveTarget(string cmd, string cwd)
    {
        string target = cwd;
        var cd = CdRe().Match(cmd);
        if (cd.Success) target = cd.Groups[2].Value;
        var dashC = GitDashCRe().Match(cmd);
        if (dashC.Success) target = dashC.Groups[1].Value;
        return target;
    }

    static bool IsWhitelistedUrl(string url)
    {
        if (url.Length == 0) return false;
        string lc = url.ToLowerInvariant();
        if (lc.Contains("..")) return false;   // traversal could leave the org
        return GithubRe().IsMatch(lc)
            || AdoEvolxRe().IsMatch(lc)
            || AdoEvolxSshRe().IsMatch(lc);
    }

    // remote sub-verb: first lowercase-hyphen token after "remote ".
    static string RemoteSubFrom(string stripped)
    {
        var m = RemoteSubRe().Match(stripped);
        return m.Success ? m.Groups[1].Value : "";
    }

    static string LastToken(string stripped)
    {
        var parts = stripped.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        return parts.Length == 0 ? "" : parts[^1];
    }

    // ensure_hook: returns "ok" | "foreign" | "norepo". Installs/refreshes our
    // stub into the target repo's real hooks dir; never clobbers a foreign hook.
    static string EnsureHook(string dir)
    {
        // The target may be MSYS-form (/c/...); we're a native Win32 process, so
        // normalize before any Win32 filesystem op OR child-process working dir.
        dir = ToWindowsPath(dir);

        if (!Directory.Exists(TemplateHooks)) return "ok"; // no template -> defer

        string? hookdir = GitHooksDir(dir);
        if (string.IsNullOrEmpty(hookdir)) return "norepo";

        // rev-parse --git-path returns a repo-relative path; make absolute.
        hookdir = ToWindowsPath(hookdir);
        if (!IsAbsolute(hookdir))
            hookdir = Path.Combine(dir, hookdir);
        try { Directory.CreateDirectory(hookdir); } catch { /* best-effort */ }

        bool foreign = false;
        foreach (string h in new[] { "pre-commit", "commit-msg", "pre-push" })
        {
            string tmpl = Path.Combine(TemplateHooks, h);
            if (!File.Exists(tmpl)) continue;
            string dst = Path.Combine(hookdir, h);

            int cur = -1;
            if (File.Exists(dst))
            {
                cur = StubVersion(dst);
                if (cur < 0 && new FileInfo(dst).Length > 0) { foreign = true; continue; }
            }
            int want = StubVersion(tmpl);
            if (cur != want)
            {
                try { File.Copy(tmpl, dst, overwrite: true); MakeExecutable(dst); } catch { /* best-effort */ }
            }
        }
        return foreign ? "foreign" : "ok";
    }

    // Read "git-guard-stub vN" marker; -1 if absent.
    static int StubVersion(string path)
    {
        try
        {
            foreach (string line in File.ReadLines(path))
            {
                var m = StubMarkerRe().Match(line);
                if (m.Success) return int.Parse(m.Groups[1].Value);
            }
        }
        catch { /* unreadable -> treat as no marker */ }
        return -1;
    }

    // Run `git -C <dir> <args...>` and return trimmed stdout, or null on any
    // failure. The single place this process shells out to git.
    static string? Git(string dir, params string[] args)
    {
        try
        {
            // Callers hand us whatever the hook JSON carried, which under Git
            // Bash is a POSIX path (/c/git/...). We are a native Win32 process,
            // so both WorkingDirectory and `git -C` need Windows form — without
            // this, git runs outside the repo and reports no remotes, which
            // reads as "destination could not be determined" and blocks
            // everything.
            dir = ToWindowsPath(dir);
            var psi = new System.Diagnostics.ProcessStartInfo("git")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                WorkingDirectory = Directory.Exists(dir) ? dir : Environment.CurrentDirectory,
            };
            psi.ArgumentList.Add("-C");
            psi.ArgumentList.Add(dir);
            foreach (var a in args) psi.ArgumentList.Add(a);
            using var p = System.Diagnostics.Process.Start(psi);
            if (p is null) return null;
            string outp = p.StandardOutput.ReadToEnd().Trim();
            p.StandardError.ReadToEnd();
            p.WaitForExit();
            return p.ExitCode == 0 && outp.Length > 0 ? outp : null;
        }
        catch { return null; }
    }

    static string? GitHooksDir(string dir) =>
        Git(dir, "rev-parse", "--git-path", "hooks");

    // Where would a push from <dir> land? Ask GIT rather than parsing the
    // command string. An explicit URL or remote name on the command line wins;
    // then the branch's upstream remote; then every configured push remote (a
    // bare `git push` with no upstream could reach any of them).
    static List<string> ResolvePushUrls(string dir, string stripped)
    {
        var urls = new List<string>();

        // Only the push's own arguments can name a destination: a URL elsewhere
        // on the line (`...; curl https://x`) is not where the push lands, and
        // a commit takes no destination argument at all.
        var seg = PushArgsRe().Match(stripped);
        string pushArgs = seg.Success ? "push" + seg.Groups["args"].Value : "";

        // An explicit URL argument is the destination, whatever the remotes say.
        foreach (var tok in pushArgs.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            if (tok.Contains("://") || (tok.Contains('@') && tok.Contains(':')))
            {
                urls.Add(tok);
                return urls;
            }
        }

        // An explicit remote NAME after `push`.
        var m = PushRemoteNameRe().Match(pushArgs);
        if (m.Success)
        {
            var u = Git(dir, "remote", "get-url", "--push", m.Groups[3].Value);
            if (u is not null) { urls.Add(u); return urls; }
        }

        // The current branch's upstream remote.
        var up = Git(dir, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}");
        if (up is not null)
        {
            var name = up.Split('/')[0];
            if (name.Length > 0)
            {
                var u = Git(dir, "remote", "get-url", "--push", name);
                if (u is not null) { urls.Add(u); return urls; }
            }
        }

        // Fall back to every push remote.
        return PushRemoteUrls(dir);
    }

    // Every configured push URL of the repo at <dir>, de-duplicated.
    static List<string> PushRemoteUrls(string dir)
    {
        var urls = new List<string>();
        var all = Git(dir, "remote", "-v");
        if (all is not null)
        {
            foreach (var line in all.Split('\n'))
            {
                var parts = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length >= 3 && parts[2] == "(push)" && !urls.Contains(parts[1]))
                    urls.Add(parts[1]);
            }
        }
        return urls;
    }

    // Every URL must be ours. No URLs at all -> false (fail closed: the
    // destination could not be established).
    static bool AllWhitelisted(List<string> urls)
    {
        if (urls.Count == 0) return false;
        foreach (var u in urls) if (!IsWhitelistedUrl(u)) return false;
        return true;
    }

    static bool IsAbsolute(string p) =>
        p.StartsWith('/') || (p.Length >= 2 && char.IsLetter(p[0]) && p[1] == ':');

    static void MakeExecutable(string path)
    {
        if (OperatingSystem.IsWindows()) return; // chmod is a no-op on the NTFS side
        try
        {
            var psi = new System.Diagnostics.ProcessStartInfo("chmod")
            { UseShellExecute = false, RedirectStandardError = true, RedirectStandardOutput = true };
            psi.ArgumentList.Add("+x");
            psi.ArgumentList.Add(path);
            System.Diagnostics.Process.Start(psi)?.WaitForExit();
        }
        catch { /* best-effort */ }
    }

    // ── Regexes (source-generated for NativeAOT) ─────────────────────────────
    // Shared `git` prefix: git preceded by a non-[alnum_/\] boundary or start,
    // then any number of whitespace-separated tokens before the verb.
    const string GitPrefix = @"(^|[^a-zA-Z0-9_/\\])git\s+([^\s]+\s+)*";

    [GeneratedRegex(GitPrefix + @"(commit|push)([^a-zA-Z0-9_]|$)")]
    private static partial Regex CommitPushRe();

    // `git [global opts] <verb> <rest-of-segment>`. Only global options may sit
    // between git and the verb (so `git log --grep stash` is not a stash);
    // the rest runs to the next shell separator. Keep in sync with _VERB_RE.
    [GeneratedRegex("""(?<![a-zA-Z0-9_/\\])git(([ \t]+-[Cc][ \t]+[^ \t;&|]+)|([ \t]+--?[a-zA-Z][^ \t;&|]*))*[ \t]+(?<verb>checkout|switch|branch|stash|add|reset|clean|worktree)(?<rest>([ \t][^;&|]*)?)(?=[;&|]|$)""")]
    private static partial Regex VerbRe();

    [GeneratedRegex(GitPrefix + @"remote\s+(add|remove|rm|rename|set-url|set-branches|set-head|prune)([^a-zA-Z0-9_]|$)")]
    private static partial Regex RemoteMutationRe();

    [GeneratedRegex(GitPrefix + @"config\s+([^\s]+\s+)*(--add|--unset|--unset-all|--replace-all)\s+remote\.[^\s]+\.(url|pushurl|fetch|push|mirror)([^a-zA-Z0-9_]|$)")]
    private static partial Regex ConfigRemoteFlagRe();

    [GeneratedRegex(GitPrefix + @"config\s+([^\s]+\s+)*remote\.[^\s]+\.(url|pushurl|fetch|push|mirror)\s+[^\s]")]
    private static partial Regex ConfigRemoteBareRe();

    [GeneratedRegex(@"(^|[\s;&|])(GIT_DIR|GIT_WORK_TREE|GIT_COMMON_DIR|GIT_INDEX_FILE)=")]
    private static partial Regex RedirectEnvRe();

    [GeneratedRegex(@"(^|\s)--(git-dir|work-tree|namespace)(=|\s|$)")]
    private static partial Regex RedirectFlagRe();

    [GeneratedRegex(@"(^|\s)--no-verify(\s|=|$)")]
    private static partial Regex NoVerifyRe();

    // `-n` only counts as git's flag when it follows `git [opts] commit|push`.
    // The shell's string-test operator in `if [ -n "$x" ]; then git commit ...`
    // is ordinary scripting and must not be blocked.
    [GeneratedRegex(@"git(\s+-[^\s]+)*\s+(commit|push)(\s+[^\s]+)*\s+-n(\s|$)")]
    private static partial Regex GitDashNRe();

    [GeneratedRegex("""<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?""")]
    private static partial Regex HeredocRe();

    // `git [tokens] push <args to the next shell separator>`. Keep in sync
    // with _PUSH_ARGS_RE.
    [GeneratedRegex(@"(?<![a-zA-Z0-9_/\\])git([ \t]+[^ \t;&|\n]+)*?[ \t]+push(?<args>([ \t][^;&|\n]*)?)(?=[;&|\n]|$)")]
    private static partial Regex PushArgsRe();

    [GeneratedRegex(@"push\s+((-[^\s]+\s+)*)([a-zA-Z0-9._-]+)")]
    private static partial Regex PushRemoteNameRe();

    [GeneratedRegex(@"(^|[^a-zA-Z0-9_])cd\s+[""']?([^""'\s;&|]+)")]
    private static partial Regex CdRe();

    [GeneratedRegex(@"git\s+-C\s+[""']?([^""'\s]+)")]
    private static partial Regex GitDashCRe();

    [GeneratedRegex(@"remote\s+([a-z-]+)")]
    private static partial Regex RemoteSubRe();

    [GeneratedRegex(@"git-guard-stub v([0-9]+)")]
    private static partial Regex StubMarkerRe();

    // Anchored at the URL start and terminated at the host boundary, so a URL
    // that merely CONTAINS one of these does not match ('github.com.evil.io/x',
    // 'https://oebb.example.com/github.com/osis'). The content
    // judge (GitHook.cs) classifies repos with the same three.
    [GeneratedRegex(@"^(https://|git@|ssh://git@)github\.com[/:]")]
    private static partial Regex GithubRe();

    [GeneratedRegex(@"^https://([^@/]+@)?dev\.azure\.com/evolx/")]
    private static partial Regex AdoEvolxRe();

    [GeneratedRegex(@"^(ssh://)?git@ssh\.dev\.azure\.com:(v3/)?evolx/")]
    private static partial Regex AdoEvolxSshRe();
}

// The PreToolUse fields the guards read. JsonDocument, not reflection (AOT).
// A field of the wrong JSON type is a parse error: the hook fails closed.
internal sealed class Hook
{
    public string Tool = "";
    public string? Cwd, Command, FilePath, NotebookPath, Path, Content, NewString;
    public List<string> EditNewStrings = new();

    public static Hook Parse(string json)
    {
        var h = new Hook();
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (root.ValueKind == JsonValueKind.Null) return h;
        if (root.ValueKind != JsonValueKind.Object) throw new JsonException("hook input is not an object");
        h.Tool = Str(root, "tool_name") ?? "";
        h.Cwd = Str(root, "cwd");
        if (!root.TryGetProperty("tool_input", out var ti) || ti.ValueKind == JsonValueKind.Null) return h;
        if (ti.ValueKind != JsonValueKind.Object) throw new JsonException("tool_input is not an object");
        h.Command = Str(ti, "command");
        h.FilePath = Str(ti, "file_path");
        h.NotebookPath = Str(ti, "notebook_path");
        h.Path = Str(ti, "path");
        h.Content = Str(ti, "content");
        h.NewString = Str(ti, "new_string");
        if (ti.TryGetProperty("edits", out var edits) && edits.ValueKind == JsonValueKind.Array)
            foreach (var e in edits.EnumerateArray())
                if (e.ValueKind == JsonValueKind.Object && Str(e, "new_string") is { } s) h.EditNewStrings.Add(s);
        return h;
    }

    static string? Str(JsonElement o, string key)
    {
        if (!o.TryGetProperty(key, out var v) || v.ValueKind == JsonValueKind.Null) return null;
        if (v.ValueKind != JsonValueKind.String) throw new JsonException($"{key} is not a string");
        return v.GetString();
    }
}
