// ev guard: block `ev` writes against customer environments. Only commands carrying
// --live are checked against ~/.evolx/ev-policy.json; everything else passes through
// unconditionally, because without --live ev cannot change an org (see "The write gate"
// below). Ported from EvolxCli tools/claude-hooks/block-ev-customer-writes.mjs.
//
// Design notes:
//   - The policy file lives outside this repo (~/.evolx/ev-policy.json) so
//     the user — not the agent — controls the allowlist. The agent can't tweak
//     it to re-allow itself.
//   - Fail-closed: any uncertainty (missing policy file, malformed JSON,
//     can't determine scope, unparsable hook input) blocks. Better a false
//     positive that asks the user than a quietly-allowed customer write.
//   - Only INTERCEPTS commands that invoke `ev`. Everything else returns right
//     after the bail-out, and only an `ev ... --live` clause that needs an ADO
//     scope starts a process (git) — the common path stays free of children.
//
// The tables below no longer decide WHETHER a command is checked — --live does
// that. They only map a verb to the policy section it is scoped against
// (dataverse vs ado). A --live command matching no entry is still denied; an
// out-of-date table now costs a clearer message, not a missed write.
//
// GEWOLLT, auch wenn es beim ersten Mal wie ein Fehler aussieht: Beispieltexte
// zaehlen mit. Wer eine Zeile schreibt, in der ein `ev`-Befehl nur als Beispiel
// vorkommt (Testfall-Liste, Doku-Schnipsel, echo), bekommt sie geblockt - der Hook
// kann Erwaehnung und Ausfuehrung nicht unterscheiden und entscheidet fail-closed.
// Solche Faelle gehoeren in eine Datei, die dann eingelesen wird.
//
// BEKANNTE GRENZE (2026-09-15): Geprueft wird die KOMMANDOZEILE. Ruft ein Skript
// `ev` auf (subprocess.run(["ev", ...]) in den Python-Deploy-Skripten der Projekte,
// PowerShell-Wrapper wie deploy-webresources.ps1, npm-Scripts), sieht der Hook nur
// `py skript.py` und laesst es durch - die Schreibzugriffe darin laufen UNGEPRUEFT.
// Der Schutz haengt fuer diesen Weg allein daran, dass es fuer Kunden-PROD kein
// ev-Profil gibt. Wer das schliessen will, braucht die Pruefung in ev selbst
// (Policy-Check im HttpGateway), nicht im Hook.
//
// Source of truth for ev's verb taxonomy: EvolxCli src/Evolx.Cli/Program.cs.
// Update WriteVerbsDv / WriteVerbsAdo when ev gains a new mutating verb.
//
// Whitespace is POSIX [[:space:]] (SP below) — the bash original's character class.
// \s would also take Unicode spaces, which changes what counts as a token boundary.

using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ClaudeGitGuard;

internal static partial class Program
{
    const string SP = @" \t\n\v\f\r";
    static readonly char[] SpChars = [' ', '\t', '\n', '\v', '\f', '\r'];

