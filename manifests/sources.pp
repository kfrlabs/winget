# frozen_string_literal: true

# @summary Manage winget package sources from a Hiera-friendly hash.
#
# Reads source declarations from the `entries` hash (Hiera key
# `winget::sources::entries`, see `Winget::SourcesHash`) and declares one
# `winget::source` resource per entry. The common case is driven from the
# main class (`winget::sources` Hiera key, which declares this class
# automatically): use `include winget`.
# Entries accept either a shorthand URL
# string or a full `Winget::SourceEntry` hash (private REST sources, trust level,
# explicit sources, auth headers).
#
# With `reset_defaults => true`, non-default sources missing from `entries`
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
# @param entries
#   Sources to manage, keyed by source name. Values are either a shorthand
#   URL string or a `Winget::SourceEntry` hash.
# @param reset_defaults
#   Whether to reset winget sources to the defaults plus `entries`
#   (`winget source reset --force`) before adding declared sources.
#   Default: false (unmanaged sources are left alone).
# @param default_sources
#   Source names treated as defaults by the reset guard. Default:
#   `['msstore', 'winget', 'winget-font']`.
#
# @example Private REST source from Hiera (preferred)
#   # hiera.yaml:
#   # winget::sources:
#   #   contoso:
#   #     url: https://winget.contoso.example.com/cache
#   #     source_type: Microsoft.Rest
#   #     trust_level: trusted
#   include winget
#
# @example Private REST source via the sub-class directly
#   # hiera.yaml:
#   # winget::sources::entries:
#   #   contoso:
#   #     url: https://winget.contoso.example.com/cache
#   #     source_type: Microsoft.Rest
#   #     trust_level: trusted
#   include winget::sources
#   Class['winget'] -> Class['winget::sources']
class winget::sources (
  Winget::SourcesHash $entries = {},
  Boolean $reset_defaults = false,
  Array[String[1]] $default_sources = ['msstore', 'winget', 'winget-font'],
) {
  if $facts['os']['family'] != 'windows' {
    fail('The winget::sources class is only supported on Windows operating systems.')
  }

  # Hardening (issue #74): expected names are interpolated into single-quoted
  # PowerShell literals inside a double-quoted reset-guard -Command string,
  # so a double quote would terminate the outer string and break (or alter)
  # the reset decision — including an unintended `source reset --force`
  # scope. (Entries keys/URLs are also validated transitively by the
  # `winget::source` guards via `create_resources` below; this fails them
  # fast at the entry point with the class parameter named.)
  ($default_sources + $entries.keys).each |$source_name| {
    if $source_name =~ /"/ {
      fail('winget::sources: default_sources and entries keys must not contain double quotes (they terminate the PowerShell -Command string).')
    }
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
      $expected = ($default_sources + $entries.keys).unique
      # Escape single quotes for PowerShell single-quoted literals.
      $quoted = $expected.map |$source_name| {
        $safe_name = regsubst($source_name, "'", "''", 'G')
        "'${safe_name}'"
      }
      $expected_list = join($quoted, ', ')
      exec { 'winget-source-reset':
        command => "${powershell} -NoProfile -Command \"& '${winget}' source reset --force --disable-interactivity\"",
        onlyif  => "${powershell} -NoProfile -Command \"\$names = & '${winget}' source list --disable-interactivity | Select-Object -Skip 2 | ForEach-Object { \$_.Split(' ')[0] } | Where-Object { \$_ -and \$_ -notmatch '^-' }; \$expected = @(${expected_list}); \$extra = \$names | Where-Object { \$expected -notcontains \$_ }; if (\$extra) { exit 0 } else { exit 1 }\"",
        timeout => 300,
      }
    }

    $pairs = $entries.map |$name, $spec| {
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
  } else {
    # $facts['winget_path'] is nil until winget has run once (e.g. a
    # fresh node mid-bootstrap): silently skipping would hide these
    # sources until a later run with no trace in the report.
    warning("winget::sources: winget_path fact is not yet set (winget not bootstrapped on this node yet); sources will be managed on a later run once the fact is present. Order sources after Class['winget'] to avoid surprises.")
  }
}
