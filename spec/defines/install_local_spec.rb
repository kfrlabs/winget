# frozen_string_literal: true

require 'spec_helper'

describe 'winget::install::local' do
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
  let(:title) { 'winget_local' }
  let(:params) { { source_path: 'C:/Sources/winget.appx' } }

  it { is_expected.to compile.with_all_deps }

  it 'uses an unless guard instead of an inverted onlyif' do
    is_expected.to contain_exec('winget_install_local_winget_local').without_onlyif
    is_expected.to contain_exec('winget_install_local_winget_local').with_unless(%r{Get-AppxPackage})
  end

  it 'falls back to provisioning when Add-AppxPackage fails under SYSTEM' do
    is_expected.to contain_exec('winget_install_local_winget_local')
      .with_command(%r{Add-AppxProvisionedPackage -Online -PackagePath .* -SkipLicense})
  end

  context 'with dependencies' do
    let(:params) do
      {
        source_path: 'C:/Sources/winget.appx',
        dependencies: ['C:/Sources/VCLibs.appx'],
      }
    end

    it { is_expected.to compile.with_all_deps }

    it 'reads the dependency identity from the embedded manifest, not Get-AppxPackageManifest -Path' do
      dep = catalogue.resource('Exec[winget_install_dep_C:/Sources/VCLibs.appx_winget_local]')
      expect(dep).not_to be_nil
      expect(dep[:unless]).to match(%r{System\.IO\.Compression\.ZipFile})
      expect(dep[:unless]).to match(%r{AppxManifest\.xml})
      expect(dep[:unless]).to match(%r{AppxBundleManifest\.xml})
      expect(dep[:unless]).not_to match(%r{Get-AppxPackageManifest -Path})
    end

    it 'skips dependencies that are already installed' do
      dep = catalogue.resource('Exec[winget_install_dep_C:/Sources/VCLibs.appx_winget_local]')
      expect(dep[:unless]).to match(%r{Get-AppxPackage -AllUsers -Name})
      expect(dep[:onlyif]).to be_nil
    end
  end

  context 'with a pinned version' do
    let(:params) { { source_path: 'C:/Sources/winget.appx', ensure: '1.8.2391' } }

    it 'guards on the installed version so the pin converges' do
      is_expected.to contain_exec('winget_install_local_winget_local')
        .with_unless(%r{-match '\^1\\.8\\.2391\(\\.|\$\)'})
    end
  end
end
