# frozen_string_literal: true

# @summary Structured declaration of a single winget package.
#   Value type of `Winget::PackagesHash` (see `winget::packages`). Every key is
#   optional. `ensure`, `install_options`, `uninstall_options` and `schedule`
#   map to `package` resource attributes; `source`, `scope`, `architecture`,
#   `location`, `override`, `installer_type` and `locale` are translated into
#   `winget install`/`winget upgrade` flags; `hold` maps to the `mark`
#   property (`winget pin add` / `winget pin remove`).
type Winget::Package = Struct[{
  Optional['ensure']            => Variant[Enum['present', 'installed', 'absent', 'purged', 'latest'], String[1]],
  Optional['source']            => String[1],
  Optional['scope']             => Enum['user', 'machine'],
  Optional['architecture']      => Enum['x86', 'x64', 'arm', 'arm64'],
  Optional['location']          => String[1],
  Optional['override']          => String[1],
  Optional['installer_type']    => String[1],
  Optional['locale']            => String[1],
  Optional['hold']              => Boolean,
  Optional['install_options']   => Array,
  Optional['uninstall_options'] => Array,
  Optional['schedule']          => String[1],
}]
