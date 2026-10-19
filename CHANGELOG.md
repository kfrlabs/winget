# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-10-19

### Added
- Pinned-version downgrade opt-in (issue #34): per-package
  `allow_downgrade` (`Winget::Package` key, translated by
  `winget::packages` into the `install_options` string flag
  `'--allow-downgrade'`, any letter case, stripped before the winget
  CLI) and raw `package` `install_options` string flag
  `'--allow-downgrade'` (legacy hash entries such as
  `{ 'allow_downgrade' => true }` are still tolerated defensively by the
  provider but cannot pass `package` type munging, so declare the string
  flag). Only a plain-numeric
  older pin with the opt-in uninstalls then installs; without it the
  provider falls back to `install --version` with a notice, and a
  failed reinstall raises stating the package was uninstalled and left
  without a usable install
- Class `winget::packages`: declares one `package` (winget provider) per
  entry of a Hiera-friendly `Winget::PackagesHash` hash (shorthand ensure
  strings or full `Winget::Package` hashes), with structured install
  parameters (`source`, `scope`, `architecture`, `location`, `override`,
  `installer_type`, `locale` translated into install flags), per-package
  and class-level `schedule`, optional `reboot_resource` wiring, and a
  `hold` flag mapped to `winget pin`
- Provider `holdable` feature: `mark => hold` / `mark => none` map to
  `winget pin add` / `winget pin remove` (idempotent, cached `pin list`
  per run, hold re-applied after install/upgrade like dpkg); `mark` is
  only reported when managed so plain resources pay no extra process
- Defined type `winget::pin`: blocking (`blocking => true`) and gating
  (`version => '1.2.*'`) pins beyond the provider plain-pin semantic
- Class `winget::sources` and defined type `winget::source`: manage
  `winget source add/remove` (private `Microsoft.Rest` sources, trust
  level, explicit sources, `Sensitive` auth header) from a
  Hiera-friendly `Winget::SourcesHash` hash, with an optional guarded
  `winget source reset --force` first (`reset_defaults`)
- Class `winget::upgrade`: new `respect_pins` parameter (default true,
  skips IDs from the new `winget_pins` fact) and `reboot_resource`
  parameter (optional notify wiring to a caller-declared `reboot`
  resource from puppetlabs/reboot, so exit `0x8A150109`/`0x8A15010A`/`0x8A15010B` reboots)
- Class `winget::packages`: same optional `reboot_resource` wiring
- Structured facts `winget_upgrades` (ID + current/available
  versions for PuppetDB inventory, fallback for `winget::upgrade` on
  server-side compilation) and
  `winget_pins` (fast local `winget pin list`); the upgrade fact memoizes
  its `winget upgrade` invocation per agent run
- Class `winget::settings`: manages `settings.json` for the agent
  account (arbitrary settings + `experimental_features`, e.g. machine
  install-scope preference and telemetry)
- Defined type `winget::configure`: applies a `winget configure` file
  idempotently (guarded by `winget configure test`)
- Bolt/PE tasks `winget::list_upgrades` (read-only upgrade inventory)
  and `winget::upgrade_now` (`ids`/`exclude`/`include_pinned`,
  reboot-aware JSON summary) for on-demand upgrades outside agent runs
- Data types `Winget::Package`, `Winget::PackagesHash`, `Winget::SourceEntry`,
  `Winget::SourcesHash` (`types/`) for structured, validated parameters
  (suffixed because Puppet folds definition names case-insensitively:
  unsuffixed names would collide with the classes/define)
- Community files: `SECURITY.md`, `CODEOWNERS`, `CODE_OF_CONDUCT.md`
- Provider `install_options` source detection now also handles the
  separate-element pair form (`['--source', 'msstore']`, as produced by
  the structured `source` key) without duplicating the flag
- Provider `self.prefetch(resources)` with a class-level `winget list`
  cache: N `package` resources now share a single listing instead of one
  listing per resource (use `clear_list_cache!` / `reset!` to invalidate)
- New `winget::upgrades` function (issue #33): on-demand structured upgrade
  inventory (same `id` + `current_version`/`available_version` rows as the
  fact) for `Class['winget::upgrade']`. Enumeration now happens only when
  the class is declared; the fact rows are only a fallback for server-side
  compilation (where the function runs without winget)
- `ensure => absent` for the `cdn` / `github` / `local` installs now also
  removes the staged provisioned package (`Remove-AppxProvisionedPackage`):
  `Remove-AppxPackage -AllUsers` alone fails with `0x80070032` on staged
  images (seen on the CI runner), and provisioned installs from our own
  bootstrap fallback were never removed. Each step is best effort; the exec
  fails closed only when an instance still resolves
- `winget_upgrades` fact is now opt-in inventory (issue #33): it returns
  `[]` without shelling out unless `WINGET_UPGRADES_ENABLED` is set to a
  true-like value (`true`, `1`, `yes`, `on`). Nodes without
  `Class['winget::upgrade']` no longer pay for a `winget upgrade` source
  round-trip on every agent run; enable the fact for PuppetDB inventory
  (or for server-side compilation of `winget::upgrade`)
- `winget::upgrade` documents the consent decision (issue #33):
  `--accept-source-agreements` is kept deliberately for enumeration, the
  provider and the Bolt tasks, so winget can never prompt (or stall where
  nothing answers) on nodes that never opted in
- Bootstrap `source => 'cdn'`: preferred name for the Microsoft CDN download
  of App Installer (`https://aka.ms/getwinget`); `source => 'msstore'` is kept
  as a deprecated alias with the same behavior and logs a deprecation warning
- Defined type `winget::install::cdn` (issue #47): the real implementation of
  the Microsoft CDN bootstrap, backing `source => 'cdn'`;
  `winget::install::msstore` is now a thin deprecated wrapper (logs a
  warning, forwards all parameters including `fail_on_error`) so existing
  manifests keep compiling. Resource titles changed (`winget_install_cdn_*`,
  `winget_uninstall_cdn_*`): exec titles show up in reports
- Simplified `hiera.yaml` (issue #47): single `common` level. The per-OS
  levels pointed at files that do not exist (`data/` only ships
  `common.yaml`) and only added failed lookups
- Bootstrap download hardening (issue #39): the App Installer bundle is
  downloaded into a per-run unique directory (no fixed name in the shared
  `$env:TEMP`, safe under retries) restricted to SYSTEM and Administrators,
  removed in a `try/finally` on success and on failure; installation fails
  closed unless `Get-AuthenticodeSignature` reports `Valid` with a Microsoft
  publisher; `$ProgressPreference = 'SilentlyContinue'` for the download
- `winget::configure` trust guardrails (issue #40): `source` must be an
  absolute local path, a UNC share or an `https://` URL (cleartext
  `http://`, other schemes and relative paths fail compilation); warns when
  the `winget_version` fact predates `configure test` (needs winget >= 1.6)
  instead of re-applying silently; new `timeout` parameter (default 1800 s);
  trust model and prerequisites documented in the README
- Convergent pins and sources (issue #38): changing `blocking` or `version`
  of a `winget::pin`, or `url`, `source_type`, `trust_level` or `explicit`
  of a `winget::source`, now removes and re-adds the object in the same run
  (explicit ordering, guards re-evaluated after removal) instead of silently
  doing nothing; unreadable attributes keep presence-only behaviour (pin
  `source`, source `header`, and fields missing from older winget exports)
- Stricter `ensure` typing (issue #45): `class winget` and the `cdn` /
  `github` / `local` install defines accept only `present`, `absent` or a
  dotted version (typos such as `presnt` fail compilation instead of behaving
  like `present`); `Winget::Package['ensure']` accepts only the package
  provider values or a version starting with a digit; setting the deprecated
  `version` parameter logs a deprecation warning
- Release pipeline hardening (issue #42): the CHANGELOG entry is validated
  before the `pdk build` and the Forge publish (a missing entry used to fail
  the job after an irreversible upload); tagged commit must be reachable from
  `main`; `workflow_dispatch` dry run validates everything without
  publishing; tag must still match `metadata.json`
- OpenVox 8 CI coverage (issue #44): unit matrix entry installing the
  `openvox` gem (`OPENVOX_GEM_VERSION`) instead of `puppet`, and a Windows
  acceptance variant with the OpenVox 8 agent; both part of the gate
- Acceptance as SYSTEM with real operations (issue #43): every `puppet
  apply` runs as SYSTEM via a one-shot scheduled task and exercises
  bootstrap, machine-scope install, pin add/no-op/drift/remove, source
  add/no-op/drift/remove, fact shapes, the `list_upgrades` task, upgrade and
  removals, with end-state assertions after each apply; plus a nightly
  scheduled run
- Windows Server support clarified (issue #46): 2019 is best effort /
  untested (dropped from `metadata.json` and the class warning list, which
  now covers 10, 11, 2022, 2025); Microsoft only documents winget for
  Windows 10, Windows 11 and Windows Server 2025

### Fixed
- Bootstrap ordering: `winget::packages`, `winget::sources` and
  `winget::settings`, when declared from the main class (Hiera keys), now
  `require` `Class['winget']`, so packages no longer run before winget is
  installed; they are deliberately not contained, which would create a
  dependency cycle with `Class['winget'] -> Package <| provider == winget |>`
- `source => 'auto'`: a failed `cdn` attempt (exit code 1 accepted via the
  new `fail_on_error => false` parameter of `winget::install::msstore`) no
  longer marks `Class['winget']` as failed, which used to skip every
  dependent resource even when the `github` fallback succeeded
- CI `gate` job always runs and fails when a required job failed, was
  cancelled or was skipped (a skipped required check counted as passing)
- `suitable?` warning throttle: the unsuitable/missing-winget warning is
  emitted only once per process (further checks use `Puppet.debug`),
  instead of once per resource
- Provider: a pinned `ensure => 'x.y.z'` now converges when another version
  is installed. `winget install --version` answers 0x8A15010D ("another
  version is installed"), which the provider treated as an idempotent
  success, so the pin was never applied and the resource reported a change
  on every run. A newer pin now runs `winget upgrade --version`; an older
  one uninstalls then installs (winget cannot downgrade in place)
- Provider `latest` reads the `winget show` version label in any language
  (`Version :`, `Versión:`, ...) and keeps non-numeric suffixes
  (`2.41.0-beta1`) instead of requiring an English `Version:` and `[\d.]+`
- `winget list` / `upgrade` / `pin list` parsing ignores the progress
  spinner frames winget redraws with carriage returns, which shifted the
  column offsets of the header line
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
- Task `winget::upgrade_now`: exit codes are handled as unsigned values. In
  PowerShell `[uint32]0x8A15002B` and `[uint32]$LASTEXITCODE` throw (hex
  literals above 0x7FFFFFFF are negative Int32), which left the constants
  `$null` and misclassified "already current" and reboot-requested results
  as failures
- `winget::source`: the REST `header` is kept `Sensitive` all the way into
  the `exec` environment instead of being unwrapped into a plain array, so it
  is redacted from the catalog stored by PuppetDB and from reports
- `winget::pin` and `winget::source`: wrap the `pin list` / `source list`
  `Select-String -Quiet` guards in `if (...) { exit 0 } else { exit 1 }` so
  the `unless` / `onlyif` exit code reflects the match instead of always
  succeeding (the pipeline alone always exits 0)
- `winget list` / `upgrade` / `pin list` table parsing is locale-independent
  in the provider, the facts and the `winget::list_upgrades` /
  `winget::upgrade_now` tasks: tables are discovered via the separator row
  and columns are mapped positionally instead of matching English/French
  header words, so localized headers (e.g. Spanish `Versión`, German
  `Quelle`) parse like the English/French ones
- Fixed-width parsing no longer misaligns on non-ASCII names (issue #32):
  rows are sliced by display width (East Asian Width + astral wide) in
  `PuppetX::Winget::Facts` (`display_slice`) and in both tasks
  (`Get-DisplaySubstring`), so display-aligned CJK, accented, `…`-truncated
  and emoji names parse like ASCII ones
- No timeout on winget commands (issue #33): all invocations go through
  `PuppetX::Winget::Runner` (`Open3` + `Timeout`, whole process tree killed
  on expiry). Defaults are 120 s for read-only commands and 600 s for
  `install`/`upgrade`/`uninstall`, overridable with `WINGET_COMMAND_TIMEOUT`.
  The provider raises `Puppet::Error` on timeout, facts return `nil`/`[]`
- Pinned-version downgrade now requires an explicit per-package opt-in
  (issue #34): an older plain-numeric pin without the
  `install_options` `'--allow-downgrade'` flag falls back to
  `install --version` with a notice instead of uninstalling; suffixed
  versions never uninstall even with the opt-in
- Pinned-version downgrade no longer uninstalls on suffixed versions
  (issue #34): only a plain-numeric (`x.y.z`) wanted version lower than a
  plain-numeric installed version triggers uninstall-then-install; anything
  else (`2.40.0.windows.1`, `1.0.0-rc1`, `v1.2`) falls back to
  `install --version` with a notice
- Class `winget` with `ensure => absent` no longer uses the package provider
  (issue #35): it declares `winget::install::msstore { 'winget': ensure =>
  'absent' }`, so the documented `Class['winget'] -> Package <| provider ==
  winget |>` collector cannot cycle, and no `Package[...]` remains in the
  catalog
- Tasks `Find-Winget` no longer picks the wrong version (issue #36):
  `WindowsApps` is scanned first (Ruby resolver order) and candidates are
  sorted numerically on the version segment (`[version]`), so `1.10`
  beats `1.9`
- Task `winget::upgrade_now` no longer falls back to "upgrade everything"
  on bad input (issue #37): non-empty stdin that cannot be parsed, or
  wrong-typed `ids`/`exclude`/`include_pinned`, returns
  `{"_error":{"kind":"winget/invalid-input"}}` with exit 1 before winget
  runs; `ids`/`exclude` entries must be non-empty strings without whitespace
- PowerShell escaping (issue #41): `winget::configure`, `winget::pin`
  (`version`, `source`), `winget::source` (`url`, `source_type`,
  `trust_level`), `winget::sources` (expected-list quoting) and
  `winget::settings` (parent dir) now double single quotes (`''`) like
  `winget::install::local` already did; `winget::source` keeps
  `[regex]::Escape` for the list guard

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
