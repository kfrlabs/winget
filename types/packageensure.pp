# frozen_string_literal: true

# @summary Permitted short-form `ensure` values for winget packages.
#
# `present`, `installed`, `absent`, `purged`, `latest` or a version string
# (plain numeric like `2.40.0`, or suffixed like `2.40.0.windows.1`).
# Anything else — including typos such as `presnt` — fails compilation
# (issue #71). Shared by the shorthand string and the `ensure` key of
# `Winget::Package` so both forms reject the same typos.
type Winget::PackageEnsure = Variant[Enum['present', 'installed', 'absent', 'purged', 'latest'], Pattern[/\A\d[\w.+-]*\z/]]
