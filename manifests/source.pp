# frozen_string_literal: true

# @summary Manage a single winget package source.
#
# Wraps `winget source add/remove` for one source (title is the source name).
# This is how enterprise private sources (e.g. an internal
# `Microsoft.Rest` source) are declared:
#
#   winget::source { 'contoso':
#     url         => 'https://winget.contoso.example.com/cache',
#     source_type => 'Microsoft.Rest',
#     trust_level => 'trusted',
#   }
#
# Nothing is declared while winget itself is absent (fresh bootstrap): order
# sources after the bootstrap class so they converge on the next run:
#
#   Class['winget'] -> Winget::Source <| |>
#
# @param ensure
#   Whether the source exists (`present`) or not (`absent`).
# @param url
#   Source URL or UNC (`winget source add --arg`). Required when
#   `ensure => present`.
# @param source_type
#   Source type (`winget source add --type`): `Microsoft.PreIndexed.Package`
#   (default) or `Microsoft.Rest`. Undef (default) lets winget decide.
# @param trust_level
#   Source trust level (`--trust-level`): `none` or `trusted`. Undef
#   (default) leaves the winget default.
# @param explicit
#   Whether the source is explicit (`--explicit`): explicit sources must be
#   targeted with `--source` on every command. Default: false. Changing this
#   on an existing source is not enforced (remove and re-add instead).
# @param header
#   Optional REST source HTTP header (`--header`). `Sensitive` so the value
#   never lands in logs or reports.
# @param accept_source_agreements
#   Whether to pass `--accept-source-agreements` when adding the source.
#   Default: true (required for non-interactive agent runs).
define winget::source (
  Enum['present', 'absent'] $ensure = 'present',
  Optional[String[1]] $url = undef,
  Optional[String[1]] $source_type = undef,
  Optional[Enum['none', 'trusted']] $trust_level = undef,
  Boolean $explicit = false,
  Optional[Sensitive[String[1]]] $header = undef,
  Boolean $accept_source_agreements = true,
) {
  # Fully qualified PowerShell: exec commands must be qualified and the
  # winget alias is unavailable in the SYSTEM context.
  $powershell = 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
  $winget = $facts['winget_path']

  if $winget {
    # A source table row starts with the source name: match it at line
    # start followed by whitespace (the header row reads `Name ...`).
    $listed_check = "${powershell} -NoProfile -Command \"& '${winget}' source list --disable-interactivity | Select-String -Quiet -Pattern '^${title}\\s'\""

    if $ensure == 'present' {
      if $url == undef {
        fail("winget::source[${title}]: url is required when ensure => present.")
      }

      $type_flag = $source_type ? {
        undef   => '',
        default => " --type '${source_type}'",
      }
      $trust_flag = $trust_level ? {
        undef   => '',
        default => " --trust-level '${trust_level}'",
      }
      $explicit_flag = $explicit ? {
        true    => ' --explicit',
        default => '',
      }
      # The header value never appears on the command line (visible in
      # debug logs, process listings and failure reports): it is passed to
      # the child process via an environment variable instead. `$env:...`
      # is written in a single-quoted Puppet string (no interpolation) so
      # it reaches PowerShell untouched and is resolved there, at runtime.
      # The environment is wrapped back into `Sensitive`: a plain array
      # holding the unwrapped value would be stored in clear text in the
      # catalog (and in PuppetDB), whereas a Sensitive resource parameter is
      # redacted from reports, logs and stored catalogs.
      if $header {
        $header_flag = ' --header $env:WINGET_SOURCE_HEADER'
        $header_environment = Sensitive(["WINGET_SOURCE_HEADER=${header.unwrap}"])
      } else {
        $header_flag = ''
        $header_environment = []
      }
      $agreements_flag = $accept_source_agreements ? {
        true    => ' --accept-source-agreements',
        default => '',
      }

      exec { "winget-source-add-${title}":
        command     => "${powershell} -NoProfile -Command \"& '${winget}' source add --name '${title}' --arg '${url}'${type_flag}${trust_flag}${explicit_flag}${header_flag}${agreements_flag} --disable-interactivity\"",
        unless      => $listed_check,
        environment => $header_environment,
        timeout     => 300,
      }
    } else {
      exec { "winget-source-remove-${title}":
        command => "${powershell} -NoProfile -Command \"& '${winget}' source remove --name '${title}' --disable-interactivity\"",
        onlyif  => $listed_check,
        timeout => 300,
      }
    }
  } else {
    # $facts['winget_path'] is nil until winget has run once (e.g. a
    # fresh node mid-bootstrap): silently skipping would hide this
    # source until a later run with no trace in the report.
    warning("winget::source[${title}]: winget_path fact is not yet set (winget not bootstrapped on this node yet); this source will be added on a later run once the fact is present. Order sources after Class['winget'] to avoid surprises.")
  }
}
