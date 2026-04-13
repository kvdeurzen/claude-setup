#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Setup installer for Windows (PowerShell).
.DESCRIPTION
    Installs skills, agents, rules, output-styles, and hooks into ~/.claude/
    using symlinks. Mirrors the behavior of install.sh for Linux/macOS.
.NOTES
    Symlinks on Windows require either Developer Mode enabled or an elevated
    (Administrator) PowerShell session.
#>

param(
    [switch]$All,
    [switch]$AllSkills,
    [switch]$AllAgents,
    [switch]$AllRules,
    [switch]$AllStyles,
    [switch]$AllHooks,
    [switch]$Uninstall,
    [switch]$List,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Items = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ClaudeDir = Join-Path $HOME '.claude'
$ManagedBy = 'claude-setup'

$Categories = @{
    'skills'        = 'skills'
    'agents'        = 'agents'
    'rules'         = 'rules'
    'output-styles' = 'output-styles'
    'hooks'         = 'hooks'
}

# ── Helpers ──────────────────────────────────────────────────────────────────

function Show-Usage {
    @"
Usage: install.ps1 [OPTIONS] [ITEMS...]

Options:
  -All            Install everything across all categories
  -AllSkills      Install all skills
  -AllAgents      Install all agents
  -AllRules       Install all rules
  -AllStyles      Install all output-styles
  -AllHooks       Install all hooks
  -Uninstall      Remove all symlinks and hook entries managed by this repo
  -List           Show what's available and what's installed
  -Help           Show this help

Items:
  Specific items to install, e.g.: skills/refinement hooks/my-hook

Without any flags or items, nothing is installed.
"@
}

function Log  ($msg) { Write-Host "  $msg" }
function Ok   ($msg) { Write-Host "  + $msg" -ForegroundColor Green }
function Warn ($msg) { Write-Host "  ! $msg" -ForegroundColor Yellow }
function Err  ($msg) { Write-Host "  x $msg" -ForegroundColor Red }

function Test-OurSymlink {
    param([string]$Path)
    $item = Get-Item $Path -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    if (-not $item.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) { return $false }
    $target = (Get-Item $Path).Target
    if (-not $target) { return $false }
    $resolved = [System.IO.Path]::GetFullPath($target)
    return $resolved.StartsWith([System.IO.Path]::GetFullPath($ScriptDir), [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-SymlinkSupport {
    $testLink = Join-Path $env:TEMP "claude-setup-symlink-test-$(Get-Random)"
    $testTarget = $ScriptDir
    try {
        New-Item -ItemType SymbolicLink -Path $testLink -Target $testTarget -ErrorAction Stop | Out-Null
        Remove-Item $testLink -Force
        return $true
    } catch {
        return $false
    }
}

# ── Symlink-based install (skills, agents, rules, output-styles) ─────────────

function Install-Item {
    param([string]$Category, [string]$Name)
    $src = Join-Path $ScriptDir $Category $Name
    $targetDir = Join-Path $ClaudeDir $Categories[$Category]
    $target = Join-Path $targetDir $Name

    if (-not (Test-Path $src)) {
        Err "${Category}/${Name} not found in repo"
        return $false
    }

    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    if (Test-OurSymlink $target) {
        Log "${Category}/${Name} already installed (symlink up to date)"
        return $true
    }

    if (Test-Path $target) {
        Warn "${Category}/${Name}: target exists and is not our symlink - skipping (remove manually to install)"
        return $false
    }

    $isDir = (Get-Item $src).PSIsContainer
    if ($isDir) {
        New-Item -ItemType SymbolicLink -Path $target -Target $src | Out-Null
    } else {
        New-Item -ItemType SymbolicLink -Path $target -Target $src | Out-Null
    }
    Ok "${Category}/${Name} installed"
    return $true
}

function Uninstall-Item {
    param([string]$Category, [string]$Name)
    $target = Join-Path $ClaudeDir $Categories[$Category] $Name

    if (Test-OurSymlink $target) {
        Remove-Item $target -Force
        Ok "${Category}/${Name} uninstalled"
    }
}

# ── Hook-specific install/uninstall ──────────────────────────────────────────

function Install-Hook {
    param([string]$Name)
    $hookDir = Join-Path $ScriptDir 'hooks' $Name
    $hookJson = Join-Path $hookDir 'hook.json'

    if (-not (Test-Path $hookJson)) {
        Err "hooks/${Name}: no hook.json found"
        return
    }

    $installed = Install-Item 'hooks' $Name
    if (-not $installed) { return }

    # Find the script file (first non-json file)
    $scriptFile = Get-ChildItem $hookDir -File | Where-Object { $_.Name -ne 'hook.json' } | Select-Object -First 1
    if (-not $scriptFile) {
        Err "hooks/${Name}: no script file found alongside hook.json"
        return
    }

    $cmd = Join-Path $ClaudeDir 'hooks' $Name $scriptFile.Name
    $hook = Get-Content $hookJson -Raw | ConvertFrom-Json

    $event = $hook.event
    $matcher = if ($hook.PSObject.Properties['matcher']) { $hook.matcher } else { $null }
    $type = if ($hook.PSObject.Properties['type']) { $hook.type } else { 'command' }
    $timeout = if ($hook.PSObject.Properties['timeout']) { $hook.timeout } else { $null }

    # Determine interpreter
    $commandStr = switch -Wildcard ($scriptFile.Name) {
        '*.sh'  { "bash `"$cmd`"" }
        '*.js'  { "node `"$cmd`"" }
        '*.py'  { "python3 `"$cmd`"" }
        '*.ps1' { "pwsh `"$cmd`"" }
        default { "`"$cmd`"" }
    }

    # Build hook entry
    $hookEntry = [ordered]@{
        _managed_by = $ManagedBy
        _hook_name  = $Name
    }
    if ($matcher) { $hookEntry['matcher'] = $matcher }
    $hookDef = [ordered]@{ type = $type; command = $commandStr }
    if ($timeout) { $hookDef['timeout'] = [int]$timeout }
    $hookEntry['hooks'] = @($hookDef)

    # Merge into settings.json
    $settingsFile = Join-Path $ClaudeDir 'settings.json'
    if (-not (Test-Path $settingsFile)) {
        '{}' | Set-Content $settingsFile
    }

    # Backup
    Copy-Item $settingsFile "$settingsFile.bak" -Force

    $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json
    if (-not $settings.PSObject.Properties['hooks']) {
        $settings | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{})
    }
    if (-not $settings.hooks.PSObject.Properties[$event]) {
        $settings.hooks | Add-Member -NotePropertyName $event -NotePropertyValue @()
    }

    # Remove existing entries for this hook, then add new one
    $existing = @($settings.hooks.$event | Where-Object {
        -not ($_.PSObject.Properties['_managed_by'] -and $_._managed_by -eq $ManagedBy -and
              $_.PSObject.Properties['_hook_name'] -and $_._hook_name -eq $Name)
    })
    $existing += $hookEntry
    $settings.hooks.$event = $existing

    $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile
    Ok "hooks/${Name} registered in settings.json (event: ${event})"
}

function Uninstall-Hook {
    param([string]$Name)
    $target = Join-Path $ClaudeDir 'hooks' $Name

    if (Test-OurSymlink $target) {
        Remove-Item $target -Force
        Ok "hooks/${Name} symlink removed"
    }

    $settingsFile = Join-Path $ClaudeDir 'settings.json'
    if (Test-Path $settingsFile) {
        $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json
        if ($settings.PSObject.Properties['hooks']) {
            foreach ($event in @($settings.hooks.PSObject.Properties.Name)) {
                $filtered = @($settings.hooks.$event | Where-Object {
                    -not ($_.PSObject.Properties['_managed_by'] -and $_._managed_by -eq $ManagedBy -and
                          $_.PSObject.Properties['_hook_name'] -and $_._hook_name -eq $Name)
                })
                if ($filtered.Count -gt 0) {
                    $settings.hooks.$event = $filtered
                } else {
                    $settings.hooks.PSObject.Properties.Remove($event)
                }
            }
            $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile
        }
        Ok "hooks/${Name} removed from settings.json"
    }
}

# ── Collect items in a category ──────────────────────────────────────────────

function Get-CategoryItems {
    param([string]$Category)
    $srcDir = Join-Path $ScriptDir $Category
    if (-not (Test-Path $srcDir)) { return @() }

    $items = @()
    foreach ($entry in Get-ChildItem $srcDir -Directory) {
        if ($entry.Name -eq '.gitkeep') { continue }
        switch ($Category) {
            'skills' { if (-not (Test-Path (Join-Path $entry.FullName 'SKILL.md'))) { continue } }
            'hooks'  { if (-not (Test-Path (Join-Path $entry.FullName 'hook.json'))) { continue } }
        }
        $items += $entry.Name
    }
    # Also check for non-directory items (files in agents, rules, output-styles)
    foreach ($entry in Get-ChildItem $srcDir -File) {
        if ($entry.Name -eq '.gitkeep') { continue }
        $items += $entry.Name
    }
    return $items
}

# ── Main ─────────────────────────────────────────────────────────────────────

if ($Help -or ($PSBoundParameters.Count -eq 0 -and $Items.Count -eq 0)) {
    Show-Usage
    exit 0
}

# Check symlink support early
if (-not $List -and -not $Help) {
    if (-not (Test-SymlinkSupport)) {
        Err "Cannot create symlinks. Enable Developer Mode (Settings > For Developers) or run as Administrator."
        exit 1
    }
}

if ($List) {
    Write-Host 'Claude Setup - Status'
    Write-Host '====================='
    foreach ($category in @('skills', 'agents', 'rules', 'output-styles', 'hooks')) {
        $categoryItems = Get-CategoryItems $category
        if ($categoryItems.Count -eq 0) {
            Write-Host ''
            Write-Host "  ${category}/  (empty)"
            continue
        }
        Write-Host ''
        Write-Host "  ${category}/"
        foreach ($name in $categoryItems) {
            $target = Join-Path $ClaudeDir $Categories[$category] $name
            if (Test-OurSymlink $target) {
                Write-Host "    + ${name}  (installed)" -ForegroundColor Green
            } elseif (Test-Path $target) {
                Write-Host "    ! ${name}  (exists but not managed by us)" -ForegroundColor Yellow
            } else {
                Write-Host "    o ${name}  (available)"
            }
        }
    }
    Write-Host ''
    exit 0
}

if ($Uninstall) {
    Write-Host 'Uninstalling claude-setup managed items...'
    foreach ($category in @('skills', 'agents', 'rules', 'output-styles')) {
        $targetDir = Join-Path $ClaudeDir $Categories[$category]
        if (-not (Test-Path $targetDir)) { continue }
        foreach ($entry in Get-ChildItem $targetDir) {
            $entryPath = $entry.FullName
            if (Test-OurSymlink $entryPath) {
                Uninstall-Item $category $entry.Name
            }
        }
    }
    $hooksDir = Join-Path $ClaudeDir 'hooks'
    if (Test-Path $hooksDir) {
        foreach ($entry in Get-ChildItem $hooksDir) {
            if (Test-OurSymlink $entry.FullName) {
                Uninstall-Hook $entry.Name
            }
        }
    }
    # Clean orphaned managed entries from settings.json
    $settingsFile = Join-Path $ClaudeDir 'settings.json'
    if (Test-Path $settingsFile) {
        $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json
        if ($settings.PSObject.Properties['hooks']) {
            foreach ($event in @($settings.hooks.PSObject.Properties.Name)) {
                $filtered = @($settings.hooks.$event | Where-Object {
                    -not ($_.PSObject.Properties['_managed_by'] -and $_._managed_by -eq $ManagedBy)
                })
                if ($filtered.Count -gt 0) {
                    $settings.hooks.$event = $filtered
                } else {
                    $settings.hooks.PSObject.Properties.Remove($event)
                }
            }
            $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile
        }
    }
    Write-Host 'Done.'
    exit 0
}

# ── Determine what to install ──
$installQueue = @()

$categoryFlags = @{}
if ($All) {
    foreach ($cat in $Categories.Keys) { $categoryFlags[$cat] = $true }
}
if ($AllSkills) { $categoryFlags['skills'] = $true }
if ($AllAgents) { $categoryFlags['agents'] = $true }
if ($AllRules)  { $categoryFlags['rules'] = $true }
if ($AllStyles) { $categoryFlags['output-styles'] = $true }
if ($AllHooks)  { $categoryFlags['hooks'] = $true }

foreach ($cat in $categoryFlags.Keys) {
    foreach ($name in (Get-CategoryItems $cat)) {
        $installQueue += "${cat}/${name}"
    }
}

$installQueue += $Items

if ($installQueue.Count -eq 0) {
    Write-Host 'Nothing to install. Use -All, -All<Category>, or specify items.'
    Write-Host 'Run with -Help for usage.'
    exit 0
}

# ── Install ──
Write-Host 'Installing claude-setup items...'
foreach ($item in $installQueue) {
    $parts = $item -split '/', 2
    $category = $parts[0]
    $name = $parts[1]

    if (-not $Categories.ContainsKey($category)) {
        Err "Unknown category: ${category}"
        continue
    }

    if ($category -eq 'hooks') {
        Install-Hook $name
    } else {
        Install-Item $category $name | Out-Null
    }
}
Write-Host 'Done.'
