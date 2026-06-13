// claude-git-guard — NativeAOT port of claude-git-guard.sh (the THIN Claude Code
// PreToolUse hook). Same contract: PreToolUse JSON on stdin, exit 0 = allow,
// exit 2 = block (message on stderr). The whitelist judging lives in the per-repo
// git hooks (git-guard.sh); this layer only does what the git layer can't:
//   1. Belt: block shapes git hooks are blind to / that bypass them
//        (--no-verify, GIT_DIR/--git-dir redirect, remote add/set-url to a
//         non-whitelisted URL, git config remote.* writes).
//   2. Self-heal: before commit|push, install our git-hook stub into the target
//      repo (or block if a foreign hook is present).
// Logic is a faithful port of the bash version — the same test suite must pass
// against either implementation.

using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace ClaudeGitGuard;

internal static partial class Program
{
    const int GuardStubVersion = 1;

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

            string stripped = StripQuotes(cmd);
            if (NoVerifyRe().IsMatch(stripped))
            {
                Console.Error.WriteLine("BLOCKED: --no-verify / -n is not allowed on commit/push — it bypasses the git-guard hook that judges the destination. Run it manually if you truly intend to skip the guard.");
                return 2;
            }

            string target = ResolveTarget(cmd, cwd);
            if (string.IsNullOrEmpty(target))
            {
                Console.Error.WriteLine("BLOCKED: could not determine target directory for git command.");
                return 2;
            }

            if (EnsureHook(target) == "foreign")
            {
                Console.Error.WriteLine($"BLOCKED: {target}/.git/hooks already has a non-git-guard pre-commit/pre-push hook. Refusing to overwrite it. Install git-guard manually (chain it) or run the command yourself.");
                return 2;
            }
            return 0; // armed (or deferred): the git hook now does the real judging
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
        string lc = url.ToLowerInvariant();
        return GithubRe().IsMatch(lc) || AdoEvolxRe().IsMatch(lc);
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
        foreach (string h in new[] { "pre-commit", "pre-push" })
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

    static string? GitHooksDir(string dir)
    {
        try
        {
            var psi = new System.Diagnostics.ProcessStartInfo("git")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                WorkingDirectory = Directory.Exists(dir) ? dir : Environment.CurrentDirectory,
            };
            psi.ArgumentList.Add("-C");
            psi.ArgumentList.Add(dir);
            psi.ArgumentList.Add("rev-parse");
            psi.ArgumentList.Add("--git-path");
            psi.ArgumentList.Add("hooks");
            using var p = System.Diagnostics.Process.Start(psi);
            if (p is null) return null;
            string outp = p.StandardOutput.ReadToEnd().Trim();
            p.StandardError.ReadToEnd();
            p.WaitForExit();
            return p.ExitCode == 0 && outp.Length > 0 ? outp : null;
        }
        catch { return null; }
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

    [GeneratedRegex(@"(^|\s)(--no-verify|-n)(\s|=|$)")]
    private static partial Regex NoVerifyRe();

    [GeneratedRegex(@"(^|[^a-zA-Z0-9_])cd\s+[""']?([^""'\s;&|]+)")]
    private static partial Regex CdRe();

    [GeneratedRegex(@"git\s+-C\s+[""']?([^""'\s]+)")]
    private static partial Regex GitDashCRe();

    [GeneratedRegex(@"remote\s+([a-z-]+)")]
    private static partial Regex RemoteSubRe();

    [GeneratedRegex(@"git-guard-stub v([0-9]+)")]
    private static partial Regex StubMarkerRe();

    [GeneratedRegex(@"github\.com")]
    private static partial Regex GithubRe();

    [GeneratedRegex(@"dev\.azure\.com/evolx/")]
    private static partial Regex AdoEvolxRe();
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