    // Each entry is the argv prefix after `ev` that maps to a policy section.
    //
    // No always-deny section for the explicitly destructive verbs (remove,
    // delete): we treat remove/delete on allowed envs as still allowed since
    // the user already gated it with --yes. Add one if it bites.
    static readonly string[] WriteVerbsDv =
    [
        "dv schema choice new",
        "dv schema choice update",
        "dv schema choice remove",
        "dv schema table new",
        "dv schema table update",
        "dv schema table remove",
        "dv schema column new",
        "dv schema column update",
        "dv schema column remove",
        "dv schema column copy",
        "dv schema many-to-many",
        "dv schema polymorphic-lookup",
        "dv schema publish",
        "dv create",
        "dv update",
        "dv delete",
        "dv batch",
        "dv role-new",
        "dv role-set-privilege",
        "dv table-access set",
        "dv user-role assign",
        "dv user-role unassign",
        "dv team-role assign",
        "dv team-role unassign",
        "dv team-member add",
        "dv team-member remove",
        "dv solution new",
        "dv solution import",
        "dv solution promote",
        "dv solution publish",
        "dv solution add-component",
        "dv solution remove-component",
        "dv webresource push",
        "dv webresource publish",
        "dv plugin sync",
        "dv view push",
        "dv form push",
        "dv sitemap push",
        "dv appmodule push",
        "dv appmodule remove",
        "dv appmodule add-component",
        "dv appmodule remove-component",
        "dv ribbon push",
        "dv button add",
        "dv button hide",
        "dv button unhide",
        "dv relationship hide",
        "dv relationship show",
        "dv language provision",
        "dv translations import",
        "dv translations set-label",
        // `pp connection` writes live in this list rather than a third section because they
        // resolve the same way: the target environment comes from the active profile, so
        // ResolveDvEnv answers "which customer am I about to write to" correctly for them.
        // A connection is customer state — creating one puts a credential into their
        // environment, deleting one breaks every flow bound to it.
        "pp connection new",
        "pp connection delete",
    ];

    static readonly string[] WriteVerbsAdo =
    [
        "ado pr create",
        "ado pr comment",
        "ado pr complete",
        "ado pr abandon",
        "ado pr vote",
        "ado wi create",
        "ado wi comment",
        "ado wi close",
        "ado wi link",
    ];

    static int EvBlock(string msg)
    {
        Console.Error.WriteLine(msg);
        return 2;
    }

