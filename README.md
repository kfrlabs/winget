# winget

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

This module provides a `winget` provider for Puppet's built-in `package` type, allowing you to manage Windows packages using the Windows Package Manager (winget). It also includes a `winget` class to bootstrap winget on systems where it is not pre-installed, and custom facts `winget_path` and `winget_version` for inventory and conditional logic.

## Requirements

- **Puppet**: >= 8.0.0 < 9.0.0 (OpenVox 8 / Puppet 8 compatible)
- **Operating System**: Windows 10 1809 (build 17763) or later, Windows Server 2019, 2022 or 2025
- **Architecture**: x64 and arm64 supported
- **Internet Access**: Required for downloading winget from Microsoft Store or GitHub (unless using `source_path` for offline installation)
- **Proxy Support**: Configurable via `proxy` parameter
- **SYSTEM Account Access**: The SYSTEM account (under which Puppet agent runs) must have read access to `%ProgramFiles%\WindowsApps`. This is required for the path resolver to locate winget.exe.

## Setup

### What winget affects

- Adds a `winget` provider to Puppet's `package` type
- Optionally installs winget via the `winget` class (bootstrap)
- Creates custom facts `winget_path` and `winget_version`
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

#### Latest Version (Upgrade)

```puppet
package { 'Microsoft.VisualStudioCode':
  ensure   => latest,
  provider => winget,
}
```

#### Bulk Upgrade (all packages with available updates)

The `winget::upgrade` class reads the IDs from the `winget_upgrades` fact and
declares one `package` with `ensure => latest` per ID, so upgrades are regular
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

Note: the `winget_upgrades` fact runs `winget upgrade` once per agent run
even when the packages are skipped by the schedule; the schedule only skips
the `package` resources outside the window.

#### Microsoft Store Source

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

- `msstore` downloads the Microsoft CDN distribution of App Installer
  (`https://aka.ms/getwinget`, a `.msixbundle`). This is the documented
  Microsoft download channel for App Installer, and unlike the Store app it
  works headless under SYSTEM with no Store dependency and no winget CLI.
  It always installs the latest published build; pin a version with one of
  the methods below instead.
- `github` downloads a versioned `Microsoft.WinGet.Client` bundle from the
  `microsoft/winget-cli` GitHub releases. This is the recommended method for
  pinning an exact winget version.
- `local` installs a caller-supplied AppX/MSIX/MSIXBundle file (plus optional
  dependency packages) for fully offline environments.
- `auto` (the default) runs the `msstore` method first, then the `github`
  method as a fallback.

#### Minimal Bootstrap

```puppet
include winget
```

#### Specific Version from Microsoft Store

> Note: the `msstore` method always installs the latest published build.
> To pin an exact version, use `source => 'github'` or `source_path`.

```puppet
class { 'winget':
  ensure => 'present',
  source => 'msstore',
}
```

#### Pinned Version from GitHub Releases

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
  source_path  => 'C:/Sources/Microsoft.WinGet.Client_1.8.2391_x64.msixbundle',
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

### Facts

The module provides three custom facts for inventory and conditional logic:

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

Returns the list of winget package IDs with an available upgrade (e.g.
`['Git.Git']`), or `[]` when winget is absent or the query fails. Used by
`Class['winget::upgrade']` to declare one `package` per ID.

## Reference

Full Puppet Strings reference is available in [REFERENCE.md](REFERENCE.md),
generated with `pdk bundle exec puppet strings generate --format markdown`.

### Classes

#### `winget`

Main class for bootstrapping winget. See [Bootstrap Class Examples](#bootstrap-class-examples)
and [REFERENCE.md](REFERENCE.md#winget).

### Defined Types

#### `winget::install::msstore`

Installs winget from Microsoft Store.

#### `winget::install::github`

Installs winget from GitHub releases.

#### `winget::install::local`

Installs winget from a local AppX/MSIX/MSIXBundle file.

### Provider

#### `winget` (package provider)

Provider for the `package` type using Windows Package Manager.

**Features**: installable, uninstallable, upgradeable, versionable, install_options, uninstall_options

**Default flags passed to all commands**:
- `--accept-package-agreements`
- `--accept-source-agreements`
- `--disable-interactivity`
- `--exact`
- `--silent`

**Source selection**: via `install_options` parameter (hash with `source` key or string array)

**Exit code handling**: Maps winget exit codes to idempotent behavior with meaningful errors.

### Facts

#### `winget_path`

Type: String or nil
Description: Absolute path to winget.exe, or nil if not found.

#### `winget_version`

Type: String or nil
Description: Version of winget (e.g., `1.8.2391`), or nil if not found.

## Limitations

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

Offline installation via `source_path` requires a valid Microsoft.WinGet.Client or Microsoft.DesktopAppInstaller `.appx`, `.msix`, `.msixbundle`, or `.appxbundle` file with all dependencies. Dependency files must be provided separately via the `dependencies` parameter.

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

### Package installation fails with exit code 0x8A150006 (NOT_FOUND)

**Cause**: Package ID not found in the configured source.

**Solutions**:
- Verify the package ID: `winget search <name>`
- Try a different source: `install_options => [{ 'source' => 'msstore' }]`
- Check if the package exists in the winget repository

### Package installation fails with exit code 0x8A150001 (NO_APPLICABLE_INSTALLER)

**Cause**: Package is already installed.

**Solution**: This is treated as idempotent success. No action needed.

### Package installation fails with exit code 0x8A150003 (REBOOT_REQUIRED)

**Cause**: Installation succeeded but requires a reboot.

**Solution**: Schedule a reboot. Puppet will warn but treat as success.

### winget bootstrap fails on Windows Server

**Cause**: Microsoft Store may not be available on Server editions.

**Solutions**:
- Use `source => 'github'` instead
- Use `source_path` with a local AppX/MSIX file
- Install Microsoft Store on Server first (not recommended for production)

### winget_version fact returns nil but winget is installed

**Causes**:
1. `winget --version` fails to execute → Check SYSTEM access to winget.exe
2. winget.exe is corrupted → Reinstall via bootstrap class

### Proxy not working

**Cause**: Proxy configuration not passed correctly.

**Solutions**:
- Ensure `proxy` parameter includes scheme: `http://proxy:8080`
- Verify proxy allows HTTPS to GitHub and Microsoft Store endpoints
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

### Litmus Setup

This module includes optional Litmus acceptance testing configuration for Windows. However, running Windows acceptance tests requires:

1. A Windows test VM (Azure, AWS, or local Hyper-V)
2. WinRM configured and accessible
3. Appropriate credentials

Due to the complexity of Windows CI/CD infrastructure, acceptance tests are not run automatically in CI. To run them locally:

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