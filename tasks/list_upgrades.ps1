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

function Test-TableSeparator($line) {
  return ("$line" -match '^\s*[-=]{3,}\s*$')
}

function Get-HeaderCellOffsets($header) {
  # Offsets count UTF-16 code units (.NET strings): a package name with
  # astral-plane characters (e.g. emoji) before the Id column shifts every
  # offset by one unit per character, while the Ruby facts count characters
  # (BMP-only assumption for full parity; BMP text aligns on both sides).
  $text = "$header"
  $starts = @()
  $pos = 0
  foreach ($cell in ($text -split '\s{2,}|\t+')) {
    if ([string]::IsNullOrEmpty($cell)) { continue }
    $idx = $text.IndexOf($cell, $pos)
    if ($idx -lt 0) { break }
    $starts += $idx
    $pos = $idx + $cell.Length
  }
  return $starts
}

function Find-TableHeaders($lines) {
  $found = @()
  for ($i = 0; $i -lt ($lines.Count - 1); $i++) {
    if (-not (Test-TableSeparator $lines[$i + 1])) { continue }
    $offsets = @(Get-HeaderCellOffsets $lines[$i])
    if ($offsets.Count -lt 3) { continue }
    # The separator must reach the Version column: a short stray line such
    # as '---' under a data row is a row to skip, not a table boundary.
    if (("$($lines[$i + 1])".Trim().Length) -lt $offsets[2]) { continue }
    $second = "$($lines[$i])".Substring($offsets[1], $offsets[2] - $offsets[1]).Trim()
    if ($second -ine 'Id') {
      Write-Verbose ("winget: unexpected second header cell '{0}', parsing table positionally" -f $second)
    }
    $found += $i
  }
  return $found
}

function Remove-ProgressFrames($line) {
  $text = "$line"
  if ($text.Contains("`r")) {
    $segments = $text -split "`r"
    $text = ''
    for ($k = $segments.Count - 1; $k -ge 0; $k--) {
      if (-not [string]::IsNullOrWhiteSpace($segments[$k])) { $text = $segments[$k]; break }
    }
  }
  return $text.TrimStart([char]0xFEFF)
}

function Get-VisibleLines($lines) {
  $clean = @()
  foreach ($raw in $lines) {
    $line = Remove-ProgressFrames $raw
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    # A leading BOM would shift the first column.
    $clean += $line.TrimStart([char]0xFEFF)
  }
  return $clean
}

function Get-ColumnOffsets($header) {
  $offsets = @(Get-HeaderCellOffsets $header)
  if ($offsets.Count -lt 3) { return $null }
  return @{ Id = $offsets[1]; Version = $offsets[2] }
}

# Legacy single-line header predicate, kept for compatibility (the table
# functions above recognize localized headers structurally instead, see
# Find-TableHeaders): true when the line segments into at least three cells
# whose second cell reads exactly 'Id'.
function Test-TableHeader($line) {
  $offsets = @(Get-HeaderCellOffsets "$line")
  if ($offsets.Count -lt 3) { return $false }
  $cell = "$line".Substring($offsets[1], $offsets[2] - $offsets[1]).Trim()
  return $cell -ieq 'Id'
}

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

function Get-PinnedIds($winget) {
  $ids = @()
  $lines = @(& $winget pin list --accept-source-agreements --disable-interactivity 2>&1)
  if ($LASTEXITCODE -ne 0) { return $ids }
  $clean = @(Get-VisibleLines $lines)
  $headerIdx = @(Find-TableHeaders $clean)
  for ($t = 0; $t -lt $headerIdx.Count; $t++) {
    $h = $headerIdx[$t]
    $tableEnd = if ($t + 1 -lt $headerIdx.Count) { $headerIdx[$t + 1] } else { $clean.Count }
    $offsets = Get-ColumnOffsets $clean[$h]
    if (-not $offsets) { continue }
    for ($j = $h + 2; $j -lt $tableEnd; $j++) {
      $line = $clean[$j]
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
      if ($line.Length -lt $offsets.Version) { continue }
      $id = $line.Substring($offsets.Id, $offsets.Version - $offsets.Id).Trim()
      if ([string]::IsNullOrWhiteSpace($id)) { continue }
      if ($id -match '\s') { continue }
      if ($seen.ContainsKey($id)) { continue }
      $seen[$id] = $true
      $current = $null
      $available = $null
      if ($null -ne $availableStart) {
        # Mirror the Ruby lenient slicing without ever throwing: a row that
        # ends inside the Available column still yields its current version
        # with a null available version ($line is at least $offsets.Version
        # long here, so the first Substring length is never negative).
        $vLen = [Math]::Max(0, [Math]::Min($availableStart, $line.Length) - $offsets.Version)
        $current = $line.Substring($offsets.Version, $vLen).Trim()
        if ([string]::IsNullOrWhiteSpace($current)) { $current = $null }
        $rest = if ($line.Length -gt $availableStart) { $line.Substring($availableStart).Trim() } else { '' }
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
