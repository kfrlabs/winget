#Requires -Version 5.1
<#
.SYNOPSIS
  Pester 5 suite for tasks/list_upgrades.ps1 (issue #76).
.DESCRIPTION
  Executes the task script for real instead of only asserting on its
  source text (the regex specs in spec/unit/tasks stay as-is). The task
  script is import-safe: dot-sourcing defines its functions without
  running the task (see the import guard at the bottom of the function
  definitions), so parsing tests call Get-UpgradeRows with captured
  static winget output from spec/fixtures. Subprocess tests drive the
  whole script through Windows PowerShell 5.1 with piped stdin to cover
  the fail-closed input validation and the winget-not-found path.
#>

BeforeAll {
  . (Join-Path $PSScriptRoot '../../tasks/winget_task_common.ps1')
  . (Join-Path $PSScriptRoot '../../tasks/list_upgrades.ps1')

  $script:isWindowsOS = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
  $script:powershellExe = $null
  $script:haveWindowsPowerShell = $false
  if ($script:isWindowsOS) {
    # Join-Path with an empty parent throws, so only resolve on Windows.
    $script:powershellExe = Join-Path ([System.Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:haveWindowsPowerShell = Test-Path -LiteralPath $script:powershellExe
  }

  function Read-FixtureLines {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    # Raw byte read with explicit UTF-8 decoding (identical on 5.1 and 7):
    # Get-Content would strip the BOM and may mis-decode CJK without one,
    # while this preserves BOM prefixes and spinner CR frames byte-exactly.
    $full = Join-Path $PSScriptRoot (Join-Path '../fixtures' $RelativePath)
    $bytes = [System.IO.File]::ReadAllBytes($full)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    return @($text -split "`r?`n")
  }

  function New-FakeWingetInstall([string]$Root, [string]$Version) {
    $dir = Join-Path $Root "WindowsApps\Microsoft.DesktopAppInstaller_${Version}__8wekyb3d8bbwe"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $dir 'winget.exe') | Out-Null
  }

  function Invoke-TaskProcess {
    # Runs a task script in a child Windows PowerShell with $Stdin piped,
    # optionally hiding every real winget (WindowsApps glob and PATH) so
    # the lookup outcome is fully determined by the test.
    param(
      [Parameter(Mandatory = $true)][string]$TaskPath,
      [Parameter(Mandatory = $true)][string]$Stdin,
      [string]$ProgramFilesRoot,
      [string]$PathValue
    )
    $oldPF = $env:ProgramFiles
    $oldPF64 = ${env:ProgramW6432}
    $oldPath = $env:PATH
    try {
      if ($ProgramFilesRoot) { $env:ProgramFiles = $ProgramFilesRoot; ${env:ProgramW6432} = $ProgramFilesRoot }
      if ($PathValue) { $env:PATH = $PathValue }
      $lines = @($Stdin | & $script:powershellExe -NoProfile -ExecutionPolicy Bypass -File $TaskPath 2>&1)
      return @{ Output = ($lines -join "`n"); ExitCode = $LASTEXITCODE }
    } finally {
      $env:ProgramFiles = $oldPF
      ${env:ProgramW6432} = $oldPF64
      $env:PATH = $oldPath
    }
  }
}

Describe 'list_upgrades parsing (Get-UpgradeRows)' {
  It 'parses the en-US table' {
    $rows = @(Get-UpgradeRows (Read-FixtureLines 'upgrade/en.txt'))
    $rows.Count | Should -Be 2
    $rows[0].id | Should -Be 'Git.Git'
    $rows[0].current_version | Should -Be '2.40.0'
    $rows[0].available_version | Should -Be '2.41.0'
    $rows[1].id | Should -Be 'Notepad++.Notepad++'
    $rows[1].current_version | Should -Be '8.5.4'
    $rows[1].available_version | Should -Be '8.6.0'
  }

  It 'parses the fr-FR table (Disponible header)' {
    $rows = @(Get-UpgradeRows (Read-FixtureLines 'upgrade/fr.txt'))
    $rows.Count | Should -Be 2
    $rows[0].id | Should -Be 'Git.Git'
    $rows[0].available_version | Should -Be '2.41.0'
    $rows[1].id | Should -Be 'Notepad++.Notepad++'
    $rows[1].available_version | Should -Be '8.6.0'
  }

  It 'parses the de-DE table with collapsed single-space gaps' {
    $rows = @(Get-UpgradeRows (Read-FixtureLines 'upgrade/de-collapsed.txt'))
    $rows.Count | Should -Be 2
    $rows[0].id | Should -Be 'Microsoft.DotNet.AspNetCore.6'
    $rows[0].current_version | Should -Be '6.0.35'
    $rows[0].available_version | Should -Be '6.0.36'
    $rows[1].id | Should -Be 'Git.Git'
    $rows[1].available_version | Should -Be '2.41.0'
  }

  It 'deduplicates rows across tables and never leaks headers as IDs' {
    $rows = @(Get-UpgradeRows (Read-FixtureLines '../pester/fixtures/multi-table.txt'))
    $rows.Count | Should -Be 2
    $rows[0].id | Should -Be 'Git.Git'
    $rows[1].id | Should -Be 'Foo.Foo'
    $rows[1].current_version | Should -Be '1.0'
    $rows[1].available_version | Should -Be '2.0'
  }

  It 'keeps rows with null versions when the table has no Available column' {
    $rows = @(Get-UpgradeRows (Read-FixtureLines 'list/en.txt'))
    $rows.Count | Should -Be 2
    $rows[0].id | Should -Be 'Git.Git'
    $rows[0].current_version | Should -BeNullOrEmpty
    $rows[0].available_version | Should -BeNullOrEmpty
  }

  It 'strips spinner progress frames' {
    $rows = @(Get-UpgradeRows (Read-FixtureLines 'upgrade/en-spinner.txt'))
    $rows.Count | Should -Be 2
    $rows[0].id | Should -Be 'Git.Git'
    $rows[0].available_version | Should -Be '2.41.0'
  }

  It 'tolerates a BOM prefix' {
    $rows = @(Get-UpgradeRows (Read-FixtureLines 'list/es-bom.txt'))
    $rows.Count | Should -Be 2
    $rows[0].id | Should -Be 'Git.Git'
    $rows[1].id | Should -Be 'Notepad++.Notepad++'
  }

  It 'parses wide/CJK names by display width' {
    $rows = @(Get-UpgradeRows (Read-FixtureLines 'wide/upgrade-display.txt'))
    $rows.Count | Should -Be 4
    $rows[0].id | Should -Be 'CJK.Package'
    $rows[0].current_version | Should -Be '1.0'
    $rows[0].available_version | Should -Be '2.0'
    $rows[1].id | Should -Be 'Accented.App'
    $rows[2].id | Should -Be 'Truncated.App'
    $rows[2].available_version | Should -Be '6.0.36'
    $rows[3].id | Should -Be 'Emoji.Party'
    $rows[3].available_version | Should -Be '4.0'
  }
}

Describe 'list_upgrades Find-Winget' -Skip:(-not $script:isWindowsOS) {
  BeforeEach {
    $script:oldProgramFiles = $env:ProgramFiles
    $script:oldProgramW6432 = ${env:ProgramW6432}
    $script:oldPath = $env:PATH
  }

  AfterEach {
    $env:ProgramFiles = $script:oldProgramFiles
    ${env:ProgramW6432} = $script:oldProgramW6432
    $env:PATH = $script:oldPath
  }

  It 'picks the highest version numerically (1.10 over 1.9)' {
    $root = Join-Path $TestDrive 'pf'
    New-FakeWingetInstall $root '1.8.0.0'
    New-FakeWingetInstall $root '1.9.2.0'
    New-FakeWingetInstall $root '1.10.5.0'
    $env:ProgramFiles = $root
    ${env:ProgramW6432} = $root
    $env:PATH = $env:SystemRoot
    Find-Winget | Should -BeLike '*1.10.5.0*'
  }

  It 'scans WindowsApps before PATH' {
    $root = Join-Path $TestDrive 'pf2'
    New-FakeWingetInstall $root '1.9.2.0'
    $env:ProgramFiles = $root
    ${env:ProgramW6432} = $root
    $bin = Join-Path $TestDrive 'bin'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $bin 'winget.exe') | Out-Null
    $env:PATH = "$bin$([System.IO.Path]::PathSeparator)$env:PATH"
    Find-Winget | Should -BeLike '*WindowsApps*'
  }
}

Describe 'list_upgrades task process (fail-closed input, winget lookup)' -Skip:(-not ($script:haveWindowsPowerShell -and $script:isWindowsOS)) {
  It 'fails closed on malformed JSON with winget/invalid-input (exit 1)' {
    $task = Join-Path $PSScriptRoot '../../tasks/list_upgrades.ps1'
    $empty = Join-Path $TestDrive 'emptyroot'
    New-Item -ItemType Directory -Force -Path $empty | Out-Null
    # No winget is discoverable here: invalid-input (not not-found) proves
    # validation runs before the winget lookup, i.e. winget never runs.
    $r = Invoke-TaskProcess -TaskPath $task -Stdin 'not json{' -ProgramFilesRoot $empty -PathValue $env:SystemRoot
    $r.ExitCode | Should -Be 1
    ($r.Output | ConvertFrom-Json)._error.kind | Should -Be 'winget/invalid-input'
  }

  It 'never invokes winget when input validation fails' {
    $task = Join-Path $PSScriptRoot '../../tasks/list_upgrades.ps1'
    $empty = Join-Path $TestDrive 'emptyroot2'
    New-Item -ItemType Directory -Force -Path $empty | Out-Null
    $stubDir = Join-Path $TestDrive 'stubbin'
    New-Item -ItemType Directory -Force -Path $stubDir | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $stubDir 'winget.exe') | Out-Null
    # A discoverable (but broken) winget.exe: had validation run after the
    # lookup, the task would try to execute this stub and report something
    # other than winget/invalid-input.
    $path = "$stubDir$([System.IO.Path]::PathSeparator)$env:SystemRoot"
    $r = Invoke-TaskProcess -TaskPath $task -Stdin '{"include_pinned": "yes"}' -ProgramFilesRoot $empty -PathValue $path
    $r.ExitCode | Should -Be 1
    ($r.Output | ConvertFrom-Json)._error.kind | Should -Be 'winget/invalid-input'
  }

  It 'reports winget/not-found (exit 1) when winget is missing' {
    $task = Join-Path $PSScriptRoot '../../tasks/list_upgrades.ps1'
    $empty = Join-Path $TestDrive 'emptyroot3'
    New-Item -ItemType Directory -Force -Path $empty | Out-Null
    $r = Invoke-TaskProcess -TaskPath $task -Stdin '{}' -ProgramFilesRoot $empty -PathValue $env:SystemRoot
    $r.ExitCode | Should -Be 1
    ($r.Output | ConvertFrom-Json)._error.kind | Should -Be 'winget/not-found'
  }
}
