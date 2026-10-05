// Process budget for the git hook stubs: git for Windows runs each hook through sh, and every extra
// process costs a second or more here (the bash judge forked ~25 per hook: 118s per commit).
// A stub may only use shell builtins and end in one exec of git-guard.exe.
// Usage: node tests/stubs.test.mjs
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const dir = new URL("../templates/hooks/", import.meta.url).pathname.slice(1);
let bad = 0;
for (const name of readdirSync(dir)) {
  const code = readFileSync(join(dir, name), "utf8").split(/\r?\n/).map(l => l.trim()).filter(l => l && !l.startsWith("#"));
  const problems = [];
  if (code.some(l => /\$\(|`/.test(l))) problems.push("command substitution forks a process");
  if (code.some(l => /(^|[^|])\|([^|]|$)/.test(l))) problems.push("pipe forks a process");
  const execs = code.filter(l => l.startsWith("exec "));
  if (execs.length !== 1 || code.at(-1) !== execs[0]) problems.push("must end in exactly one exec");
  if (!/git-guard\.exe/.test(code.join("\n"))) problems.push("exec must target git-guard.exe");
  // Anything else must be a builtin: assignment, [ test ] || { echo ...; exit N; }
  for (const l of code.slice(0, -1))
    if (!/^[A-Za-z_][A-Za-z0-9_]*=/.test(l) && !/^\[ .* \] \|\| \{ echo .*; exit \d+; \}$/.test(l)) problems.push(`not a builtin: ${l}`);
  if (problems.length) bad++;
  console.log(`${problems.length ? "FAIL" : "ok  "} ${name}${problems.length ? ": " + problems.join("; ") : ""}`);
}
console.log(bad ? `${bad} failed` : "all passed");
process.exit(bad ? 1 : 0);