    static int EvGuard(Hook h)
    {
        if (h.Command is null) return 0;
        string command = h.Command.TrimEnd('\n');

        // ---------------------------------------------------------- Fast bail-out
        // Only do work when the command actually invokes `ev`. This check MUST run on
        // the DECODED command, never on the raw JSON blob. The previous version grepped
        // the raw input and produced false NEGATIVES — which silently skip the entire
        // policy check rather than falling through to the slow path:
        //   1. The window `[^"]*` ends at the first escaped quote, so an `ev` further
        //      right in the command was never seen.
        //   2. A JSON-escaped newline is the two characters \ and n, so
        //      `...osisdev\nev dv create ...` reads as `nev` in the raw text and the
        //      `\b` in front of `ev` does not hold.
        // Both bit on 2026-09-12: a three-line command starting with
        // `export EVOLX_PROFILE=osisdev` walked straight past an otherwise correct
        // hook and created two systemuser rows in the OSIS DEV customer environment.
        // A guard that fails open is not a guard.
        // `(\.exe)?` and the quote: `ev.exe dv ...` and `"C:/.../ev.exe" dv ...` bailed here.
        if (!EvBailRe().IsMatch(command)) return 0;

        // Line continuations (bash `\`, PowerShell backtick) join before the newline split,
        // or a `--live` on the continuation line lands in a clause without ev and is never seen.
        string joined = command
            .Replace("\\\r\n", " ")
            .Replace("\\\n", " ")
            .Replace("`\r\n", " ")
            .Replace("`\n", " ");

        // Some commands chain multiple invocations with && / ; / |. Split on
        // those separators and inspect each clause independently. If ANY clause is
        // a blocked ev write, the whole command is blocked.
        string[] clauses = joined
            .Replace("&&", "\n")
            .Replace("||", "\n")
            .Replace(";", "\n")
            .Replace("|", "\n")
            .Split('\n');

        // ---------------------------------------------------------- Policy load
        // Loaded only after the bail-out, but before any clause is looked at: a command that
        // runs ev with no policy in place is blocked even when it carries no --live.
        string policyFile = Environment.GetEnvironmentVariable("EV_POLICY_FILE") is { Length: > 0 } pf
            ? pf : $"{Home}/.evolx/ev-policy.json";
        if (!File.Exists(policyFile))
            return EvBlock($"BLOCKED: ev policy file not found at {policyFile}. Copy tools/claude-hooks/policy.json from the EvolxCli repo and edit to your customer list.");

        // Validate the shape up front. We touch every section we'll read so a
        // malformed policy fails here, not deep inside the matcher. Same truthiness as
        // jq: only null and false are falsy — an empty list is a valid list.
        JsonDocument policyDoc;
        try
        {
            policyDoc = ParseJsonFile(policyFile);
            foreach (var section in new[] { "dataverse", "ado" })
                foreach (var key in new[] { "writes_allowed", "writes_denied", "default" })
                    if (IsNullOrFalse(Field(Field(policyDoc.RootElement, section), key))) throw new InvalidOperationException();
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or IOException or UnauthorizedAccessException)
        {
            return EvBlock($"BLOCKED: {policyFile} is malformed. Expected sections: dataverse{{writes_allowed,writes_denied,default}}, ado{{writes_allowed,writes_denied,default}}.");
        }
        using var _ = policyDoc;
        var policy = policyDoc.RootElement;

        // ---------------------------------------------------------- Main check
        // Walk every clause. Each clause is independent; one blocked clause blocks
        // the whole command (it might be the second action in `cmd1 && ev dv ...`).
        foreach (var raw in clauses)
        {
            string clause = raw.Trim(SpChars);
            if (clause.Length == 0) continue;

            // Strip leading env-var assignments (FOO=bar ev ...) and any prefix path
            // to expose ev's actual argv. Two cases to handle:
            //   1. Bare `ev` at the start of the clause:           ev dv schema ...
            //   2. ev preceded by a path or quote:    /usr/bin/ev dv schema ...
            //                                         "C:/.../ev.exe" dv schema ...
            // WARNUNG (Fix 2026-09-13): Bis hierher verlangte der Strip, dass `ev` am ANFANG
            // der Klausel steht. In einer Schleife steht davor aber noch ein Schluesselwort:
            //     for x in a b; do ev dv schema column update ... ; done
            // Die Klausel beginnt dann mit "do ev ...", der Strip griff nicht, die Klausel
            // wurde uebersprungen -- und der Schreibbefehl lief UNGEPRUEFT durch (am
            // 12.09.2026 an echten Kunden-Writes beobachtet). Jetzt wird alles VOR einem
            // `ev` als eigenem Wort mit weggeschnitten: nach Leerraum oder einem der
            // Trenner ; & | ( { -- also auch nach do/then/else. Fail-closed bleibt die
            // Regel: lieber eine Klausel zu viel pruefen als eine zu wenig.
            // (Bei mehreren ev-Aufrufen in EINER Klausel greift das letzte - `.*` ist
            // gierig; das war auch vorher schon so.)
            string evArgs = clause;
            foreach (var re in new[] { StripEnvRe(), StripPathEvRe(), StripQuotedEvRe(), StripWordEvRe(), StripBareEvRe() })
                evArgs = re.Replace(evArgs, "", 1);
            // If the strip changed nothing, this clause doesn't run ev at all
            // (someone merely mentioned `ev` in a comment or inside a filename).
            if (evArgs == clause) continue;

            // -------------------------------------------------------- The write gate
            // One question decides everything: did the user type --live?
            //
            // ev cannot change an org without it. Writing is opt-in, enforced centrally in
            // HttpGateway.SendCoreAsync via WriteGuard — underneath every command, at the single
            // point all HTTP passes through. A verb without --live is a dry run by construction,
            // not by remembering to ask.
            //
            // So this hook gates on the flag, not on the verb. That matters for two reasons:
            //
            //   1. It cannot drift. The verb table above listed 35 Dataverse verbs and was
            //      missing at least seven real writers (seed apply, pcf push, button add/hide,
            //      form disable-seeded, webresource delete, canvas import) — each one a write
            //      this hook waved through while blocking `--help`. Duplicating ev's taxonomy in
            //      the hook guaranteed that gap; asking ev's own safety flag closes it permanently.
            //
            //   2. It lets agents use ev offline. Every dry run, every --help, every plan and
            //      preview now passes untouched, which is the overwhelming majority of what an
            //      agent does. Only the one command that can actually reach a customer org stops
            //      here.
            //
            // Matched as a whole argv token, so a value that merely contains the text
            // (`--solution my-live-thing`) does not open the gate. A MISSPELT --live needs no
            // special case: Program.cs refuses those outright (exit 2, nothing sent), so anything
            // that isn't this exact token cannot write either.
            if (!$" {evArgs} ".Contains(" --live ", StringComparison.Ordinal)) continue;

            // Longest match wins so that "dv schema column copy" is matched before
            // "dv schema column".
            string matchedVerb = "", matchedSection = "";
            foreach (var (section, verbs) in new[] { ("dataverse", WriteVerbsDv), ("ado", WriteVerbsAdo) })
                foreach (var verb in verbs)
                    if ((evArgs.StartsWith(verb + " ", StringComparison.Ordinal) || evArgs == verb) && verb.Length > matchedVerb.Length)
                    {
                        matchedVerb = verb;
                        matchedSection = section;
                    }

            // --live but no matching verb. The table is now only used to pick which policy
            // section applies, and an unrecognised verb means we cannot tell — so fail closed
            // rather than assume. This is the branch that used to let seed apply, pcf push and
            // the rest through unchecked, back when a table miss meant "not a write".
            if (matchedVerb.Length == 0)
            {
                var f = evArgs.TrimStart(' ', '\t').Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
                matchedVerb = $"{(f.Length > 0 ? f[0] : "")} {(f.Length > 1 ? f[1] : "")} {(f.Length > 2 ? f[2] : "")}";
                matchedSection = evArgs.StartsWith("ado", StringComparison.Ordinal) ? "ado" : "dataverse";
            }

            string scope, scopeLabel;
            if (matchedSection == "dataverse")
            {
                scope = ResolveDvEnv(clause, command);
                scopeLabel = "Dataverse env";
            }
            else
            {
                scope = ResolveAdoScope(clause, h.Cwd);
                scopeLabel = "ADO org/project";
            }

            if (Decide(policy, matchedSection, scope) == "deny")
                return EvBlock($"""
                    BLOCKED: ev {matchedVerb} is a write verb against a non-allowed {scopeLabel}.
                      Scope:    {(scope.Length > 0 ? scope : "(could not resolve — fail-closed deny)")}
                      Verb:     ev {matchedVerb}
                      Policy:   {policyFile}

                    If this is legitimate, run the command yourself, or edit the policy file
                    to add this scope to {matchedSection}.writes_allowed.
                    """);
        }

        // No clause matched a blocked write, or every match resolved to allow.
        return 0;
    }

