# frozen_string_literal: true

# @summary Upgrades every winget package with an available update.
#
# Reads package IDs from the `winget_upgrades` fact and declares one `package`
# resource with `ensure => latest` (winget provider) per ID. Upgrades are
# therefore regular Puppet resources (reporting, noop, `--tags`) instead of
# an out-of-band scheduled task script.
#
# A package already declared elsewhere in the catalog (e.g. `package {
# 'Git.Git': ensure => present }`) is left alone: redeclaring it would be a
# duplicate-declaration error. Such packages are therefore skipped here; to
# upgrade them, either remove the other declaration or list the ID in
# `exclude` and manage its upgrade yourself. Note the `defined()` guard only
# sees resources parsed before this class, so declare `winget::upgrade`
# after your own `package` resources (or rely on `exclude`).
#
# The fact runs `winget upgrade` once per agent run (source round-trips, a few
# seconds) even when the packages are skipped by a `schedule` metaparameter:
# the schedule only skips the `package` resources outside the window, it does
# not skip the fact.
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
# @param schedule
#   Name of a Puppet `schedule` resource applied as metaparameter to every
#   managed package. Declare the resource yourself, or set `manage_schedule`
#   to have this class declare it. Undef (default) means no schedule: packages
#   are enforced on every agent run.
#   Note: this parameter intentionally shares its name with the Puppet
#   `schedule` metaparameter. In a resource-like class declaration (`class {
#   'winget::upgrade': schedule => '...', }`) the class parameter wins and is
#   forwarded as the metaparameter to the managed packages; this is covered
#   by unit tests on Puppet 7 and 8.
# @param manage_schedule
#   Whether this class declares `schedule { $schedule: ... }` from the
#   `schedule_*` parameters below.
# @param schedule_name
#   Name used for the managed schedule when `schedule` is undef.
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
# @example Weekly window with exclusions
#   class { 'winget::upgrade':
#     exclude          => ['Google.Chrome'],
#     manage_schedule  => true,
#     schedule_period  => 'weekly',
#     schedule_weekday => 'Sunday',
#     schedule_range   => '3 - 5',
#   }
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
#     schedule => 'maintenance-window',
#   }
class winget::upgrade (
  Array[String[1]] $exclude = [],
  Array[String[1]] $only = [],
  Optional[String[1]] $schedule = undef,
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
    $_schedule = $schedule ? {
      undef   => $schedule_name,
      default => $schedule,
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
    $_schedule = $schedule
  }

  # Winget IDs are case-insensitive: compare lowercased.
  $upgradable = $facts['winget_upgrades'] ? {
    undef   => [],
    default => $facts['winget_upgrades'],
  }
  $only_lc = $only.map |$id| { $id.downcase }
  $exclude_lc = $exclude.map |$id| { $id.downcase }
  $targets = $upgradable.filter |$id| {
    ($only_lc.empty or $id.downcase in $only_lc) and !($id.downcase in $exclude_lc)
  }.unique

  if $_schedule {
    $targets.each |$id| {
      if !defined(Package[$id]) {
        package { $id:
          ensure   => latest,
          provider => winget,
          schedule => $_schedule,
        }
      }
    }
  } else {
    $targets.each |$id| {
      if !defined(Package[$id]) {
        package { $id:
          ensure   => latest,
          provider => winget,
        }
      }
    }
  }
}
