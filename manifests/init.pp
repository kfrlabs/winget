# frozen_string_literal: true

# @summary Manages the installation and configuration of the Windows Package Manager (winget).
#
# Ensures winget is available on the system so that the `winget` package provider can function.
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
#     source_path => 'C:\Sources\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle',
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
#   Installation source for winget. Valid values: 'cdn' (Microsoft CDN
#   distribution of App Installer, preferred), 'github' (GitHub releases),
#   or 'auto' (tries cdn first, falls back to github). Default: 'auto'.
#   'msstore' is a deprecated alias for 'cdn' (same aka.ms/getwinget
#   download, not the Store app): it still works but logs a deprecation
#   warning, use 'cdn' instead. When a specific version is requested via
#   `ensure`/`version`, `auto` uses `github` directly: the Microsoft CDN
#   always serves the latest App Installer, so cdn cannot honor a pin.
#
# @param source_path
#   Local filesystem path to a winget AppX/MSIX bundle file. When specified,
#   this takes precedence over `source`: only the local file is installed and
#   no `cdn`/`github` download is attempted. Use for offline installation.
#   The file must be a valid Microsoft.DesktopAppInstaller package.
#
# @param dependencies
#   Array of local AppX/MSIX files installed before the `source_path` bundle
#   (e.g. VCLibs / UI.Xaml framework packages for offline hosts). Only used
#   together with `source_path`.
#
# @param proxy
#   Proxy URL for downloading winget (e.g., 'http://proxy.example.com:8080'). Only used
#   when downloading from Microsoft CDN or GitHub. Default: undef (uses system proxy).
#
# @param accept_source_agreements
#   Whether to automatically accept source agreements during bootstrap. Default: true.
#
# @param enable_winget
#   Whether to manage winget installation. Set to false to disable the bootstrap class
#   while keeping the provider available. Default: true.
#
# @param packages
#   Packages to manage, keyed by winget ID (see `Winget::PackagesHash`).
#   Hiera key: `winget::packages`. Declares `winget::packages`
#   automatically when non-empty, so `include winget` is enough.
#
# @param packages_schedule
#   Default Puppet `schedule` forwarded to `winget::packages`.
#
# @param packages_reboot_resource
#   Optional `reboot` resource title forwarded to `winget::packages`.
#
# @param sources
#   Sources to manage, keyed by source name (see `Winget::SourcesHash`).
#   Hiera key: `winget::sources`. Declares `winget::sources`
#   automatically when non-empty (or when `sources_reset_defaults` is true).
#
# @param sources_reset_defaults
#   Whether to reset winget sources before adding `sources`.
#
# @param sources_default_sources
#   Source names treated as defaults by the reset guard.
#
# @param settings
#   Arbitrary settings.json content (see `winget::settings`).
#   Hiera key: `winget::settings`. Declares `winget::settings`
#   automatically when non-empty.
#
# @param experimental_features
#   Experimental features forwarded to `winget::settings`.
#   Hiera key: `winget::experimental_features`.
#
# @param settings_path
#   Explicit settings.json path forwarded to `winget::settings`.
#
# @example Manage packages from Hiera
#   # hiera.yaml:
#   # winget::packages:
#   #   Git.Git:
#   #     ensure: present
#   #     scope: machine
#   include winget
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
  Enum['msstore', 'cdn', 'github', 'auto'] $source = 'auto',
  Optional[String] $source_path     = undef,
  Array[String] $dependencies       = [],
  Optional[String] $proxy           = undef,
  Boolean $accept_source_agreements = true,
  Boolean $enable_winget            = true,
  Winget::PackagesHash $packages = {},
  Optional[String[1]] $packages_schedule = undef,
  Optional[String[1]] $packages_reboot_resource = undef,
  Winget::SourcesHash $sources = {},
  Boolean $sources_reset_defaults = false,
  Array[String[1]] $sources_default_sources = ['msstore', 'winget', 'winget-font'],
  Hash $settings = {},
  Hash $experimental_features = {},
  Optional[String] $settings_path = undef,
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
      # takes precedence over `source`, so no cdn/github download is
      # attempted and the two installations cannot race each other.
      if $source_path {
        winget::install::local { 'winget_local':
          ensure       => $real_ensure,
          source_path  => $source_path,
          dependencies => $dependencies,
        }
      } else {
        # `cdn` is the preferred name; `msstore` is a deprecated alias for
        # the same aka.ms/getwinget download (not the Store app).
        if $source == 'msstore' {
          warning("winget: source 'msstore' is deprecated, use source => 'cdn' instead (same Microsoft CDN download).")
        }
        # Install winget using the selected source
        case $source {
          'msstore', 'cdn': {
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
            # The cdn always serves the latest App Installer and
            # cannot honor a version pin: with a pinned version, go straight
            # to github so `ensure => '1.8.2391'` actually converges.
            if $real_ensure =~ /^\d+(\.\d+)+$/ {
              winget::install::github { 'winget':
                ensure => $real_ensure,
                proxy  => $proxy,
              }
            } else {
              # cdn first, github as independent fallback (no chaining
              # arrow: with `->`, a failed cdn exec would skip the
              # fallback, and a successful one would make it a no-op, so the
              # fallback would never run). Both execs carry an `unless`
              # presence guard; the catalog applies cdn first, and the
              # fallback still runs when cdn fails.
              # `fail_on_error => false`: a failed cdn attempt must not mark
              # Class['winget'] as failed, otherwise every resource ordered
              # after it is skipped even when the github fallback succeeds.
              winget::install::msstore { 'winget':
                ensure                   => $real_ensure,
                accept_source_agreements => $accept_source_agreements,
                proxy                    => $proxy,
                fail_on_error            => false,
              }
              winget::install::github { 'winget_fallback':
                ensure => $real_ensure,
                proxy  => $proxy,
              }
            }
          }
          default: {
            fail("Invalid source '${source}'. Valid values: 'cdn', 'github', 'auto' ('msstore' is a deprecated alias for 'cdn')")
          }
        }
      }
    }
  }

  # Fleet configuration from the main class (Hiera keys `winget::packages`,
  # `winget::sources`, `winget::settings`): declare the sub-classes only when
  # there is something to manage. An explicit `include winget::packages`
  # elsewhere wins via the `defined()` guard instead of failing with a
  # duplicate declaration.
  if !$packages.empty and !defined(Class['winget::packages']) {
    # `require` orders the sub-class after everything contained in this
    # class (the bootstrap execs), so packages never run before winget is
    # installed. The sub-class is not contained here: that would create a
    # dependency cycle with `Class['winget'] -> Package <| provider == winget |>`.
    class { 'winget::packages':
      entries         => $packages,
      schedule        => $packages_schedule,
      reboot_resource => $packages_reboot_resource,
      require         => Class['winget'],
    }
  }

  if (!$sources.empty or $sources_reset_defaults) and !defined(Class['winget::sources']) {
    class { 'winget::sources':
      entries         => $sources,
      reset_defaults  => $sources_reset_defaults,
      default_sources => $sources_default_sources,
      require         => Class['winget'],
    }
  }

  if (!$settings.empty or !$experimental_features.empty) and !defined(Class['winget::settings']) {
    class { 'winget::settings':
      config                => $settings,
      experimental_features => $experimental_features,
      settings_path         => $settings_path,
      require               => Class['winget'],
    }
  }
}