    // UTF-8, one leading BOM dropped — what Notepad-edited policy files carry.
    static JsonDocument ParseJsonFile(string p)
    {
        string text = new UTF8Encoding(false).GetString(File.ReadAllBytes(p));
        if (text.StartsWith('\uFEFF')) text = text[1..];
        return JsonDocument.Parse(text);
    }

    // jq's `.key`: null on null or a missing key, an error on anything that is not an object.
    // The last duplicate key wins, as in JSON.parse.
    static JsonElement? Field(JsonElement? o, string key)
    {
        if (o is not { } obj || obj.ValueKind == JsonValueKind.Null) return null;
        if (obj.ValueKind != JsonValueKind.Object) throw new InvalidOperationException($"cannot index {obj.ValueKind} with {key}");
        JsonElement? v = null;
        foreach (var p in obj.EnumerateObject())
            if (p.Name == key) v = p.Value;
        return v is { ValueKind: JsonValueKind.Null } ? null : v;
    }

    static bool IsNullOrFalse(JsonElement? v) => v is null || v.Value.ValueKind == JsonValueKind.False;

    // jq -r rendering of a value.
    static string Raw(JsonElement v) => v.ValueKind == JsonValueKind.String ? v.GetString()! : v.GetRawText();

    // Extract a flag value from a single clause: --env <value> or --env=<value>.
    // The LAST occurrence wins (greedy `.*`). Returns '' if not present.
    static string ExtractFlag(string clause, string flag)
    {
        var (space, eq) = flag == "--env" ? (EnvSpaceRe(), EnvEqRe()) : (ProfileSpaceRe(), ProfileEqRe());
        var m = space.Match(clause);
        if (m.Success) return m.Groups[1].Value;
        m = eq.Match(clause);
        return m.Success ? m.Groups[1].Value : "";
    }

