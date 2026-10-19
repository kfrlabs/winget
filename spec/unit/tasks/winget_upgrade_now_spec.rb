# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'winget upgrade_now task (issue #37)' do
  let(:content) { File.read(File.expand_path('../../../tasks/upgrade_now.ps1', __dir__)) }

  it 'fails closed with winget/invalid-input instead of falling back to defaults' do
    expect(content).to include('winget/invalid-input')
    expect(content).not_to include('fall back to defaults')
  end

  it 'exits 1 before winget runs when input cannot be parsed' do
    invalid_pos = content.index('winget/invalid-input')
    find_winget_pos = content.index('$winget = Find-Winget')
    expect(invalid_pos).not_to be_nil
    expect(find_winget_pos).not_to be_nil
    expect(invalid_pos).to be < find_winget_pos
    expect(content).to match(%r{exit 1})
  end

  it "validates ids as an array of non-empty strings without whitespace" do
    expect(content).to match(%r{'ids' must be an array})
    expect(content).to match(%r{'ids' entries must be non-empty strings without whitespace})
  end

  it "validates exclude and include_pinned types" do
    expect(content).to match(%r{'exclude' must be an array})
    expect(content).to match(%r{'include_pinned' must be a boolean})
  end

  it 'keeps valid input behaviour (empty ids enumerates upgrades)' do
    expect(content).to include('Get-UpgradableIds')
    expect(content).to match(%r{if \(\$taskParams\.ids\.Count -gt 0\)})
  end
end
