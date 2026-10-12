# frozen_string_literal: true

# winget_version fact
# Returns the version of winget (e.g. '1.8.2391'), or nil if not found.
# Uses the shared PuppetX::Winget::Facts helper (which reuses the path resolver)
# to avoid code duplication. Never raises.

require 'puppet_x/winget/facts'

Facter.add('winget_version') do
  confine kernel: :windows

  setcode do
    PuppetX::Winget::Facts.winget_version
  end
end
