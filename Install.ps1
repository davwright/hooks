<#
.SYNOPSIS
    Install the two-layer git-write guard.

.DESCRIPTION
    Builds csharp\ (NativeAOT, one exe for both layers) and deploys:
      1. The git-side judge  -> $HOME\.githooks\git-guard.exe
                                + git-guard.sh, a shim that keeps repos armed
                                before v3 working until their stubs self-update
      2. The git template    -> $HOME\.git-template\hooks\{pre-commit,commit-msg,pre-push}
                                (one-line stubs that exec the judge)
                                + sets git config --global init.templateDir
         so every future `git init` / `git clone` is armed automatically.
      3. The Claude hook     -> ~\.claude\hooks\claude-git-guard.exe
                                + registers it in ~\.claude\settings.json under
                                PreToolUse for Bash, PowerShell and Edit/Write/MultiEdit/NotebookEdit,
                                in exec form (args present = no shell), REPLACING
                                any older git-guard entry.

    No shell versions: a hook run through bash costs seconds per call on this
    machine. If the exe cannot be built, the install fails.

    Idempotent: re-running overwrites in place and de-dupes the settings entry.

.PARAMETER ClaudeHome
    Override the Claude Code config dir. Defaults to $env:USERPROFILE\.claude.

.PARAMETER WhatIf
    Preview without writing.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ClaudeHome = (Join-Path $env:USERPROFILE '.claude')
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Home_     = $env:USERPROFILE

# A running exe cannot be overwritten, but it can be renamed: move it aside so
# a hook call in flight does not fail the install.
function Copy-Exec {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '')]
    param($src, $dst)
    if (-not (Test-Path $src)) { throw "Source not found: $src" }
    $dir = Split-Path -Parent $dst
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ($PSCmdlet.ShouldProcess($dst, 'Deploy')) {
        if ($dst -like '*.exe' -and (Test-Path $dst)) {
            $old = "$dst.old"
            if (Test-Path $old) { Remove-Item -LiteralPath $old -Force }
            Move-Item -LiteralPath $dst -Destination $old
        }
        Copy-Item -LiteralPath $src -Destination $dst -Force
        Write-Host "  -> $dst" -ForegroundColor Green
    }
}

# 0. Build. NativeAOT links via MSVC; its target shells out to vswhere.exe,
#    which is often not on PATH.
Write-Host 'Build:' -ForegroundColor Cyan
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw 'dotnet SDK not found - it is required to build the guard (plus the VS C++ build tools for NativeAOT).' }
$vswhereDir = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer'
if ((Test-Path (Join-Path $vswhereDir 'vswhere.exe')) -and ($env:PATH -notlike "*$vswhereDir*")) {
    $env:PATH = "$env:PATH;$vswhereDir"
}
$ExeSrc = Join-Path $ScriptDir 'csharp\bin\Release\net9.0\win-x64\publish\claude-git-guard.exe'
if ($PSCmdlet.ShouldProcess((Join-Path $ScriptDir 'csharp'), 'dotnet publish -r win-x64 -c Release')) {
    & dotnet publish (Join-Path $ScriptDir 'csharp') -r win-x64 -c Release | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed (exit $LASTEXITCODE)." }
    if (-not (Test-Path $ExeSrc)) { throw "dotnet publish succeeded but $ExeSrc is missing." }
}

# 1. Git-side judge.
Write-Host 'Git-side judge:' -ForegroundColor Cyan
$JudgeDst = Join-Path $Home_ '.githooks\git-guard.exe'
Copy-Exec $ExeSrc $JudgeDst
Copy-Exec (Join-Path $ScriptDir 'src\git-guard.sh') (Join-Path $Home_ '.githooks\git-guard.sh')

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

# 3. Claude PreToolUse hook, exec form: an absolute path and an args array, so
#    Claude Code starts the exe directly instead of through a shell.
Write-Host 'Claude PreToolUse hook:' -ForegroundColor Cyan
$HookDst = Join-Path $ClaudeHome 'hooks\claude-git-guard.exe'
Copy-Exec $ExeSrc $HookDst
$NewCmd = $HookDst -replace '\\', '/'

# Older commands to strip so only ONE git-guard entry remains.
$claudeFwd = ($ClaudeHome -replace '\\', '/') + '/hooks'
$GuardCmds = @(
    '~/.claude/hooks/block-git-write.sh',
    ('bash "{0}/block-git-write.sh"' -f $claudeFwd),
    '~/.claude/hooks/claude-git-guard.sh',
    '~/.claude/hooks/claude-git-guard.exe',
    $NewCmd
)

$SettingsPath = Join-Path $ClaudeHome 'settings.json'
if (-not (Test-Path $SettingsPath)) { throw "settings.json not found at $SettingsPath" }
$settings = (Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8) | ConvertFrom-Json

if (-not ($settings.PSObject.Properties.Name -contains 'hooks')) {
    Add-Member -InputObject $settings -MemberType NoteProperty -Name 'hooks' -Value ([pscustomobject]@{}) -Force
}
if (-not ($settings.hooks.PSObject.Properties.Name -contains 'PreToolUse')) {
    Add-Member -InputObject $settings.hooks -MemberType NoteProperty -Name 'PreToolUse' -Value @() -Force
}
# Strip every git-guard command from EVERY entry - other matchers may already
# list it - then register it once, in its own entry. Every other hook is
# preserved; an entry left empty is dropped.
$Matcher = 'Bash|PowerShell|Edit|Write|MultiEdit|NotebookEdit'
$preList = @()
foreach ($e in @($settings.hooks.PreToolUse)) {
    $kept = @($e.hooks | Where-Object { $GuardCmds -notcontains $_.command })
    if ($kept.Count -eq 0) { continue }
    $e.hooks = $kept
    $preList += $e
}
$hook = [pscustomobject][ordered]@{ type = 'command'; command = $NewCmd; args = @(); timeout = 10 }
$preList += [pscustomobject]@{ matcher = $Matcher; hooks = @($hook) }
$settings.hooks.PreToolUse = $preList

if ($PSCmdlet.ShouldProcess($SettingsPath, "Register $NewCmd in PreToolUse:$Matcher")) {
    $json = $settings | ConvertTo-Json -Depth 20
    # No BOM: Set-Content -Encoding UTF8 in PowerShell 5.1 writes one.
    [IO.File]::WriteAllText($SettingsPath, $json, (New-Object Text.UTF8Encoding $false))
    Write-Host "  registered $NewCmd (exec form) for $Matcher" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Done. Restart open Claude Code sessions to pick up the PreToolUse hook.' -ForegroundColor Cyan
