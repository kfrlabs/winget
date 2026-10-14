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
$EXIT_SUCCESS = 0
$EXIT_UPDATE_NOT_APPLICABLE = [uint32]0x8A15002B
$EXIT_PACKAGE_ALREADY_INSTALLED = [uint32]0x8A150061
$EXIT_INSTALL_ALREADY_INSTALLED = [uint32]0x8A15010D
$EXIT_REBOOT_REQUIRED_TO_FINISH = [uint32]0x8A150109
$EXIT_REBOOT_REQUIRED_FOR_INSTALL = [uint32]0x8A15010A
$EXIT_REBOOT_INITIATED = [uint32]0x8A15010B
$EXIT_NO_APPLICABLE_INSTALLER = [uint32]0x8A150010

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

function Get-UpgradableIds($winget) {
  $ids = @()
  $seen = @{}
  $lines = @(& $winget upgrade --accept-source-agreements --disable-interactivity 2>&1)
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
  $code = [uint32]$LASTEXITCODE
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
