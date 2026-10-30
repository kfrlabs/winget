# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'winget tasks shared helper (issue #75)' do
  let(:helper) { File.read(File.expand_path('../../../tasks/winget_task_common.ps1', __dir__)) }

  it 'holds the numeric version sort in the shared helper' do
    # Numeric [version] comparison on the directory version segment.
    expect(helper).to match(%r{\[version\].*split.*_.*\[1\]})
    # No textual FullName descending sort remains.
    expect(helper).not_to match(%r{Sort-Object\s+FullName\s+-Descending})
  end

  it 'scans WindowsApps before PATH in the shared helper (Ruby resolver order)' do
    windows_apps_pos = helper.index('WindowsApps')
    get_command_pos = helper.index('Get-Command winget.exe')
    expect(windows_apps_pos).not_to be_nil
    expect(get_command_pos).not_to be_nil
    expect(windows_apps_pos).to be < get_command_pos
  end

  it 'slices tables by display width in the shared helper (issue #32)' do
    expect(helper).to include('Get-DisplayWidth')
    expect(helper).to include('Get-DisplaySubstring')
    expect(helper).to include('Test-WideCodepoint')
  end

  ['list_upgrades.ps1', 'upgrade_now.ps1'].each do |task|
    it "#{task} dot-sources the shared helper instead of redefining it" do
      content = File.read(File.expand_path("../../../tasks/#{task}", __dir__))
      sourcing = content.index("Join-Path $PSScriptRoot 'winget_task_common.ps1'")
      guard = content.index("if ($MyInvocation.InvocationName -eq '.') { return }")
      expect(sourcing).not_to be_nil
      expect(guard).not_to be_nil
      expect(sourcing).to be < guard
      ['Find-Winget', 'Test-TableSeparator', 'Test-WideCodepoint', 'Get-DisplayWidth', 'Get-DisplaySubstring',
       'Get-HeaderCellOffsets', 'Find-TableHeaders', 'Remove-ProgressFrames', 'Get-VisibleLines',
       'Get-ColumnOffsets', 'Test-TableHeader', 'Get-PinnedIds'].each do |function|
        expect(content).not_to include("function #{function}")
      end
    end
  end
end
