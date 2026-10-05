// ev customer-write guard (EvGuard.cs) in claude-git-guard.exe: a throwaway policy, profiles and git
// repos, then each case is fed to the exe (spawned directly, no shell) and must exit 0 (allow) or 2 (block).
// Usage: node tests/ev-guard.test.mjs   (GUARD_CMD=<exe> for another build)
//
// Intentionally a smoke test, not exhaustive. The verb tables are hand-maintained against ev's
// Program.cs; whenever ev grows a new write verb, add a case here too so the guard stays honest.
import { spawnSync, execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const EXE = process.env.GUARD_CMD ?? new URL("../csharp/bin/Release/net9.0/win-x64/publish/claude-git-guard.exe", import.meta.url).pathname.slice(1);
const root = mkdtempSync(join(tmpdir(), "ev-hook-test-"));
const home = join(root, "home");
const policy = join(root, "ev-policy.json");

// Test policy. Anything not explicitly listed defaults to deny.
writeFileSync(policy, JSON.stringify({
  dataverse: {
    writes_allowed: ["https://allowed.crm4.dynamics.com", "*.internal.crm4.dynamics.com"],
    writes_denied: ["*.customer.crm4.dynamics.com"],
    default: "deny",
  },
  ado: { writes_allowed: ["internal-org", "evolx/OurProject"], writes_denied: ["evolx/CustomerProject"], default: "deny" },
}));

// Profiles under a throwaway HOME so the guard doesn't latch onto the real user's binding.
// ev keys profiles by $EVOLX_PROFILE (bzw. --profile) unter profiles/<name>.json.
mkdirSync(join(home, ".evolx", "profiles"), { recursive: true });
writeFileSync(join(home, ".evolx", "profiles", "allowedprofile.json"),
  JSON.stringify({ envUrl: "https://allowed.crm4.dynamics.com", adoOrg: "internal-org" }));
writeFileSync(join(home, ".evolx", "profiles", "customerprofile.json"),
  JSON.stringify({ envUrl: "https://prod.customer.crm4.dynamics.com", adoOrg: "evolx", adoProject: "CustomerProject" }));

// ADO scope is resolved from the git 'origin' remote of the hook input's cwd, so the ADO cases run
// from inside throwaway repos with fake remotes. The exe is NOT started in that cwd, so a case
// proves it reads the input's cwd.
const repo = (name, remote) => {
  const dir = join(root, name);
  mkdirSync(dir);
  execFileSync("git", ["-C", dir, "init", "-q"]);
  execFileSync("git", ["-C", dir, "remote", "add", "origin", remote]);
  return dir;
};
const ALLOWED = repo("allowed", "https://evolx@dev.azure.com/evolx/OurProject/_git/r");
const DENIED = repo("denied", "https://evolx@dev.azure.com/evolx/CustomerProject/_git/r");
const GITHUB = repo("github", "https://github.com/davwright/EvolxCli.git");

const CUST = "--env https://prod.customer.crm4.dynamics.com";
const OK = "--env https://allowed.crm4.dynamics.com";
const cases = [
  // Read verbs always pass
  ["whoami read", "allow", "ev dv whoami"],
  ["query read", "allow", "ev dv query systemusers --top 5"],
  ["tables read", "allow", "ev dv tables"],
  ["WI list read", "allow", "ev ado wi list", DENIED],
  ["canvas pack (local)", "allow", "ev canvas pack ./mydir"],
  ["solution diff (local)", "allow", "ev dv solution diff a.zip b.zip"],
  ["non-ev command", "allow", "git status"],

  // Dataverse writes
  ["schema write allowed (exact)", "allow", `ev dv schema table new evo_test ${OK} --live`],
  ["schema write allowed (glob)", "allow", "ev dv schema table new evo_test --env https://foo.internal.crm4.dynamics.com --live"],
  ["schema write customer (glob)", "block", `ev dv schema table new evo_test ${CUST} --live`],
  ["solution promote customer", "block", `ev dv solution promote HueckFolien ${CUST} --live`],
  ["solution promote allowed", "allow", `ev dv solution promote Foo ${OK} --live`],
  ["schema write default-deny", "block", "ev dv schema table new evo_test --env https://unknown.crm4.dynamics.com --live"],
  ["schema column remove customer", "block", "ev dv schema column remove t c --env https://x.customer.crm4.dynamics.com --yes --live"],
  ["data create customer", "block", `ev dv create accounts --json '{}' ${CUST} --live`],
  ["role-new customer", "block", `ev dv role-new --name X ${CUST} --live`],
  ["webresource push customer", "block", `ev dv webresource push foo.js ./foo.js ${CUST} --live`],
  ["customer write without --live", "allow", `ev dv create accounts --json x ${CUST}`],
  ["appmodule remove-component customer", "block", `ev dv appmodule remove-component app --view x ${CUST} --live`],
  ["appmodule remove-component allowed", "allow", `ev dv appmodule remove-component app --view x ${OK} --live`],

  // ADO writes — scope comes from the cwd's git origin remote.
  ["PR create our project", "allow", "ev ado pr create --source x --title y --live", ALLOWED],
  ["PR create customer", "block", "ev ado pr create --source x --title y --live", DENIED],
  ["PR complete customer", "block", "ev ado pr complete 1 --merge-strategy squash --live", DENIED],
  ["PR complete our project", "allow", "ev ado pr complete 1 --live", ALLOWED],
  ["PR abandon customer", "block", "ev ado pr abandon 1 --live", DENIED],
  ["WI create customer", "block", "ev ado wi create --title hi --live", DENIED],
  ["PR comment customer", "block", "ev ado pr comment 1 hi --live", DENIED],
  ["PR create non-ADO → deny", "block", "ev ado pr create --source x --title y --live", GITHUB],

  // Chained: ANY blocked clause blocks the whole command
  ["chained read+write", "block", `ev dv whoami && ev dv schema table remove x --yes ${CUST} --live`],
  ["chained two reads", "allow", "ev dv whoami && ev dv tables"],

  // Fix 2026-09-13: `ev` mitten in einer Klausel (Schleife, if-Block) darf nicht durchrutschen.
  ["ev in for-Schleife (Kunde)", "block", `for t in a b; do ev dv schema column update t c ${CUST} --live; done`],
  ["ev nach then (Kunde)", "block", `if true; then ev dv create accounts --json x ${CUST} --live; fi`],
  ["ev in Schleife (erlaubt)", "allow", `for t in a b; do ev dv schema column update t c ${OK} --live; done`],
  ["ev nur im Dateinamen", "allow", "cat /tmp/preview.txt"],
  ["ev im Kommentartext", "allow", "echo bitte ev dv nicht verwechseln"],

  // Fix 2026-09-15: --profile und export EVOLX_PROFILE werden gelesen.
  ["--profile erlaubt", "allow", "ev dv webresource push a.js ./a.js --profile allowedprofile --live"],
  ["--profile Kunde", "block", "ev dv webresource push a.js ./a.js --profile customerprofile --live"],
  ["export-Profil erlaubt", "allow", "export EVOLX_PROFILE=allowedprofile; ev dv webresource push a.js ./a.js --live"],
  ["export-Profil Kunde", "block", "export EVOLX_PROFILE=customerprofile; ev dv webresource push a.js ./a.js --live"],
  ["Profil-Praefix erlaubt", "allow", "EVOLX_PROFILE=allowedprofile ev dv webresource publish a.js --live"],
  // Wechselt der Befehl das Profil, laesst sich nicht sagen, welches gilt -> fail-closed.
  ["zwei Profile im Befehl", "block", "export EVOLX_PROFILE=allowedprofile; ev dv webresource publish a.js --live; export EVOLX_PROFILE=customerprofile; ev dv webresource publish b.js --live"],
  ["--env schlaegt Profil", "block", `export EVOLX_PROFILE=allowedprofile; ev dv create accounts --json x ${CUST} --live`],
  // Steckt der Befehl in einer Zeichenkette, haengt deren Ende am Wert; PROD bleibt PROD.
  ["--env mit JSON-Rest", "allow", 'ev dv create accounts --json x --live --env https://allowed.crm4.dynamics.com"}}'],
  ["--env Kunde mit JSON-Rest", "block", 'ev dv create accounts --json x --live --env https://prod.customer.crm4.dynamics.com"}}'],
  ["Profil mit JSON-Rest", "allow", 'ev dv webresource publish a.js --live --profile allowedprofile"}}'],

  // Line continuations join before the clause split, so a --live on the next line is still seen.
  ["--live after bash continuation", "block", `ev dv create accounts --json x ${CUST} \\\n  --live`],
  ["--live after PowerShell backtick", "block", `ev dv create accounts --json x ${CUST} \`\r\n  --live`],
  ["ev.exe with quoted path", "block", `"C:/Users/x/.local/bin/ev.exe" dv create accounts --json x ${CUST} --live`],
];

const env = { ...process.env, EV_POLICY_FILE: policy, HOME: home, USERPROFILE: home };
delete env.EVOLX_PROFILE;   // an inherited profile would skew the cases
const run = (input, e = env) => spawnSync(EXE, [], { input, env: e, encoding: "utf8" });
let pass = 0, fail = 0;
for (const [label, expect, command, cwd = process.cwd()] of cases) {
  const r = run(JSON.stringify({ tool_input: { command }, cwd }));
  const ok = (expect === "allow" && r.status === 0) || (expect === "block" && r.status === 2);
  if (ok) { pass++; console.log(`PASS  [${label}]`); continue; }
  fail++;
  console.log(`FAIL  [${label}]  expected=${expect}  got exit=${r.status}\n       cmd: ${command}`);
  console.log(r.stderr.split("\n").slice(0, 5).map(l => "       > " + l).join("\n"));
}
// Fail closed: without a readable policy a --live write is blocked; commands without ev never need one.
writeFileSync(join(root, "broken.json"), "{ not json");
for (const [label, expect, command, file] of [
  ["missing policy blocks --live", "block", `ev dv create accounts --json x ${OK} --live`, join(root, "nope.json")],
  ["malformed policy blocks --live", "block", `ev dv create accounts --json x ${OK} --live`, join(root, "broken.json")],
  ["missing policy, non-ev command", "allow", "git status", join(root, "nope.json")],
]) {
  const r = run(JSON.stringify({ tool_input: { command }, cwd: process.cwd() }), { ...env, EV_POLICY_FILE: file });
  const ok = (expect === "allow" && r.status === 0) || (expect === "block" && r.status === 2);
  ok ? pass++ : fail++;
  console.log(`${ok ? "PASS" : "FAIL"}  [${label}]${ok ? "" : `  got exit=${r.status}`}`);
}
const garbled = run("not json");
garbled.status === 2 ? pass++ : fail++;
console.log(`${garbled.status === 2 ? "PASS" : "FAIL"}  [unparsable hook input blocks]`);
rmSync(root, { recursive: true, force: true });
console.log(`ev-guard: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
