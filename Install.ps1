<#
.SYNOPSIS
    Install the block-git-write hook into the local Claude Code config.

.DESCRIPTION
    Copies block-git-write.sh into ~\.claude\hooks\ and registers it as a
    PreToolUse:Bash hook in ~\.claude\settings.json. Idempotent: re-running
    overwrites the script in place; the settings entry is added only if it
    is not already present.

.PARAMETER ClaudeHome
    Override the Claude Code config directory. Defaults to $env:USERPROFILE\.claude.

.PARAMETER WhatIf
    Preview the changes without writing anything.

.EXAMPLE
    .\Install.ps1
    Install with defaults.

.EXAMPLE
    .\Install.ps1 -WhatIf
    Show what would change.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ClaudeHome = (Join-Path $env:USERPROFILE '.claude')
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Source    = Join-Path $ScriptDir 'block-git-write.sh'

if (-not (Test-Path $Source)) {
    throw "Source hook not found at $Source. Run from the repo root."
}

# 1. Make sure ~/.claude/hooks exists.
$HooksDir = Join-Path $ClaudeHome 'hooks'
if (-not (Test-Path $HooksDir)) {
    if ($PSCmdlet.ShouldProcess($HooksDir, 'Create directory')) {
        New-Item -ItemType Directory -Path $HooksDir -Force | Out-Null
        Write-Host "Created $HooksDir" -ForegroundColor Green
    }
}

# 2. Copy block-git-write.sh.
$Dest = Join-Path $HooksDir 'block-git-write.sh'
if ($PSCmdlet.ShouldProcess($Dest, 'Copy hook script')) {
    Copy-Item -LiteralPath $Source -Destination $Dest -Force
    Write-Host "Copied hook to $Dest" -ForegroundColor Green
}

# 3. Register the hook in settings.json. PreToolUse hooks are matched by
#    a tool-name pattern; we register against Bash. The shape mirrors what
#    Claude Code expects:
#
#      {
#        "hooks": {
#          "PreToolUse": [
#            { "matcher": "Bash", "hooks": [ { "type": "command", "command": "<path>" } ] }
#          ]
#        }
#      }
#
#    We add an entry idempotently: if a Bash matcher already exists, we
#    append our command to it (deduped); if not, we add a new matcher.
$SettingsPath = Join-Path $ClaudeHome 'settings.json'
$HookCommand  = ('bash "{0}"' -f ($Dest -replace '\\', '/'))

if (Test-Path $SettingsPath) {
    $raw = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8
    if (-not $raw.Trim()) { $settings = [pscustomobject]@{} }
    else { $settings = $raw | ConvertFrom-Json }
} else {
    $settings = [pscustomobject]@{}
}

# Ensure hooks.PreToolUse exists
if (-not ($settings.PSObject.Properties.Name -contains 'hooks')) {
    Add-Member -InputObject $settings -MemberType NoteProperty -Name 'hooks' -Value ([pscustomobject]@{}) -Force
}
if (-not ($settings.hooks.PSObject.Properties.Name -contains 'PreToolUse')) {
    Add-Member -InputObject $settings.hooks -MemberType NoteProperty -Name 'PreToolUse' -Value @() -Force
}

# Find or create the Bash matcher entry. PreToolUse is a list of objects
# each with { matcher, hooks: [...] }.
$preList = @($settings.hooks.PreToolUse)
$bashEntry = $preList | Where-Object { $_.matcher -eq 'Bash' } | Select-Object -First 1

$alreadyRegistered = $false
if ($bashEntry) {
    $existing = @($bashEntry.hooks | Where-Object { $_.command -eq $HookCommand })
    if ($existing.Count -gt 0) { $alreadyRegistered = $true }
}

if ($alreadyRegistered) {
    Write-Host "Hook already registered in $SettingsPath - no settings change needed." -ForegroundColor DarkGray
} else {
    if ($PSCmdlet.ShouldProcess($SettingsPath, 'Register PreToolUse:Bash hook')) {
        $hookEntry = [pscustomobject]@{ type = 'command'; command = $HookCommand }
        if ($bashEntry) {
            # Append to existing matcher
            $bashEntry.hooks = @($bashEntry.hooks) + $hookEntry
        } else {
            # New matcher
            $newMatcher = [pscustomobject]@{
                matcher = 'Bash'
                hooks   = @($hookEntry)
            }
            $preList += $newMatcher
            $settings.hooks.PreToolUse = $preList
        }
        $json = $settings | ConvertTo-Json -Depth 10
        Set-Content -LiteralPath $SettingsPath -Value $json -Encoding UTF8
        Write-Host "Registered hook in $SettingsPath" -ForegroundColor Green
    }
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan
Write-Host 'Whitelist (case-insensitive grep -E patterns) is at the top of:'
Write-Host "  $Dest" -ForegroundColor Yellow
Write-Host 'Edit it for your environment, then restart any open Claude Code sessions.'
