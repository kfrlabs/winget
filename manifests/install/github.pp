# frozen_string_literal: true

# == Define: winget::install::github
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
      command => "${powershell} -NoProfile -Command \"Get-AppxPackage Microsoft.DesktopAppInstaller | Remove-AppxPackage\"",
      onlyif  => "${powershell} -NoProfile -Command \"if (Get-AppxPackage Microsoft.DesktopAppInstaller) { exit 0 } else { exit 1 }\"",
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

    exec { "winget_install_github_${title}":
      command     => "${powershell} -NoProfile -ExecutionPolicy Bypass -Command \"Invoke-WebRequest -UseBasicParsing -Uri '${download_url}' -OutFile (Join-Path \$env:TEMP 'winget.msixbundle'); Add-AppxPackage -Path (Join-Path \$env:TEMP 'winget.msixbundle')\"",
      timeout     => 600,
      tries       => $retry_count,
      try_sleep   => $retry_interval,
      environment => $download_env,
      unless      => "${powershell} -NoProfile -Command \"if (Get-AppxPackage Microsoft.DesktopAppInstaller) { exit 0 } else { exit 1 }\"",
    }
  }
}
