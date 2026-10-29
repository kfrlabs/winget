# frozen_string_literal: true

# winget_pins fact
# Returns the list of pinned winget package IDs (`winget pin list`, e.g.
# `['Google.Chrome']`), or an empty array when winget is absent, pins are
# unsupported, or the query fails. Never raises.
#
# Used by `Class['winget::upgrade']` (`respect_pins`) to skip pinned packages,
# and backing the provider `holdable` feature (`mark => hold`).
# Unlike `winget_upgrades`, this fact is a fast local query (no source
# round-trips) and is always enabled.

require 'puppet_x/winget/facts'

Facter.add('winget_pins') do
  confine kernel: :windows

  setcode do
    # Per-resolution scoping: drop the previous resolution's cached output
    # so this resolution re-runs winget once (repeated helper calls within
    # this resolution still share that single invocation).
    PuppetX::Winget::Facts.clear_resolution_cache!
    PuppetX::Winget::Facts.pinned_ids
  end
end
