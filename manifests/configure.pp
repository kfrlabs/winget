# frozen_string_literal: true

# @summary Apply a winget configuration file (`winget configure`).
#
# Applies a Desired State Configuration file (`.winget` / `.win-get.yaml`,
# see `winget configure`) idempotently: the `exec` is skipped while
# `winget configure test` reports the system in the desired state. Use this
# for machine configuration winget handles natively (e.g. installing a tool
# set alongside registry or package settings) instead of hand-rolled `exec`
# resources.
#
# Nothing is declared while winget itself is absent (fresh bootstrap): order
# configurations after the bootstrap class:
#
#   Class['winget'] -> Winget::Configure <| |>
#
# Trust model: `source` may point at an HTTPS URL. Whoever controls that URL
# controls the node (the configuration runs as SYSTEM with
# `accept_configuration_agreements` defaulting to true), so prefer files from
# internal, pinned locations you control. Only local absolute paths (drive
# letter or UNC) and `https://` URLs are accepted; anything else (including
# cleartext `http://` and relative paths, which would resolve against the
# agent working directory) fails compilation.
#
# Idempotence relies entirely on `winget configure test`: it must exit 0 when
# the system matches and non-zero otherwise. The `test` subcommand requires
# winget >= 1.6; on older builds the guard fails every run and the
# configuration is re-applied each time, so a warning is logged when the
# `winget_version` fact reports an older winget instead of re-applying
# silently.
#
# @param source
#   Path or HTTPS URL of the configuration file (`winget configure -f`).
#   Defaults to the resource title. Must be an absolute local path
#   (`C:/...`, `C:\...` or `\\server\share\...`) or an `https://` URL.
# @param accept_configuration_agreements
#   Whether to pass `--accept-configuration-agreements`. Default: true
#   (required for non-interactive agent runs).
# @param timeout
#   Seconds before the configure/test commands are killed. Default: 1800.
#   Configuration files that install large tool sets may need more.
#
# @example Apply a baseline configuration
#   winget::configure { 'C:/Configs/workstation.winget':
#   }
define winget::configure (
  String $source = $title,
  Boolean $accept_configuration_agreements = true,
  Integer $timeout = 1800,
) {
  # Fully qualified PowerShell: exec commands must be qualified and the
  # winget alias is unavailable in the SYSTEM context.
  $powershell = 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
  $winget = $facts['winget_path']

  # Trust guard (issue #40): fail closed on anything that is not an absolute
  # local path / UNC share or an https:// URL. A URL with any other scheme
  # (including cleartext http://) or a relative path never reaches the exec.
  if $source =~ /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\// {
    if $source !~ /^https:\/\// {
      fail("winget::configure[${title}]: source URL must use https:// (cleartext and unknown schemes are rejected for a SYSTEM-run configuration).")
    }
  } elsif $source =~ /^\\\\/ or $source =~ /^[a-zA-Z]:[\\\/]/ {
    # UNC share or drive-absolute local path: accepted.
  } else {
    fail("winget::configure[${title}]: source must be an absolute local path (C:/..., C:\\... or \\\\server\\share\\...) or an https:// URL; relative paths would resolve against the agent working directory.")
  }

  if $winget {
    # Escape single quotes for PowerShell single-quoted literals.
    $safe_source = regsubst($source, "'", "''", 'G')
    $agreements_flag = $accept_configuration_agreements ? {
      true    => ' --accept-configuration-agreements',
      default => '',
    }

    # `configure test` needs winget >= 1.6: older builds fail the guard on
    # every run and re-apply the configuration each time. Warn instead of
    # re-applying silently (the exec below is unchanged).
    $winget_version = $facts['winget_version']
    if $winget_version and versioncmp($winget_version, '1.6') < 0 {
      warning("winget::configure[${title}]: winget ${winget_version} predates the 'configure test' subcommand (needs >= 1.6); the configuration will be re-applied on every run until winget is upgraded.")
    }

    exec { "winget-configure-${title}":
      command => "${powershell} -NoProfile -Command \"& '${winget}' configure -f '${safe_source}'${agreements_flag} --disable-interactivity\"",
      unless  => "${powershell} -NoProfile -Command \"& '${winget}' configure test -f '${safe_source}'${agreements_flag} --disable-interactivity\"",
      timeout => $timeout,
    }
  } else {
    # $facts['winget_path'] is nil until winget has run once (e.g. a
    # fresh node mid-bootstrap): silently skipping would hide this
    # configuration until a later run with no trace in the report.
    warning("winget::configure[${title}]: winget_path fact is not yet set (winget not bootstrapped on this node yet); this configuration will be applied on a later run once the fact is present. Order configurations after Class['winget'] to avoid surprises.")
  }
}
