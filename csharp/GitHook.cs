// The per-repo git hook — the CONTENT judge. A repo's .git/hooks/pre-commit,
// commit-msg and pre-push are one-line stubs that exec this binary:
//
//   git-guard.exe pre-commit              # scan the staged diff
//   git-guard.exe commit-msg <file>       # scan the FINAL commit message
//   git-guard.exe pre-push <name> <url>   # scan what is about to be published
//
// Exit 0 = allow, nonzero = git aborts the operation.
//
// WHY THIS DOES NOT JUDGE THE PUSH DESTINATION
//
// This hook runs for EVERYONE — the user's terminal, VSCode's Source Control
// panel, any GUI client, and Claude alike. Git hooks cannot tell who invoked
// them, and no environment variable can establish that either: every var in a
// process is writable by that process for any child it spawns, so an env-var
// "am I Claude?" test is spoofable by the one party it exists to constrain.
//
// So the two rules are split by WHO they must bind:
//   * DESTINATION ("don't push to customer repos") binds CLAUDE ONLY. That rule
//     lives in the PreToolUse hook (Program.cs), which fires only for Claude by
//     construction.
//   * CONTENT ("no AI-tool words in customer history") binds EVERYONE, the user
//     included. That rule is THIS FILE.
//
// The remote URL only decides WHETHER TO SCAN: own repos are skipped (their
// history may legitimately discuss Claude — this very repo does), customer
// repos are scanned.
//
// NOTE: --no-verify skips git hooks entirely, so this cannot stop a
// `--no-verify` commit/push. For Claude that hole is closed in the PreToolUse
// hook. A human using --no-verify is doing so deliberately.

using System.Text.RegularExpressions;

namespace ClaudeGitGuard;

internal static partial class Program
{
    // Word-bounded and case-insensitive: 'claude' trips, 'claudel' does not.
    static readonly string[] AiWords =
        ["claude", "anthropic", "opus", "sonnet", "haiku", "fable", "llm", "gpt", "copilot"];