    // Nachtrag 2026-09-15 (aus dem Gegentest einer zweiten Session): steckt der Befehl
    // in einer Zeichenkette - z.B. eine Testfall-Datei oder ein JSON-Body -, haengt am
    // extrahierten Wert noch deren Ende ("}}' o.ae.). Der Vergleich gegen die Policy ist
    // ein Stringvergleich: eine erlaubte Umgebung verfehlt ihren Eintrag und wird
    // geblockt (fail-closed, aber ein Fehlalarm), und in der Meldung steht ein
    // unleserlicher Scope. Deshalb werden Anfuehrungszeichen und Klammer-/Trennzeichen
    // am ENDE abgeschnitten - ein Hostname endet nie darauf, der Host selbst bleibt
    // unangetastet, PROD bleibt damit PROD.
    static string TrimJunk(string v)
    {
        // Anfuehrungszeichen fliegen ueberall raus (weder ein Hostname noch ein Profilname
        // enthaelt welche), Klammern und Trennzeichen nur am Ende.
        v = StripQuoteChars(v).TrimEnd(']', ')', '}', ',', ';', '\\');
        return v.EndsWith('/') ? v[..^1] : v;
    }

    static string StripQuoteChars(string v) => v.Replace("\"", "").Replace("'", "");

    // Return the Dataverse env URL the clause targets:
    //   --env <url> wins; else the active profile's envUrl. ev keys profiles by
    //   $EVOLX_PROFILE at ~/.evolx/profiles/<name>.json — there is no single
    //   profile.json. Fail-closed ('') if no profile is named or the file is
    //   missing/broken.
    //
    // Aufloesung des aktiven Profils GENAU wie in ev: `--profile <name>` aus dem
    // Befehl gewinnt, sonst $EVOLX_PROFILE.
    //
    // WARNUNG (Fix 2026-09-15, gleiche Klasse wie der ADO-Fix vom 13.09.): Bis hierher
    // las diese Funktion NUR $EVOLX_PROFILE aus der Umgebung des Hooks. Zwei ganz
    // normale Aufrufformen blieben damit ohne Scope und wurden fail-closed geblockt,
    // obwohl die Policy die Zielumgebung ausdruecklich erlaubt:
    //   ev dv webresource push ... --profile hueck
    //   export EVOLX_PROFILE=hueck; ev dv webresource push ...
    // (im zweiten Fall setzt der Befehl die Variable in SEINER Shell - der Hook laeuft
    // vorher und sieht sie nicht). `ev --env` gibt es nicht, der dokumentierte Ausweg
    // ging also ins Leere. Jetzt werden beide Formen gelesen; PROD bleibt unveraendert
    // gesperrt, weil die Policy den aufgeloesten Scope weiterhin entscheidet - der
    // Hook wird durch den Fix genauer, nicht schwaecher.
    static string ResolveDvEnv(string clause, string command)
    {
        string env = ExtractFlag(clause, "--env");
        if (env.Length > 0) return TrimJunk(env);

        string name = ExtractFlag(clause, "--profile");
        // `EVOLX_PROFILE=x ev ...` in derselben Klausel
        if (name.Length == 0)
        {
            var m = ProfileAssignInClauseRe().Match(clause);
            if (m.Success) name = m.Groups[1].Value;
        }
        // `export EVOLX_PROFILE=x; ev ...` - das Setzen steht in einer FRUEHEREN Klausel,
        // gilt aber fuer dieselbe Shell. Nur uebernehmen, wenn im ganzen Befehl genau EIN
        // Profil gesetzt wird: bei mehreren wechselnden Werten laesst sich ohne echte
        // Shell-Semantik nicht sagen, welches hier gilt -> leer lassen und fail-closed denyen.
        if (name.Length == 0)
        {
            var values = ProfileAssignRe().Matches(command).Select(m => StripQuoteChars(m.Groups[1].Value)).Distinct().ToList();
            var nonEmpty = values.Where(v => v.Length > 0).ToList();
            if (nonEmpty.Count == 1)
            {
                // `EVOLX_PROFILE=''` neben einem echten Wert ist ebenfalls ein Wechsel.
                if (values.Count > 1) return "";
                name = nonEmpty[0];
            }
        }
        if (name.Length == 0) name = Environment.GetEnvironmentVariable("EVOLX_PROFILE") ?? "";
        if (name.Length == 0) return "";
        name = TrimJunk(StripQuoteChars(name));
        string profile = $"{Home}/.evolx/profiles/{name}.json";
        if (!File.Exists(profile)) return "";
        JsonElement? envUrl;
        try
        {
            using var doc = ParseJsonFile(profile);
            envUrl = Field(doc.RootElement, "envUrl")?.Clone();
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or IOException or UnauthorizedAccessException)
        {
            return "";
        }
        if (IsNullOrFalse(envUrl)) return "";
        string url = Raw(envUrl!.Value);
        return url.EndsWith('/') ? url[..^1] : url;
    }

