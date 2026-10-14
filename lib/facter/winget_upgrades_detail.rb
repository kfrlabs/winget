# frozen_string_literal: true

# winget_upgrades_detail fact
# Returns structured upgrade rows for PuppetDB inventory and reporting: an
# array of hashes with the package ID, the installed version and the
# available version, e.g.
# `[{'id' => 'Git.Git', 'current_version' => '2.40.0', 'available_version' => '2.41.0'}]`,
# or an empty array when winget is absent or the query fails. Never raises.
#
# Cost note: shares a single memoized `winget upgrade` invocation per agent
# run with the `winget_upgrades` fact (same `WINGET_UPGRADES_ENABLED=false`
# opt-out and facter.conf TTL caching apply).

require 'puppet_x/winget/facts'

Facter.add('winget_upgrades_detail') do
  confine kernel: :windows

  setcode do
    PuppetX::Winget::Facts.upgrade_details
  end
end
