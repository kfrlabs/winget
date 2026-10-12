# frozen_string_literal: true

# winget_path fact
# Returns the absolute path to winget.exe, or nil if not found.
# Uses the shared PuppetX::Winget::Facts helper (which reuses the path resolver)
# to avoid code duplication. Never raises.

require 'puppet_x/winget/facts'

Facter.add('winget_path') do
  confine kernel: :windows

  setcode do
    PuppetX::Winget::Facts.winget_path
  end
end
