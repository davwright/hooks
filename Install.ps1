<#
.SYNOPSIS
    Install the two-layer git-write guard.

.DESCRIPTION
    Deploys:
      1. The canonical judge  -> $HOME\.githooks\git-guard.sh
      2. The git template     -> $HOME\.git-template\hooks\{pre-commit,pre-push}  (thin stubs)
                                 + sets git config --global init.templateDir
         so every future `git init` / `git clone` is armed automatically.
      3. The thin Claude hook -> ~\.claude\hooks\claude-git-guard.sh
                                 + registers it in ~\.claude\settings.json under
                                 PreToolUse:Bash, REPLACING the old block-git-write.sh
                                 entry if present (no protection gap, no duplicate).

    Idempotent: re-running overwrites scripts in place and de-dupes the settings entry.

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

function Copy-Exec($src, $dst) {
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
Copy-Exec (Join-Path $ScriptDir 'git-guard.sh') $CanonDst

# 2. Git template + init.templateDir.
Write-Host 'Git template (arms every future init/clone):' -ForegroundColor Cyan
$TmplHooks = Join-Path $Home_ '.git-template\hooks'
Copy-Exec (Join-Path $ScriptDir 'templates\hooks\pre-commit') (Join-Path $TmplHooks 'pre-commit')
Copy-Exec (Join-Path $ScriptDir 'templates\hooks\pre-push')   (Join-Path $TmplHooks 'pre-push')
$TmplDir = (Join-Path $Home_ '.git-template') -replace '\\', '/'
$curTmpl = (& git config --global init.templateDir) 2>$null
if ($curTmpl -eq $TmplDir) {
    Write-Host "  init.templateDir already = $TmplDir" -ForegroundColor DarkGray
} elseif ($PSCmdlet.ShouldProcess('git config --global init.templateDir', "set to $TmplDir")) {
    & git config --global init.templateDir $TmplDir
    Write-Host "  set init.templateDir = $TmplDir" -ForegroundColor Green
    if ($curTmpl) { Write-Host "  (was: $curTmpl)" -ForegroundColor Yellow }
}

# 3. Thin Claude hook + settings.json swap.
Write-Host 'Thin Claude PreToolUse hook:' -ForegroundColor Cyan
$HookDst = Join-Path $ClaudeHome 'hooks\claude-git-guard.sh'
Copy-Exec (Join-Path $ScriptDir 'claude-git-guard.sh') $HookDst

$SettingsPath = Join-Path $ClaudeHome 'settings.json'
$NewCmd = '~/.claude/hooks/claude-git-guard.sh'
$OldCmds = @('~/.claude/hooks/block-git-write.sh', ('bash "{0}"' -f (($ClaudeHome -replace '\\','/') + '/hooks/block-git-write.sh')))

if (-not (Test-Path $SettingsPath)) { throw "settings.json not found at $SettingsPath" }
$settings = (Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8) | ConvertFrom-Json

if (-not ($settings.PSObject.Properties.Name -contains 'hooks')) {
    Add-Member -InputObject $settings -MemberType NoteProperty -Name 'hooks' -Value ([pscustomobject]@{}) -Force
}
if (-not ($settings.hooks.PSObject.Properties.Name -contains 'PreToolUse')) {
    Add-Member -InputObject $settings.hooks -MemberType NoteProperty -Name 'PreToolUse' -Value @() -Force
}
$preList   = @($settings.hooks.PreToolUse)
$bashEntry = $preList | Where-Object { $_.matcher -eq 'Bash' } | Select-Object -First 1

if (-not $bashEntry) {
    $bashEntry = [pscustomobject]@{ matcher = 'Bash'; hooks = @() }
    $preList += $bashEntry
    $settings.hooks.PreToolUse = $preList
}

# Rebuild the Bash hooks list: drop any old block-git-write entry, ensure the
# new one is present exactly once. Preserve every other hook (python, ev, ...).
$kept = @($bashEntry.hooks | Where-Object {
    ($OldCmds -notcontains $_.command) -and ($_.command -ne $NewCmd)
})
$newEntry = [pscustomobject]@{ type = 'command'; command = $NewCmd; timeout = 10 }
$bashEntry.hooks = @($kept) + $newEntry

if ($PSCmdlet.ShouldProcess($SettingsPath, 'Swap block-git-write -> claude-git-guard in PreToolUse:Bash')) {
    $json = $settings | ConvertTo-Json -Depth 20
    Set-Content -LiteralPath $SettingsPath -Value $json -Encoding UTF8
    Write-Host "  registered $NewCmd (removed any old block-git-write.sh)" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan
Write-Host 'Whitelist lives in:' -NoNewline; Write-Host "  $CanonDst" -ForegroundColor Yellow
Write-Host 'Restart open Claude Code sessions to pick up the new PreToolUse hook.'
