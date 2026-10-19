# frozen_string_literal: true

# @summary Declare winget packages from a Hiera-friendly hash.
#
# Reads package declarations from the `entries` hash (Hiera key
# `winget::packages::entries`, see `Winget::PackagesHash`) and declares one
# `package` resource with the winget provider per entry. The common case is
# driven from the main class (`winget::packages` Hiera key, which declares
# this class automatically): use `include winget`.
# Entries accept either
# a shorthand ensure string or a full `Winget::Package` hash:
#
# - `ensure`, `install_options`, `uninstall_options` and `schedule` map to
#   `package` resource attributes.
# - `source`, `scope`, `architecture`, `location`, `override`,
#   `installer_type` and `locale` are translated into `winget install` /
#   `winget upgrade` flags (appended before any extra `install_options`).
# - `hold` maps to the `mark` property, i.e. `winget pin add/remove` via the
#   provider `holdable` feature (see `winget::pin` for blocking/gating pins).
# - `allow_downgrade` opts a pinned version in to the destructive
#   uninstall-then-install downgrade: `true` appends the string flag
#   `'--allow-downgrade'` to `install_options` (stripped by the provider
#   before calling winget; a string is required because the package type
#   munges `install_options` hashes to String values only). Default/undef/false means no downgrade: an
#   older plain-numeric pin falls back to `install --version` with a
#   notice. Only pinned versions can downgrade (`ensure => latest` never
#   does); suffixed versions never uninstall even with the opt-in.
#
# A package already declared elsewhere in the catalog (e.g. `package {
# 'Git.Git': ensure => present }`) is left alone: redeclaring it would be a
# duplicate-declaration error. Declare `winget::packages` after your own
# `package` resources.
#
# Scope note: the Puppet agent runs as SYSTEM. Packages installed with the
# default (user) scope are invisible to `winget list` under SYSTEM, so prefer
# `scope => 'machine'` for agent-managed packages (or set the matching
# `installBehavior` preference via `winget::settings`).
#
# Ordering with the bootstrap class is done at the call site:
#
#   Class['winget'] -> Class['winget::packages']
#
# @param entries
#   Packages to manage, keyed by winget ID. Values are either a shorthand
#   ensure string or a `Winget::Package` hash.
# @param schedule
#   Default Puppet `schedule` applied as metaparameter to every managed
#   package. A per-package `schedule` key overrides it. Undef (default) means
#   no schedule: packages are enforced on every agent run.
# @param reboot_resource
#   Optional title of a `reboot` resource (puppetlabs/reboot, declared by the
#   caller) notified by every managed package, so a pending reboot requested
#   by an installer (winget exit `0x8A150109`/`0x8A15010A`/`0x8A15010B`) is honored. Undef (default)
#   means no reboot wiring: installs still succeed with a warning, exactly
#   like the provider default.
#
# @example Manage packages from Hiera (preferred)
#   # hiera.yaml:
#   # winget::packages:
#   #   Git.Git:
#   #     ensure: present
#   #     scope: machine
#   #   Microsoft.VisualStudioCode:
#   #     ensure: '1.95.0'
#   #     hold: true
#   include winget
#
# @example Manage packages via the sub-class directly
#   # hiera.yaml:
#   # winget::packages::entries:
#   #   Git.Git:
#   #     ensure: present
#   #     scope: machine
#   include winget::packages
#   Class['winget'] -> Class['winget::packages']
#
# @example Structured install parameters
#   class { 'winget::packages':
#     entries => {
#       'Git.Git' => {
#         ensure       => '2.44.0',
#         scope        => 'machine',
#         architecture => 'x64',
#         source       => 'winget',
#       },
#     },
#   }
class winget::packages (
  Winget::PackagesHash $entries = {},
  Optional[String[1]] $schedule = undef,
  Optional[String[1]] $reboot_resource = undef,
) {
  if $facts['os']['family'] != 'windows' {
    fail('The winget::packages class is only supported on Windows operating systems.')
  }

  $notify_hash = $reboot_resource ? {
    undef   => {},
    default => { 'notify' => Reboot[$reboot_resource] },
  }

  $pairs = $entries.map |$id, $spec| {
    if $spec =~ String {
      $config = { 'ensure' => $spec }
    } else {
      $config = $spec
    }

    $ensure = $config['ensure'] ? {
      undef   => 'present',
      default => $config['ensure'],
    }

    if $config['hold'] == true and ($ensure == 'absent' or $ensure == 'purged') {
      fail("winget::packages[${id}]: hold cannot be combined with ensure => '${ensure}'.")
    }
    if $config['hold'] == true and $ensure == 'latest' {
      # A plain pin (`mark => hold`) only excludes the package from
      # `winget upgrade --all`; it does NOT stop an explicit upgrade, and
      # `ensure => latest` performs exactly that explicit upgrade on every
      # run. Combined, the pin would be silently ineffective and the
      # package would keep being upgraded despite `hold => true`. Pin the
      # package to a specific version instead, or use a blocking
      # `winget::pin` if the intent is to also refuse explicit upgrades.
      fail("winget::packages[${id}]: hold => true has no effect combined with ensure => 'latest' (an explicit upgrade still runs every run); pin to a specific version, or use a blocking winget::pin instead.")
    }
    $mark_hash = $config['hold'] ? {
      true    => { 'mark' => 'hold' },
      false   => { 'mark' => 'none' },
      default => {},
    }

    $scope_flags = $config['scope'] ? {
      undef   => [],
      default => ['--scope', $config['scope']],
    }
    $architecture_flags = $config['architecture'] ? {
      undef   => [],
      default => ['--architecture', $config['architecture']],
    }
    $location_flags = $config['location'] ? {
      undef   => [],
      default => ['--location', $config['location']],
    }
    $override_flags = $config['override'] ? {
      undef   => [],
      default => ['--override', $config['override']],
    }
    $installer_type_flags = $config['installer_type'] ? {
      undef   => [],
      default => ['--installer-type', $config['installer_type']],
    }
    $locale_flags = $config['locale'] ? {
      undef   => [],
      default => ['--locale', $config['locale']],
    }
    $source_flags = $config['source'] ? {
      undef   => [],
      default => ['--source', $config['source']],
    }
    $extra_install_options = $config['install_options'] ? {
      undef   => [],
      default => $config['install_options'],
    }
    if $config['allow_downgrade'] == true and ($ensure == 'latest' or $ensure == 'present' or $ensure == 'installed' or $ensure == 'absent' or $ensure == 'purged') {
      warning("winget::packages[${id}]: allow_downgrade => true has no effect with ensure => '${ensure}' (only a pinned older plain-numeric version can downgrade).")
    }
    $allow_downgrade_marker = $config['allow_downgrade'] ? {
      true    => ['--allow-downgrade'],
      default => [],
    }
    $install_options = $scope_flags + $architecture_flags + $location_flags + $override_flags + $installer_type_flags + $locale_flags + $source_flags + $extra_install_options + $allow_downgrade_marker
    $uninstall_options = $config['uninstall_options'] ? {
      undef   => [],
      default => $config['uninstall_options'],
    }

    $effective_schedule = $config['schedule'] ? {
      undef   => $schedule,
      default => $config['schedule'],
    }
    $schedule_hash = $effective_schedule ? {
      undef   => {},
      default => { 'schedule' => $effective_schedule },
    }

    $attributes = {
      'ensure'            => $ensure,
      'provider'          => 'winget',
      'install_options'   => $install_options,
      'uninstall_options' => $uninstall_options,
    } + $schedule_hash + $notify_hash + $mark_hash
    # Assigned (not a bare line-start `[`) to satisfy
    # manifest_whitespace_opening_bracket_before.
    $entry = [$id, $attributes]
    $entry
  }.filter |$pair| {
    !defined(Package[$pair[0]])
  }

  create_resources('package', Hash($pairs))
}
