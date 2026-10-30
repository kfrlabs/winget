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
  # Fail closed like upgrade_now: malformed JSON or a wrong-typed field
  # throws so the caller exits 1 before winget runs.
  $params = @{}
  $raw = $null
  if ([Console]::IsInputRedirected) {
    $raw = [Console]::In.ReadToEnd()
  }
  if ([string]::IsNullOrWhiteSpace($raw)) { return $params }
  try {
    $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "Invalid task input JSON: $($_.Exception.Message)"
  }
  if ($null -ne $parsed.include_pinned) {
    if ($parsed.include_pinned -isnot [bool]) { throw "Invalid task input: 'include_pinned' must be a boolean" }
    $params['include_pinned'] = $parsed.include_pinned
  }
  return $params
}

# Shared fixed-width table helpers (issue #75): the single source of truth
# lives in the sibling winget_task_common.ps1 so both tasks stay identical.
# Fail closed when the helper is missing: emit the task JSON _error
# contract instead of a raw terminating dot-source error.
$wingetTaskCommon = Join-Path $PSScriptRoot 'winget_task_common.ps1'
if (-not (Test-Path -LiteralPath $wingetTaskCommon)) {
  Write-Output (@{ _error = @{ kind = 'winget/not-found'; msg = 'winget_task_common.ps1 helper not found next to the task' } } | ConvertTo-Json -Depth 3 -Compress)
  exit 1
}
. $wingetTaskCommon

function Get-AvailableOffset($header, $versionStart) {
  # $versionStart is unused; kept so the two-argument call form keeps working.
  $text = "$header"
  $offsets = @(Get-HeaderCellOffsets $text)
  if ($offsets.Count -ge 5) { return $offsets[3] }
  if ($offsets.Count -eq 4) {
    $fourth = $text.Substring($offsets[3]).Trim()
    if ($fourth -match '\b(Available|Disponible)\b') { return $offsets[3] }
  }
  return $null
}

function Get-UpgradeRows($lines) {
  $rows = @()
  $seen = @{}
  $clean = @(Get-VisibleLines $lines)
  $headerIdx = @(Find-TableHeaders $clean)
  for ($t = 0; $t -lt $headerIdx.Count; $t++) {
    $h = $headerIdx[$t]
    $tableEnd = if ($t + 1 -lt $headerIdx.Count) { $headerIdx[$t + 1] } else { $clean.Count }
    $offsets = Get-ColumnOffsets $clean[$h]
    if (-not $offsets) { continue }
    $availableStart = Get-AvailableOffset $clean[$h] $offsets.Version
    for ($j = $h + 2; $j -lt $tableEnd; $j++) {
      $line = $clean[$j]
      if ($line -match '^\s*[-=]+\s*$') { continue }
      if ((Get-DisplayWidth $line) -lt $offsets.Version) { continue }
      $id = (Get-DisplaySubstring $line $offsets.Id $offsets.Version).Trim()
      if ([string]::IsNullOrWhiteSpace($id)) { continue }
      if ($id -match '\s') { continue }
      if ($seen.ContainsKey($id)) { continue }
      $seen[$id] = $true
      $current = $null
      $available = $null
      if ($null -ne $availableStart) {
        # Mirror the Ruby lenient slicing without ever throwing: a row that
        # ends inside the Available column still yields its current version
        # with a null available version (display width is used so CJK names
        # align like the Ruby parser).
        $lineWidth = Get-DisplayWidth $line
        $vLen = [Math]::Max(0, [Math]::Min($availableStart, $lineWidth) - $offsets.Version)
        $current = (Get-DisplaySubstring $line $offsets.Version ($offsets.Version + $vLen)).Trim()
        if ([string]::IsNullOrWhiteSpace($current)) { $current = $null }
        $rest = if ($lineWidth -gt $availableStart) { (Get-DisplaySubstring $line $availableStart 99999).Trim() } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($rest)) { $available = ($rest -split '\s+')[0] }
      }
      $rows += @{ id = $id; current_version = $current; available_version = $available }
    }
  }
  return $rows
}

# Import guard for the Pester suites (spec/pester): dot-sourcing this
# script defines the functions above without running the task below, so
# tests can call them with stubbed winget output. A real task run
# (powershell -File) has an InvocationName of the script path, never '.'.
if ($MyInvocation.InvocationName -eq '.') { return }

try {
  $taskParams = Read-TaskParams
} catch {
  Write-Output (@{ _error = @{ kind = 'winget/invalid-input'; msg = "$_" } } | ConvertTo-Json -Depth 3 -Compress)
  exit 1
}

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
