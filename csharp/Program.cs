// claude-git-guard — NativeAOT port of claude-git-guard.sh (the THIN Claude Code
// PreToolUse hook). Same contract: PreToolUse JSON on stdin, exit 0 = allow,
// exit 2 = block (message on stderr).
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
// The per-repo git hook (git-guard.sh) owns the CONTENT rule instead: no
// AI-tool words in a customer repo's history, enforced for everyone.
// Logic is a faithful port of the bash version — the same test suite must pass
// against either implementation.

using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace ClaudeGitGuard;

internal static partial class Program
{
    const int GuardStubVersion = 2;

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

    static int Main()
    {
        string input = Console.In.ReadToEnd();

        // Fast bail: no "git" substring anywhere -> no work. Mirrors the bash
        // `case "$input" in *git*) ;; *) exit 0` on the raw JSON.
        if (!input.Contains("git", StringComparison.Ordinal))
            return 0;

        string cmd;
        string cwd;
        try
        {
            var hook = JsonSerializer.Deserialize(input, HookJson.Default.HookInput);
            cmd = hook?.ToolInput?.Command ?? "";
            cwd = hook?.Cwd ?? "";
        }
        catch (JsonException)
        {
            Console.Error.WriteLine("BLOCKED: failed to parse hook input.");
            return 2;
        }

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

        return 0; // not a git write we police — let it through
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

    static string StripQuotes(string s)
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
            if (ch is '\'' or '"') { q = ch; continue; }
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

        string? hookdir = GitHooksDir(dir);
        if (string.IsNullOrEmpty(hookdir)) return "norepo";

        // rev-parse --git-path returns a repo-relative path; make absolute.
        hookdir = ToWindowsPath(hookdir);
        if (!IsAbsolute(hookdir))
            hookdir = Path.Combine(dir, hookdir);

        if (!Directory.Exists(TemplateHooks)) return "ok"; // no template -> defer
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

        // An explicit URL argument is the destination, whatever the remotes say.
        foreach (var tok in stripped.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            if (tok.Contains("://") || (tok.Contains('@') && tok.Contains(':')))
            {
                urls.Add(tok);
                return urls;
            }
        }

        // An explicit remote NAME after `push`.
        var m = PushRemoteNameRe().Match(stripped);
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
    // 'https://oebb.example.com/github.com/osis'). Keep in sync with
    // OWN_REMOTES in git-guard.sh.
    [GeneratedRegex(@"^(https://|git@|ssh://git@)github\.com[/:]")]
    private static partial Regex GithubRe();

    [GeneratedRegex(@"^https://([^@/]+@)?dev\.azure\.com/evolx/")]
    private static partial Regex AdoEvolxRe();

    [GeneratedRegex(@"^(ssh://)?git@ssh\.dev\.azure\.com:(v3/)?evolx/")]
    private static partial Regex AdoEvolxSshRe();
}

internal sealed class HookInput
{
    [JsonPropertyName("cwd")] public string? Cwd { get; set; }
    [JsonPropertyName("tool_input")] public ToolInput? ToolInput { get; set; }
}

internal sealed class ToolInput
{
    [JsonPropertyName("command")] public string? Command { get; set; }
}

[JsonSourceGenerationOptions(PropertyNameCaseInsensitive = true)]
[JsonSerializable(typeof(HookInput))]
internal partial class HookJson : JsonSerializerContext;
