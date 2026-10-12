# frozen_string_literal: true

# winget_upgrades fact
# Returns the list of winget package IDs with an available upgrade (e.g.
# `['Git.Git', 'Notepad++.Notepad++']`), or an empty array when winget is
# absent or the query fails. Never raises.
#
# Used by `Class['winget::upgrade']` to declare one `package` resource with
# `ensure => latest` per ID. Note the fact runs `winget upgrade` once per
# agent run (source round-trips, a few seconds) even when the packages are
# skipped by a Puppet `schedule` metaparameter.

require 'puppet_x/winget/facts'

Facter.add('winget_upgrades') do
  confine kernel: :windows

  setcode do
    PuppetX::Winget::Facts.winget_upgrades
  end
end
