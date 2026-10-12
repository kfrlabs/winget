# frozen_string_literal: true

# == Define: winget::install::local
#
# Installs winget from a local AppX/MSIX/MSIXBundle file. Use this for offline
# installation where no internet access is available.
#
# All commands run through the fully qualified PowerShell executable: the
# `winget` alias is unavailable in the agent/SYSTEM context, so no bare
# `winget` command is used here.
#
# === Parameters
#
# @param source_path
#   Required. Local filesystem path to the winget AppX/MSIX/MSIXBundle file.
#   Must be a valid Microsoft.WinGet.Client or Microsoft.DesktopAppInstaller package.
#
# @param ensure
#   Desired state: 'present', 'absent', or a specific version string.
#
# @param version
#   Specific version to install (e.g., '1.8.2391'). Recorded for interface
#   consistency; the installed version is determined by the file content.
#
# @param dependencies
#   Array of dependency AppX/MSIX files to install first. Optional.
#
define winget::install::local (
  String $source_path,
  String $ensure              = 'present',
  Optional[String] $version   = undef,
  Array[String] $dependencies = []
) {
  if $version and $version =~ /^\d+(\.\d+)+$/ {
    $real_ensure = $version
  } else {
    $real_ensure = $ensure
  }

  # Fully qualified PowerShell: exec commands must be qualified and the
  # winget alias is unavailable in the SYSTEM context.
  $powershell = 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'

  # Validate file extension
  $valid_extensions = ['.appx', '.msix', '.msixbundle', '.appxbundle']
  $ext = regsubst($source_path, '^.*(\.[^.]+)$', '\1')
  if !($ext in $valid_extensions) {
    fail("winget::install::local: Invalid file extension '${ext}'. Must be one of: ${valid_extensions.join(', ')}")
  }

  if $real_ensure == 'absent' {
    exec { "winget_uninstall_local_${title}":
      command => "${powershell} -NoProfile -Command \"Remove-AppxPackage -AllUsers -Package (Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller).PackageFullName\"",
      onlyif  => "${powershell} -NoProfile -Command \"if (Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller) { exit 0 } else { exit 1 }\"",
      timeout => 300,
    }
  } else {
    # Install dependencies first
    $dependencies.each |$dep| {
      exec { "winget_install_dep_${dep}_${title}":
        command => "${powershell} -NoProfile -Command \"Add-AppxPackage -Path '${dep}'\"",
        onlyif  => "${powershell} -NoProfile -Command \"if (Get-AppxPackage -AllUsers -Name (Get-AppxPackageManifest -Path '${dep}').Package.PackageIdentity.Name) { exit 0 } else { exit 1 }\"",
        timeout => 300,
      }
    }

    exec { "winget_install_local_${title}":
      command   => "${powershell} -NoProfile -Command \"Add-AppxPackage -Path '${source_path}'\"",
      onlyif    => "${powershell} -NoProfile -Command \"if (Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller) { exit 1 } else { exit 0 }\"",
      timeout   => 300,
      tries     => 3,
      try_sleep => 10,
    }
  }
}
