# frozen_string_literal: true

# @summary Permitted `ensure` values for winget bootstrap resources.
#
# `present`, `absent` or a dotted numeric version (e.g. `1.8.2391`).
# Anything else — including typos such as `presnt`, or `installed` /
# `latest`, which have no distinct meaning for the presence-based bootstrap
# — fails compilation (issue #45).
type Winget::Ensure = Variant[Enum['present', 'absent'], Pattern[/\A\d+(\.\d+)+\z/]]
