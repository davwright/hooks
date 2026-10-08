// claude-guard: blocks tool calls the user has corrected in many sessions, with the
// fix in the message. A blocked call teaches every session; a skill has to be remembered.
// Rules come from the 2026-09-25 skill review. Exit 2 = block; stderr is shown to Claude.
// Ported from ~/.claude/hooks/claude-guard.mjs.
//
// The regexes run with RegexOptions.ECMAScript so \b, \w and \s keep JavaScript's ASCII
// meaning (.NET's are Unicode).

using System.Text.RegularExpressions;

namespace ClaudeGitGuard;

internal static partial class Program
{
    const RegexOptions JsI = RegexOptions.ECMAScript | RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;
    const RegexOptions Js = RegexOptions.ECMAScript | RegexOptions.CultureInvariant;

    static string Norm(string s) => s.Replace('\\', '/').ToLowerInvariant();

    static readonly string UserHome = Norm(Environment.GetEnvironmentVariable("USERPROFILE") ?? "");

    static bool TouchesPulseData(string s)
    {
        string n = Norm(s);
        foreach (var p in new[] { $"{UserHome}/pulse", $"{UserHome}/devpulse", $"{UserHome}/appdata/local/devpulse" })
        {
            for (int i = n.IndexOf(p, StringComparison.Ordinal); i >= 0; i = n.IndexOf(p, i + 1, StringComparison.Ordinal))
            {
                int end = i + p.Length;
                if (end == n.Length || n[end] is '/' or '"' or '\'' || IsJsSpace(n[end])) return true;
            }
        }
        return false;
    }

    // JavaScript's \s.
    static bool IsJsSpace(char c) =>
        c is '\t' or '\n' or '\v' or '\f' or '\r' or ' ' or '\u00a0' or '\u1680' or '\u2028' or '\u2029'
            or '\u202f' or '\u205f' or '\u3000' or '\ufeff'
        || (c >= '\u2000' && c <= '\u200a');

    const string PulseMsg = "Read Pulse tasks through the devpulse MCP tools (get_task, list_tasks, next_task, task_graph), " +
        "not from the Pulse's files on disk. Direct file access is only for developing the Pulse itself, from c:/git/extensions/devpulse.";
    const string JiraMsg = "Jira tickets go through the Pulse (devpulse MCP tools), not Jira directly. Direct Jira REST or " +
        "Atlassian MCP is only for building Jira features into the Pulse, from c:/git/extensions/devpulse.";

    sealed record Rule(Func<string, bool> Test, string Msg, bool SkipSearches = false, bool UnlessDevpulse = false);

