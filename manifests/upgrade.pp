# frozen_string_literal: true

# @summary Upgrades every winget package with an available update.
#
# Execution model / compatibility (read first under master/agent):
#
# | Setup | Behaviour |
# | ----- | --------- |
# | `puppet apply` | Fully functional: `winget::upgrades()` runs on the node where winget exists. |
# | master/agent with `winget_upgrades` fact enabled (`WINGET_UPGRADES_ENABLED=true` on the agent) | Functional: on-demand enumeration runs on the server (no winget, returns `undef`), the class falls back to the fact rows with a warning. |
# | master/agent without the fact (default) | Manages nothing: both enumeration (`undef` on the server) and fact rows are empty; the class logs a warning and declares no `package` resources. Enable the fact (see below) or run `puppet apply`. |
#
# Agent-side execution decision: a Deferred function or `exec`-based upgrade
# was evaluated and rejected for this class. Enumeration stays at
# compilation time (function, then fact fallback) so upgrades remain regular
# `package` resources with reporting, noop and `--tags` support; the Bolt
# tasks `winget::upgrade_now` / `winget::list_upgrades` already cover
# on-demand agent-side execution without catalog changes.
#
# Enumerates upgrade rows on demand through the `winget::upgrades` function
# (one hash with `id`, `current_version` and `available_version` per
# package) and declares one `package` resource with `ensure => latest`
# (winget provider) per ID. Upgrades are
# therefore regular Puppet resources (reporting, noop, `--tags`) instead of
# an out-of-band scheduled task script.
#
# Enumeration runs only when this class is declared: nodes without the class
# never pay for a `winget upgrade` source round-trip. The opt-in
# `winget_upgrades` fact (`WINGET_UPGRADES_ENABLED=true`) is only a fallback
# for server-side compilation, where the function runs on the server without
# winget, and standalone PuppetDB inventory. The function returns `undef`
# when winget is absent or the query fails (fall back to the fact rows with
# a warning) and `[]` only when the query succeeds with no rows (authoritative,
# no fallback). A stale fact (e.g. TTL-cached)
# is harmless: `ensure => latest` is idempotent, so IDs with no real upgrade
# stay in sync.
#
# Consent note: enumeration passes `--accept-source-agreements`, kept
# deliberately so winget can never prompt (or stall where nothing answers)
# on nodes that never opted in; the same flag is used by the provider and
# the Bolt tasks for the upgrades applied here.
#
# A package already declared elsewhere in the catalog (e.g. `package {
# 'Git.Git': ensure => present }`) is left alone: redeclaring it would be a
# duplicate-declaration error. Such packages are therefore skipped here; to
# upgrade them, either remove the other declaration or list the ID in
# `exclude` and manage its upgrade yourself. Note the `defined()` guard only
# sees resources parsed before this class, so declare `winget::upgrade`
# after your own `package` resources (or rely on `exclude`).
#
# A Puppet `schedule` metaparameter only skips the `package` resources outside
# the window, it does not skip enumeration. When upgrades are confined to a
# maintenance window, cache the opt-in fact with a TTL in facter.conf so the
# inventory cost is paid at most once per window
# (`facts: { ttls: [{ "winget_upgrades": "7 days" }] }`).
#
# Ordering with the bootstrap class is done at the call site:
#
#   Class['winget'] -> Class['winget::upgrade']
#
# @param exclude
#   Winget IDs never upgraded (case-insensitive).
# @param only
#   When non-empty, upgrade only these winget IDs (case-insensitive).
#   Combined with `exclude`: an ID must be in `only` and not in `exclude`.
# @param respect_pins
#   Whether pinned packages (`winget pin`, see the `winget_pins` fact and
#   `winget::pin`) are skipped. Default: true. This is the upgrade-side
#   counterpart of the provider `holdable` feature and is more robust than
#   `exclude` alone: pins travel with the node, not with this declaration.
#   Set to false to upgrade pinned packages explicitly.
# @param reboot_resource
#   Optional title of a `reboot` resource (puppetlabs/reboot, declared by the
#   caller) notified by every managed package, so a pending reboot requested
#   by an installer (winget exit `0x8A150109`/`0x8A15010A`/`0x8A15010B`) is honored. Undef (default)
#   means no reboot wiring: upgrades still succeed with a warning, exactly
#   like the provider default.
# @param package_schedule
#   Name of a Puppet `schedule` resource applied as metaparameter to every
#   managed package. Declare the resource yourself, or set `manage_schedule`
#   to have this class declare it. Undef (default) means no schedule: packages
#   are enforced on every agent run.
# @param manage_schedule
#   Whether this class declares `schedule { $_schedule: ... }` from the
#   `schedule_*` parameters below.
# @param schedule_name
#   Name used for the managed schedule when `package_schedule` is undef.
# @param schedule_period
#   `schedule` period.
# @param schedule_range
#   `schedule` range, e.g. `'3 - 5'` (03:00-05:00).
# @param schedule_weekday
#   `schedule` weekday, only used when `schedule_period` is `weekly`.
# @param schedule_repeat
#   `schedule` repeat: how many times the resources may be enforced inside
#   the window.
#
# @example Upgrade everything on every run
#   include winget::upgrade
#
# @example Weekly window with exclusions, pins respected, reboot wired
#   reboot { 'maintenance-reboot':
#     when => pending,
#   }
#
#   class { 'winget::upgrade':
#     exclude          => ['Google.Chrome'],
#     manage_schedule  => true,
#     schedule_period  => 'weekly',
#     schedule_weekday => 'Sunday',
#     schedule_range   => '3 - 5',
#     reboot_resource  => 'maintenance-reboot',
#   }
#
# @example Upgrade only selected packages, if installed
#   class { 'winget::upgrade':
#     only => ['Google.Chrome'],
#   }
#   # Hiera equivalent (automatic parameter lookup):
#   # winget::upgrade::only:
#   #   - Google.Chrome
#   # Absent IDs declare no resource and are never installed (unlike
#   # `package { ensure => latest }`), because IDs are matched against the
#   # on-demand enumeration which only lists installed packages.
#
# @example Reuse a schedule declared elsewhere
#   schedule { 'maintenance-window':
#     period  => weekly,
#     weekday => 'Sunday',
#     range   => '3 - 5',
#     repeat  => 1,
#   }
#
#   class { 'winget::upgrade':
#     package_schedule => 'maintenance-window',
#   }
class winget::upgrade (
  Array[String[1]] $exclude = [],
  Array[String[1]] $only = [],
  Boolean $respect_pins = true,
  Optional[String[1]] $reboot_resource = undef,
  Optional[String[1]] $package_schedule = undef,
  Boolean $manage_schedule = false,
  String[1] $schedule_name = 'winget-upgrade-window',
  Enum['hourly', 'daily', 'weekly', 'monthly'] $schedule_period = 'weekly',
  String[1] $schedule_range = '3 - 5',
  String[1] $schedule_weekday = 'Sunday',
  Integer[1] $schedule_repeat = 1,
) {
  if $facts['os']['family'] != 'windows' {
    fail('The winget::upgrade class is only supported on Windows operating systems.')
  }

  if $manage_schedule {
    $_schedule = $package_schedule ? {
      undef   => $schedule_name,
      default => $package_schedule,
    }

    # `weekday` is only valid on a weekly schedule.
    if $schedule_period == 'weekly' {
      schedule { $_schedule:
        period  => $schedule_period,
        range   => $schedule_range,
        weekday => $schedule_weekday,
        repeat  => $schedule_repeat,
      }
    } else {
      schedule { $_schedule:
        period => $schedule_period,
        range  => $schedule_range,
        repeat => $schedule_repeat,
      }
    }
  } else {
    $_schedule = $package_schedule
  }

  # Winget IDs are case-insensitive: compare lowercased. The enumeration
  # returns structured rows; accept plain String IDs too (older agents).
  # Live on-demand enumeration wins: `undef` (absent/error) falls back to the
  # fact rows for server-side compilation (where the function runs without
  # winget); `[]` (successful query with no rows) is authoritative and does
  # not fall back. A fallback emits a warning, and an empty result emits a
  # notice, so the no-op is visible in reports without failing the catalog.
  $fact_upgrades = $facts['winget_upgrades'] ? {
    undef   => [],
    default => $facts['winget_upgrades'],
  }
  $live_upgrades = winget::upgrades()
  if $live_upgrades == undef {
    warning("winget::upgrade: on-demand enumeration unavailable (winget absent or query failed, or server-side compilation without winget); falling back to 'winget_upgrades' fact rows. If the fact is disabled, enable it with WINGET_UPGRADES_ENABLED=true on the agent (and remove any 'winget_upgrades' facter blocklist entry); rows may still be stale on server-side compilation (TTL).")
  }
  $raw_upgrades = $live_upgrades ? {
    undef   => $fact_upgrades,
    default => $live_upgrades,
  }
  if $raw_upgrades.empty {
    notice("winget::upgrade: no upgradable packages found (on-demand enumeration and 'winget_upgrades' fact yielded no rows); the node may be up to date, or enumeration may have failed - check winget and source configuration if unexpected.")
  }
  $upgradable = $raw_upgrades.map |$row| {
    $row =~ String[1] ? { true => $row, default => $row =~ Hash ? { true => $row['id'], default => undef } }
  }.filter |$id| { $id =~ String[1] }
  $pinned = $facts['winget_pins'] ? {
    undef   => [],
    default => $facts['winget_pins'],
  }
  $only_lc = $only.map |$id| { $id.downcase }
  $exclude_lc = $exclude.map |$id| { $id.downcase }
  $pinned_lc = $pinned.filter |$id| { $id =~ String[1] }.map |$id| { $id.downcase }
  $targets = $upgradable.filter |$id| {
    ($only_lc.empty or $id.downcase in $only_lc) and !($id.downcase in $exclude_lc) and !($respect_pins and ($id.downcase in $pinned_lc))
  }.unique

  $schedule_hash = $_schedule ? {
    undef   => {},
    default => { 'schedule' => $_schedule },
  }
  $notify_hash = $reboot_resource ? {
    undef   => {},
    default => { 'notify' => Reboot[$reboot_resource] },
  }
  $pairs = $targets.filter |$id| { !defined(Package[$id]) }.map |$id| {
    [$id, { 'ensure' => 'latest', 'provider' => 'winget' } + $schedule_hash + $notify_hash]
  }
  create_resources('package', Hash($pairs))
}