    // Return the ADO scope the clause targets, formatted "<org>/<project>".
    //
    // Aufloesung GENAU wie in ev (Services/AdoService.cs):
    //   Org     = adoOrg des aktiven Profils, sonst die Org des git-Remotes
    //   Projekt = Projekt des git-Remotes, sonst adoProject des Profils
    // Aktives Profil ist `--profile <name>` aus dem Befehl, sonst $EVOLX_PROFILE.
    //
    // WARNUNG (Fix 2026-09-13): Bis hierher las diese Funktion NUR das git-Remote.
    // Der Hook laeuft im Projektverzeichnis der Session, nicht in dem, in das ein
    // Befehl hineinwechselt -- arbeitet man ausserhalb eines ADO-Checkouts, blieb der
    // Scope leer und JEDER ADO-Schreibbefehl wurde fail-closed geblockt, obwohl ev
    // ueber das Profil sehr wohl weiss, wohin es schreibt. Ein Eintrag in
    // ado.writes_allowed konnte in dem Fall gar nicht greifen.
    //
    // The remote is read in the session's cwd from the hook input.
    //
    // Remote-URL-Formen:
    //   https://[user@]dev.azure.com/{org}/{project}/_git/{repo}
    //   https://{org}.visualstudio.com/[{collection}/]{project}/_git/{repo}
    // Fail-closed (''), wenn Org oder Projekt unbestimmt bleiben.
    static string ResolveAdoScope(string clause, string? cwd)
    {
        string remoteOrg = "", remoteProj = "", profOrg = "", profProj = "";

        // Not a repo / no origin: the remote just contributes nothing. No cwd in the
        // input: git -C "" stays in the hook's own directory.
        string url = Git(cwd ?? "", "remote", "get-url", "origin") ?? "";
        if (url.Length > 0)
        {
            Match m;
            if ((m = AdoRemoteRe().Match(url)).Success)
            {
                remoteOrg = m.Groups[1].Value;
                remoteProj = m.Groups[2].Value;
            }
            else if ((m = VsRemoteRe().Match(url)).Success)
            {
                remoteOrg = m.Groups[1].Value;
                // Project is the last path segment before _git (drop any collection prefix).
                string path = m.Groups[2].Value;
                remoteProj = path[(path.LastIndexOf('/') + 1)..];
            }
        }

        string name = ExtractFlag(clause, "--profile");
        if (name.Length == 0) name = Environment.GetEnvironmentVariable("EVOLX_PROFILE") ?? "";
        string profile = $"{Home}/.evolx/profiles/{name}.json";
        if (name.Length > 0 && File.Exists(profile))
        {
            try
            {
                using var doc = ParseJsonFile(profile);
                var o = Field(doc.RootElement, "adoOrg");
                var pr = Field(doc.RootElement, "adoProject");
                if (!IsNullOrFalse(o)) profOrg = Raw(o!.Value).Replace("\r", "");
                if (!IsNullOrFalse(pr)) profProj = Raw(pr!.Value).Replace("\r", "");
            }
            catch (Exception e) when (e is JsonException or InvalidOperationException or IOException or UnauthorizedAccessException)
            {
                // A broken profile contributes nothing; the remote alone may still resolve.
            }
        }

        string org = profOrg.Length > 0 ? profOrg : remoteOrg;
        string proj = remoteProj.Length > 0 ? remoteProj : profProj;
        if (org.Length == 0 || proj.Length == 0) return "";
        return $"{org}/{proj}";
    }

