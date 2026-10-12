# frozen_string_literal: true

# == Define: winget::install::msstore
#
# Installs winget from the Microsoft CDN distribution of App Installer
# (`https://aka.ms/getwinget`, a .msixbundle). This method is used instead of
# the Microsoft Store app because it works in the SYSTEM context without the
# Store and without an existing winget CLI, and it accepts the same proxy
# settings as the other install methods.
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
#   Accepted for interface consistency but ignored: the Microsoft CDN always
#   serves the latest App Installer. Pin a version with the `github` source
#   or a local file instead.
#
# @param accept_source_agreements
#   Kept for interface consistency. Source agreements are implicitly accepted
#   by direct package installation.
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
define winget::install::msstore (
  String $ensure                    = 'present',
  Optional[String] $version         = undef,
  Boolean $accept_source_agreements = true,
  Optional[String] $proxy           = undef,
  Integer $retry_count              = 3,
  Integer $retry_interval           = 10
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
    exec { "winget_uninstall_msstore_${title}":
      command => "${powershell} -NoProfile -Command \"Get-AppxPackage Microsoft.DesktopAppInstaller | Remove-AppxPackage\"",
      onlyif  => "${powershell} -NoProfile -Command \"if (Get-AppxPackage Microsoft.DesktopAppInstaller) { exit 0 } else { exit 1 }\"",
      timeout => 300,
    }
  } else {
    if $proxy {
      $download_env = ["HTTPS_PROXY=${proxy}", "HTTP_PROXY=${proxy}"]
    } else {
      $download_env = undef
    }

    exec { "winget_install_msstore_${title}":
      command     => "${powershell} -NoProfile -ExecutionPolicy Bypass -Command \"Invoke-WebRequest -UseBasicParsing -Uri 'https://aka.ms/getwinget' -OutFile (Join-Path \$env:TEMP 'winget.msixbundle'); Add-AppxPackage -Path (Join-Path \$env:TEMP 'winget.msixbundle')\"",
      environment => $download_env,
      timeout     => 600,
      tries       => $retry_count,
      try_sleep   => $retry_interval,
      unless      => "${powershell} -NoProfile -Command \"if (Get-AppxPackage Microsoft.DesktopAppInstaller) { exit 0 } else { exit 1 }\"",
    }
  }
}
