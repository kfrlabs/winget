# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/winget/facts'

describe 'winget::upgrades' do
  let(:rows) do
    [
      { 'id' => 'Git.Git', 'current_version' => '2.40.0', 'available_version' => '2.41.0' },
      { 'id' => 'Notepad++.Notepad++', 'current_version' => '8.5.4', 'available_version' => '8.6.0' },
    ]
  end
  let(:upgrade_output) do
    <<~OUTPUT
      Name              Id                      Version   Available   Source
      --------------------------------------------------------------------
      Git               Git.Git                 2.40.0    2.41.0      winget
      Notepad++         Notepad++.Notepad++     8.5.4     8.6.0       winget
      2 upgrades available.
    OUTPUT
  end

  before(:each) do
    PuppetX::Winget::Facts.reset!
  end

  after(:each) do
    PuppetX::Winget::Facts.reset!
  end

  it 'enumerates on demand, bypassing the opt-in inventory gate' do
    allow(PuppetX::Winget::Facts).to receive(:run_upgrade).with(nil, force: true).and_return(upgrade_output)
    is_expected.to run.with_params.and_return(rows)
  end

  it 'returns [] when the query succeeds with no rows' do
    allow(PuppetX::Winget::Facts).to receive(:run_upgrade).with(nil, force: true).and_return("No applicable update found.\n")
    is_expected.to run.with_params.and_return([])
  end

  it 'returns undef when winget is absent or the query fails instead of raising' do
    allow(PuppetX::Winget::Facts).to receive(:run_upgrade).with(nil, force: true).and_return(nil)
    is_expected.to run.with_params.and_return(nil)
  end

  it 'returns undef when enumeration raises instead of raising' do
    allow(PuppetX::Winget::Facts).to receive(:run_upgrade).and_raise(StandardError.new('boom'))
    is_expected.to run.with_params.and_return(nil)
  end

  it 'returns undef when the helper cannot be loaded instead of raising' do
    # LoadError (ScriptError, not StandardError): partially deployed or
    # stale module lib on the server must degrade to the fact fallback,
    # not fail catalog compilation with a 500.
    allow(PuppetX::Winget::Facts).to receive(:run_upgrade).and_raise(LoadError.new('cannot load such file -- puppet_x/winget/facts'))
    is_expected.to run.with_params.and_return(nil)
  end
end
