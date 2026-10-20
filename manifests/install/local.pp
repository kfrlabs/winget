# frozen_string_literal: true

# @summary Installs winget from a local AppX/MSIX/MSIXBundle file.
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
#   Must be a valid Microsoft.DesktopAppInstaller package.
#
# @param ensure
#   Desired state: 'present', 'absent', or a specific version string.
#   Anything else (typos included) fails compilation.
#
# @param version
#   DEPRECATED: use `ensure` instead. Specific version to install (e.g.,
#   '1.8.2391'). Kept for backward compatibility (still honored); setting it
#   logs a deprecation warning. Recorded for interface consistency; the
#   installed version is determined by the file content.
#
# @param dependencies
#   Array of dependency AppX/MSIX files to install first. Optional.
#   Typically the VCLibs / UI.Xaml framework packages on offline hosts.
#
# @note When `ensure` pins a version, the `source_path` bundle must contain
#   that version: the guard reinstalls while the installed version differs,
#   so a mismatching file would reinstall on every run.
define winget::install::local (
  String $source_path,
  Winget::Ensure $ensure      = 'present',
  Optional[String] $version   = undef,
  Array[String] $dependencies = []
) {
  if $version {
    warning("winget::install::local[${title}]: the version parameter is deprecated, use ensure => '<version>' instead (still honored for backward compatibility).")
  }
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
    # Removal covers both registration flavors: per-user/all-users instances
    # (`Remove-AppxPackage`, which fails with 0x80070032 on staged images)
    # and the staged provisioned package (`Remove-AppxProvisionedPackage`,
    # which offline installs may create). Each step is best effort; the exec
    # fails closed only when an instance still resolves afterwards.
    exec { "winget_uninstall_local_${title}":
      command => "${powershell} -NoProfile -Command \"\$pkgs = Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller; if (\$pkgs) { try { \$pkgs | Remove-AppxPackage -AllUsers -ErrorAction Stop } catch { Write-Warning ('Remove-AppxPackage failed, trying provisioned removal: ' + \$_.Exception.Message) } }; \$prov = Get-AppxProvisionedPackage -Online | Where-Object { \$_.PackageName -like 'Microsoft.DesktopAppInstaller*' }; if (\$prov) { try { \$prov | ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName \$_.PackageName -ErrorAction Stop } } catch { Write-Warning ('Remove-AppxProvisionedPackage failed: ' + \$_.Exception.Message) } }; if (Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller) { throw 'Microsoft.DesktopAppInstaller is still installed' }\"",
      onlyif  => "${powershell} -NoProfile -Command \"if (Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller) { exit 0 } elseif (Get-AppxProvisionedPackage -Online | Where-Object { \$_.PackageName -like 'Microsoft.DesktopAppInstaller*' }) { exit 0 } else { exit 1 }\"",
      timeout => 300,
    }
  } else {
    # Escape single quotes for PowerShell single-quoted literals.
    $quoted_source = regsubst($source_path, "'", "''", 'G')

    # Same version-aware guard as the github source: a pinned version
    # reinstalls while the installed version differs, and is a no-op once it
    # matches. AppX versions carry an extra revision segment (installed
    # `1.8.2391.0` satisfies pin `1.8.2391`).
    if $real_ensure =~ /^\d+(\.\d+)+$/ {
      $version_re = regsubst($real_ensure, '\.', '\\.', 'G')
      $presence_check = "if (((Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller | Select-Object -First 1).Version -join '') -match '^${version_re}(\\.|$)') { exit 0 } else { exit 1 }"
    } else {
      $presence_check = 'if (Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller) { exit 0 } else { exit 1 }'
    }

    # Install dependencies first. The dependency identity (package Name) is
    # read from the manifest embedded in each bundle: unlike the previous
    # `Get-AppxPackageManifest -Path` (no such `-Path` parameter; the cmdlet
    # takes `-Package`), opening the bundle as a zip works for any
    # .appx/.msix file. Plain packages carry `AppxManifest.xml` at the zip
    # root, while .appxbundle/.msixbundle files carry
    # `AppxMetadata/AppxBundleManifest.xml` with a `<Bundle>` root instead of
    # `<Package>`: both layouts are tried. The guard skips bundles whose
    # package is already installed for all users.
    $dependencies.each |$dep| {
      $quoted_dep = regsubst($dep, "'", "''", 'G')
      exec { "winget_install_dep_${dep}_${title}":
        command => "${powershell} -NoProfile -Command \"try { Add-AppxPackage -Path '${quoted_dep}' -ErrorAction Stop } catch { Add-AppxProvisionedPackage -Online -PackagePath '${quoted_dep}' -SkipLicense }\"",
        unless  => "${powershell} -NoProfile -Command \"Add-Type -AssemblyName System.IO.Compression.FileSystem; \$zip = [System.IO.Compression.ZipFile]::OpenRead('${quoted_dep}'); try { \$entry = \$zip.GetEntry('AppxManifest.xml'); if (\$entry) { \$reader = New-Object System.IO.StreamReader(\$entry.Open()); [xml]\$manifest = \$reader.ReadToEnd(); \$dep_name = \$manifest.Package.Identity.Name } else { \$bundle_entry = \$zip.GetEntry('AppxMetadata/AppxBundleManifest.xml'); \$bundle_reader = New-Object System.IO.StreamReader(\$bundle_entry.Open()); [xml]\$bundle_manifest = \$bundle_reader.ReadToEnd(); \$dep_name = \$bundle_manifest.Bundle.Identity.Name } } finally { if (\$reader) { \$reader.Close() }; if (\$bundle_reader) { \$bundle_reader.Close() }; \$zip.Dispose() }; if (\$dep_name -and (Get-AppxPackage -AllUsers -Name \$dep_name)) { exit 0 } else { exit 1 }\"",
        timeout => 300,
      }
    }

    # `Add-AppxPackage` is flaky under the SYSTEM account, so fall back to
    # `Add-AppxProvisionedPackage -Online -SkipLicense`, which stages the
    # package for all users without a Store license.
    exec { "winget_install_local_${title}":
      command   => "${powershell} -NoProfile -Command \"try { Add-AppxPackage -Path '${quoted_source}' -ErrorAction Stop } catch { Add-AppxProvisionedPackage -Online -PackagePath '${quoted_source}' -SkipLicense }\"",
      unless    => "${powershell} -NoProfile -Command \"${presence_check}\"",
      timeout   => 300,
      tries     => 3,
      try_sleep => 10,
    }
  }
}
