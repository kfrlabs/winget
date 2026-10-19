# frozen_string_literal: true

# @summary Installs winget from the Microsoft CDN distribution of App Installer.
#
# Installs winget from the Microsoft CDN distribution of App Installer
# (`https://aka.ms/getwinget`, a .msixbundle). This method is used instead of
# the Microsoft Store app because it works in the SYSTEM context without the
# Store and without an existing winget CLI, and it accepts the same proxy
# settings as the other install methods.
#
# Backs `source => 'cdn'` of the `winget` class. `source => 'msstore'` is a
# deprecated alias kept for backward compatibility (see
# `winget::install::msstore`): the download is the Microsoft CDN in both
# cases, never the Store app.
#
# The install runs only when App Installer is absent (presence guard): this
# matters because the bundle version and the inner payload version can differ
# (e.g. bundle 2026.728.x carrying a 1.29.290 payload), and Windows refuses
# downgrades (0x80073D19), so reinstalling over a newer build would fail.
#
# All commands run through the fully qualified PowerShell executable: the
# `winget` alias is unavailable in the agent/SYSTEM context, so no bare
# `winget` command is used here.
#
# === Parameters
#
# @param ensure
#   Desired state: 'present', 'absent', or a specific version string.
#   Anything else (typos included) fails compilation.
#
# @param version
#   DEPRECATED: use `ensure` instead. Accepted for interface consistency but
#   ignored: the Microsoft CDN always serves the latest App Installer. Pin a
#   version with the `github` source or a local file instead. Setting it logs
#   a deprecation warning.
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
# @param fail_on_error
#   Whether a failed install makes the catalog run fail. Default: true. Set
#   to false when another method acts as a fallback (`source => 'auto'`):
#   exit code 1 is then accepted, so the failure of this attempt does not
#   mark the including class as failed and the fallback still gets a chance.
#   Note that Puppet does not retry (`retry_count`) once exit code 1 is
#   accepted.
#
define winget::install::cdn (
  Winget::Ensure $ensure                    = 'present',
  Optional[String] $version                 = undef,
  Boolean $accept_source_agreements         = true,
  Optional[String] $proxy                   = undef,
  Integer $retry_count                      = 3,
  Integer $retry_interval                   = 10,
  Boolean $fail_on_error                    = true
) {
  if $version {
    warning("winget::install::cdn[${title}]: the version parameter is deprecated and ignored (the cdn source always serves latest), use ensure instead.")
  }
  if $version and $version =~ /^\d+(\.\d+)+$/ {
    $real_ensure = $version
  } else {
    $real_ensure = $ensure
  }

  # Fully qualified PowerShell: exec commands must be qualified and the
  # winget alias is unavailable in the SYSTEM context.
  $powershell = 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'

  if $real_ensure == 'absent' {
    exec { "winget_uninstall_cdn_${title}":
      command => "${powershell} -NoProfile -Command \"Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller | Remove-AppxPackage -AllUsers\"",
      onlyif  => "${powershell} -NoProfile -Command \"if (Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller) { exit 0 } else { exit 1 }\"",
      timeout => 300,
    }
  } else {
    if $proxy {
      $download_env = ["HTTPS_PROXY=${proxy}", "HTTP_PROXY=${proxy}"]
    } else {
      $download_env = undef
    }

    # The Microsoft CDN always serves the latest App Installer, so a pinned
    # version cannot be honored here (use the `github` source or a local file
    # to pin). The guard below therefore stays presence-based on purpose: a
    # version-based guard would reinstall latest on every run when a version
    # is pinned, and could never converge.
    if $real_ensure =~ /^\d+(\.\d+)+$/ {
      warning("winget::install::cdn[${title}]: ensure '${real_ensure}' pins a version, but the cdn source always installs the latest App Installer. Use source => 'github' or source_path to pin a version.")
    }

    # `Add-AppxPackage` is flaky under the SYSTEM account and the aka.ms
    # bundle does not embed the VCLibs / UI.Xaml framework packages, so fall
    # back to `Add-AppxProvisionedPackage -Online -SkipLicense`, which stages
    # the package for all users without a Store license.
    #
    # Hardening (issue #39): the bundle is downloaded into a per-run unique
    # directory (no fixed name in the shared `$env:TEMP`, safe under
    # `tries` retries and concurrent `cdn`/`github` attempts), locked down to
    # SYSTEM and Administrators, and removed in a `finally` block on success
    # and on failure. Before installing, the Authenticode signature must be
    # `Valid` with a Microsoft publisher, otherwise the run fails closed.
    # `$ProgressPreference = 'SilentlyContinue'` avoids the extremely slow
    # progress bar of Windows PowerShell 5.1 `Invoke-WebRequest`.
    $exec_returns = $fail_on_error ? {
      true    => [0],
      default => [0, 1],
    }

    exec { "winget_install_cdn_${title}":
      command     => "${powershell} -NoProfile -ExecutionPolicy Bypass -Command \"\$ProgressPreference = 'SilentlyContinue'; \$workDir = Join-Path \$env:TEMP ('winget-install-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path \$workDir -Force | Out-Null; \$acl = Get-Acl -Path \$workDir; \$acl.SetAccessRuleProtection(\$true, \$false); \$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\\SYSTEM', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))); \$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('BUILTIN\\Administrators', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))); Set-Acl -Path \$workDir -AclObject \$acl; try { \$bundle = Join-Path \$workDir 'winget.msixbundle'; Invoke-WebRequest -UseBasicParsing -Uri 'https://aka.ms/getwinget' -OutFile \$bundle; \$sig = Get-AuthenticodeSignature -FilePath \$bundle; if ((\$sig.Status -ne 'Valid') -or (\$sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation')) { throw ('winget bundle signature check failed (Status: ' + \$sig.Status + ')') }; try { Add-AppxPackage -Path \$bundle -ErrorAction Stop } catch { Add-AppxProvisionedPackage -Online -PackagePath \$bundle -SkipLicense } } finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue \$workDir }\"",
      environment => $download_env,
      timeout     => 600,
      tries       => $retry_count,
      try_sleep   => $retry_interval,
      returns     => $exec_returns,
      unless      => "${powershell} -NoProfile -Command \"if (Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller) { exit 0 } else { exit 1 }\"",
    }
  }
}
