# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'live acceptance coverage (issue #70)' do
  let(:root) { File.expand_path('../..', __dir__) }

  it 'covers winget::settings live with an idempotence assertion' do
    content = File.read(File.join(root, '.github/workflows/ci.yml'))
    expect(content).to include('winget::settings live as SYSTEM')
    expect(content).to include('winget_settings.pp')
    expect(content).to include('assert_settings.ps1')
  end

  it 'covers winget::packages from Hiera in the same catalog as the bootstrap' do
    content = File.read(File.join(root, '.github/workflows/ci.yml'))
    expect(content).to include('winget::packages from Hiera as SYSTEM')
    expect(content).to include('winget::packages::entries')
    expect(content).to include('--hiera_config')
  end

  it 'covers the winget::upgrade class and the upgrade_now task live' do
    content = File.read(File.join(root, '.github/workflows/ci.yml'))
    expect(content).to include('winget::upgrade class live as SYSTEM')
    expect(content).to include('Deliberately no machine')
    expect(content).to include('Task smoke test (upgrade_now) as SYSTEM')
  end

  it 'covers winget::configure convergence and the configure test guard live' do
    content = File.read(File.join(root, '.github/workflows/ci.yml'))
    expect(content).to include('winget::configure live as SYSTEM')
    expect(content).to include('acceptance_config.winget')
    expect(content).to include('assert_configure.ps1')
    expect(content).to include('0x80004002')
  end

  it 'documents the remaining live-coverage limits (issue #70)' do
    readme = File.read(File.join(root, 'README.md'))
    expect(readme).to include('Coverage limits (issue #70)')
    expect(readme).to include('windows-latest')
  end
end
