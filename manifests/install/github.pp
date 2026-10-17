# frozen_string_literal: true

# @summary Installs winget from GitHub releases.
#
# Installs winget from GitHub releases by downloading the AppX/MSIX bundle
# and installing it with Add-AppxPackage. This is the recommended method for
# pinning a specific winget version.
#
# All commands run through the fully qualified PowerShell executable: the
# `winget` alias is unavailable in the agent/SYSTEM context, so no bare
# `winget` command is used here.
#
# === Parameters
#
# @param ensure
#   Desired state: 'present', 'absent', or a specific version string.
#
# @param version
#   Specific version to install (e.g., '1.8.2391'). Defaults to latest release.
#
# @param proxy
#   Proxy URL for the download.
#
# @param retry_count
#   Number of retry attempts for the installation. Default: 3.
#
# @param retry_interval
#   Seconds between retry attempts. Default: 10.
#
define winget::install::github (
  String $ensure           = 'present',
  Optional[String] $version = undef,
  Optional[String] $proxy  = undef,
  Integer $retry_count     = 3,
  Integer $retry_interval  = 10
) {
  if $version and $version =~ /^\d+(\.\d+)+$/ {
    $real_ensure = $version
  } else {
    $real_ensure = $ensure
  }

  # Fully qualified PowerShell: exec commands must be qualified and the
  # winget alias is unavailable in the SYSTEM context.
  $powershell = 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'

  if $real_ensure == 'absent' {
    exec { "winget_uninstall_github_${title}":
      command => "${powershell} -NoProfile -Command \"Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller | Remove-AppxPackage -AllUsers\"",
      onlyif  => "${powershell} -NoProfile -Command \"if (Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller) { exit 0 } else { exit 1 }\"",
      timeout => 300,
    }
  } else {
    # The GitHub release publishes a single arch-independent bundle
    # (Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle). An explicit
    # version (via ensure or version) pins the download URL, otherwise the
    # latest release is used.
    if $real_ensure =~ /^\d+(\.\d+)+$/ {
      $download_url = "https://github.com/microsoft/winget-cli/releases/download/v${real_ensure}/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
    } else {
      $download_url = 'https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
    }

    if $proxy {
      $download_env = ["HTTPS_PROXY=${proxy}", "HTTP_PROXY=${proxy}"]
    } else {
      $download_env = undef
    }

    # A pinned version makes the guard version-aware so `ensure =>
    # '1.8.2391'` converges (reinstalls when another version is present) and
    # stays idempotent once installed. Without a pin, the guard stays
    # presence-based. AppX versions carry an extra revision segment
    # (e.g. installed `1.8.2391.0` satisfies pin `1.8.2391`).
    if $real_ensure =~ /^\d+(\.\d+)+$/ {
      $version_re = regsubst($real_ensure, '\.', '\\.', 'G')
      $presence_check = "if (((Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller | Select-Object -First 1).Version -join '') -match '^${version_re}(\\.|$)') { exit 0 } else { exit 1 }"
    } else {
      $presence_check = 'if (Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller) { exit 0 } else { exit 1 }'
    }

    # `Add-AppxPackage` is flaky under the SYSTEM account, so fall back to
    # `Add-AppxProvisionedPackage -Online -SkipLicense`, which stages the
    # package for all users without a Store license.
    exec { "winget_install_github_${title}":
      command     => "${powershell} -NoProfile -ExecutionPolicy Bypass -Command \"Invoke-WebRequest -UseBasicParsing -Uri '${download_url}' -OutFile (Join-Path \$env:TEMP 'winget.msixbundle'); try { Add-AppxPackage -Path (Join-Path \$env:TEMP 'winget.msixbundle') -ErrorAction Stop } catch { Add-AppxProvisionedPackage -Online -PackagePath (Join-Path \$env:TEMP 'winget.msixbundle') -SkipLicense }\"",
      timeout     => 600,
      tries       => $retry_count,
      try_sleep   => $retry_interval,
      environment => $download_env,
      unless      => "${powershell} -NoProfile -Command \"${presence_check}\"",
    }
  }
}
