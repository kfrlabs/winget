# winget

[![CI](https://github.com/kfrlabs/winget/actions/workflows/ci.yml/badge.svg)](https://github.com/kfrlabs/winget/actions/workflows/ci.yml)
[![Release to the Puppet Forge](https://github.com/kfrlabs/winget/actions/workflows/release.yml/badge.svg)](https://github.com/kfrlabs/winget/actions/workflows/release.yml)
[![Puppet Forge version](https://img.shields.io/puppetforge/v/kfrlabs/winget.svg)](https://forge.puppet.com/modules/kfrlabs/winget)
[![Puppet Forge downloads](https://img.shields.io/puppetforge/dt/kfrlabs/winget.svg)](https://forge.puppet.com/modules/kfrlabs/winget)
[![License: Apache-2.0](https://img.shields.io/github/license/kfrlabs/winget.svg)](LICENSE)
[![Puppet >= 7.0, < 9.0](https://img.shields.io/badge/puppet-%3E%3D7.0_%3C9.0-blue.svg)](metadata.json)

Puppet module for managing Windows packages via winget (Windows Package Manager).

## Table of Contents

1. [Description](#description)
2. [Requirements](#requirements)
3. [Setup](#setup)
4. [Usage](#usage)
5. [Reference](#reference)
6. [Limitations](#limitations)
7. [Troubleshooting](#troubleshooting)
8. [Development](#development)

## Description

This module provides a `winget` provider for Puppet's built-in `package` type, allowing you to manage Windows packages using the Windows Package Manager (winget). It also includes a `winget` class to bootstrap winget on systems where it is not pre-installed, a `winget::packages` class to declare packages from Hiera, a `winget::upgrade` class for bulk upgrades, `winget::sources` / `winget::source` for private package sources, `winget::pin` plus a provider `holdable` feature to hold packages back, a `winget::settings` class for the winget client configuration, Bolt tasks for on-demand upgrades, and custom facts `winget_path`, `winget_version`, `winget_upgrades` and `winget_pins` for inventory and conditional logic.

## Requirements

- **Puppet**: >= 7.0.0 < 9.0.0 (Puppet 7/8, OpenVox 8 compatible)
- **Operating System**: Windows 10 1809 (build 17763) or later, Windows Server 2019, 2022 or 2025
- **Architecture**: x64 and arm64 supported
- **Internet Access**: Required for downloading winget from the Microsoft CDN (`aka.ms/getwinget`) or GitHub (unless using `source_path` for offline installation)
- **Proxy Support**: Configurable via `proxy` parameter
- **SYSTEM Account Access**: The SYSTEM account (under which Puppet agent runs) must have read access to `%ProgramFiles%\WindowsApps`. This is required for the path resolver to locate winget.exe.

## Setup

### What winget affects

- Adds a `winget` provider to Puppet's `package` type
- Optionally installs winget via the `winget` class (bootstrap)
- Creates custom facts `winget_path`, `winget_version`, `winget_upgrades` and `winget_pins`
- Does not modify WindowsApps ACLs (must be configured separately if needed)

### Beginning with winget

#### Basic package management (winget already installed)

```puppet
package { 'Git.Git':
  ensure   => installed,
  provider => winget,
}
```

#### Full setup with bootstrap class

```puppet
# Ensure winget is installed, then manage packages
class { 'winget':
  ensure => present,
}

package { 'Microsoft.VisualStudioCode':
  ensure   => installed,
  provider => winget,
}

# Guarantee ordering: bootstrap before packages
Class['winget'] -> Package <| provider == winget |>
```

## Usage

### Package Resource Examples

#### Basic Installation

```puppet
package { 'Git.Git':
  ensure   => installed,
  provider => winget,
}
```

#### Pinned Version

```puppet
package { 'Git.Git':
  ensure   => '2.40.0',
  provider => winget,
}
```

A newer pin runs `winget upgrade --version`. Moving to an older
plain-numeric version (`2.40.0` -> `2.39.0`) uninstalls then installs
(winget cannot downgrade in place): this is destructive (user data may be
lost, the app is stopped) and not atomic, so only plain `x.y.z` versions
trigger it. Suffixed versions (`2.40.0.windows.1`, `1.0.0-rc1`, `v1.2`)
never uninstall: they fall back to `install --version` with a notice.

#### Latest Version (Upgrade)

```puppet
package { 'Microsoft.VisualStudioCode':
  ensure   => latest,
  provider => winget,
}
```

#### Bulk Upgrade (all packages with available updates)

The `winget::upgrade` class reads the structured rows from the `winget_upgrades` fact and
declares one `package` with `ensure => latest` per `id`, so upgrades are regular
Puppet resources (reporting, noop, `--tags`) instead of a scheduled task script.

```puppet
include winget::upgrade

# Guarantee ordering: bootstrap before upgrades
Class['winget'] -> Class['winget::upgrade']
```

With exclusions and a weekly maintenance window (Puppet `schedule`
metaparameter, no Windows scheduled task):

```puppet
class { 'winget::upgrade':
  exclude          => ['Google.Chrome'],
  manage_schedule  => true,
  schedule_period  => 'weekly',
  schedule_weekday => 'Sunday',
  schedule_range   => '3 - 5',
}
```

Or reuse a `schedule` resource declared elsewhere (e.g. in a profile):

```puppet
class { 'winget::upgrade':
  schedule => 'maintenance-window',
}
```

#### Upgrade Selected Packages Only If Installed

To update specific packages (e.g. `Google.Chrome`) only when they are
already installed, use `only`: IDs are matched against the
`winget_upgrades` fact, which only lists installed packages with an
available update. An absent package declares no resource and is never
installed (unlike `package { ensure => latest }`, which installs it):

```puppet
class { 'winget::upgrade':
  only => ['Google.Chrome'],
}
```

The same via Hiera (automatic parameter lookup):

```yaml
winget::upgrade::only:
  - Google.Chrome
```

```puppet
include winget::upgrade
Class['winget'] -> Class['winget::upgrade']
```

Note: the `winget_upgrades` fact runs `winget upgrade` once per agent run
even when the packages are skipped by the schedule; the schedule only skips
the `package` resources outside the window. When upgrades are confined to a
maintenance window, cache the fact with a TTL in `facter.conf` so the cost
is paid at most once per window:

```ini
facts : {
  ttls : [ { "winget_upgrades" : "7 days" } ]
}
```

Or opt out entirely with the `WINGET_UPGRADES_ENABLED=false` environment
variable (`false`, `0`, `no`, `off`; or `facts : { blocklist : [ "winget_upgrades" ] }`): the fact then
returns `[]` without shelling out.

Every winget invocation runs with a timeout (`PuppetX::Winget::Runner`):
120 s for read-only commands (`list`, `show`, `pin list`, `upgrade`
listing) and 600 s for `install`/`upgrade`/`uninstall`, overridable with
`WINGET_COMMAND_TIMEOUT` (seconds). A timeout kills the whole process
tree; the provider fails with a clear error while facts return `nil`/`[]`
so the agent never hangs on a stuck winget.

A package already declared elsewhere in the catalog (e.g. `package {
'Git.Git': ensure => present }`) is left alone by `winget::upgrade`:
redeclaring it would fail with a duplicate-declaration error. Declare
`winget::upgrade` after your own `package` resources, or list such IDs in
`exclude` and manage their upgrades yourself.

Pinned packages (`winget pin`, see [Holding Packages Back](#holding-packages-back-pins))
are skipped automatically (`respect_pins => true`, backed by the
`winget_pins` fact). To upgrade them explicitly, set
`respect_pins => false`.

To chain a reboot (puppetlabs/reboot) when an installer requests one
(winget exit `0x8A150109`/`0x8A15010A`/`0x8A15010B`, otherwise a warning + success):

```puppet
reboot { 'maintenance-reboot':
  when => pending,
}

class { 'winget::upgrade':
  reboot_resource => 'maintenance-reboot',
}
```

#### Declaring Packages from Hiera (`winget::packages`)

The `winget` class reads a `Winget::PackagesHash` hash (Hiera key
`winget::packages`, see `types/`) and declares one `package` with the winget
provider per entry. Entries accept either a shorthand ensure string or a
full hash with structured install parameters, an optional `schedule`, and a
`hold` flag:

```yaml
# hiera.yaml
winget::packages:
  Git.Git:
    ensure: present
    scope: machine
  Microsoft.VisualStudioCode:
    ensure: '1.95.0'
    hold: true
  Old.App:
    ensure: absent
```

```puppet
include winget
```

Direct use of the sub-class (e.g. with its own `schedule`) stays possible
via the `winget::packages::entries` key:

```yaml
# hiera.yaml
winget::packages::entries:
  Git.Git:
    ensure: present
```

```puppet
include winget::packages
Class['winget'] -> Class['winget::packages']
```

Structured keys (`source`, `scope`, `architecture`, `location`,
`override`, `installer_type`, `locale`) are translated into
`winget install` flags and prepended to any extra `install_options`.
Like `winget::upgrade`, entries already declared elsewhere are left alone.

`hold => true` combined with `ensure => latest` fails at compile time: a
plain pin (`winget pin add`) only excludes the package from
`winget upgrade --all`, it does not stop the explicit `winget upgrade --id`
that `ensure => latest` runs on every single agent run, so the hold would
be silently ineffective. Pin to an explicit version instead (as above), or
combine `ensure => latest` with a blocking `winget::pin` if explicit
upgrades must also be refused.

#### Holding Packages Back (pins)

Two complementary mechanisms keep a package at its current version:

- `mark => hold` on a `package` resource (provider `holdable` feature,
  mapped to `winget pin add` / `winget pin remove`). A plain pin excludes
  the package from `winget upgrade --all` while still allowing an explicit
  upgrade (`ensure => latest` on that same resource keeps working).
- `winget::pin` for blocking pins (`blocking => true`, which even refuse
  explicit upgrades) and gating pins (`version => '1.2.*'`, which restrict
  upgrades to a version range). Never combine a blocking pin with
  `ensure => latest` on the same package.

```puppet
# Plain hold, e.g. via Hiera (winget::packages)
# Git.Git:
#   ensure: present
#   hold: true

# Or directly on a package resource
package { 'Google.Chrome':
  ensure   => installed,
  provider => winget,
  mark     => hold,
}

# Advanced pins
winget::pin { 'Google.Chrome':
  ensure   => present,
  blocking => true,
}

winget::pin { 'Microsoft.PowerToys':
  ensure  => present,
  version => '0.70.*',
}
```

`winget::upgrade` skips pinned IDs automatically; the `winget_pins` fact
exposes them for reporting and conditional logic.

#### Private Package Sources

Declare additional winget sources (e.g. an internal `Microsoft.Rest`
source) with `winget::source`, or manage the whole set from Hiera with
`winget::sources` (including an optional reset to the defaults first):

```puppet
winget::source { 'contoso':
  url         => 'https://winget.contoso.example.com/cache',
  source_type => 'Microsoft.Rest',
  trust_level => 'trusted',
}
```

```yaml
# hiera.yaml
winget::sources:
  contoso:
    url: https://winget.contoso.example.com/cache
    source_type: Microsoft.Rest
    trust_level: trusted
```

```puppet
include winget
```

For a reset to the defaults first:

```puppet
class { 'winget':
  sources                => {
    'contoso' => {
      url         => 'https://winget.contoso.example.com/cache',
      source_type => 'Microsoft.Rest',
      trust_level => 'trusted',
    },
  },
  sources_reset_defaults => true,
}
```

Direct use of the sub-class stays possible via the
`winget::sources::entries` key:

```puppet
class { 'winget::sources':
  entries        => { 'contoso' => 'https://winget.contoso.example.com/cache' },
  reset_defaults => true,
}
Class['winget'] -> Class['winget::sources']
```

The optional `header` parameter (REST auth header) is `Sensitive` and never
lands in logs or reports: the unwrapped value is passed to the child
process through an environment variable (`WINGET_SOURCE_HEADER`), never on
the command line, so it does not appear in debug output, process listings
or failure reports either.

#### Install Scope and Structured Parameters

The Puppet agent runs as **SYSTEM**. Packages installed with the default
user scope are invisible to `winget list` under SYSTEM (the provider then
sees them as absent and reinstalls on every run). Prefer machine scope for
agent-managed packages:

```puppet
class { 'winget':
  packages => {
    'Git.Git' => {
      ensure => installed,
      scope  => 'machine',
    },
  },
}
```

The same flags are available per package: `architecture` (`x64`,
`arm64`, ...), `location` (install directory, when supported),
`override` (verbatim installer arguments), `installer_type` and `locale`,
plus raw `install_options` / `uninstall_options` appended after the
structured flags. Fleet-wide, the default scope can also be set once via
`installBehavior.preferences.scope` (see
[Winget Client Settings](#winget-client-settings)) instead of repeating
`scope => 'machine'` everywhere.

#### On-Demand Upgrades with Bolt Tasks

For upgrades outside agent runs (Bolt, Puppet Enterprise orchestrator),
the module ships two tasks:

- `winget::list_upgrades`: read-only listing of packages with available
  upgrades (ID, installed and available versions).
- `winget::upgrade_now`: upgrade the given `ids`, or everything available
  (minus `exclude`, minus pinned packages unless `include_pinned`).
  Per-package failures are reported in the JSON result; a
  reboot-requesting installer yields `reboot_required: true`.

```bash
bolt task run winget::list_upgrades --targets windows-hosts
bolt task run winget::upgrade_now exclude='["Google.Chrome"]' --targets windows-hosts
```

#### Reboot Handling

A successful install/upgrade that requests a reboot (winget exit
`0x8A150109`/`0x8A15010A`/`0x8A15010B`) is treated as success with a warning, exactly like
`--allow-reboot` without rebooting. To actually reboot, wire the optional
`reboot_resource` parameter of `winget::packages` / `winget::upgrade` to a
`reboot` resource you declare (puppetlabs/reboot module):

```puppet
reboot { 'winget-reboot':
  when => pending,
}

class { 'winget::packages':
  entries         => { 'Git.Git' => 'latest' },
  reboot_resource => 'winget-reboot',
}
```

#### Winget Client Settings

The `winget::settings` class manages `settings.json` for the agent account
(SYSTEM by default), merging `config` with `experimental_features`. The
file is replaced wholesale on every run — it is NOT merged with whatever
settings.json already contains on the node — so declare every key you
care about. The parent `LocalState` directory is created automatically if
it does not exist yet (e.g. winget has never run interactively under that
profile):

```puppet
class { 'winget::settings':
  config => {
    'telemetry'       => { 'disable' => true },
    'installBehavior' => { 'preferences' => { 'scope' => 'machine' } },
  },
  experimental_features => { 'resume' => true },
}

Class['winget'] -> Class['winget::settings']
```

A Desired State Configuration file can be applied idempotently with
`winget::configure` (guarded by `winget configure test`):

```puppet
winget::configure { 'C:/Configs/workstation.winget': }

Class['winget'] -> Winget::Configure <| |>
```

#### Microsoft Store Source

> Note: `--source msstore` here is the winget CLI package source (passed
> through to `winget install`), not the bootstrap `source` parameter
> (`cdn`/`github`/`auto`).

```puppet
package { '9NBLGGH4VVD1':  # Example Store app ID
  ensure          => installed,
  provider        => winget,
  install_options => [{ 'source' => 'msstore' }],
}
```

#### Using String Array for install_options

```puppet
package { 'Git.Git':
  ensure          => installed,
  provider        => winget,
  install_options => ['--source', 'msstore'],
}
```

#### Uninstall a Package

```puppet
package { 'Git.Git':
  ensure   => absent,
  provider => winget,
}
```

#### With Additional Options

```puppet
package { 'Git.Git':
  ensure           => installed,
  provider         => winget,
  install_options  => ['--location', 'C:/Tools/Git', '--silent'],
  uninstall_options => ['--preserve-data'],
}
```

### Bootstrap Class Examples

#### Bootstrap method choice

The bootstrap class never invokes the `winget` CLI itself: that would be a
chicken-and-egg problem on nodes where winget is missing, and the `winget`
alias is unavailable in the agent/SYSTEM context anyway. Instead, all install
methods download (or accept) a real App Installer package and install it with
`Add-AppxPackage` through the fully qualified PowerShell executable:

- `cdn` downloads the Microsoft CDN distribution of App Installer
  (`https://aka.ms/getwinget`, a `.msixbundle`). This is the documented
  Microsoft download channel for App Installer, and unlike the Store app it
  works headless under SYSTEM with no Store dependency and no winget CLI.
  (`source => 'msstore'` is a deprecated alias for `cdn`: same download,
  logs a deprecation warning.) The `cdn` method always installs the latest
  published build; pin a version with one of the methods below instead.
  The install only runs when App Installer is
  absent: the bundle version and the inner payload version can differ, and
  Windows refuses downgrades (`0x80073D19`), so reinstalling over a newer
  build would fail.
- `github` downloads a versioned `Microsoft.DesktopAppInstaller` bundle from the
  `microsoft/winget-cli` GitHub releases. This is the recommended method for
  pinning an exact winget version.
- `local` installs a caller-supplied AppX/MSIX/MSIXBundle file (plus optional
  dependency packages) for fully offline environments.
- `auto` (the default) tries the `cdn` method first, then the `github`
  method as an independent fallback: the fallback has no ordering
  dependency on `cdn`, so it still runs when the `cdn` install
  fails. When a specific version is requested (`ensure => '1.8.2391'`),
  `auto` uses `github` directly, because the `cdn` download always serves
  the latest build and cannot honor a pin.

#### Minimal Bootstrap

```puppet
include winget
```

#### Latest from Microsoft CDN

> Note: the `cdn` method always installs the latest published build.
> To pin an exact version, use `source => 'github'` or `source_path`.
> (`source => 'msstore'` is a deprecated alias for `cdn`.)

```puppet
class { 'winget':
  ensure => 'present',
  source => 'cdn',
}
```

#### Pinned Version from GitHub Releases

```puppet
class { 'winget':
  ensure => '1.8.2391',
  source => 'github',
}
```

#### Offline Installation from Local File

```puppet
class { 'winget':
  ensure       => '1.8.2391',
  source_path  => 'C:/Sources/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle',
}
```

#### With Proxy

```puppet
class { 'winget':
  proxy => 'http://proxy.example.com:8080',
}
```

#### Disable Automatic Source Agreement Acceptance

```puppet
class { 'winget':
  accept_source_agreements => false,
}
```

#### Disable Bootstrap (Use Provider Only)

```puppet
class { 'winget':
  enable_winget => false,
}
```

#### Guarantee Ordering with Packages

```puppet
class { 'winget':
  ensure => present,
}

# All packages using winget provider will run after winget bootstrap
Class['winget'] -> Package <| provider == winget |>
```

`ensure => absent` on class `winget` removes winget without any `Package`
resource, so the collector above cannot cycle; `winget::packages` entries
cannot converge once winget itself is gone (a warning is logged).

#### First Run (Bootstrap and Packages in One Catalog)

On a node where winget is not installed yet, a `package` resource with
`provider => winget` fails with `Provider winget is not functional on this
host` if Puppet evaluates it before the bootstrap installed winget. Always
keep the ordering relationship above.

With that ordering, a single agent run converges: the provider re-resolves
`winget.exe` on every call while it is absent (a `nil` path is never
memoized), so the package installs once the bootstrap `exec` resources have
run. The prefetch listing taken before the bootstrap simply reports packages
as absent, which is correct on a host without winget. Without the ordering,
the first run may fail as above and only the second run (winget now present)
succeeds.

### Facts

The module provides four custom facts for inventory and conditional logic:

#### winget_path

Returns the absolute path to `winget.exe`, or `nil` if not found.

```puppet
# Usage in Puppet code
if $facts['winget_path'] {
  notify { "winget found at ${facts['winget_path']}": }
}
```

#### winget_version

Returns the version string of winget (e.g., `1.8.2391`), or `nil` if not found.

```puppet
# Usage in Puppet code
if $facts['winget_version'] and versioncmp($facts['winget_version'], '1.5.0') >= 0 {
  notify { 'winget version is >= 1.5.0': }
}
```

#### winget_upgrades

Returns structured upgrade rows for PuppetDB inventory and reporting, e.g.
`[{'id' => 'Git.Git', 'current_version' => '2.40.0',
'available_version' => '2.41.0'}]`, or `[]` when winget is absent or the
query fails. Used by `Class['winget::upgrade']` (one `package` per `id`).

```puppet
# Usage in Puppet code
$updates = $facts['winget_upgrades'].map |$row| {
  "${row['id']} ${row['current_version']} -> ${row['available_version']}"
}
```

#### winget_pins

Returns the list of pinned winget package IDs (`winget pin list`, e.g.
`['Google.Chrome']`), or `[]` when winget is absent, pins are unsupported,
or the query fails. Used by `Class['winget::upgrade']` (`respect_pins`)
and backing the provider `holdable` feature. Unlike `winget_upgrades`,
this is a fast local query (no source round-trips) and is always enabled.

## Reference

Full Puppet Strings reference is available in [REFERENCE.md](REFERENCE.md),
generated with `pdk bundle exec puppet strings generate --format markdown`.

### Classes

#### `winget`

Main class: bootstraps winget and optionally manages packages, sources
and settings from Hiera (`winget::packages`, `winget::sources`,
`winget::settings`). See [Bootstrap Class Examples](#bootstrap-class-examples)
and [REFERENCE.md](REFERENCE.md#winget).

`source` accepts `'cdn'` (Microsoft CDN, preferred), `'github'`, `'auto'`
(default) and `'msstore'` (deprecated alias for `'cdn'`).

#### `winget::packages`

Declares one `package` with the winget provider per entry of a
Hiera-friendly hash, with structured install parameters (`scope`,
`architecture`, `location`, `override`, ...), optional `schedule`, optional
`reboot_resource` wiring, and a `hold` flag mapped to `winget pin`.
See [Declaring Packages from Hiera](#declaring-packages-from-hiera-wingetpackages)
and [REFERENCE.md](REFERENCE.md#winget--packages).

#### `winget::upgrade`

Declares one `package` with `ensure => latest` per `id` from the
`winget_upgrades` fact. See [Bulk Upgrade](#bulk-upgrade-all-packages-with-available-updates)
and [REFERENCE.md](REFERENCE.md#winget--upgrade).

#### `winget::sources`

Manages winget package sources from a Hiera-friendly hash, with an
optional reset to the defaults first. See
[Private Package Sources](#private-package-sources) and
[REFERENCE.md](REFERENCE.md#winget--sources).

#### `winget::settings`

Manages the winget client configuration (`settings.json`) for the agent
account, including experimental features. See
[Winget Client Settings](#winget-client-settings) and
[REFERENCE.md](REFERENCE.md#winget--settings).

### Defined Types

#### `winget::source`

Manages a single winget package source (`winget source add/remove`),
including private `Microsoft.Rest` sources.

#### `winget::pin`

Manages blocking and version-gating pins (`winget pin add/remove`) beyond
the provider `holdable` feature.

#### `winget::configure`

Applies a winget configuration file idempotently (`winget configure`,
guarded by `winget configure test`).

#### `winget::install::msstore`

Installs winget from the Microsoft CDN (`https://aka.ms/getwinget`).
Backs both `source => 'cdn'` (preferred) and the deprecated
`source => 'msstore'` alias: never the Store app.

#### `winget::install::github`

Installs winget from GitHub releases.

#### `winget::install::local`

Installs winget from a local AppX/MSIX/MSIXBundle file.

### Data Types

`types/` aliases for structured parameters: `Winget::Package` /
`Winget::PackagesHash` (see `winget::packages`), `Winget::SourceEntry` /
`Winget::SourcesHash` (see `winget::sources`). See [REFERENCE.md](REFERENCE.md).

### Bolt Tasks

- `winget::list_upgrades`: read-only listing of available upgrades
  (ID, installed and available versions) for on-demand inventory.
- `winget::upgrade_now`: upgrade the given `ids` now, or everything
  available (minus `exclude`, minus pins unless `include_pinned`).

See [On-Demand Upgrades with Bolt Tasks](#on-demand-upgrades-with-bolt-tasks).

### Provider

#### `winget` (package provider)

Provider for the `package` type using Windows Package Manager.

**Features**: installable, uninstallable, upgradeable, versionable, install_options, uninstall_options, holdable

**Hold support**: `mark => hold` maps to `winget pin add` (plain pinning:
excluded from `upgrade --all`, explicit upgrades still allowed);
`mark => none` (default) maps to `winget pin remove`.

**Default flags** (always after the subcommand; only flags documented for that subcommand are used):
- `install` / `upgrade`: `--accept-package-agreements --accept-source-agreements --disable-interactivity --exact --silent`
- `uninstall`: `--accept-source-agreements --disable-interactivity --exact --silent` (no package agreements)
- `show` / `list` / `pin list`: see `lib/puppet/provider/package/winget.rb` (`SHOW_FLAGS`, `LIST_FLAGS`, `PIN_FLAGS`)

**Source selection**: via `install_options` parameter (hash with `source` key or string array)

**Exit code handling**: Maps winget exit codes to idempotent behavior with meaningful errors.

### Facts

#### `winget_path`

Type: String or nil
Description: Absolute path to winget.exe, or nil if not found.

#### `winget_version`

Type: String or nil
Description: Version of winget (e.g., `1.8.2391`), or nil if not found.

#### `winget_upgrades`

Type: Array of Hash (`id`, `current_version`, `available_version`)
Description: Structured upgrade rows for PuppetDB inventory and reporting
(e.g. `[{'id' => 'Git.Git', 'current_version' => '2.40.0',
'available_version' => '2.41.0'}]`), or `[]` when winget is absent or the
query fails. Read by `Class['winget::upgrade']` (one `package` per `id`).

#### `winget_pins`

Type: Array of String
Description: Pinned winget package IDs (`winget pin list`), or `[]` when
winget is absent or the query fails. Read by `Class['winget::upgrade']`
(`respect_pins`) and backing the provider `holdable` feature.

## Limitations

### Install Scope under SYSTEM

The Puppet agent runs as SYSTEM: prefer `scope => 'machine'` for
agent-managed packages (or the `installBehavior.preferences.scope`
setting via `winget::settings`). User-scope installs are invisible to
`winget list` under SYSTEM, so the provider would report them absent and
reinstall on every run. See
[Install Scope and Structured Parameters](#install-scope-and-structured-parameters).

### SYSTEM Context and WindowsApps ACL

The Puppet agent runs as SYSTEM. The `winget` executable lives in `%ProgramFiles%\WindowsApps\Microsoft.DesktopAppInstaller_*`, which by default has restricted ACLs. The SYSTEM account may not have read access to this folder.

**Workaround**: Ensure SYSTEM has read access to `%ProgramFiles%\WindowsApps`. This can be done via Group Policy, PowerShell, or during image creation.

```powershell
# PowerShell example to grant SYSTEM read access
$acl = Get-Acl "C:\Program Files\WindowsApps"
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM","ReadAndExecute","ContainerInherit,ObjectInherit","None","Allow")
$acl.AddAccessRule($rule)
Set-Acl "C:\Program Files\WindowsApps" $acl
```

### Windows Server Support

- Windows Server 2019, 2022 and 2025 are supported
- Windows Server 2016 and earlier are **not supported** (winget requires Windows 10 1809+ / Server 2019+)
- Some packages may not be available on Server editions

### Source Agreements

By default, the bootstrap class accepts source agreements automatically (`accept_source_agreements => true`). This is required for Microsoft Store source. Set to `false` if you need to handle agreements manually.

### Offline Installation

Offline installation via `source_path` requires a valid Microsoft.DesktopAppInstaller `.appx`, `.msix`, `.msixbundle`, or `.appxbundle` file with all dependencies. Dependency files must be provided separately via the `dependencies` parameter. When `source_path` is set it takes precedence: only the local file is installed and no `cdn`/`github` download is attempted.

```puppet
class { 'winget':
  ensure       => '1.8.2391',
  source_path  => 'C:/Sources/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle',
  dependencies => ['C:/Sources/Microsoft.VCLibs.x64.appx'],
}
```

### Architecture Support

- x64: Fully supported
- arm64: Supported (path resolver detects arm64 variants)
- x86: Not supported by winget itself

## Troubleshooting

### winget provider reports "unsuitable"

**Error**: `winget provider is unsuitable: winget.exe not found in WindowsApps`

**Causes**:
1. winget is not installed → Use the `winget` class to bootstrap it
2. SYSTEM cannot read `%ProgramFiles%\WindowsApps` → Fix ACLs as described above
3. winget is installed but in an unexpected location → Report an issue
4. First run without ordering: a `package` with `provider => winget` evaluated
   before the bootstrap fails with `Provider winget is not functional on this
   host` → Add `Class['winget'] -> Package <| provider == winget |>` (see
   [First Run](#first-run-bootstrap-and-packages-in-one-catalog))

### Package installation fails with exit code 0x8A150014 (NO_APPLICATIONS_FOUND) or 0x8A150017 (NO_MANIFEST_FOUND)

**Cause**: Package ID not found in the configured source.

**Solutions**:
- Verify the package ID: `winget search <name>`
- Try a different source: `install_options => [{ 'source' => 'msstore' }]`
- Check if the package exists in the winget repository

### Package install reports already installed (0x8A150061 / 0x8A15010D)

**Cause**: The package (or another version of it) is already installed
(`APPINSTALLER_CLI_ERROR_PACKAGE_ALREADY_INSTALLED` / `APPINSTALLER_CLI_ERROR_INSTALL_ALREADY_INSTALLED`).

**Solution**: This is treated as idempotent success. No action needed.

### Package installation fails with exit code 0x8A150010 (NO_APPLICABLE_INSTALLER)

**Cause**: None of the installers are applicable for the current system
(e.g. wrong architecture/OS requirements).

**Solutions**:
- Check the package manifest for supported architectures and OS versions
- Try a different package version or source

### Package installation fails with exit code 0x8A150001 (INTERNAL_ERROR) or 0x8A150003 (COMMAND_FAILED)

**Cause**: Generic winget failure (internal error / command failed). These
are not success codes: the install did not complete.

**Solutions**:
- Rerun with debug logging and inspect the winget log (`winget --open-logs`)
- Look up the exact code with `winget error <code>`

### Package installation requests a reboot (0x8A150109 / 0x8A15010A / 0x8A15010B)

**Cause**: Installation succeeded but requires a reboot.

**Solution**: Schedule a reboot. Puppet will warn but treat as success.

### winget list fails during an agent run

**Symptom**: A `winget` package resource raises `Cannot determine whether
package '<id>' is installed: winget list failed this run` instead of
installing or reporting a clean state.

**Cause**: `winget list` itself returned a non-zero exit code or raised
(transient winget/WinRT glitch, corrupted index, etc.). The provider
deliberately refuses to treat this as "nothing installed" (which would
trigger pointless, potentially disruptive reinstalls of packages that are
actually already present) and instead fails the resource so the run is
retried.

**Solutions**:
- Rerun the agent; this is usually transient
- Run `winget list` by hand on the node to diagnose a persistent failure
- Check `winget --info` / `winget --open-logs` for a corrupted source index

### `winget::pin`, `winget::source`, `winget::sources`, `winget::configure` or `winget::settings` do nothing on the first run (warn and converge next run)

**Symptom**: No exec/file resource shows up in the report for one of these
resources on a freshly bootstrapped node, with a `Puppet.warning` such as
`winget::pin[...]: winget_path fact is not yet set (...)`.

**Cause**: These resources are gated on `$facts['winget_path']`, which is
`nil` until winget has actually run once on the node (e.g. mid-bootstrap,
before the `winget_path` fact has a value to report). They converge
automatically on the next run once the fact is populated.

**Solution**: This is expected and now explicitly warned about instead of
being silent; order these resources after the bootstrap class so they
converge as soon as possible:

```puppet
Class['winget'] -> Winget::Pin <| |>
Class['winget'] -> Winget::Source <| |>
Class['winget'] -> Class['winget::sources']
Class['winget'] -> Winget::Configure <| |>
Class['winget'] -> Class['winget::settings']
```

### winget bootstrap fails on Windows Server

**Cause**: The bootstrap does not use the Microsoft Store: it downloads App Installer
from the Microsoft CDN (`aka.ms/getwinget`) or GitHub. On a server this usually fails
because the download is blocked (proxy, firewall) or because the framework
dependencies (VCLibs / UI.Xaml) are missing.

**Solutions**:
- Set the `proxy` parameter if the server reaches the internet through a proxy
- Use `source => 'github'` instead
- Use `source_path` with a local AppX/MSIX file, plus `dependencies` for the VCLibs / UI.Xaml packages

### Cannot uninstall App Installer (NonRemovable Store package)

**Cause**: A Store-installed `Microsoft.DesktopAppInstaller` can be flagged
`NonRemovable`: both `Remove-AppxPackage -AllUsers` and
`Remove-AppxProvisionedPackage -Online` then fail with "Removal failed".
This was observed live on Windows Server 2025 (App Installer 1.29.380.0,
`SignatureKind=Store`, absent from the provisioned list).

**Consequences**: the bootstrap installers only run when App Installer is
absent (presence guard), so this never blocks Puppet runs — but you cannot
force a reinstall/downgrade via the module on such a host. Windows also
refuses downgrades (`0x80073D19`) when a bundle payload is older than the
installed build.

### winget_version fact returns nil but winget is installed

**Causes**:
1. `winget --version` fails to execute → Check SYSTEM access to winget.exe
2. winget.exe is corrupted → Reinstall via bootstrap class

### Proxy not working

**Cause**: Proxy configuration not passed correctly.

**Solutions**:
- Ensure `proxy` parameter includes scheme: `http://proxy:8080`
- Verify proxy allows HTTPS to GitHub and the Microsoft CDN (`aka.ms`)
- Check SYSTEM account proxy settings

## Development

### Running Tests

```bash
# Unit tests
pdk test unit

# Validation
pdk validate
```

### Generating Documentation

```bash
# Generate REFERENCE.md
pdk bundle exec puppet strings generate --format markdown
```

### Code Style

- Ruby: RuboCop (PDK default config)
- Puppet: puppet-lint (PDK default config)
- All code, comments, docs, and commit messages MUST be in English

### Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes with tests
4. Run `pdk validate` and `pdk test unit`
5. Submit a pull request

## Acceptance Testing

### CI (Windows runner, real `puppet apply`, no Litmus)

The `acceptance` CI job runs on `windows-latest` with a real Puppet agent.
It is part of the gate and never degrades to a syntax-only check:

1. Installs `puppet-agent` via Chocolatey.
2. Stages the repo as the `winget` module in the agent modulepath.
3. Applies `class { 'winget': ensure => present }` with
   `--detailed-exitcodes` (first run: 0 or 2), then applies the same manifest
   again and requires exit code 0 (idempotency).
4. Checks `winget --version`, then evaluates a noop catalog with a
   `package { 'Git.Git': provider => winget }` ordered after
   `Class['winget']` to prove the provider loads without installing anything.

### Optional Litmus runs (local only)

The `spec/acceptance` Litmus suite is kept for local runs against a
provisioned Windows target, but CI does not use it. Running it requires:

1. A Windows test VM (Azure, AWS, or local Hyper-V)
2. WinRM configured and accessible
3. Appropriate credentials

To run them locally:

```bash
# Install litmus
gem install puppet_litmus

# Provision a Windows node
litmus provision --platform windows_server_2022 --inventory inventory.yaml

# Run acceptance tests
pdk bundle exec rake 'litmus:acceptance:parallel'
```

**Note**: This requires a paid cloud account or local Hyper-V setup. See the [Litmus documentation](https://github.com/puppetlabs/puppet_litmus) for details.

## License

Apache-2.0