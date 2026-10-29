# frozen_string_literal: true

# @summary Hash of winget packages for `winget::packages`.
#   Keys are winget package IDs. Values are either a shorthand ensure string
#   (a `Winget::PackageEnsure`: `'present'`, `'installed'`, `'absent'`,
#   `'purged'`, `'latest'` or a version string — typos such as `'presnt'`
#   fail compilation, issue #71) or a full `Winget::Package` hash. Designed for Hiera (`winget::packages`, or
#   `winget::packages::entries` when declaring the sub-class directly):
#
#   ```yaml
#   winget::packages:
#     Git.Git:
#       ensure: present
#       scope: machine
#     Microsoft.VisualStudioCode:
#       ensure: latest
#   ```
#
#   Named `PackagesHash` (rather than `Packages`) because Puppet folds
#   definition names case-insensitively: `Winget::Packages` would collide
#   with the `winget::packages` class.
type Winget::PackagesHash = Hash[String[1], Variant[Winget::PackageEnsure, Winget::Package]]