    // Bash [[ value == pattern ]] glob: * ? [...] and backslash escapes; * crosses '/'.
    static Regex GlobToRegex(string pattern)
    {
        var re = new StringBuilder();
        for (int i = 0; i < pattern.Length; i++)
        {
            char c = pattern[i];
            if (c == '*') re.Append(@"[\s\S]*");
            else if (c == '?') re.Append(@"[\s\S]");
            else if (c == '\\' && i + 1 < pattern.Length) re.Append(Regex.Escape(pattern[++i].ToString()));
            else if (c == '[')
            {
                int end = i + 2 <= pattern.Length ? pattern.IndexOf(']', i + 2) : -1;
                if (end == -1)
                {
                    re.Append(@"\[");
                    continue;
                }
                string body = pattern[(i + 1)..end];
                bool negate = body.Length > 0 && body[0] is '!' or '^';
                if (negate) body = body[1..];
                // '[' is escaped too: in .NET, "-[" inside a class is class subtraction.
                string cls = Regex.Replace(body, @"[\\\]\^\[]", @"\$0");
                // JS reads [] as "nothing" and [^] as "anything"; .NET cannot parse either.
                re.Append(cls.Length > 0 ? $"[{(negate ? "^" : "")}{cls}]" : negate ? @"[\s\S]" : "(?!)");
                i = end;
            }
            else re.Append(Regex.Escape(c.ToString()));
        }
        return new Regex($"^{re}\\z", RegexOptions.CultureInvariant);
    }

    // Match a value against a policy list. Pattern shapes:
    //   *.foo.com         — suffix glob (anything ending in .foo.com)
    //   https://org*.x    — general glob
    //   evolit-internal   — org-only ADO entry (matches "evolit-internal/<any-project>")
    //   exact-string      — strict equality
    //
    // \r is stripped from patterns because policy files edited on Windows commonly
    // arrive with CRLF endings. A trailing \r breaks equality silently — the script
    // would happily block "foo.com\r" while the user thinks they allowed "foo.com".
    static bool MatchInArray(string value, JsonElement? list)
    {
        IEnumerable<JsonElement> items = list switch
        {
            { ValueKind: JsonValueKind.Array } a => a.EnumerateArray(),
            { ValueKind: JsonValueKind.Object } o => o.EnumerateObject().Select(p => p.Value),
            _ => [],
        };
        foreach (var raw in string.Join("\n", items.Select(Raw)).Split('\n'))
        {
            string pattern = raw.Replace("\r", "");
            if (pattern.Length == 0) continue;
            if (pattern.StartsWith("*.", StringComparison.Ordinal))
            {
                if (value.EndsWith(pattern[1..], StringComparison.Ordinal)) return true;
            }
            else if (pattern.Contains('*'))
            {
                // General glob (e.g. https://org*.crm4.dynamics.com — the scratch-org
                // wildcard the policy has carried since 2026-08-11; before this branch
                // existed it silently never matched). Same semantics as ev's EvPolicy.
                if (GlobToRegex(pattern).IsMatch(value)) return true;
            }
            else if (!pattern.Contains('/') && value.Contains('/'))
            {
                // ADO entry that names only the org. Match any project under it:
                // pattern "evolit-internal" matches value "evolit-internal/X".
                if (value.StartsWith(pattern + "/", StringComparison.Ordinal)) return true;
            }
            else if (value == pattern) return true;
        }
        return false;
    }

