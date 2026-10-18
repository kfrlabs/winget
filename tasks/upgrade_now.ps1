#Requires -Version 5.1
<#
.SYNOPSIS
  Upgrade winget packages immediately (on-demand, outside agent runs).
.DESCRIPTION
  Bolt/PE task counterpart of `Class['winget::upgrade']`. Upgrades the IDs
  given in `ids`, or enumerates `winget upgrade` and upgrades everything
  (minus `exclude`, minus pinned packages unless `include_pinned`) when `ids`
  is empty. Prints a JSON summary; exit code is 0 unless winget itself is
  missing or no enumeration was possible. Per-package installer failures are
  reported in the JSON result, not as task failure. A reboot-requesting
  installer (exit 0x8A150109/0x8A15010A/0x8A15010B) counts as success with `reboot_required: true`.
#>
[CmdletBinding()]
param()

# 'Continue' (not 'Stop'): installers and winget itself may write to stderr
# and native-command stderr records must never terminate this task; every
# failure mode is handled explicitly via exit codes below.
$ErrorActionPreference = 'Continue'

# winget exit codes (subset relevant to upgrades, verified against
# https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-manager/winget/returnCodes.md).
# PowerShell types hex literals above 0x7FFFFFFF as negative Int32 and
# $LASTEXITCODE is a signed Int32, so `[uint32]0x8A15002B` and
# `[uint32]$LASTEXITCODE` both throw. The constants are therefore parsed
# from their hex text, and the exit code is reinterpreted bit for bit.
$EXIT_SUCCESS = 0
$EXIT_UPDATE_NOT_APPLICABLE = [Convert]::ToUInt32('8A15002B', 16)
$EXIT_PACKAGE_ALREADY_INSTALLED = [Convert]::ToUInt32('8A150061', 16)
$EXIT_INSTALL_ALREADY_INSTALLED = [Convert]::ToUInt32('8A15010D', 16)
$EXIT_REBOOT_REQUIRED_TO_FINISH = [Convert]::ToUInt32('8A150109', 16)
$EXIT_REBOOT_REQUIRED_FOR_INSTALL = [Convert]::ToUInt32('8A15010A', 16)
$EXIT_REBOOT_INITIATED = [Convert]::ToUInt32('8A15010B', 16)
$EXIT_NO_APPLICABLE_INSTALLER = [Convert]::ToUInt32('8A150010', 16)

function ConvertTo-UInt32ExitCode([int]$Code) {
  return [BitConverter]::ToUInt32([BitConverter]::GetBytes($Code), 0)
}

function Read-TaskParams {
  $params = @{ ids = @(); exclude = @(); include_pinned = $false }
  try {
    if ([Console]::IsInputRedirected) {
      $raw = [Console]::In.ReadToEnd()
      if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $parsed = $raw | ConvertFrom-Json
        if ($null -ne $parsed.ids) { $params['ids'] = @($parsed.ids) }
        if ($null -ne $parsed.exclude) { $params['exclude'] = @($parsed.exclude) }
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

function Get-UpgradableIds($winget) {
  $ids = @()
  $seen = @{}
  $lines = @(& $winget upgrade --accept-source-agreements --disable-interactivity 2>&1)
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
      if ($seen.ContainsKey($id)) { continue }
      $seen[$id] = $true
      $ids += $id
    }
  }
  return $ids
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

$taskParams = Read-TaskParams

$winget = Find-Winget
if (-not $winget) {
  Write-Output (@{ _error = @{ kind = 'winget/not-found'; msg = 'winget.exe not found on PATH or in WindowsApps' } } | ConvertTo-Json -Depth 3 -Compress)
  exit 1
}

if ($taskParams.ids.Count -gt 0) {
  $targets = @($taskParams.ids)
} else {
  $targets = @(Get-UpgradableIds $winget)
  if ($taskParams.exclude.Count -gt 0) {
    $lowerExclude = @($taskParams.exclude | ForEach-Object { "$_".ToLowerInvariant() })
    $targets = @($targets | Where-Object { $lowerExclude -notcontains "$_".ToLowerInvariant() })
  }
  if (-not $taskParams.include_pinned) {
    $pinned = @(Get-PinnedIds $winget)
    if ($pinned.Count -gt 0) {
      $lowerPinned = @($pinned | ForEach-Object { "$_".ToLowerInvariant() })
      $targets = @($targets | Where-Object { $lowerPinned -notcontains "$_".ToLowerInvariant() })
    }
  }
}

$upgraded = @()
$alreadyCurrent = @()
$failed = @()
$rebootRequired = $false

foreach ($id in $targets) {
  $null = & $winget upgrade --id $id --exact --accept-package-agreements --accept-source-agreements --disable-interactivity --silent 2>&1
  $code = ConvertTo-UInt32ExitCode $LASTEXITCODE
  if ($code -eq $EXIT_SUCCESS) {
    $upgraded += $id
  } elseif ($code -eq $EXIT_REBOOT_REQUIRED_TO_FINISH -or $code -eq $EXIT_REBOOT_REQUIRED_FOR_INSTALL -or $code -eq $EXIT_REBOOT_INITIATED) {
    $upgraded += $id
    $rebootRequired = $true
  } elseif ($code -eq $EXIT_UPDATE_NOT_APPLICABLE -or $code -eq $EXIT_PACKAGE_ALREADY_INSTALLED -or $code -eq $EXIT_INSTALL_ALREADY_INSTALLED) {
    $alreadyCurrent += $id
  } else {
    $failed += @{ id = $id; exit_code = $code }
  }
}

Write-Output (@{
  upgraded         = $upgraded
  already_current  = $alreadyCurrent
  failed           = $failed
  reboot_required  = $rebootRequired
} | ConvertTo-Json -Depth 4 -Compress)
exit 0
