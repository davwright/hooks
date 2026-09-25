<#
.SYNOPSIS
    Install the two-layer git-write guard.

.DESCRIPTION
    Deploys:
      1. The canonical judge  -> $HOME\.githooks\git-guard.sh
      2. The git template     -> $HOME\.git-template\hooks\{pre-commit,commit-msg,pre-push}  (thin stubs)
                                 + sets git config --global init.templateDir
         so every future `git init` / `git clone` is armed automatically.
      3. The thin Claude hook -> ~\.claude\hooks\claude-git-guard.{exe|sh}
                                 + registers it in ~\.claude\settings.json under
                                 PreToolUse for Bash, PowerShell and Edit/Write/MultiEdit/NotebookEdit, REPLACING any older entry
                                 (block-git-write.sh / the other impl) — no
                                 protection gap, no duplicate.

    The Claude hook fires on EVERY Bash tool call, so by default this installs
    the fast NativeAOT C# build (csharp\). If it isn't built and can't be built
    (no .NET SDK / MSVC), it falls back to the bash hook automatically.

    Idempotent: re-running overwrites scripts in place and de-dupes the settings entry.

.PARAMETER HookImpl
    Which Claude-hook implementation to deploy: 'auto' (default — native if
    available/buildable, else bash), 'native' (force the C# exe; build it if
    missing), or 'bash' (force the shell script).

.PARAMETER ClaudeHome
    Override the Claude Code config dir. Defaults to $env:USERPROFILE\.claude.

.PARAMETER WhatIf
    Preview without writing.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('auto', 'native', 'bash')]
    [string]$HookImpl = 'auto',
    [string]$ClaudeHome = (Join-Path $env:USERPROFILE '.claude')
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Home_     = $env:USERPROFILE

function Copy-Exec {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '')]
    param($src, $dst)
    if (-not (Test-Path $src)) { throw "Source not found: $src" }
    $dir = Split-Path -Parent $dst
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ($PSCmdlet.ShouldProcess($dst, 'Deploy')) {
        Copy-Item -LiteralPath $src -Destination $dst -Force
        Write-Host "  -> $dst" -ForegroundColor Green
    }
}

# 1. Canonical judge.
Write-Host 'Canonical judge:' -ForegroundColor Cyan
$CanonDst = Join-Path $Home_ '.githooks\git-guard.sh'
Copy-Exec (Join-Path $ScriptDir 'src\git-guard.sh') $CanonDst

# 2. Git template + init.templateDir.
Write-Host 'Git template (arms every future init/clone):' -ForegroundColor Cyan
$TmplHooks = Join-Path $Home_ '.git-template\hooks'
foreach ($h in @('pre-commit', 'commit-msg', 'pre-push')) {
    Copy-Exec (Join-Path $ScriptDir "templates\hooks\$h") (Join-Path $TmplHooks $h)
}
$TmplDir = (Join-Path $Home_ '.git-template') -replace '\\', '/'
$curTmpl = (& git config --global init.templateDir) 2>$null
if ($curTmpl -eq $TmplDir) {
    Write-Host "  init.templateDir already = $TmplDir" -ForegroundColor DarkGray
} elseif ($PSCmdlet.ShouldProcess('git config --global init.templateDir', "set to $TmplDir")) {
    & git config --global init.templateDir $TmplDir
    Write-Host "  set init.templateDir = $TmplDir" -ForegroundColor Green
    if ($curTmpl) { Write-Host "  (was: $curTmpl)" -ForegroundColor Yellow }
}

# 3. Decide which Claude-hook implementation to deploy.
#    The exe is the hot path; prefer it, but degrade gracefully to bash.
$ExeSrc = Join-Path $ScriptDir 'csharp\bin\Release\net9.0\win-x64\publish\claude-git-guard.exe'

function Invoke-NativeHookBuild {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '')]
    param()
    $proj = Join-Path $ScriptDir 'csharp'
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        Write-Host '  dotnet SDK not found — cannot build native hook.' -ForegroundColor Yellow
        return $false
    }
    # NativeAOT links via MSVC; its target shells out to vswhere.exe, which is
    # often not on PATH. Add the standard installer dir so the link step works.
    $vswhereDir = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer'
    if ((Test-Path (Join-Path $vswhereDir 'vswhere.exe')) -and ($env:PATH -notlike "*$vswhereDir*")) {
        $env:PATH = "$env:PATH;$vswhereDir"
    }
    Write-Host '  building native hook (dotnet publish, first run is slow)...' -ForegroundColor DarkGray
    if ($PSCmdlet.ShouldProcess($proj, 'dotnet publish -r win-x64 -c Release')) {
        Push-Location $proj
        try { & dotnet publish -r win-x64 -c Release | Out-Null }
        finally { Pop-Location }
    }
    return (Test-Path $ExeSrc)
}

