# frozen_string_literal: true

# winget_upgrades fact
# Opt-in structured upgrade inventory for PuppetDB reporting: an array of
# hashes with the package ID, the installed version and the available
# version, e.g.
# `[{'id' => 'Git.Git', 'current_version' => '2.40.0', 'available_version' => '2.41.0'}]`,
# or an empty array when winget is absent or the query fails. Never raises.
#
# Disabled by default: set `WINGET_UPGRADES_ENABLED=true` (also accepts `1`,
# `yes`, `on`) to populate it. Nodes that do not declare
# `Class['winget::upgrade']` then never pay for a `winget upgrade` source
# round-trip during fact resolution.
#
# `Class['winget::upgrade']` does not need this fact: it enumerates on demand
# through the `winget::upgrades` function and only falls back to these rows
# for server-side compilation (where the function runs without winget).
#
# Cost note: when enabled, the fact runs `winget upgrade` once per agent run
# (source round-trips, a few seconds) even when the upgrades are skipped by
# a Puppet `schedule` metaparameter: the schedule only skips the `package`
# resources outside the window, it does not skip the fact. When upgrades are
# confined to a maintenance window, cache the fact with a TTL in facter.conf
# so the inventory cost is paid at most once per window:
#
#   facts: {
#     ttls: [{ "winget_upgrades": "7 days" }]
#   }
#
# Consent note: enumeration passes `--accept-source-agreements`, kept
# deliberately so winget can never prompt (or stall where nothing answers);
# the provider and the Bolt tasks use the same flag for the upgrades applied
# from these rows.
#
# Every invocation runs with a timeout (120 s by default, `WINGET_COMMAND_TIMEOUT`
# overrides): a stuck winget returns `[]` instead of stalling the agent run.

require 'puppet_x/winget/facts'

Facter.add('winget_upgrades') do
  confine kernel: :windows

  setcode do
    # Per-resolution scoping: drop the previous resolution's cached output
    # so this resolution re-runs winget once (repeated helper calls within
    # this resolution still share that single invocation).
    PuppetX::Winget::Facts.clear_resolution_cache!
    PuppetX::Winget::Facts.winget_upgrades
  end
end