    // Shell commands (Bash and PowerShell tools).
    static readonly Rule[] CommandRules =
    [
        new(s => AzReposPrRe().IsMatch(s), "Use `ev ado pr ...` (create, list, update, complete, abandon), not az repos pr.", SkipSearches: true),
        new(s => PatEnvRe().IsMatch(s),
            "Don't use a PAT via AZURE_DEVOPS_EXT_PAT. Use `ev ado ...`, `ev ado api <path>`, or `ev auth token --resource ado` for a raw call.",
            SkipSearches: true),
        new(s => BasicAuthRe().IsMatch(s),
            "Don't hand-build a Basic auth header from base64. Use `ev ado api <path>` or `ev auth token --resource ado`; with a PAT, `curl -u \":$PAT\"`.",
            SkipSearches: true),
        // Only the retired runner: canvas-app-tester/editor is the live canvas-app-editor.
        new(s => CanvasAppTesterRe().IsMatch(s),
            "canvas-app-tester is retired; you are building dat (evotester). Run tests with `evt run`, get a browser tab with evotester's `POST /api/v2/browser/open` (see the evotester skill).",
            SkipSearches: true),
        new(s => PlaywrightRe().IsMatch(s),
            "No ad-hoc Playwright for UI tests. Use evotester: `evt run`, and `POST /api/v2/browser/open` for the one signed-in browser (see the evotester skill).",
            SkipSearches: true),
        new(s => AzRe().IsMatch(s),
            "Don't use az for ADO or Dataverse. Use ev (see the ev-auth skill): `ev auth token`, `ev ado ...`, `ev dv ...`.",
            SkipSearches: true),
        // Searching for or writing about the names is fine; only running them is the mistake.
        new(s => DeprecatedCmdletRe().IsMatch(s),
            "The DataverseCmdlets and deploy scripts are deprecated. Edit the yaml, run yamlizer, and use the ev commands it emits (see the yamlize-ev skill).",
            SkipSearches: true),
        new(s => KillNodeRe().IsMatch(s),
            "Never kill node.exe by name: claude-proxy and the MCP servers run on node, and every Claude session depends on them. Find the specific PID (e.g. by command line) and stop only that."),
        new(s => JiraRestRe().IsMatch(s), JiraMsg, UnlessDevpulse: true),
        new(TouchesPulseData, PulseMsg, UnlessDevpulse: true),
        // Branches kept appearing in personal tool repos (Claude-Alert, githooks) and left work unmerged.
        new(s => BranchStashRe().IsMatch(s),
            "No branches and no stash: work on main and commit there (see the git-workflow skill). " +
            "If a branch already exists, fast-forward main to it and delete it.",
            SkipSearches: true),
        // Python isn't installed; Claude reaches for it anyway. Statement-leading only (line start, after
        // a separator, or after KEY=value prefixes), so `pythonic`, paths and `node -e '...python...'` pass.
        new(s => PythonRe().IsMatch(s),
            "Python toolchain is not installed on this machine. Solve it in Node.js (node, npm, npx) or PowerShell 5.1 " +
            "(powershell.exe -NoProfile -ExecutionPolicy Bypass -File <script.ps1>). If you genuinely need Python, ask the user before installing anything."),
        // ev's profiles hold the agent permissions ("agent" section); writing them would let an
        // agent grant itself. Reads (cat, grep, Get-Content) pass; anything that writes is blocked.
        // SkipSearches: a commit message or grep that describes the rule is not a write.
        new(s => EvProfileFileRe().IsMatch(s) && ShellWriteRe().IsMatch(s), EvProfileMsg, SkipSearches: true),
        // ev recognises Claude by CLAUDECODE, which every command Claude runs inherits. Clearing it
        // would make ev treat Claude as the person and skip the profile's permissions.
        new(s => ClaudeMarkerRe().IsMatch(s), ClaudeMarkerMsg, SkipSearches: true),
    ];

    const string EvProfileMsg = "ev's profile and policy files (~/.evolx/profiles/*.json, ~/.evolx/ev-policy.json) carry what Claude may " +
        "change, so Claude may not write them. Use ev's verbs (ev profile set / bind / edit); permissions are the user's: " +
        "ev profile agent <NAME> --<service> read|write, run by the user.";

    const string ClaudeMarkerMsg = "CLAUDECODE tells ev that Claude is running it, so ev applies the profile's Claude permissions. " +
        "Do not clear or change it. If a write is refused, ask the user to grant it: ev profile agent <NAME> --<service> write.";

    // A shell-form hook (a .sh, or a command line with arguments in `command`) starts Git Bash, which
    // takes 1.5s idle and 5-12s under load here. Claude Code cancels the hook at its timeout, so a guard
    // silently fails open and an alert never arrives. Measured 2026-10-05: 2000+ cancelled hooks in a day.
    const string HookMsg = "Hooks must run in exec form, with no shell: {\"type\":\"command\",\"command\":\"node\",\"args\":[\"C:/.../x.mjs\"]} " +
        "or {\"type\":\"command\",\"command\":\"C:/.../x.exe\",\"args\":[]}. A .sh or a command line in \"command\" starts Git Bash " +
        "(1.5-12s here); Claude Code cancels the hook at its timeout and a guard fails open. Port the script to node, or fold it " +
        "into an existing exe (ClaudeHook in c:/git/tools/Claude-Alert, claude-git-guard in c:/git/tools/githooks).";

    const string PlaywrightToolMsg = "Use the claude-browser tools (mcp__claude-browser__browser_*): one persistent Edge with the user's MFA logins. " +
        "Plugin Playwright browsers are separate and empty. If mcp__claude-browser__ tools are missing, the session predates " +
        "their registration — ask the user to restart the session or reconnect claude-browser via /mcp.";

    static int ClaudeBlock(string msg)
    {
        Console.Error.WriteLine($"BLOCKED by claude-guard: {msg}");
        return 2;
    }