$useNative = $false
switch ($HookImpl) {
    'bash'   { $useNative = $false }
    'native' { $useNative = (Test-Path $ExeSrc) -or (Invoke-NativeHookBuild) ; if (-not $useNative) { throw 'HookImpl=native requested but the exe is not built and could not be built.' } }
    'auto'   { $useNative = (Test-Path $ExeSrc) -or (Invoke-NativeHookBuild) }
}

Write-Host 'Thin Claude PreToolUse hook:' -ForegroundColor Cyan
if ($useNative) {
    $HookDst = Join-Path $ClaudeHome 'hooks\claude-git-guard.exe'
    Copy-Exec $ExeSrc $HookDst
    $NewCmd  = '~/.claude/hooks/claude-git-guard.exe'
    Write-Host '  (native NativeAOT build -- the fast hot-path hook)' -ForegroundColor DarkGray
} else {
    $HookDst = Join-Path $ClaudeHome 'hooks\claude-git-guard.sh'
    Copy-Exec (Join-Path $ScriptDir 'src\claude-git-guard.sh') $HookDst
    $NewCmd  = '~/.claude/hooks/claude-git-guard.sh'
    Write-Host '  (bash build -- install the .NET SDK + re-run for the faster native hook)' -ForegroundColor DarkGray
}

# Older / sibling commands to strip so only ONE git-guard entry remains.
$claudeFwd = ($ClaudeHome -replace '\\', '/') + '/hooks'
$OldCmds = @(
    '~/.claude/hooks/block-git-write.sh',
    ('bash "{0}/block-git-write.sh"' -f $claudeFwd),
    '~/.claude/hooks/claude-git-guard.sh',
    '~/.claude/hooks/claude-git-guard.exe'
) | Where-Object { $_ -ne $NewCmd }

$SettingsPath = Join-Path $ClaudeHome 'settings.json'
if (-not (Test-Path $SettingsPath)) { throw "settings.json not found at $SettingsPath" }
$settings = (Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8) | ConvertFrom-Json

if (-not ($settings.PSObject.Properties.Name -contains 'hooks')) {
    Add-Member -InputObject $settings -MemberType NoteProperty -Name 'hooks' -Value ([pscustomobject]@{}) -Force
}
if (-not ($settings.hooks.PSObject.Properties.Name -contains 'PreToolUse')) {
    Add-Member -InputObject $settings.hooks -MemberType NoteProperty -Name 'PreToolUse' -Value @() -Force
}
# The guard judges shell commands (Bash, PowerShell) and file edits (the
# read-only-mirror rule). Strip every git-guard command from EVERY entry —
# other matchers may already list it — then register it once, in its own
# entry. Every other hook is preserved; an entry left empty is dropped.
$Matcher = 'Bash|PowerShell|Edit|Write|MultiEdit|NotebookEdit'
$GuardCmds = @($OldCmds) + $NewCmd
$preList = @()
foreach ($e in @($settings.hooks.PreToolUse)) {
    $kept = @($e.hooks | Where-Object { $GuardCmds -notcontains $_.command })
    if ($kept.Count -eq 0) { continue }
    $e.hooks = $kept
    $preList += $e
}
$preList += [pscustomobject]@{ matcher = $Matcher; hooks = @([pscustomobject]@{ type = 'command'; command = $NewCmd; timeout = 10 }) }
$settings.hooks.PreToolUse = $preList

if ($PSCmdlet.ShouldProcess($SettingsPath, "Register $NewCmd in PreToolUse:$Matcher")) {
    $json = $settings | ConvertTo-Json -Depth 20
    # No BOM: Set-Content -Encoding UTF8 in PowerShell 5.1 writes one.
    [IO.File]::WriteAllText($SettingsPath, $json, (New-Object Text.UTF8Encoding $false))
    Write-Host "  registered $NewCmd for $Matcher (removed any older git-guard entry)" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan
Write-Host 'Whitelist lives in:' -NoNewline; Write-Host "  $CanonDst" -ForegroundColor Yellow
Write-Host 'Restart open Claude Code sessions to pick up the new PreToolUse hook.'
