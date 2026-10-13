# frozen_string_literal: true

# == Class: winget
#
# This class manages the installation and configuration of the Windows Package Manager (winget).
# It ensures winget is available on the system so that the `winget` package provider can function.
#
# === Prerequisites
#
# * Windows 10 version 1809 (build 17763) or later, Windows Server 2019 or later
# * Internet access to download the App Installer package (or a local source via `source_path`)
# * SYSTEM account must have read access to `%ProgramFiles%\WindowsApps`
# * Proxy support via `proxy` parameter if the system requires a proxy for internet access
#
# === Usage
#
# To ensure winget is installed with defaults:
#
#   include winget
#
# To install a specific version from a local source:
#
#   class { 'winget':
#     ensure      => '1.8.2391',
#     source_path => 'C:\Sources\Microsoft.WinGet.Client_1.8.2391_x64.appx',
#   }
#
# To guarantee ordering before packages using the winget provider:
#
#   Class['winget'] -> Package <| provider == winget |>
#
# === Parameters
#
# @param ensure
#   Desired state of winget. Valid values: 'present', 'absent', or a specific version string
#   (e.g., '1.8.2391'). Default: 'present' (installs latest available).
#
# @param version
#   DEPRECATED: Use `ensure` instead. Specific version to install (e.g., '1.8.2391').
#   This parameter is kept for backward compatibility.
#
# @param source
#   Installation source for winget. Valid values: 'msstore' (Microsoft Store),
#   'github' (GitHub releases), or 'auto' (tries msstore first, falls back to
#   github). Default: 'auto'. When a specific version is requested via
#   `ensure`/`version`, `auto` uses `github` directly: the Microsoft CDN
#   always serves the latest App Installer, so msstore cannot honor a pin.
#
# @param source_path
#   Local filesystem path to a winget AppX/MSIX bundle file. When specified,
#   this takes precedence over `source`: only the local file is installed and
#   no `msstore`/`github` download is attempted. Use for offline installation.
#   The file must be a valid Microsoft.WinGet.Client or
#   Microsoft.DesktopAppInstaller package.
#
# @param dependencies
#   Array of local AppX/MSIX files installed before the `source_path` bundle
#   (e.g. VCLibs / UI.Xaml framework packages for offline hosts). Only used
#   together with `source_path`.
#
# @param proxy
#   Proxy URL for downloading winget (e.g., 'http://proxy.example.com:8080'). Only used
#   when downloading from Microsoft Store or GitHub. Default: undef (uses system proxy).
#
# @param accept_source_agreements
#   Whether to automatically accept source agreements during bootstrap. Default: true.
#
# @param enable_winget
#   Whether to manage winget installation. Set to false to disable the bootstrap class
#   while keeping the provider available. Default: true.
#
# === Ordering
#
# Ordering with packages using the winget provider is done at the class level:
#
#   Class['winget'] -> Package <| provider == winget |>
#
class winget (
  String $ensure                    = 'present',
  Optional[String] $version         = undef,
  Enum['msstore', 'github', 'auto'] $source = 'auto',
  Optional[String] $source_path     = undef,
  Array[String] $dependencies       = [],
  Optional[String] $proxy           = undef,
  Boolean $accept_source_agreements = true,
  Boolean $enable_winget            = true,
) {
  # Validate that we're on Windows
  if $facts['os']['family'] != 'windows' {
    fail('The winget class is only supported on Windows operating systems.')
  }

  # Warn on OS releases outside the supported list (see metadata.json).
  # String comparison only: os.release values are strings in facts.
  $os_major = $facts['os']['release']['major']
  $supported_releases = ['10', '11', '2019', '2022', '2025']
  if !($os_major in $supported_releases) {
    warning('winget requires Windows 10, Windows 11, Windows Server 2019, Windows Server 2022 or Windows Server 2025. Current OS may not be supported.')
  }

  # Backward compatibility: if version is specified, use it for ensure
  if $version and $version =~ /^\d+(\.\d+)+$/ {
    $real_ensure = $version
  } else {
    $real_ensure = $ensure
  }

  # Main winget installation logic
  if $enable_winget {
    if $real_ensure == 'absent' {
      # Uninstall winget via winget itself (if available) or AppX removal.
      # No collector chaining here: this package itself uses the winget
      # provider, so chaining to Package <| provider == winget |> would be
      # a dependency cycle on itself.
      package { 'Microsoft.DesktopAppInstaller':
        ensure   => 'absent',
        provider => 'winget',
      }
    } else {
      # Dependencies only make sense together with a local bundle.
      if !$dependencies.empty and $source_path == undef {
        fail('winget: dependencies requires source_path to be set.')
      }
      # If source_path is provided, only the local file is installed: it
      # takes precedence over `source`, so no msstore/github download is
      # attempted and the two installations cannot race each other.
      if $source_path {
        winget::install::local { 'winget_local':
          ensure       => $real_ensure,
          source_path  => $source_path,
          dependencies => $dependencies,
        }
      } else {
        # Install winget using the selected source
        case $source {
          'msstore': {
            winget::install::msstore { 'winget':
              ensure                   => $real_ensure,
              accept_source_agreements => $accept_source_agreements,
              proxy                    => $proxy,
            }
          }
          'github': {
            winget::install::github { 'winget':
              ensure => $real_ensure,
              proxy  => $proxy,
            }
          }
          'auto': {
            # The msstore CDN always serves the latest App Installer and
            # cannot honor a version pin: with a pinned version, go straight
            # to github so `ensure => '1.8.2391'` actually converges.
            if $real_ensure =~ /^\d+(\.\d+)+$/ {
              winget::install::github { 'winget':
                ensure => $real_ensure,
                proxy  => $proxy,
              }
            } else {
              # msstore first, github as independent fallback (no chaining
              # arrow: with `->`, a failed msstore exec would skip the
              # fallback, and a successful one would make it a no-op, so the
              # fallback would never run). Both execs carry an `unless`
              # presence guard; the catalog applies msstore first, and the
              # fallback still runs when msstore fails.
              winget::install::msstore { 'winget':
                ensure                   => $real_ensure,
                accept_source_agreements => $accept_source_agreements,
                proxy                    => $proxy,
              }
              winget::install::github { 'winget_fallback':
                ensure => $real_ensure,
                proxy  => $proxy,
              }
            }
          }
          default: {
            fail("Invalid source '${source}'. Valid values: 'msstore', 'github', 'auto'")
          }
        }
      }
    }
  }
}
