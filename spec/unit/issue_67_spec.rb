# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'winget::upgrade execution-model discoverability (issue #67)' do
  let(:root) { File.expand_path('../..', __dir__) }

  it 'documents the compatibility table at the top of manifests/upgrade.pp' do
    content = File.read(File.join(root, 'manifests/upgrade.pp'))
    expect(content).to include('Execution model / compatibility')
    expect(content).to include('`puppet apply`')
    expect(content).to include('master/agent without the fact (default)')
    expect(content).to include('master/agent with `winget_upgrades` fact enabled')
  end

  it 'names the exact WINGET_UPGRADES_ENABLED switch in the fallback warning' do
    content = File.read(File.join(root, 'manifests/upgrade.pp'))
    expect(content).to match(%r{warning\(.*WINGET_UPGRADES_ENABLED=true}m)
  end

  it 'records the Deferred/exec agent-side decision in manifests/upgrade.pp' do
    content = File.read(File.join(root, 'manifests/upgrade.pp'))
    expect(content).to match(%r{Agent-side execution decision}i)
    expect(content).to include('winget::upgrade_now')
  end

  it 'mirrors the compatibility table in README.md and REFERENCE.md' do
    readme = File.read(File.join(root, 'README.md'))
    expect(readme).to include('master/agent without the fact (default)')
    expect(readme).to include('WINGET_UPGRADES_ENABLED=true')

    reference = File.read(File.join(root, 'REFERENCE.md'))
    expect(reference).to include('master/agent without the fact (default)')
  end
end
