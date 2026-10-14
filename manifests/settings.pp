# frozen_string_literal: true

# @summary Manage the winget client configuration (settings.json).
#
# Writes `%LOCALAPPDATA%/Packages/Microsoft.DesktopAppInstaller_*/LocalState/settings.json`
# for the Puppet agent account (SYSTEM by default, i.e.
# `C:/Windows/System32/config/systemprofile/...`), merging `settings` with
# `experimental_features` under the `experimentalFeatures` key. Accepts any
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
# settings after the bootstrap class:
#
#   Class['winget'] -> Class['winget::settings']
#
# @param settings
#   Arbitrary settings.json content merged as-is (e.g.
#   `{ 'telemetry' => { 'disable' => true } }`).
# @param experimental_features
#   Experimental features merged under the `experimentalFeatures` key,
#   overriding any `experimentalFeatures` entry of `settings`.
# @param settings_path
#   Explicit settings.json path (e.g. to manage another user's file).
#   Undef (default) manages the SYSTEM profile file used by the agent.
#
# @example Disable telemetry and prefer machine scope
#   class { 'winget::settings':
#     settings => {
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
  Hash $settings = {},
  Hash $experimental_features = {},
  Optional[String] $settings_path = undef,
) {
  if $facts['os']['family'] != 'windows' {
    fail('The winget::settings class is only supported on Windows operating systems.')
  }

  if $experimental_features.empty {
    $merged = $settings
  } else {
    $merged = $settings + { 'experimentalFeatures' => $experimental_features }
  }

  $resolved_path = $settings_path ? {
    undef   => 'C:/Windows/System32/config/systemprofile/AppData/Local/Packages/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe/LocalState/settings.json',
    default => $settings_path,
  }

  if $facts['winget_path'] {
    # Rendered with inline_template (core function) rather than to_json so
    # this module keeps zero dependencies (no stdlib required for offline
    # Windows fleets).
    file { $resolved_path:
      ensure  => file,
      content => inline_template('<%= require "json"; JSON.generate(@merged) %>'),
    }
  }
}
