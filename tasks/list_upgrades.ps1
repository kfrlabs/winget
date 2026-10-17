#Requires -Version 5.1
<#
.SYNOPSIS
  List winget packages with available upgrades (read-only, makes no changes).
.DESCRIPTION
  Bolt/PE task counterpart of the `winget_upgrades` fact, for on-demand
  inventory outside Puppet agent runs. Runs `winget upgrade` once, parses the
  result tables with the same fixed-width header-offset technique as the
  module facts (winget shrinks inter-column gaps to a single space for long
  names, so a whitespace split would corrupt IDs), and prints a JSON result.
  Exit code is 0 on success, 1 when winget itself is missing or fails.
#>
[CmdletBinding()]
param()

# 'Continue' (not 'Stop'): winget may write informational lines to stderr and
# native-command stderr records must never terminate this task; every failure
# mode is handled explicitly via exit codes below.
$ErrorActionPreference = 'Continue'

function Read-TaskParams {
  $params = @{}
  try {
    if ([Console]::IsInputRedirected) {
      $raw = [Console]::In.ReadToEnd()
      if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $parsed = $raw | ConvertFrom-Json
        if ($null -ne $parsed.include_pinned) { $params['include_pinned'] = [bool]$parsed.include_pinned }
      }
    }
  } catch {
    # Unparseable task input: fall back to defaults.
  }
  return $params
}

function Find-Winget {
  $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $roots = @($env:ProgramFiles, ${env:ProgramW6432}) | Where-Object { $_ } | Select-Object -Unique
  foreach ($root in $roots) {
    $pattern = Join-Path $root 'WindowsApps\Microsoft.DesktopAppInstaller_*__8wekyb3d8bbwe\winget.exe'
    $hits = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue
    if ($hits) { return ($hits | Sort-Object FullName -Descending | Select-Object -First 1).FullName }
  }
  return $null
}

function Get-ColumnOffsets($header) {
  $idMatch = [regex]::Match($header, '\bId\b', 'IgnoreCase')
  $versionMatch = [regex]::Match($header, '\bVersion\b', 'IgnoreCase')
  if (-not $idMatch.Success -or -not $versionMatch.Success) { return $null }
  if ($versionMatch.Index -le $idMatch.Index) { return $null }
  return @{ Id = $idMatch.Index; Version = $versionMatch.Index }
}

function Test-TableHeader($line) {
  if ($line -notmatch 'Id.*Version') { return $false }
  $offsets = Get-ColumnOffsets $line
  if (-not $offsets) { return $false }
  $cell = $line.Substring($offsets.Id, $offsets.Version - $offsets.Id).Trim()
  return $cell -ieq 'Id'
}

function Get-AvailableOffset($header, $versionStart) {
  $tail = $header.Substring($versionStart + 'Version'.Length)
  $m = [regex]::Match($tail, '\b(Available|Disponible)\b', 'IgnoreCase')
  if (-not $m.Success) { return $null }
  return ($versionStart + 'Version'.Length + $m.Index)
}

function Get-PinnedIds($winget) {
  $ids = @()
  $lines = @(& $winget pin list --accept-source-agreements --disable-interactivity 2>&1)
  if ($LASTEXITCODE -ne 0) { return $ids }
  $headerIdx = @()
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if (Test-TableHeader $lines[$i]) { $headerIdx += $i }
  }
  foreach ($h in $headerIdx) {
    $offsets = Get-ColumnOffsets $lines[$h]
    if (-not $offsets) { continue }
    for ($j = $h + 2; $j -lt $lines.Count; $j++) {
      $line = $lines[$j]
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      if (Test-TableHeader $line) { break }
      if ($line -match '^\s*[-=]+\s*$') { continue }
      if ($line.Length -lt $offsets.Version) { continue }
      $id = $line.Substring($offsets.Id, $offsets.Version - $offsets.Id).Trim()
      if ([string]::IsNullOrWhiteSpace($id)) { continue }
      if ($id -match '\s') { continue }
      if ($ids -notcontains $id) { $ids += $id }
    }
  }
  return $ids
}

function Get-UpgradeRows($lines) {
  $rows = @()
  $seen = @{}
  $headerIdx = @()
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if (Test-TableHeader $lines[$i]) { $headerIdx += $i }
  }
  foreach ($h in $headerIdx) {
    $offsets = Get-ColumnOffsets $lines[$h]
    if (-not $offsets) { continue }
    $availableStart = Get-AvailableOffset $lines[$h] $offsets.Version
    for ($j = $h + 2; $j -lt $lines.Count; $j++) {
      $line = $lines[$j]
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      if (Test-TableHeader $line) { break }
      if ($line -match '^\s*[-=]+\s*$') { continue }
      if ($line.Length -lt $offsets.Version) { continue }
      $id = $line.Substring($offsets.Id, $offsets.Version - $offsets.Id).Trim()
      if ([string]::IsNullOrWhiteSpace($id)) { continue }
      if ($id -match '\s') { continue }
      if ($seen.ContainsKey($id)) { continue }
      $seen[$id] = $true
      $current = $null
      $available = $null
      if ($null -ne $availableStart -and $line.Length -gt $availableStart) {
        $current = $line.Substring($offsets.Version, $availableStart - $offsets.Version).Trim()
        if ([string]::IsNullOrWhiteSpace($current)) { $current = $null }
        $rest = $line.Substring($availableStart).Trim()
        if (-not [string]::IsNullOrWhiteSpace($rest)) { $available = ($rest -split '\s+')[0] }
      }
      $rows += @{ id = $id; current_version = $current; available_version = $available }
    }
  }
  return $rows
}

$taskParams = Read-TaskParams

$winget = Find-Winget
if (-not $winget) {
  Write-Output (@{ _error = @{ kind = 'winget/not-found'; msg = 'winget.exe not found on PATH or in WindowsApps' } } | ConvertTo-Json -Depth 3 -Compress)
  exit 1
}

$rawLines = @(& $winget upgrade --accept-source-agreements --disable-interactivity 2>&1)
$upgrades = @(Get-UpgradeRows $rawLines)

# By default pinned packages are still listed; only exclude them when
# include_pinned is explicitly false (mirrors upgrade_now without include_pinned).
if ($taskParams.ContainsKey('include_pinned') -and -not $taskParams['include_pinned']) {
  $pinned = @(Get-PinnedIds $winget)
  if ($pinned.Count -gt 0) {
    $lowerPinned = @($pinned | ForEach-Object { "$_".ToLowerInvariant() })
    $upgrades = @($upgrades | Where-Object { $lowerPinned -notcontains "$($_.id)".ToLowerInvariant() })
  }
}

Write-Output (@{ upgrades = $upgrades } | ConvertTo-Json -Depth 4 -Compress)
exit 0
