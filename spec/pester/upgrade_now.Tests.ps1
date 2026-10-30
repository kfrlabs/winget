#Requires -Version 5.1
<#
.SYNOPSIS
  Pester 5 suite for tasks/upgrade_now.ps1 (issue #76).
.DESCRIPTION
  Executes the task script for real instead of only asserting on its
  source text (the regex specs in spec/unit/tasks stay as-is). The task
  script is import-safe: dot-sourcing defines its functions without
  running the task (see the import guard at the bottom of the function
  definitions), so tests call Get-UpgradableIds / Get-PinnedIds with a
  stub winget.cmd on PATH-free invocations. Subprocess tests drive the
  whole script through Windows PowerShell 5.1 with piped stdin to cover
  the fail-closed input validation and the winget-not-found path.

  NOTE: list_upgrades.Tests.ps1 dot-sources a different script defining
  same-named functions (Read-TaskParams differs). Each file re-dotsources
  its own task in BeforeAll, and Pester runs files sequentially, so every
  test sees its own file's functions. Do not enable Pester parallel
  containers without isolating the dot-sourced functions: parallel
  containers share the session state, so same-named functions would be
  last-writer-wins.
#>

BeforeAll {
  . (Join-Path $PSScriptRoot '../../tasks/upgrade_now.ps1')

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

  function New-WingetCmdStub {
    # A stub "winget.exe" Pester can execute: a .cmd file is a native
    # command, so & sets $LASTEXITCODE like a real winget.exe would. The
    # caller passes the stub path as the $winget argument (Find-Winget is
    # bypassed); the stub ignores its arguments and replays one fixture.
    # Paths come from the caller: $TestDrive is only visible in test
    # blocks, not inside helper functions.
    param(
      [Parameter(Mandatory = $true)][string]$StubPath,
      [Parameter(Mandatory = $true)][string]$FixturePath
    )
    '@echo off' + "`r`n" + 'type "' + $FixturePath + '"' + "`r`n" | Set-Content -LiteralPath $StubPath -Encoding Ascii -NoNewline
  }

  function Get-StubbedWinget([string]$Name, [string]$FixtureRelativePath) {
    # $PSScriptRoot is file scope; $script:stubDir is set per-test above.
    $fixture = Join-Path $PSScriptRoot (Join-Path '../fixtures' $FixtureRelativePath)
    $stub = Join-Path $script:stubDir $Name
    New-WingetCmdStub -StubPath $stub -FixturePath $fixture
    return $stub
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

Describe 'upgrade_now enumeration (stubbed winget)' -Skip:(-not $script:isWindowsOS) {
  BeforeEach {
    # $script: scope: helper functions see script scope, not container locals.
    $script:stubDir = Join-Path $TestDrive 'stubs'
    New-Item -ItemType Directory -Force -Path $script:stubDir | Out-Null
  }

  It 'lists upgradable IDs from stubbed winget output' {
    $ids = @(Get-UpgradableIds (Get-StubbedWinget 'winget-en.cmd' 'upgrade/en.txt'))
    $ids.Count | Should -Be 2
    $ids | Should -Contain 'Git.Git'
    $ids | Should -Contain 'Notepad++.Notepad++'
  }

  It 'deduplicates across tables from stubbed winget output' {
    $ids = @(Get-UpgradableIds (Get-StubbedWinget 'winget-multi.cmd' '../pester/fixtures/multi-table.txt'))
    $ids.Count | Should -Be 2
    $ids[0] | Should -Be 'Git.Git'
    $ids[1] | Should -Be 'Foo.Foo'
  }

  It 'strips spinner progress frames from stubbed winget output' {
    $ids = @(Get-UpgradableIds (Get-StubbedWinget 'winget-spinner.cmd' 'upgrade/en-spinner.txt'))
    $ids.Count | Should -Be 2
    $ids | Should -Contain 'Git.Git'
  }

  It 'returns pinned IDs from stubbed pin list output' {
    # Get-PinnedIds bails out on a stale nonzero $LASTEXITCODE, which the
    # task never sees (fresh process): reset it like a fresh process would.
    $global:LASTEXITCODE = 0
    $ids = @(Get-PinnedIds (Get-StubbedWinget 'winget-pin.cmd' 'pin_list/en.txt'))
    $ids.Count | Should -Be 2
    $ids | Should -Contain 'Git.Git'
    $ids | Should -Contain 'Google.Chrome'
  }

  It 'returns no pinned IDs when pin list fails' {
    $dir = Join-Path $TestDrive 'failstub'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $stub = Join-Path $dir 'winget-fail.cmd'
    '@echo off' + "`r`n" + 'exit /b 1' + "`r`n" | Set-Content -LiteralPath $stub -Encoding Ascii -NoNewline
    @(Get-PinnedIds $stub).Count | Should -Be 0
  }
}

Describe 'upgrade_now ConvertTo-UInt32ExitCode' {
  # Pure PowerShell: runs on every OS, no winget stub needed.
  It 'round-trips native exit codes through ConvertTo-UInt32ExitCode' {
    ConvertTo-UInt32ExitCode 0 | Should -Be 0
    ConvertTo-UInt32ExitCode -1 | Should -Be ([uint32]::MaxValue)
    $asNative = [BitConverter]::ToInt32([BitConverter]::GetBytes($EXIT_REBOOT_REQUIRED_TO_FINISH), 0)
    ConvertTo-UInt32ExitCode $asNative | Should -Be $EXIT_REBOOT_REQUIRED_TO_FINISH
  }
}

Describe 'upgrade_now task process (fail-closed input, winget lookup)' -Skip:(-not ($script:haveWindowsPowerShell -and $script:isWindowsOS)) {
  It 'fails closed on malformed JSON with winget/invalid-input (exit 1)' {
    $task = Join-Path $PSScriptRoot '../../tasks/upgrade_now.ps1'
    $empty = Join-Path $TestDrive 'emptyroot'
    New-Item -ItemType Directory -Force -Path $empty | Out-Null
    # No winget is discoverable here: invalid-input (not not-found) proves
    # validation runs before the winget lookup, i.e. winget never runs.
    $r = Invoke-TaskProcess -TaskPath $task -Stdin 'not json{' -ProgramFilesRoot $empty -PathValue $env:SystemRoot
    $r.ExitCode | Should -Be 1
    ($r.Output | ConvertFrom-Json)._error.kind | Should -Be 'winget/invalid-input'
  }

  It 'never invokes winget when input validation fails' {
    $task = Join-Path $PSScriptRoot '../../tasks/upgrade_now.ps1'
    $empty = Join-Path $TestDrive 'emptyroot2'
    New-Item -ItemType Directory -Force -Path $empty | Out-Null
    $stubDir = Join-Path $TestDrive 'stubbin'
    New-Item -ItemType Directory -Force -Path $stubDir | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $stubDir 'winget.exe') | Out-Null
    # A discoverable (but broken) winget.exe: had validation run after the
    # lookup, the task would try to execute this stub and report something
    # other than winget/invalid-input.
    $path = "$stubDir$([System.IO.Path]::PathSeparator)$env:SystemRoot"
    $r = Invoke-TaskProcess -TaskPath $task -Stdin '{"ids": "Git.Git"}' -ProgramFilesRoot $empty -PathValue $path
    $r.ExitCode | Should -Be 1
    ($r.Output | ConvertFrom-Json)._error.kind | Should -Be 'winget/invalid-input'
  }

  It 'rejects wrong-typed ids, empty ids and whitespace ids' {
    $task = Join-Path $PSScriptRoot '../../tasks/upgrade_now.ps1'
    $empty = Join-Path $TestDrive 'emptyroot3'
    New-Item -ItemType Directory -Force -Path $empty | Out-Null
    foreach ($stdin in @('{"ids": [""]}', '{"ids": ["   "]}', '{"ids": ["Git.Git Foo"]}', '{"exclude": "x"}', '{"include_pinned": "yes"}')) {
      $r = Invoke-TaskProcess -TaskPath $task -Stdin $stdin -ProgramFilesRoot $empty -PathValue $env:SystemRoot
      $r.ExitCode | Should -Be 1
      ($r.Output | ConvertFrom-Json)._error.kind | Should -Be 'winget/invalid-input'
    }
  }

  It 'reports winget/not-found (exit 1) when winget is missing' {
    $task = Join-Path $PSScriptRoot '../../tasks/upgrade_now.ps1'
    $empty = Join-Path $TestDrive 'emptyroot4'
    New-Item -ItemType Directory -Force -Path $empty | Out-Null
    $r = Invoke-TaskProcess -TaskPath $task -Stdin '{}' -ProgramFilesRoot $empty -PathValue $env:SystemRoot
    $r.ExitCode | Should -Be 1
    ($r.Output | ConvertFrom-Json)._error.kind | Should -Be 'winget/not-found'
  }
}
