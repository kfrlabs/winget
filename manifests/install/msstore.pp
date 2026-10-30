# frozen_string_literal: true

# @summary Deprecated alias for winget::install::cdn.
#
# The Microsoft CDN download (`https://aka.ms/getwinget`) never came from the
# Microsoft Store app; the define was renamed to `winget::install::cdn` to
# stop implying otherwise. This wrapper keeps existing manifests compiling:
# it logs a deprecation warning and declares `winget::install::cdn` with the
# same parameters, including `fail_on_error`.
#
# @param ensure
#   Desired state: 'present', 'absent', or a specific version string.
#
# @param version
#   Accepted for interface consistency but ignored: the Microsoft CDN always
#   serves the latest App Installer. Pin a version with the `github` source
#   or a local file instead.
#
# @param accept_source_agreements
#   Kept for interface consistency. Source agreements are implicitly accepted
#   by direct package installation.
#
# @param proxy
#   Proxy URL for the download. Accepts a plain string or `Sensitive` (e.g.
#   `Sensitive('http://user:pass@proxy.example.com:8080')`): forwarded to
#   `winget::install::cdn`, whose download environment is `Sensitive`-wrapped
#   so credentials are redacted from catalogs, PuppetDB and reports. A plain
#   string still works but embeds credentials in clear text when the URL
#   contains them, so prefer `Sensitive` for URLs with credentials.
#
# @param retry_count
#   Number of retry attempts for the installation. Default: 3.
#
# @param retry_interval
#   Seconds between retry attempts. Default: 10.
#
# @param fail_on_error
#   Whether a failed install makes the catalog run fail. Default: true. Set
#   to false when another method acts as a fallback (`source => 'auto'`).
#
define winget::install::msstore (
  Winget::Ensure $ensure                    = 'present',
  Optional[String] $version                 = undef,
  Boolean $accept_source_agreements         = true,
  Optional[Variant[String, Sensitive[String]]] $proxy                   = undef,
  Integer $retry_count                      = 3,
  Integer $retry_interval                   = 10,
  Boolean $fail_on_error                    = true
) {
  warning('winget::install::msstore is deprecated, use winget::install::cdn instead (same Microsoft CDN download, never the Store app).')

  winget::install::cdn { $title:
    ensure                   => $ensure,
    version                  => $version,
    accept_source_agreements => $accept_source_agreements,
    proxy                    => $proxy,
    retry_count              => $retry_count,
    retry_interval           => $retry_interval,
    fail_on_error            => $fail_on_error,
  }
}
