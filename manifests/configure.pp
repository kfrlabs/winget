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
# @param source
#   Path or HTTPS URL of the configuration file (`winget configure -f`).
#   Defaults to the resource title.
# @param accept_configuration_agreements
#   Whether to pass `--accept-configuration-agreements`. Default: true
#   (required for non-interactive agent runs).
#
# @example Apply a baseline configuration
#   winget::configure { 'C:/Configs/workstation.winget':
#   }
define winget::configure (
  String $source = $title,
  Boolean $accept_configuration_agreements = true,
) {
  # Fully qualified PowerShell: exec commands must be qualified and the
  # winget alias is unavailable in the SYSTEM context.
  $powershell = 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
  $winget = $facts['winget_path']

  if $winget {
    $agreements_flag = $accept_configuration_agreements ? {
      true    => ' --accept-configuration-agreements',
      default => '',
    }

    exec { "winget-configure-${title}":
      command => "${powershell} -NoProfile -Command \"& '${winget}' configure -f '${source}'${agreements_flag} --disable-interactivity\"",
      unless  => "${powershell} -NoProfile -Command \"& '${winget}' configure test -f '${source}'${agreements_flag} --disable-interactivity\"",
      timeout => 1800,
    }
  } else {
    # $facts['winget_path'] is nil until winget has run once (e.g. a
    # fresh node mid-bootstrap): silently skipping would hide this
    # configuration until a later run with no trace in the report.
    warning("winget::configure[${title}]: winget_path fact is not yet set (winget not bootstrapped on this node yet); this configuration will be applied on a later run once the fact is present. Order configurations after Class['winget'] to avoid surprises.")
  }
}
