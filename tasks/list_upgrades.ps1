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

function Find-Winget {
  # Highest installed version first (WindowsApps scan before PATH, like the
  # Ruby resolver): compare the version segment numerically, not the full
  # path as text (1.9 sorts after 1.10 as text).
  $roots = @($env:ProgramFiles, ${env:ProgramW6432}) | Where-Object { $_ } | Select-Object -Unique
  foreach ($root in $roots) {
    $pattern = Join-Path $root 'WindowsApps\Microsoft.DesktopAppInstaller_*__8wekyb3d8bbwe\winget.exe'
    $hits = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue
    if ($hits) {
      $best = @($hits) | Sort-Object {
        try { [version](($_.Directory.Name -split '_')[1]) } catch { [version]'0.0' }
      } -Descending | Select-Object -First 1
      if ($best) { return $best.FullName }
    }
  }
  $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Test-TableSeparator($line) {
  return ("$line" -match '^\s*[-=]{3,}\s*$')
}


function Test-WideCodepoint([int]$code) {
  if ($code -ge 0x1100 -and $code -le 0x115F) { return $true }
  if ($code -ge 0x2329 -and $code -le 0x232A) { return $true }
  if ($code -ge 0x2E80 -and $code -le 0x303E) { return $true }
  if ($code -ge 0x3041 -and $code -le 0x33FF) { return $true }
  if ($code -ge 0x3400 -and $code -le 0x4DBF) { return $true }
  if ($code -ge 0x4E00 -and $code -le 0xA4CF) { return $true }
  if ($code -ge 0xAC00 -and $code -le 0xD7A3) { return $true }
  if ($code -ge 0xF900 -and $code -le 0xFAFF) { return $true }
  if ($code -ge 0xFE10 -and $code -le 0xFE19) { return $true }
  if ($code -ge 0xFE30 -and $code -le 0xFE4F) { return $true }
  if ($code -ge 0xFF00 -and $code -le 0xFF60) { return $true }
  if ($code -ge 0xFFE0 -and $code -le 0xFFE6) { return $true }
  if ($code -ge 0x20000 -and $code -le 0x2FFFD) { return $true }
  if ($code -ge 0x30000 -and $code -le 0x3FFFD) { return $true }
  if ($code -ge 0x1F300 -and $code -le 0x1FAFF) { return $true }
  if ($code -ge 0x2600 -and $code -le 0x27BF) { return $true }
  if ($code -ge 0x2B00 -and $code -le 0x2BFF) { return $true }
  if ($code -ge 0x10000) { return $true }
  return $false
}

function Get-DisplayWidth([string]$text) {
  $w = 0
  $i = 0
  while ($i -lt $text.Length) {
    $c = [int][char]$text[$i]
    if ($c -ge 0xD800 -and $c -le 0xDBFF -and ($i + 1) -lt $text.Length) {
      $low = [int][char]$text[$i + 1]
      if ($low -ge 0xDC00 -and $low -le 0xDFFF) {
        $code = 0x10000 + (($c - 0xD800) * 0x400) + ($low - 0xDC00)
        if (Test-WideCodepoint $code) { $w += 2 } else { $w += 2 }
        $i += 2
        continue
      }
    }
    if (Test-WideCodepoint $c) { $w += 2 } else { $w += 1 }
    $i++
  }
  return $w
}

function Get-DisplaySubstring([string]$line, [int]$startDisplay, [int]$endDisplay) {
  # Mirrors Ruby display_substring: slice by terminal display columns.
  if ($null -eq $endDisplay) { $endDisplay = [int]::MaxValue }
  $out = ''
  $col = 0
  $i = 0
  while ($i -lt $line.Length) {
    $unitLen = 1
    $charWidth = 1
    $c = [int][char]$line[$i]
    $code = $c
    if ($c -ge 0xD800 -and $c -le 0xDBFF -and ($i + 1) -lt $line.Length) {
      $low = [int][char]$line[$i + 1]
      if ($low -ge 0xDC00 -and $low -le 0xDFFF) {
        $code = 0x10000 + (($c - 0xD800) * 0x400) + ($low - 0xDC00)
        $unitLen = 2
      }
    }
    if ($unitLen -eq 2) { $charWidth = 2 }
    elseif (Test-WideCodepoint $code) { $charWidth = 2 }
    if ($col -ge $startDisplay -and $col -lt $endDisplay) { $out += $line.Substring($i, $unitLen) }
    $col += $charWidth
    if ($col -ge $endDisplay) { break }
    $i += $unitLen
  }
  return $out
}

function Get-HeaderCellOffsets($header) {
  # Header offsets are display columns (headers are ASCII, so display
  # equals UTF-16 units here). Data rows are sliced with Get-DisplaySubstring
  # so CJK/emoji names align like the Ruby display_slice.
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
      if ((Get-DisplayWidth $line) -lt $offsets.Version) { continue }
      $id = (Get-DisplaySubstring $line $offsets.Id $offsets.Version).Trim()
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