    static int RunGitHook(string[] args)
    {
        string mode = args[0];
        if (mode is not ("pre-commit" or "commit-msg" or "pre-push"))
        {
            Console.Error.WriteLine($"git-guard: unknown mode '{mode}' (expected pre-commit, commit-msg or pre-push) — refusing (fail closed).");
            return 1;
        }

        string cwd = Environment.CurrentDirectory;

        // Refresh this repo's stubs from the template when their version marker
        // differs. Never clobbers a foreign hook.
        EnsureHook(cwd);

        // On pre-push git hands us the ACTUAL destination URL in argv — judge
        // that, not `git remote -v`: `git push https://host/x.git main` names a
        // URL directly. Otherwise use the configured push remotes. A remote-less
        // repo is skipped: nothing can be published from it yet, and the gate
        // re-applies the moment a remote exists.
        var urls = mode == "pre-push" && args.Length > 2 && args[2].Length > 0
            ? [args[2]]
            : PushRemoteUrls(cwd);
        if (urls.Count == 0 || AllWhitelisted(urls)) return 0;

        switch (mode)
        {
            case "pre-commit":
                // Content only. The message is NOT judged here: git has not
                // necessarily composed it yet (COMMIT_EDITMSG can still hold the
                // previous message). commit-msg is where git guarantees it.
                return ScanText("staged diff", AddedLines(cwd, "diff", "--cached"))
                    ? 0 : ReportBlocked("the staged changes");

            case "commit-msg":
            {
                string path = args.Length > 1 ? args[1] : "";
                if (path.Length == 0 || !File.Exists(path)) return 0;
                // Drop git's comment lines, and the scissors section from
                // --verbose (it holds the whole diff, which pre-commit judges).
                var kept = new List<string>();
                foreach (var line in File.ReadAllLines(path))
                {
                    if (line == "# ------------------------ >8 ------------------------") break;
                    if (!line.StartsWith('#')) kept.Add(line);
                }
                return ScanMessage("commit message", string.Join('\n', kept))
                    ? 0 : ReportBlocked("the commit message");
            }

            default: // pre-push
            {
                // stdin: one line per ref, <local ref> <local sha> <remote ref> <remote sha>
                bool clean = true;
                string? refLine;
                while ((refLine = Console.In.ReadLine()) is not null)
                {
                    var f = refLine.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
                    if (f.Length < 2) continue;
                    string lsha = f[1], rsha = f.Length > 3 ? f[3] : "";
                    if (AllZeros().IsMatch(lsha)) continue; // branch deletion
                    // A new remote branch: only commits not already published elsewhere.
                    string? range = AllZeros().IsMatch(rsha)
                        ? Git(cwd, "rev-list", lsha, "--not", "--remotes")
                        : Git(cwd, "rev-list", $"{rsha}..{lsha}");
                    if (range is null) continue;
                    foreach (var sha in range.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                    {
                        string head = Git(cwd, "log", "-1", "--format=%h%n%B", sha) ?? "";
                        int nl = head.IndexOf('\n');
                        string shortSha = nl < 0 ? head : head[..nl];
                        string body = nl < 0 ? "" : head[(nl + 1)..];
                        clean &= ScanMessage($"commit {shortSha} message", body);
                        clean &= ScanText($"commit {shortSha} diff", AddedLines(cwd, "show", sha, "--format="));
                    }
                }
                return clean ? 0 : ReportBlocked("the commits being pushed");
            }
        }
    }

    // The '+' side of a diff, minus the +++ file headers. -U0 keeps context
    // lines out, so a pre-existing dirty line near an edit does not trip, and a
    // commit that REMOVES a dirty word is clean.
    static string AddedLines(string dir, params string[] args)
    {
        string diff = Git(dir, [.. args, "--no-color", "-U0", "--diff-filter=d"]) ?? "";
        var added = diff.Split('\n')
            .Where(l => l.StartsWith('+') && !l.StartsWith("+++"));
        return string.Join('\n', added);
    }

    // Report each blacklist hit on stderr. true = clean.
    static bool ScanText(string label, string text)
    {
        if (text.Length == 0) return true;
        string lc = text.ToLowerInvariant();
        bool clean = true;
        foreach (var w in AiWords)
        {
            // Only [a-z0-9] continues a word: 'sonnets_are_fine' must pass.
            if (Regex.IsMatch(lc, $"(^|[^a-z0-9]){w}([^a-z0-9]|$)"))
            {
                Console.Error.WriteLine($"  {label}: contains '{w}'");
                clean = false;
            }
        }
        foreach (var re in new[] { CoAuthoredRe(), GeneratedWithRe() })
        {
            if (re.IsMatch(lc))
            {
                Console.Error.WriteLine($"  {label}: matches attribution pattern");
                clean = false;
            }
        }
        return clean;
    }

    // ScanText, plus the private Pulse ids (commit MESSAGES only: a customer
    // repo's history must not point at a tracker nobody there can read).
    static bool ScanMessage(string label, string text)
    {
        bool clean = ScanText(label, text);
        var m = PulseIdRe().Match(text.ToLowerInvariant());
        if (m.Success)
        {
            Console.Error.WriteLine($"  {label}: contains '{m.Groups[2].Value}' (a private Pulse id)");
            clean = false;
        }
        return clean;
    }

    static int ReportBlocked(string where)
    {
        Console.Error.WriteLine($"git-guard: BLOCKED — AI-tool reference or private Pulse id in {where}.");
        Console.Error.WriteLine("This repo's push remote is not github/evolx, so AI-tool references must");
        Console.Error.WriteLine("not enter its history. Blacklisted (word-bounded, case-insensitive):");
        Console.Error.WriteLine($"  {string.Join(' ', AiWords)}");
        Console.Error.WriteLine("  and Pulse ids (PS-<n>, pulse<n>) in commit messages");
        Console.Error.WriteLine("Reword and retry.");
        return 1;
    }

    [GeneratedRegex(@"^0+$")]
    private static partial Regex AllZeros();

    // Attribution phrases, tolerant of punctuation and reflowed whitespace.
    [GeneratedRegex(@"co-?authored[-\s]*by:?\s*claude")]
    private static partial Regex CoAuthoredRe();

    [GeneratedRegex(@"generated\s+with\s+claude")]
    private static partial Regex GeneratedWithRe();

    [GeneratedRegex(@"(^|[^a-z0-9])(ps-[0-9]+|pulse[0-9]+)([^a-z0-9]|$)")]
    private static partial Regex PulseIdRe();
}
