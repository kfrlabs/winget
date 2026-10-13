# frozen_string_literal: true

require 'spec_helper'

describe 'winget::install::github' do
  let(:facts) do
    {
      # Legacy facts: facterdb provides them and rspec-puppet stubs
      # Facter from them, which the exec providers use for confinement.
      # Without them no exec provider is suitable on Puppet 7.
      'operatingsystem' => 'windows',
      'osfamily' => 'windows',
      os: {
        family: 'windows',
        name: 'windows',
        release: { major: '10', full: '10' },
        architecture: 'x86_64',
      },
    }
  end
  let(:title) { 'winget' }

  it { is_expected.to compile.with_all_deps }

  it 'downloads the latest bundle without a pin' do
    is_expected.to contain_exec('winget_install_github_winget')
      .with_command(%r{releases/latest/download})
  end

  it 'falls back to provisioning when Add-AppxPackage fails under SYSTEM' do
    is_expected.to contain_exec('winget_install_github_winget')
      .with_command(%r{Add-AppxProvisionedPackage -Online -PackagePath .* -SkipLicense})
  end

  context 'with a pinned version' do
    let(:params) { { ensure: '1.8.2391' } }

    it { is_expected.to compile.with_all_deps }

    it 'downloads the pinned release' do
      is_expected.to contain_exec('winget_install_github_winget')
        .with_command(%r{releases/download/v1\.8\.2391/})
    end

    it 'guards on the installed version so the pin converges' do
      is_expected.to contain_exec('winget_install_github_winget')
        .with_unless(%r{-match '\^1\\.8\\.2391\(\\.|\$\)'})
    end
  end
end
