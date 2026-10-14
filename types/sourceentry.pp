# frozen_string_literal: true

# @summary Structured declaration of a single winget package source.
#   Value type of `Winget::SourcesHash` (see `winget::sources` and
#   `winget::source`). `url` maps to `winget source add --arg`; `source_type`
#   to `--type` (`Microsoft.PreIndexed.Package` or `Microsoft.Rest` for
#   private REST sources); `trust_level` to `--trust-level`; `explicit` to
#   `--explicit`; `header` to `--header` (REST source HTTP header, kept
#   `Sensitive` so it never lands in logs or reports).
#
#   Named `SourceEntry` (rather than `Source`) because Puppet folds
#   definition names case-insensitively: `Winget::Source` would collide with
#   the `winget::source` defined type.
type Winget::SourceEntry = Struct[{
  Optional['ensure']                   => Enum['present', 'absent'],
  Optional['url']                      => String[1],
  Optional['source_type']              => String[1],
  Optional['trust_level']              => Enum['none', 'trusted'],
  Optional['explicit']                 => Boolean,
  Optional['header']                   => Sensitive[String[1]],
  Optional['accept_source_agreements'] => Boolean,
}]
