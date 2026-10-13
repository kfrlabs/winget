# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- `source => 'auto'` fallback: the `github` fallback is no longer chained
  after `msstore` with `->`, so it still runs when the `msstore` install
  fails (previously it never ran: skipped on failure, no-op on success)
- `auto` with a pinned version (`ensure => '1.8.2391'`) now installs from
  `github` directly, since the `msstore` CDN always serves latest and cannot
  honor a pin; `msstore` with a pin logs a warning explaining this
- `source_path` precedence: when set, only the local bundle is installed and
  no `msstore`/`github` download is attempted (previously both ran and raced)
- Version pinning is now idempotent for the `github` and `local` sources via
  a version-aware `unless` guard (AppX revision segment tolerated); new
  `dependencies` parameter on class `winget`, forwarded to the local install
- `winget::install::local` dependencies: replaced the invalid
  `Get-AppxPackageManifest -Path` guard (no such parameter) with a manifest
  identity read from the embedded `AppxManifest.xml`, and fixed the inverted
  `onlyif` (dependencies installed when present, skipped when absent)
- Bootstrap installs fall back to `Add-AppxProvisionedPackage -Online
  -SkipLicense` when `Add-AppxPackage` fails under the SYSTEM account
- `winget upgrade` fact parser handles multi-table output (explicit-targeting
  table): each table is parsed with its own header offsets instead of leaking
  the second header's `Id` cell as a package ID
- `winget::upgrade` skips packages already declared elsewhere in the catalog
  instead of failing with a duplicate-declaration error (declare the class
  after your own `package` resources, or use `exclude`)
- Acceptance test no longer asserts `Git.Git` is installed by the bare
  `winget` class: it checks `winget --version` after bootstrap, then installs
  `Git.Git` through the provider in a dedicated step

## [1.0.0] - 2026-10-13

### Added
- Class `winget::upgrade`: declares one `package` with `ensure => latest`
  (winget provider) per ID from the new `winget_upgrades` fact, with `exclude` /
  `only` filters and an optional Puppet `schedule` metaparameter (managed via
  `manage_schedule` or declared externally)
- Custom fact `winget_upgrades`: IDs of winget packages with an available
  update, resolved with the shared `PuppetX::Winget::Facts` helper

### Fixed
- `winget_upgrades` fact and provider `winget list` parsing slice table
  columns at the header offsets instead of splitting on whitespace: winget
  shrinks inter-column gaps to one space for long names (truncated with `…`),
  which previously produced bogus IDs like `6.0.35` and silently dropped
  packages from the fact
- `PuppetX::Winget::Facts` now explicitly requires `puppet_x/winget/path_resolver`,
  so the facts also resolve when the provider was never loaded (e.g. standalone
  `facter` runs)
- Provider treats `winget upgrade` exit code `0x8A15002B` (update not applicable,
  e.g. `7zip.7zip` `26.04` available vs `26.04.00.0` installed) as idempotent
  success for `upgrade` instead of failing `ensure => latest` every run
- Provider `latest` reports the installed version when winget advertises a
  version its own upgrade deems not newer, so `ensure => latest` stays in
  sync instead of logging a corrective change on every run; `query` and
  `latest` now share a single memoized `winget list` per resource

## [0.2.1] - 2026-10-12

### Added
- Windows Server 2025 support (metadata, bootstrap class OS check and tests)

## [0.2.0] - 2026-10-12

### Added
- Bootstrap class `winget` with `msstore`, `github` and `auto` sources, plus
  offline installation via `source_path`
- Defined types for each installation method: `winget::install::msstore`,
  `winget::install::github` and `winget::install::local`
- Custom facts `winget_path` and `winget_version`, resolved with the shared
  path resolver through a unit-testable `PuppetX::Winget::Facts` helper;
  both return nil safely when winget is absent and never raise
- Proxy support for downloads and retry settings for installations
- Ordering support via `Class['winget'] -> Package <| provider == winget |>`
- Comprehensive README with examples, bootstrap method justification,
  limitations and troubleshooting
- REFERENCE.md generated via Puppet Strings
- rspec-puppet tests for the class and unit specs for the facts

### Changed
- Bootstrap never invokes the `winget` CLI (chicken-and-egg on missing
  winget, alias unavailable under SYSTEM); all installs go through the
  fully qualified PowerShell executable with `Add-AppxPackage`
- `msstore` installs the Microsoft CDN App Installer bundle
  (`https://aka.ms/getwinget`), which works headless under SYSTEM with no
  Store dependency; pin versions with the `github` source or a local file

## [0.1.0] - 2026-10-12

### Added
- Initial module scaffold with PDK
- Path resolver helper (`lib/puppet_x/winget/path_resolver.rb`)
- winget package provider (`lib/puppet/provider/package/winget.rb`)
- Support for installable, uninstallable, upgradeable, versionable features
- Source selection via install_options (winget vs msstore)
- Reliable `winget list` parsing (localized headers, spinners, truncated columns)
- Exit code mapping for idempotent behavior
- Unit tests for path resolver and provider (50 tests)
- PDK validation and unit test configuration

### Features
- Confined to Windows, not default provider (explicit opt-in)
- Unsuitable with clear message when winget absent
- Always passes required winget flags
- Proper version pinning with `ensure => '1.2.3'`
- Upgrade support with `ensure => latest`
