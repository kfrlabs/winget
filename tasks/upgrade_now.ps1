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
  # Fail closed: non-empty stdin that cannot be parsed, or fields with the
  # wrong type, throw so the caller exits 1 before winget runs. An empty
  # `ids` means "upgrade everything", so silently falling back to defaults
  # on bad input would turn a typo into a fleet-wide upgrade.
  $params = @{ ids = @(); exclude = @(); include_pinned = $false }
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
  if ($null -ne $parsed.ids) {
    if ($parsed.ids -isnot [array]) { throw "Invalid task input: 'ids' must be an array" }
    foreach ($entry in $parsed.ids) {
      if ([string]::IsNullOrWhiteSpace($entry) -or ("$entry" -match '\s')) {
        throw "Invalid task input: 'ids' entries must be non-empty strings without whitespace"
      }
    }
    $params['ids'] = @($parsed.ids | ForEach-Object { "$_" })
  }
  if ($null -ne $parsed.exclude) {
    if ($parsed.exclude -isnot [array]) { throw "Invalid task input: 'exclude' must be an array" }
    foreach ($entry in $parsed.exclude) {
      if ([string]::IsNullOrWhiteSpace($entry) -or ("$entry" -match '\s')) {
        throw "Invalid task input: 'exclude' entries must be non-empty strings without whitespace"
      }
    }
    $params['exclude'] = @($parsed.exclude | ForEach-Object { "$_" })
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
      if ((Get-DisplayWidth $line) -lt $offsets.Version) { continue }
      $id = (Get-DisplaySubstring $line $offsets.Id $offsets.Version).Trim()
      if ([string]::IsNullOrWhiteSpace($id)) { continue }
      if ($id -match '\s') { continue }
      if ($seen.ContainsKey($id)) { continue }
      $seen[$id] = $true
      $ids += $id
    }
  }
  return $ids
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
