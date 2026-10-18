# frozen_string_literal: true

# @summary Pin (hold) a winget package against unattended upgrades.
#
# Manages `winget pin add/remove` for a single package ID. This covers the
# advanced pin flavors the provider `holdable` feature (`mark => hold`, plain
# pinning) does not: blocking pins (`blocking => true`, which also block
# explicit `winget upgrade --id` unless `--force` is used) and gating pins
# (`version => '1.2.*'`, which restrict upgrades to a version range).
#
# A plain (non-blocking, unversioned) pin excludes the package from
# `winget upgrade --all` while still allowing explicit upgrades, which is
# exactly the `mark => hold` semantic; `winget::upgrade` additionally skips
# pinned IDs automatically (`respect_pins`, backed by the `winget_pins` fact).
# Do not combine a blocking pin with `ensure => latest` on the same package:
# the explicit upgrade would fail until the pin is removed.
#
# The pin presence guard is ID-based: changing `version` or `blocking` on an
# existing pin requires removing it first (`ensure => absent`, then
# `present` again).
#
# Nothing is declared while winget itself is absent (fresh bootstrap): order
# pins after the bootstrap class so they converge on the next run:
#
#   Class['winget'] -> Winget::Pin <| |>
#
# @param ensure
#   Whether the pin exists (`present`) or not (`absent`).
# @param version
#   Optional gating version (`'1.2.3'` or range `'1.2.*'`). Undef (default)
#   means a plain pin without version gating.
# @param blocking
#   Whether the pin blocks even explicit upgrades. Default: false (plain
#   pinning: only `upgrade --all` skips the package).
# @param source
#   Optional source scoping the pin (`--source`). Undef (default) means all
#   sources.
#
# @example Hold back Chrome with a blocking pin
#   winget::pin { 'Google.Chrome':
#     ensure   => present,
#     blocking => true,
#   }
#
# @example Gate PowerToys to the 0.70 patch range
#   winget::pin { 'Microsoft.PowerToys':
#     ensure  => present,
#     version => '0.70.*',
#   }
define winget::pin (
  Enum['present', 'absent'] $ensure = 'present',
  Optional[String[1]] $version = undef,
  Boolean $blocking = false,
  Optional[String[1]] $source = undef,
) {
  # Fully qualified PowerShell: exec commands must be qualified and the
  # winget alias is unavailable in the SYSTEM context.
  $powershell = 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
  $winget = $facts['winget_path']

  if $winget {
    # Escape single quotes for PowerShell single-quoted literals.
    $safe_title = regsubst($title, "'", "''", 'G')
    $safe_version = $version ? {
      undef   => undef,
      default => regsubst($version, "'", "''", 'G'),
    }
    $safe_source_param = $source ? {
      undef   => undef,
      default => regsubst($source, "'", "''", 'G'),
    }

    $version_flag = $safe_version ? {
      undef   => '',
      default => " --version '${safe_version}'",
    }
    $blocking_flag = $blocking ? {
      true    => ' --blocking',
      default => '',
    }
    $source_flag = $safe_source_param ? {
      undef   => '',
      default => " --source '${safe_source_param}'",
    }

    $pinned_check = "${powershell} -NoProfile -Command \"if (& '${winget}' pin list --id '${safe_title}' --exact --disable-interactivity | Select-String -Quiet -SimpleMatch '${safe_title}') { exit 0 } else { exit 1 }\""

    if $ensure == 'present' {
      exec { "winget-pin-add-${title}":
        command => "${powershell} -NoProfile -Command \"& '${winget}' pin add --id '${safe_title}' --exact${version_flag}${blocking_flag}${source_flag} --accept-source-agreements --disable-interactivity\"",
        unless  => $pinned_check,
        timeout => 300,
      }
    } else {
      exec { "winget-pin-remove-${title}":
        command => "${powershell} -NoProfile -Command \"& '${winget}' pin remove --id '${safe_title}' --exact --disable-interactivity\"",
        onlyif  => $pinned_check,
        timeout => 300,
      }
    }
  } else {
    # $facts['winget_path'] is nil until winget has run once (e.g. a
    # fresh node mid-bootstrap): silently skipping would hide this pin
    # until a later run with no trace in the report.
    warning("winget::pin[${title}]: winget_path fact is not yet set (winget not bootstrapped on this node yet); this pin will be applied on a later run once the fact is present. Order pins after Class['winget'] to avoid surprises.")
  }
}
