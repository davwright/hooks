// claude-guard rules (ClaudeGuard.cs) in claude-git-guard.exe: each case is fed to the exe,
// spawned directly (no shell), and must exit 0 (allow) or 2 (block).
// Usage: node tests/claude-guard.test.mjs   (GUARD_CMD=<exe> for another build)
//
// Ported from ~/.claude/hooks/claude-guard.test.mjs. The exe runs the git checks first, and
// those block a commit whose destination is not ours, so the commit cases that test the
// "commit message is not a command" exemption run in a throwaway repo with a github remote.
import { spawnSync, execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const EXE = process.env.GUARD_CMD ?? new URL("../csharp/bin/Release/net9.0/win-x64/publish/claude-git-guard.exe", import.meta.url).pathname.slice(1);
const H = process.env.USERPROFILE;
const other = "C:\\git\\tools\\opus5.5", dev = "c:\\git\\extensions\\devpulse";

// HOME without a git template (no self-heal into real repos) and with an ev policy (a command
// that runs ev is blocked without one). USERPROFILE stays real: the Pulse rules are rooted there.
const root = mkdtempSync(join(tmpdir(), "claude-guard-test-"));
const home = join(root, "home");
mkdirSync(home);
const policy = join(root, "ev-policy.json");
writeFileSync(policy, JSON.stringify({
  dataverse: { writes_allowed: [], writes_denied: [], default: "deny" },
  ado: { writes_allowed: [], writes_denied: [], default: "deny" },
}));
const own = join(root, "own");
execFileSync("git", ["init", "-q", own]);
execFileSync("git", ["-C", own, "remote", "add", "origin", "https://github.com/me/x.git"]);
const env = { ...process.env, HOME: home, EV_POLICY_FILE: policy };

const sh = (command, cwd = other, tool = "Bash") => ({ tool_name: tool, tool_input: { command }, cwd });
const cases = [
  [sh("az devops invoke --area git"), 2], [sh("az rest --method get --url x", other, "PowerShell"), 2], [sh("az --version"), 0],
  [sh("Connect-Dataverse -Url x"), 2], [sh("./Deploy-Module.ps1 -Module tour"), 2],
  [sh("taskkill /F /IM node.exe"), 2], [sh("Stop-Process -Name node -Force", other, "PowerShell"), 2], [sh("pkill -f node"), 2],
  [sh("Get-Process node | Select-Object Id"), 0], [sh("taskkill /PID 1234 /F"), 0],
  [sh("curl -u me https://evolit.atlassian.net/rest/api/3/issue/OSIS-1"), 2],
  [sh("curl -u me https://evolit.atlassian.net/rest/api/3/issue/OSIS-1", dev), 0],
  [{ tool_name: "mcp__claude_ai_Atlassian_Rovo_2__getJiraIssue", tool_input: {}, cwd: other }, 2],
  [{ tool_name: "mcp__claude_ai_Atlassian_Rovo_2__getJiraIssue", tool_input: {}, cwd: dev }, 0],
  [{ tool_name: "Read", tool_input: { file_path: `${H}\\pulse\\activity.jsonl` }, cwd: other }, 2],
  [{ tool_name: "Read", tool_input: { file_path: `${H}\\pulse\\activity.jsonl` }, cwd: dev }, 0],
  [{ tool_name: "Grep", tool_input: { path: `${H}/pulse/workspaces`, pattern: "PS-9" }, cwd: other }, 2],
  [sh(`cat ${H.replace(/\\/g, "/")}/pulse/activity.jsonl`), 2],
  [sh(`Get-Content "${H}\\pulse\\activity.jsonl"`, other, "PowerShell"), 2],
  [{ tool_name: "Read", tool_input: { file_path: `${H}\\pulsestuff\\notes.md` }, cwd: other }, 0],
  [{ tool_name: "Read", tool_input: { file_path: "c:\\git\\extensions\\devpulse\\README.md" }, cwd: other }, 0],
  [{ tool_name: "mcp__devpulse__get_task", tool_input: { id: "PS-961" }, cwd: other }, 0],
  [sh("git status"), 0],
  [sh("powershell -File c:/osis/tools/Deploy-Module.ps1 -Module tour"), 2],
  [sh("./deploy-webresources.ps1"), 2],
  [sh('grep -rn "Push-DVWebResource" wiki/'), 0],
  [sh("rg -l Connect-Dataverse ."), 0],
  [sh("Select-String -Path *.md -Pattern Deploy-Module.ps1", other, "PowerShell"), 0],
  [sh("cat > doc.md <<'EOF'\nPush-DV* cmdlets are deprecated\nEOF"), 0],
  [sh("cat > doc.md <<'EOF'\nnotes\nEOF\nConnect-Dataverse -Url x"), 2],
  [sh("grep x . ; Connect-Dataverse -Url y"), 2],
  [sh('git commit -m "az-pr: drop az repos pr recipes, use ev ado pr"', own), 0],
  [sh(`git -C ${own} commit -m "remove Connect-Dataverse calls"`), 0],
  [sh('git commit -m x; az repos pr create --title t', own), 2],
  [{ tool_name: "mcp__plugin_model-apps_playwright__browser_tabs", tool_input: {}, cwd: other }, 2],
  [{ tool_name: "mcp__claude-browser__browser_snapshot", tool_input: {}, cwd: other }, 0],
  [sh("az repos pr create --title x"), 2], [sh("az repos pr list", other, "PowerShell"), 2],
  [sh("export AZURE_DEVOPS_EXT_PAT=abc; az devops login"), 2],
  [sh("$env:AZURE_DEVOPS_EXT_PAT = 'x'; ev ado pr list", other, "PowerShell"), 2],
  [sh("grep -rn AZURE_DEVOPS_EXT_PAT ."), 0],
  [sh('curl -H "Authorization: Basic $(echo -n ":$PAT" | base64)" https://dev.azure.com/x'), 2],
  [sh('$h = @{ Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat")))" }', other, "PowerShell"), 2],
  [sh('$h = @{ Authorization = "Basic " + [Convert]::ToBase64String($b) }', other, "PowerShell"), 2],
  [sh('curl -u ":$PAT" https://dev.azure.com/x'), 0],
  [sh("ev ado pr create --title x"), 0],
  [sh("node c:/git/tools/canvas-app-tester/md-tester/run-ui-yaml.js tests.yaml"), 2],
  [sh("cd c:\\git\\tools\\canvas-app-tester\\md-tester; npm start", other, "PowerShell"), 2],
  [sh("./Run-5x.ps1"), 2],
  [sh("powershell -File c:/git/evolx/osis/tools/deploy/steps/step_ui_tests.ps1 -Module tour"), 2],
  [sh("node --check c:/git/tools/canvas-app-tester/editor/scripts/sync.js"), 0],
  [sh("git -C c:/git/tools/canvas-app-tester commit -m x -- editor/scripts/sync.js"), 0],
  [sh("powershell -File c:\\git\\tools\\canvas-app-tester\\editor\\install.ps1", other, "PowerShell"), 0],
  [sh('grep -rn "run-ui-yaml.js" ~/.claude/skills'), 0],
  [sh("node -e \"const { chromium } = require('playwright'); chromium.launch()\""), 2],
  [sh("npx playwright test"), 2],
  [sh("npx playwright show-trace trace.zip"), 0],
  [sh("evt run modules/tour/tests/ui/a.test.yaml"), 0],
  [sh("python script.py"), 2], [sh("python3 -c 'print(1)'"), 2], [sh("py -3 x.py", other, "PowerShell"), 2],
  [sh("pip install requests"), 2], [sh("cd x && python -m http.server"), 2], [sh("FOO=1 BAR=2 python x.py"), 2],
  [sh("ls; uv run x"), 2], [sh("echo a | pip3 freeze"), 2], [sh("python.exe x.py"), 2], [sh("ls\npoetry install"), 2],
  [sh("node pythonic.js"), 0], [sh("ls /c/tools/python/bin"), 0], [sh("node -e 'console.log(\"python\")'"), 0],
  [sh("grep -rn python ."), 0], [sh("cat deploy.py"), 0], [sh("echo pip"), 0],
  [sh("git checkout -b feature-x"), 2], [sh("git -C c:/git/tools/x switch -c topic"), 2], [sh("git branch new-thing"), 2],
  [sh("git stash"), 2], [sh("git stash pop"), 2], [sh("git checkout -q -B x"), 2], [sh("git switch --create y"), 2],
  [sh("git branch -d old"), 0], [sh("git branch -a -vv"), 0], [sh("git branch --show-current"), 0], [sh("git branch"), 0],
  [sh("git checkout main"), 0], [sh("git switch main"), 0], [sh("git checkout -- file.cs"), 0], [sh("git log --oneline main..HEAD"), 0],
  ...(() => {
    const st = `${H}\\.claude\\settings.json`;
    const w = (file_path, content) => ({ tool_name: "Write", tool_input: { file_path, content }, cwd: other });
    const e = (file_path, new_string) => ({ tool_name: "Edit", tool_input: { file_path, old_string: "x", new_string }, cwd: other });
    return [
      [w(st, '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"C:/x/alert.sh"}]}]}}'), 2],
      [e(st, '"command": "~/.claude/hooks/block-python.sh", "timeout": 10'), 2],
      [e(st, '"command": "node C:/Users/x/.claude/hooks/g.mjs"'), 2],
      [e(`${H}\\.claude\\settings.local.json`, '"command":"bash -c true"'), 2],
      [e("c:\\git\\x\\.claude-plugin\\hooks\\hooks.json", '"command": "${CLAUDE_PLUGIN_ROOT}/run.sh"'), 2],
      [e(st, '"command": "node", "args": ["C:/Users/x/.claude/hooks/g.mjs"]'), 0],
      [e(st, '"command": "C:/Program Files/Tool/tool.exe", "args": []'), 0],
      [e("c:\\git\\x\\docs\\hooks.md", '"command": "x.sh"'), 0],
      [w("c:\\git\\x\\run.sh", "#!/bin/bash\necho hi"), 0],
    ];
  })(),
];
let bad = 0;
for (const [inp, want] of cases) {
  const r = spawnSync(EXE, [], { input: JSON.stringify(inp), env, encoding: "utf8" });
  const ok = r.status === want;
  if (!ok) bad++;
  console.log(`${ok ? "ok  " : "FAIL"} exit=${r.status} want=${want}  ${inp.tool_name} ${(inp.tool_input.command ?? inp.tool_input.file_path ?? inp.tool_input.path ?? "").slice(0, 70)}${inp.cwd === dev ? "  [cwd devpulse]" : ""}`);
  if (!ok && r.stderr) console.log(`       > ${r.stderr.trim().split("\n")[0]}`);
}
rmSync(root, { recursive: true, force: true });
console.log(`claude-guard: ${cases.length - bad} passed, ${bad} failed`);
process.exit(bad ? 1 : 0);
