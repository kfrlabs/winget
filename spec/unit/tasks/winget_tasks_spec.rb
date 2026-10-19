# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'winget tasks (issue #36)' do
  %w[list_upgrades.ps1 upgrade_now.ps1].each do |task|
    it "#{task} picks the highest version numerically, not textually" do
      content = File.read(File.expand_path("../../../tasks/#{task}", __dir__))
      # Numeric [version] comparison on the directory version segment.
      expect(content).to match(%r{\[version\].*split.*_.*\[1\]})
      # No textual FullName descending sort remains.
      expect(content).not_to match(%r{Sort-Object\s+FullName\s+-Descending})
    end

    it "#{task} scans WindowsApps before PATH (Ruby resolver order)" do
      content = File.read(File.expand_path("../../../tasks/#{task}", __dir__))
      windows_apps_pos = content.index('WindowsApps')
      get_command_pos = content.index('Get-Command winget.exe')
      expect(windows_apps_pos).not_to be_nil
      expect(get_command_pos).not_to be_nil
      expect(windows_apps_pos).to be < get_command_pos
    end

    it "#{task} slices tables by display width (issue #32)" do
      content = File.read(File.expand_path("../../../tasks/#{task}", __dir__))
      expect(content).to include('Get-DisplayWidth')
      expect(content).to include('Get-DisplaySubstring')
      expect(content).to include('Test-WideCodepoint')
    end
  end
end
