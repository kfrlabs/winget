# frozen_string_literal: true

# @summary Manage winget package sources from a Hiera-friendly hash.
#
# Reads source declarations from the `sources` hash (automatic Hiera lookup
# via `winget::sources::sources`, see `Winget::SourcesHash`) and declares one
# `winget::source` resource per entry. Entries accept either a shorthand URL
# string or a full `Winget::SourceEntry` hash (private REST sources, trust level,
# explicit sources, auth headers).
#
# With `reset_defaults => true`, non-default sources missing from `sources`
# are removed first (`winget source reset --force`, idempotent guard included),
# then the declared sources are added. The defaults themselves
# (`msstore`, `winget`, `winget-font`, overridable via `default_sources`) are
# never removed.
#
# Nothing is declared while winget itself is absent (fresh bootstrap): order
# sources after the bootstrap class so they converge on the next run:
#
#   Class['winget'] -> Class['winget::sources']
#
# @param sources
#   Sources to manage, keyed by source name. Values are either a shorthand
#   URL string or a `Winget::SourceEntry` hash.
# @param reset_defaults
#   Whether to reset winget sources to the defaults plus `sources`
#   (`winget source reset --force`) before adding declared sources.
#   Default: false (unmanaged sources are left alone).
# @param default_sources
#   Source names treated as defaults by the reset guard. Default:
#   `['msstore', 'winget', 'winget-font']`.
#
# @example Private REST source from Hiera
#   # hiera.yaml:
#   # winget::sources::sources:
#   #   contoso:
#   #     url: https://winget.contoso.example.com/cache
#   #     source_type: Microsoft.Rest
#   #     trust_level: trusted
#   include winget::sources
#   Class['winget'] -> Class['winget::sources']
class winget::sources (
  Winget::SourcesHash $sources = {},
  Boolean $reset_defaults = false,
  Array[String[1]] $default_sources = ['msstore', 'winget', 'winget-font'],
) {
  if $facts['os']['family'] != 'windows' {
    fail('The winget::sources class is only supported on Windows operating systems.')
  }

  # Fully qualified PowerShell: exec commands must be qualified and the
  # winget alias is unavailable in the SYSTEM context.
  $powershell = 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
  $winget = $facts['winget_path']

  if $winget {
    $require_hash = $reset_defaults ? {
      true    => { 'require' => Exec['winget-source-reset'] },
      default => {},
    }

    if $reset_defaults {
      # Sources listed by `winget source list` (header and separator skipped,
      # first column is the name) beyond the expected set trigger the reset.
      $expected = ($default_sources + $sources.keys).unique
      $quoted = $expected.map |$source_name| { "'${source_name}'" }
      $expected_list = join($quoted, ', ')
      exec { 'winget-source-reset':
        command => "${powershell} -NoProfile -Command \"& '${winget}' source reset --force --disable-interactivity\"",
        onlyif  => "${powershell} -NoProfile -Command \"\$names = & '${winget}' source list --disable-interactivity | Select-Object -Skip 2 | ForEach-Object { \$_.Split(' ')[0] } | Where-Object { \$_ -and \$_ -notmatch '^-' }; \$expected = @(${expected_list}); \$extra = \$names | Where-Object { \$expected -notcontains \$_ }; if (\$extra) { exit 0 } else { exit 1 }\"",
        timeout => 300,
      }
    }

    $pairs = $sources.map |$name, $spec| {
      if $spec =~ String {
        # Assigned (not a bare line-start `[`) to satisfy
        # manifest_whitespace_opening_bracket_before.
        $entry = [$name, { 'url' => $spec } + $require_hash]
      } else {
        $entry = [$name, $spec + $require_hash]
      }
      $entry
    }

    create_resources('winget::source', Hash($pairs))
  }
}
