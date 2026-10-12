# winget

Puppet module for managing Windows packages via winget (Windows Package Manager).

## Description

This module adds a `winget` provider to the built-in Puppet `package` type, allowing you to manage Windows packages using the Windows Package Manager (winget).

## Requirements

- Puppet >= 8.0.0 < 9.0.0 (OpenVox 8 / Puppet 8 compatible)
- Windows Server 2019/2022 or Windows 10/11
- winget must be installed on the target node
- The SYSTEM account must have read access to `%ProgramFiles%\WindowsApps`

## Setup

### What winget affects

- Adds a new package provider `winget` to Puppet
- Does not install winget itself (see Limitations)

### Beginning with winget

```puppet
package { 'Git.Git':
  ensure   => installed,
  provider => winget,
}
```

## Usage

### Basic package installation

```puppet
package { 'Microsoft.VisualStudioCode':
  ensure   => installed,
  provider => winget,
}
```

### Install specific version

```puppet
package { 'Git.Git':
  ensure   => '2.40.0',
  provider => winget,
}
```

### Use Microsoft Store source

```puppet
package { '9NBLGGH4VVD1':  # Example Store app ID
  ensure         => installed,
  provider       => winget,
  install_options => [{ 'source' => 'msstore' }],
}
```

### Using string array for install_options

```puppet
package { 'Git.Git':
  ensure          => installed,
  provider        => winget,
  install_options => ['--source', 'msstore'],
}
```

### Uninstall a package

```puppet
package { 'Git.Git':
  ensure   => absent,
  provider => winget,
}
```

## Features

The winget provider supports:

- **installable** - Install packages
- **uninstallable** - Uninstall packages
- **upgradeable** - Upgrade packages to latest version
- **versionable** - Install specific versions
- **install_options** - Pass additional options to install command (e.g., source selection)
- **uninstall_options** - Pass additional options to uninstall command

## Default flags

The provider always passes these flags to winget commands:

- `--accept-package-agreements`
- `--accept-source-agreements`
- `--disable-interactivity`
- `--exact`
- `--silent`

## How it works

### Path resolution

The provider does NOT use the `winget` alias (which is not available in the SYSTEM context). Instead, it resolves the absolute path:

```
$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe
```

It handles both x64 and arm64 variants and selects the highest version using proper version comparison (Gem::Version).

### Provider suitability

If winget is not found, the provider returns `unsuitable` with a clear message and does not break catalog compilation or other providers.

## Limitations

1. **winget must be pre-installed** - This module does not bootstrap winget. Part 2 of this project (bootstrap class, fact, docs) will address this.
2. **WindowsApps ACL** - The SYSTEM account (under which Puppet agent runs) may not have read access to `%ProgramFiles%\WindowsApps` by default. You must ensure the agent can read this folder.
3. **Windows only** - This provider is confined to Windows operatingsystems.
4. **Not default provider** - Explicit opt-in via `provider => winget` is required.

## Development

### Running tests

```bash
pdk test unit
```

### Validation

```bash
pdk validate
```

## Reference

### Provider: winget

Provider for the `package` type using Windows Package Manager.

#### Features

- installable
- uninstallable
- upgradeable
- versionable
- install_options
- uninstall_options

#### Parameters

- `ensure` - desired state: `installed`, `absent`, `latest`, or version string
- `install_options` - array of options passed to `winget install`
- `uninstall_options` - array of options passed to `winget uninstall`

## License

Apache-2.0
