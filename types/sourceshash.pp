# frozen_string_literal: true

# @summary Hash of winget package sources for `winget::sources`.
#   Keys are winget source names. Values are either a shorthand URL string
#   (added as a default source) or a full `Winget::SourceEntry` hash.
#   Designed for Hiera (`winget::sources::sources`):
#
#   ```yaml
#   winget::sources::sources:
#     contoso: https://winget.contoso.example.com/cache
#     partners:
#       url: https://winget.partners.example.com/cache
#       source_type: Microsoft.Rest
#       trust_level: trusted
#   ```
#
#   Named `SourcesHash` (rather than `Sources`) because Puppet folds
#   definition names case-insensitively: `Winget::Sources` would collide
#   with the `winget::sources` class.
type Winget::SourcesHash = Hash[String[1], Variant[String[1], Winget::SourceEntry]]