    // Given (section, scope), decide allow|deny per the policy. Fail-closed: '' scope → deny.
    static string Decide(JsonElement policy, string section, string scope)
    {
        if (scope.Length == 0) return "deny";
        var s = Field(policy, section);
        if (MatchInArray(scope, Field(s, "writes_denied"))) return "deny";
        if (MatchInArray(scope, Field(s, "writes_allowed"))) return "allow";
        return Raw(Field(s, "default")!.Value).Replace("\r", "");
    }

    [GeneratedRegex($@"(^|[^A-Za-z0-9_])ev(\.exe)?([{SP}""']|$|(?=[\u2028\u2029]))", RegexOptions.Multiline)]
    private static partial Regex EvBailRe();

    [GeneratedRegex($@"^.*--env[{SP}]+([^{SP};|&]+)", RegexOptions.Singleline)]
    private static partial Regex EnvSpaceRe();

    [GeneratedRegex($@"^.*--env=([^{SP};|&]+)", RegexOptions.Singleline)]
    private static partial Regex EnvEqRe();

    [GeneratedRegex($@"^.*--profile[{SP}]+([^{SP};|&]+)", RegexOptions.Singleline)]
    private static partial Regex ProfileSpaceRe();

    [GeneratedRegex($@"^.*--profile=([^{SP};|&]+)", RegexOptions.Singleline)]
    private static partial Regex ProfileEqRe();

    [GeneratedRegex($@"^.*EVOLX_PROFILE=([^{SP};|&]+)", RegexOptions.Singleline)]
    private static partial Regex ProfileAssignInClauseRe();

    [GeneratedRegex($@"EVOLX_PROFILE=([^{SP};|&]+)")]
    private static partial Regex ProfileAssignRe();

    [GeneratedRegex($@"^([A-Z_][A-Z0-9_]*=[^{SP}]+[{SP}]+)+")]
    private static partial Regex StripEnvRe();

    [GeneratedRegex($@"^.*[{SP};&|({{][^{SP};&|({{]*[/""]ev(\.exe)?[""']?[{SP}]+", RegexOptions.Singleline)]
    private static partial Regex StripPathEvRe();

    [GeneratedRegex($@"^.*[/""]ev(\.exe)?[""']?[{SP}]+", RegexOptions.Singleline)]
    private static partial Regex StripQuotedEvRe();

    [GeneratedRegex($@"^.*[{SP};&|({{]ev(\.exe)?[{SP}]+", RegexOptions.Singleline)]
    private static partial Regex StripWordEvRe();

    [GeneratedRegex($@"^ev(\.exe)?[{SP}]+")]
    private static partial Regex StripBareEvRe();

    [GeneratedRegex(@"dev\.azure\.com/([^/]+)/([^/]+)/_git/")]
    private static partial Regex AdoRemoteRe();

    [GeneratedRegex(@"://([^./]+)\.visualstudio\.com/(.+)/_git/")]
    private static partial Regex VsRemoteRe();
}
