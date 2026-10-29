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
# The pin presence guard is ID-based, but the declared attributes also
# converge: when `blocking` or `version` of an existing pin drift from the
# declaration, the stale pin is removed and re-added in the same run (the
# removal is ordered before the add, and the add guard is re-evaluated after
# the removal). `source` cannot be compared (`pin list` shows no source
# column), so changing only `source` on an existing pin has no effect:
# remove it (`ensure => absent`) and re-add it instead. On winget builds
# whose `pin list` renders no pin-type column, the `blocking` comparison
# degrades to presence-only and a changed `blocking` flag behaves like
# before (documented limitation, warned about in the reference).
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
#   means a plain pin without version gating. Changing it on an existing pin
#   removes and re-adds the pin so the catalog converges in one run.
# @param blocking
#   Whether the pin blocks even explicit upgrades. Default: false (plain
#   pinning: only `upgrade --all` skips the package). Changing it on an
#   existing pin removes and re-adds the pin so the catalog converges in
#   one run.
# @param source
#   Optional source scoping the pin (`--source`). Undef (default) means all
#   sources. `pin list` exposes no source column, so changing only `source`
#   on an existing pin has no effect: remove the pin first
#   (`ensure => absent`), then re-add it.
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

  # Hardening (issue #74): interpolated values sit in single-quoted
  # PowerShell literals inside a double-quoted -Command string, so a double
  # quote would terminate the outer string and break (or alter) the command.
  # Double quotes are never valid in IDs, versions or source names: fail
  # fast at compile time instead of breaking confusingly at runtime.
  if $title =~ /"/ {
    fail("winget::pin[${title}]: title (package ID) must not contain double quotes (they terminate the PowerShell -Command string).")
  }
  if $version and $version =~ /"/ {
    fail("winget::pin[${title}]: version must not contain double quotes (they terminate the PowerShell -Command string).")
  }
  if $source and $source =~ /"/ {
    fail("winget::pin[${title}]: source must not contain double quotes (they terminate the PowerShell -Command string).")
  }

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
      # Stale-attribute guard (issue #38): `pin list --id` renders one row
      # per pin (`Name Id Version Pin`, Pin is `Pinning` or `Blocking`, the
      # Version cell carries the gating pattern). When the row exists but
      # the requested `blocking` flag or `version` differs, the pin is
      # removed here and the add below re-creates it: Puppet evaluates the
      # add guard after this removal (explicit `before`), so a drifted pin
      # converges in a single run and the next run is a no-op. `source` has
      # no column and is not compared (see the parameter docs).
      $blocking_check = $blocking ? {
        true    => "if (-not (\$raw | Select-String -Quiet -Pattern '\\sBlocking(\\s|\$)')) { \$stale = \$true };",
        default => "if (\$raw | Select-String -Quiet -Pattern '\\sBlocking(\\s|\$)') { \$stale = \$true };",
      }
      $version_stale_check = $safe_version ? {
        undef   => '',
        default => "if (-not (\$raw | Select-String -Quiet -SimpleMatch '${safe_version}')) { \$stale = \$true };",
      }
      $stale_check = "${powershell} -NoProfile -Command \"\$raw = & '${winget}' pin list --id '${safe_title}' --exact --disable-interactivity; if (-not (\$raw | Select-String -Quiet -SimpleMatch '${safe_title}')) { exit 1 }; \$stale = \$false; ${blocking_check} ${version_stale_check} if (\$stale) { exit 0 } else { exit 1 }\""

      exec { "winget-pin-remove-stale-${title}":
        command => "${powershell} -NoProfile -Command \"& '${winget}' pin remove --id '${safe_title}' --exact --disable-interactivity\"",
        onlyif  => $stale_check,
        before  => Exec["winget-pin-add-${title}"],
        timeout => 300,
      }

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
