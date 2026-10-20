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

  it 'installs with default retries' do
    is_expected.to contain_exec('winget_install_local_winget_local')
      .with_tries(3)
      .with_try_sleep(10)
  end

  it 'declares no dependency exec without dependencies' do
    is_expected.to have_exec_resource_count(1)
  end

  %w[.appx .msix .msixbundle .appxbundle].each do |ext|
    context "with a #{ext} bundle" do
      let(:params) { { source_path: "C:/Sources/winget#{ext}" } }

      it { is_expected.to compile.with_all_deps }

      it 'installs the local file' do
        is_expected.to contain_exec('winget_install_local_winget_local')
          .with_command(%r{Add-AppxPackage -Path 'C:/Sources/winget})
      end
    end
  end

  %w[.exe .msi .zip].each do |ext|
    context "with an invalid #{ext} file" do
      let(:params) { { source_path: "C:/Sources/winget#{ext}" } }

      it { expect { catalogue }.to raise_error(Puppet::Error, %r{Invalid file extension}) }
    end
  end

  context 'with a path without extension' do
    let(:params) { { source_path: 'C:/Sources/winget' } }

    it { expect { catalogue }.to raise_error(Puppet::Error, %r{Invalid file extension}) }
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

  context 'with several dependencies' do
    let(:params) do
      {
        source_path: 'C:/Sources/winget.appx',
        dependencies: ['C:/Sources/VCLibs.appx', 'C:/Sources/UIXaml.appx'],
      }
    end

    it { is_expected.to compile.with_all_deps }

    it 'declares one exec per dependency plus the bundle itself' do
      is_expected.to have_exec_resource_count(3)
      is_expected.to contain_exec('winget_install_dep_C:/Sources/VCLibs.appx_winget_local')
      is_expected.to contain_exec('winget_install_dep_C:/Sources/UIXaml.appx_winget_local')
      is_expected.to contain_exec('winget_install_local_winget_local')
    end
  end

  context 'with a pinned version' do
    let(:params) { { source_path: 'C:/Sources/winget.appx', ensure: '1.8.2391' } }

    it 'guards on the installed version so the pin converges' do
      is_expected.to contain_exec('winget_install_local_winget_local')
        .with_unless(%r{-match '\^1\\.8\\.2391\(\\.|\$\)'})
    end
  end

  context 'with deprecated version parameter' do
    let(:params) { { source_path: 'C:/Sources/winget.appx', version: '1.8.2391' } }

    it { is_expected.to compile.with_all_deps }

    it 'guards on the installed version so the pin converges' do
      is_expected.to contain_exec('winget_install_local_winget_local')
        .with_unless(%r{-match '\^1\\.8\\.2391\(\\.|\$\)'})
    end
  end

  context 'with ensure => absent' do
    let(:params) { { source_path: 'C:/Sources/winget.appx', ensure: 'absent' } }

    it { is_expected.to compile.with_all_deps }

    it 'removes App Installer instead of installing it' do
      is_expected.to contain_exec('winget_uninstall_local_winget_local')
        .with_command(%r{Remove-AppxPackage -AllUsers})
        .with_onlyif(%r{Get-AppxPackage -AllUsers Microsoft\.DesktopAppInstaller})
    end

    it 'also removes the staged provisioned package (Remove-AppxPackage alone fails with 0x80070032 on staged images)' do
      exec = catalogue.resource('Exec[winget_uninstall_local_winget_local]')
      expect(exec[:command]).to match(%r{Remove-AppxProvisionedPackage -Online})
      expect(exec[:command]).to match(%r{still installed})
      expect(exec[:onlyif]).to match(%r{Get-AppxProvisionedPackage -Online})
    end

    it 'declares no install exec and no dependency exec' do
      is_expected.not_to contain_exec('winget_install_local_winget_local')
      is_expected.to have_exec_resource_count(1)
    end
  end
end