    static int ClaudeGuard(Hook h)
    {
        bool devpulse = Norm(h.Cwd ?? "").StartsWith("c:/git/extensions/devpulse", StringComparison.Ordinal);
        string tool = h.Tool;

        if (tool is "Bash" or "PowerShell")
        {
            string command = h.Command ?? "";
            string? searchless = null;
            foreach (var rule in CommandRules)
            {
                if (rule.UnlessDevpulse && devpulse) continue;
                // Search statements are exempt one statement at a time, so `grep x; Connect-Dataverse` still blocks.
                string text = rule.SkipSearches ? (searchless ??= WithoutSearches(command)) : command;
                if (rule.Test(text)) return ClaudeBlock(rule.Msg);
            }
        }
        else if (tool is "Edit" or "Write" or "MultiEdit" or "NotebookEdit" && IsEvProfileFile(h.FilePath ?? h.NotebookPath ?? ""))
        {
            return ClaudeBlock(EvProfileMsg);
        }
        else if (tool is "Edit" or "Write" or "MultiEdit")
        {
            var parts = new List<string>();
            if (!string.IsNullOrEmpty(h.Content)) parts.Add(h.Content);
            if (!string.IsNullOrEmpty(h.NewString)) parts.Add(h.NewString);
            parts.AddRange(h.EditNewStrings.Where(s => s.Length > 0));
            if (HookConfigRe().IsMatch(Norm(h.FilePath ?? "")) && ShellFormHookRe().IsMatch(string.Join("\n", parts)))
                return ClaudeBlock(HookMsg);
        }
        else if (PlaywrightToolRe().IsMatch(tool))
        {
            // Plugin-bundled Playwright servers launch their own empty browser without the user's logins.
            return ClaudeBlock(PlaywrightToolMsg);
        }
        else if (AtlassianToolRe().IsMatch(tool))
        {
            if (!devpulse) return ClaudeBlock(JiraMsg);
        }
        else if (tool is "Read" or "Grep" or "Glob")
        {
            string path = h.FilePath ?? h.Path ?? "";
            // get_task delivers embedded images as files under ~/pulse/media, so Read must reach them.
            bool pulseMedia = tool == "Read" && Norm(path).StartsWith($"{UserHome}/pulse/media/", StringComparison.Ordinal);
            if (path.Length > 0 && TouchesPulseData(path) && !devpulse && !pulseMedia) return ClaudeBlock(PulseMsg);
        }
        return 0;
    }

    static bool IsEvProfileFile(string path)
    {
        string n = Norm(path);
        return n.StartsWith($"{UserHome}/.evolx/profiles/", StringComparison.Ordinal) || n == $"{UserHome}/.evolx/ev-policy.json";
    }

    // Statements that only mention commands: searches, and commit messages that describe a change.
    static string WithoutSearches(string command) =>
        string.Join("\n", StatementSplitRe().Split(HeredocBodyRe().Replace(command, "\n")).Where(s => !SearchRe().IsMatch(s)));

