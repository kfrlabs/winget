# frozen_string_literal: true

# winget_upgrades fact
# Returns structured upgrade rows for PuppetDB inventory and reporting: an
# array of hashes with the package ID, the installed version and the
# available version, e.g.
# `[{'id' => 'Git.Git', 'current_version' => '2.40.0', 'available_version' => '2.41.0'}]`,
# or an empty array when winget is absent or the query fails. Never raises.
#
# Used by `Class['winget::upgrade']` (IDs are read from the `id` key) and for
# inventory/reporting.
#
# Cost note: the fact runs `winget upgrade` once per agent run (source
# round-trips, a few seconds) even when the packages are skipped by a Puppet
# `schedule` metaparameter: the schedule only skips the `package` resources
# outside the window, it does not skip the fact. When upgrades are confined
# to a maintenance window, cache the fact with a TTL in facter.conf so the
# cost is paid at most once per window:
#
#   facts: {
#     ttls: [{ "winget_upgrades": "7 days" }]
#   }
#
# Or opt out entirely with the `WINGET_UPGRADES_ENABLED=false`
# environment variable (or `facts: { blocklist: ["winget_upgrades"] }`):
# the fact then returns `[]` without shelling out.

require 'puppet_x/winget/facts'

Facter.add('winget_upgrades') do
  confine kernel: :windows

  setcode do
    PuppetX::Winget::Facts.winget_upgrades
  end
end
