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
#   Anything else (typos included) fails compilation.
#
# @param version
#   DEPRECATED: use `ensure` instead. Specific version to install (e.g.,
#   '1.8.2391'). Kept for backward compatibility (still honored); setting it
#   logs a deprecation warning. Defaults to latest release.
#
# @param proxy
#   Proxy URL for the download. Accepts a plain string or `Sensitive` (e.g.
#   `Sensitive('http://user:pass@proxy.example.com:8080')`): the download
#   environment is `Sensitive`-wrapped so credentials are redacted from
#   catalogs, PuppetDB and reports. A plain string still works but embeds
#   credentials in clear text when the URL contains them, so prefer `Sensitive`
#   for URLs with credentials.
#
# @param retry_count
#   Number of retry attempts for the installation. Default: 3.
#
# @param retry_interval
#   Seconds between retry attempts. Default: 10.
#
define winget::install::github (
  Winget::Ensure $ensure = 'present',
  Optional[String] $version = undef,
  Optional[Variant[String, Sensitive[String]]] $proxy  = undef,
  Integer $retry_count     = 3,
  Integer $retry_interval  = 10
) {
  include winget::install::common

  if $version {
    warning("winget::install::github[${title}]: the version parameter is deprecated, use ensure => '<version>' instead (still honored for backward compatibility).")
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
    # Removal covers both registration flavors: per-user/all-users instances
    # (`Remove-AppxPackage`, which fails with 0x80070032 on staged images)
    # and the staged provisioned package (`Remove-AppxProvisionedPackage`,
    # which our own bootstrap fallback creates). Each step is best effort;
    # the exec fails closed only when an instance still resolves afterwards.
    exec { "winget_uninstall_github_${title}":
      command => "${powershell} -NoProfile -Command \"${winget::install::common::uninstall_command}\"",
      onlyif  => "${powershell} -NoProfile -Command \"${winget::install::common::uninstall_onlyif}\"",
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
      $proxy_unwrapped = $proxy =~ Sensitive ? {
        true    => $proxy.unwrap,
        default => $proxy,
      }
      $download_env = Sensitive(["HTTPS_PROXY=${proxy_unwrapped}", "HTTP_PROXY=${proxy_unwrapped}"])
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
      $presence_check = sprintf($winget::install::common::presence_check_version_template, $version_re)
    } else {
      $presence_check = $winget::install::common::presence_check
    }

    # `Add-AppxPackage` is flaky under the SYSTEM account, so fall back to
    # `Add-AppxProvisionedPackage -Online -SkipLicense`, which stages the
    # package for all users without a Store license.
    #
    # Hardening (issue #39): the bundle is downloaded into a per-run unique
    # directory (no fixed name in the shared `$env:TEMP`, safe under retries
    # and concurrent `cdn`/`github` attempts), locked down to SYSTEM and
    # Administrators, and removed in a `finally` block on success and on
    # failure. Before installing, the Authenticode signature must be `Valid`
    # with a Microsoft publisher, otherwise the run fails closed.
    # `$ProgressPreference = 'SilentlyContinue'` avoids the extremely slow
    # progress bar of Windows PowerShell 5.1 `Invoke-WebRequest`.
    exec { "winget_install_github_${title}":
      command     => "${powershell} -NoProfile -ExecutionPolicy Bypass -Command \"${sprintf($winget::install::common::download_install_template, $download_url)}\"",
      timeout     => 600,
      tries       => $retry_count,
      try_sleep   => $retry_interval,
      environment => $download_env,
      unless      => "${powershell} -NoProfile -Command \"${presence_check}\"",
    }
  }
}