    [GeneratedRegex(@"\.evolx[\\/]+(profiles\b|ev-policy\.json)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex EvProfileFileRe();

    // A redirect (not 2> or >&), a writing cmdlet or tool, or an in-place edit.
    [GeneratedRegex(@"(?<![0-9&>])>>?(?!&)|\b(Set-Content|Add-Content|Out-File|Copy-Item|Move-Item|Remove-Item|Rename-Item|New-Item|cp|mv|rm|del|tee|writeFileSync|writeFile|appendFileSync|WriteAllText|WriteAllBytes|rename|unlink)\b|\bsed\s+-i",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex ShellWriteRe();

    // Assigning, unsetting or removing CLAUDECODE in bash, PowerShell, .NET or Node. Reading it passes.
    [GeneratedRegex(@"\bCLAUDECODE\s*=|\b(unset|env)\s+(-u\s+)?CLAUDECODE\b|\$env:CLAUDECODE\s*=|Remove-Item\s+(-Path\s+)?env:\\?CLAUDECODE|SetEnvironmentVariable\(\s*[""']CLAUDECODE|process\.env\.CLAUDECODE\s*=|delete\s+process\.env\.CLAUDECODE",
        RegexOptions.CultureInvariant)]
    private static partial Regex ClaudeMarkerRe();

    [GeneratedRegex(@"\baz\s+repos\s+pr\b", JsI)]
    private static partial Regex AzReposPrRe();

    [GeneratedRegex(@"\bAZURE_DEVOPS_EXT_PAT\b", Js)]
    private static partial Regex PatEnvRe();

    [GeneratedRegex(@"\bBasic\s+(\$\(|[""']\s*\+\s*\[Convert\]::ToBase64String)", JsI)]
    private static partial Regex BasicAuthRe();

    [GeneratedRegex(@"run-ui-yaml\.js|Run-5x\.ps1|canvas-app-tester[\\/]md-tester\b|\b(step_ui_tests|12bu-ui-tests)\.ps1", JsI)]
    private static partial Regex CanvasAppTesterRe();

    [GeneratedRegex(@"\bchromium\.launch\b|\bnpx\s+playwright\b(?!\s+show-trace)", JsI)]
    private static partial Regex PlaywrightRe();

    [GeneratedRegex(@"\baz\s+(devops|repos|boards|pipelines|rest|account\s+get-access-token)\b", JsI)]
    private static partial Regex AzRe();

    [GeneratedRegex(@"\b(Connect-Dataverse|Push-DV\w*|Import-DV\w*|Export-DV\w*|Sync-DV\w*|Deploy-Module\.ps1|deploy-webresources\.ps1)\b", JsI)]
    private static partial Regex DeprecatedCmdletRe();

    [GeneratedRegex(@"(taskkill\b[^\n]*/im\s+""?node(\.exe)?""?|Stop-Process\b[^\n]*-(Name|ProcessName)\s+""?node\b|Get-Process\s+""?node""?\s*\|\s*(Stop-Process|kill)\b|\b(pkill|killall)\s+(-\S+\s+)*node\b)", JsI)]
    private static partial Regex KillNodeRe();

    [GeneratedRegex(@"atlassian\.net/(rest|wiki/rest)/", JsI)]
    private static partial Regex JiraRestRe();

    [GeneratedRegex(@"\bgit\s+(-C\s+\S+\s+)*(checkout\s+(-\S+\s+)*-[bB]\b|switch\s+(-\S+\s+)*(-[cC]\b|--create\b)|branch\s+(?!-)(?!--)[^\s;&|]+|stash\b)", JsI)]
    private static partial Regex BranchStashRe();

    // JS /m: ^ also follows \r, \u2028 and \u2029; .NET's Multiline only follows \n.
    [GeneratedRegex(@"((?:^|(?<=[\r\u2028\u2029]))|\s*(&&|\|\||;|\||&)\s*|(?:^|(?<=[\r\u2028\u2029]))(\s*[A-Za-z_][A-Za-z0-9_]*=\S*\s+)+)(python3?|py|pip3?|pipx|poetry|uv)(\.exe)?(\s|$)", Js | RegexOptions.Multiline)]
    private static partial Regex PythonRe();

    [GeneratedRegex(@"""command""\s*:\s*""((node|bash|sh|powershell|cmd)(\.exe)?\s|(?:[^""\\]|\\.)*\.sh\b)", JsI)]
    private static partial Regex ShellFormHookRe();

    [GeneratedRegex(@"(^|/)(\.claude/settings(\.local)?\.json|hooks/hooks\.json)\z", Js)]
    private static partial Regex HookConfigRe();

    [GeneratedRegex(@"^mcp__plugin_.*playwright__browser_", JsI)]
    private static partial Regex PlaywrightToolRe();

    [GeneratedRegex(@"^mcp__.*atlassian", JsI)]
    private static partial Regex AtlassianToolRe();

    [GeneratedRegex(@"^\s*(grep|rg|egrep|findstr|Select-String|sls|git\s+(-C\s+\S+\s+)?(grep|log|show|diff|commit))\b", JsI)]
    private static partial Regex SearchRe();

    [GeneratedRegex(@"<<-?\s*(['""]?)(\w+)\1[^\n]*\n[\s\S]*?\n\s*\2\s*(\n|\z)", Js)]
    private static partial Regex HeredocBodyRe();

    [GeneratedRegex(@"\n|;|&&|\|\|", Js)]
    private static partial Regex StatementSplitRe();
}
