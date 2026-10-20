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
# Changing `url`, `source_type`, `trust_level` or `explicit` on an existing
# source removes and re-adds it in the same run (the removal is ordered
# before the add, and the add guard is re-evaluated after the removal), so
# a drifted source converges in one run and the next run is a no-op. The
# comparison reads the current definition from `winget source export`
# (JSON, locale-independent). Attributes that cannot be read back are not
# compared: `header` is write-only (see its docs), and on winget builds
# whose export lacks a field (e.g. `Explicit`), that field degrades to
# presence-only.
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
#   (default) leaves the winget default. Changing it on an existing source
#   removes and re-adds the source so the catalog converges in one run
#   (`trusted` means the exported `TrustLevel` contains `Trusted`).
# @param explicit
#   Whether the source is explicit (`--explicit`): explicit sources must be
#   targeted with `--source` on every command. Default: false. Changing it
#   on an existing source removes and re-adds the source so the catalog
#   converges in one run.
# @param header
#   Optional REST source HTTP header (`--header`). `Sensitive` so the value
#   never lands in logs or reports. The header is write-only: it cannot be
#   read back, so changing only the header is not detected — remove the
#   source (`ensure => absent`) and re-add it to rotate the header.
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
    # Escape single quotes for PowerShell single-quoted literals.
    $safe_title = regsubst($title, "'", "''", 'G')
    $safe_source_type = $source_type ? {
      undef   => undef,
      default => regsubst($source_type, "'", "''", 'G'),
    }
    $safe_trust_level = $trust_level ? {
      undef   => undef,
      default => regsubst($trust_level, "'", "''", 'G'),
    }

    # A source table row starts with the source name: match it at line
    # start followed by whitespace. Skip the header and separator rows so a
    # source named `Name` does not match the header; [regex]::Escape quotes
    # any regex metacharacters in the name.
    $listed_check = "${powershell} -NoProfile -Command \"if (& '${winget}' source list --disable-interactivity | Select-Object -Skip 2 | Select-String -Quiet -Pattern ('^' + [regex]::Escape('${safe_title}') + '\\s')) { exit 0 } else { exit 1 }\""

    if $ensure == 'present' {
      if $url == undef {
        fail("winget::source[${title}]: url is required when ensure => present.")
      }

      # Escape single quotes in user-supplied values for PowerShell single-quoted literals.
      $safe_url = regsubst($url, "'", "''", 'G')

      $type_flag = $safe_source_type ? {
        undef   => '',
        default => " --type '${safe_source_type}'",
      }
      $trust_flag = $safe_trust_level ? {
        undef   => '',
        default => " --trust-level '${safe_trust_level}'",
      }
      $explicit_flag = $explicit ? {
        true    => ' --explicit',
        default => '',
      }

      # Stale-attribute guard (issue #38): `winget source export` emits one
      # JSON object per line (`Name`, `Arg`, `Type`, `TrustLevel` array,
      # `Explicit` boolean — verified against winget 1.29). When the source
      # exists but a readable attribute differs, it is removed here and the
      # add below re-creates it: Puppet evaluates the add guard after this
      # removal (explicit `before`), so a drifted source converges in a
      # single run and the next run is a no-op. Unreadable attributes keep
      # presence-only behaviour: `header` is never compared (write-only
      # `Sensitive`), and a field missing from the export (older winget) is
      # skipped instead of forcing a removal loop.
      $trust_stale_check = $safe_trust_level ? {
        undef   => '',
        default => $trust_level ? {
          'trusted' => "if ((\$row.PSObject.Properties.Name -contains 'TrustLevel') -and (@(\$row.TrustLevel) -notcontains 'Trusted')) { \$stale = \$true };",
          default   => "if ((\$row.PSObject.Properties.Name -contains 'TrustLevel') -and (@(\$row.TrustLevel) -contains 'Trusted')) { \$stale = \$true };",
        },
      }
      # `Explicit` is a known Boolean (default false), so both directions
      # converge; the property-existence probe keeps older winget builds
      # (no `Explicit` in the export) on presence-only behaviour.
      $explicit_stale_check = $explicit ? {
        true    => "if ((\$row.PSObject.Properties.Name -contains 'Explicit') -and (-not \$row.Explicit)) { \$stale = \$true };",
        default => "if ((\$row.PSObject.Properties.Name -contains 'Explicit') -and (\$row.Explicit)) { \$stale = \$true };",
      }
      $type_stale_check = $safe_source_type ? {
        undef   => '',
        default => "if (\$row.Type -ne '${safe_source_type}') { \$stale = \$true };",
      }
      $stale_check = "${powershell} -NoProfile -Command \"\$export = & '${winget}' source export; \$rows = @(\$export | Where-Object { \$_ -match '^\\s*\\{'} | ForEach-Object { \$_ | ConvertFrom-Json }); if (-not \$rows) { exit 1 }; \$row = @(\$rows | Where-Object { \$_.Name -ieq '${safe_title}' }); if (-not \$row) { exit 1 }; \$row = \$row[0]; \$stale = \$false; if (\$row.Arg -ne '${safe_url}') { \$stale = \$true }; ${type_stale_check} ${trust_stale_check} ${explicit_stale_check} if (\$stale) { exit 0 } else { exit 1 }\""

      exec { "winget-source-remove-stale-${title}":
        command => "${powershell} -NoProfile -Command \"& '${winget}' source remove --name '${safe_title}' --disable-interactivity\"",
        onlyif  => $stale_check,
        before  => Exec["winget-source-add-${title}"],
        timeout => 300,
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
        command     => "${powershell} -NoProfile -Command \"& '${winget}' source add --name '${safe_title}' --arg '${safe_url}'${type_flag}${trust_flag}${explicit_flag}${header_flag}${agreements_flag} --disable-interactivity\"",
        unless      => $listed_check,
        environment => $header_environment,
        timeout     => 300,
      }
    } else {
      exec { "winget-source-remove-${title}":
        command => "${powershell} -NoProfile -Command \"& '${winget}' source remove --name '${safe_title}' --disable-interactivity\"",
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
