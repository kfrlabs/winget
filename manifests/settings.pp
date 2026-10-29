# frozen_string_literal: true

# @summary Manage the winget client configuration (settings.json).
#
# Writes `%LOCALAPPDATA%/Packages/Microsoft.DesktopAppInstaller_*/LocalState/settings.json`
# for the Puppet agent account (SYSTEM by default, i.e.
# `C:/Windows/System32/config/systemprofile/...`), merging `config` with
# `experimental_features` under the `experimentalFeatures` key. Hiera key
# `winget::settings::config`. The common case is driven from the main class
# (`winget::settings` Hiera key, which declares this class automatically). Accepts any
# documented winget setting (`source.autoUpdateIntervalInMinutes`,
# `installBehavior.preferences.scope`, `telemetry.disable`, ...): see
# `winget settings` and https://aka.ms/winget-settings.
#
# This is also where the fleet-wide install scope belongs: with the agent
# running as SYSTEM, `installBehavior.preferences.scope => 'machine'` keeps
# agent-driven installs visible to `winget list` without repeating
# `scope => 'machine'` on every package (see `winget::packages`).
#
# Nothing is managed while winget itself is absent (fresh bootstrap): order
# settings after the bootstrap class (automatic when driven via `include
# winget` with the `winget::settings` Hiera key):
#
#   Class['winget'] -> Class['winget::settings']
#
# The managed file is replaced wholesale on every run: `config` and
# `experimental_features` are NOT merged with whatever settings.json
# already contains on the node, they fully define its content. Declare
# every key you care about (including ones a previous manual `winget
# settings` edit may have set) or they will be dropped.
#
# @param config
#   Arbitrary settings.json content merged as-is (e.g.
#   `{ 'telemetry' => { 'disable' => true } }`).
# @param experimental_features
#   Experimental features merged under the `experimentalFeatures` key,
#   overriding any `experimentalFeatures` entry of `config`.
# @param settings_path
#   Explicit settings.json path (e.g. to manage another user's file).
#   Undef (default) manages the SYSTEM profile file used by the agent.
#
# @example Disable telemetry and prefer machine scope
#   class { 'winget::settings':
#     config => {
#       'telemetry'       => { 'disable' => true },
#       'installBehavior' => { 'preferences' => { 'scope' => 'machine' } },
#     },
#   }
#
# @example Enable an experimental feature
#   class { 'winget::settings':
#     experimental_features => { 'resume' => true },
#   }
class winget::settings (
  Hash $config = {},
  Hash $experimental_features = {},
  Optional[String] $settings_path = undef,
) {
  if $facts['os']['family'] != 'windows' {
    fail('The winget::settings class is only supported on Windows operating systems.')
  }

  # Hardening (issue #74): the path is interpolated into a single-quoted
  # PowerShell literal inside a double-quoted -Command string, so a double
  # quote would terminate the outer string and break (or alter) the command.
  # Double quotes are never valid in Windows paths: fail fast at compile
  # time instead of breaking confusingly at runtime.
  if $settings_path and $settings_path =~ /"/ {
    fail('winget::settings: settings_path must not contain double quotes (they terminate the PowerShell -Command string).')
  }

  if $experimental_features.empty {
    $merged = $config
  } else {
    $merged = $config + { 'experimentalFeatures' => $experimental_features }
  }

  $resolved_path = $settings_path ? {
    undef   => 'C:/Windows/System32/config/systemprofile/AppData/Local/Packages/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe/LocalState/settings.json',
    default => $settings_path,
  }

  # Fully qualified PowerShell: exec commands must be qualified and the
  # winget alias is unavailable in the SYSTEM context.
  $powershell = 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'

  # The LocalState directory under the SYSTEM profile is created by winget
  # itself the first time it runs; on a freshly bootstrapped node (or a
  # custom $settings_path) it may not exist yet, which would otherwise make
  # the `file` resource below fail with "parent directory does not exist".
  $parent_dir = regsubst($resolved_path, '/[^/]+$', '')
  # Escape single quotes for PowerShell single-quoted literals.
  $safe_parent_dir = regsubst($parent_dir, "'", "''", 'G')

  if $facts['winget_path'] {
    exec { 'winget-settings-ensure-localstate-dir':
      command => "${powershell} -NoProfile -Command \"New-Item -ItemType Directory -Force -Path '${safe_parent_dir}' | Out-Null\"",
      unless  => "${powershell} -NoProfile -Command \"if (Test-Path -LiteralPath '${safe_parent_dir}') { exit 0 } else { exit 1 }\"",
      timeout => 60,
    }

    # Rendered with inline_template (core function) rather than to_json so
    # this module keeps zero dependencies (no stdlib required for offline
    # Windows fleets). The full file is overwritten on every run; see the
    # class documentation above.
    file { $resolved_path:
      ensure  => file,
      content => inline_template('<%= require "json"; JSON.generate(@merged) %>'),
      require => Exec['winget-settings-ensure-localstate-dir'],
    }
  } else {
    # $facts['winget_path'] is nil until winget has run once (e.g. a fresh
    # node mid-bootstrap): silently skipping would hide this class until a
    # later run with no trace in the report.
    warning('winget::settings: winget_path fact is not yet set (winget not bootstrapped on this node yet); settings.json will be managed on a later run once the fact is present. Order this class after Class[\'winget\'] to avoid surprises.')
  }
}
