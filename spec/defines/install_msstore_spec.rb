# frozen_string_literal: true

require 'spec_helper'

describe 'winget::install::msstore' do
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

  it 'falls back to provisioning when Add-AppxPackage fails under SYSTEM' do
    is_expected.to contain_exec('winget_install_msstore_winget')
      .with_command(%r{Add-AppxProvisionedPackage -Online -PackagePath .* -SkipLicense})
  end

  it 'guards on presence since msstore always serves latest' do
    is_expected.to contain_exec('winget_install_msstore_winget')
      .with_unless(%r{Get-AppxPackage -AllUsers Microsoft\.DesktopAppInstaller})
  end

  it 'fails the run on error by default' do
    is_expected.to contain_exec('winget_install_msstore_winget').with_returns([0])
  end

  it 'sets no proxy environment by default' do
    exec = catalogue.resource('Exec[winget_install_msstore_winget]')
    expect(exec[:environment]).to be_nil
  end

  context 'with proxy' do
    let(:params) { { proxy: 'http://proxy.example.com:8080' } }

    it { is_expected.to compile.with_all_deps }

    it 'exports the proxy for the download' do
      is_expected.to contain_exec('winget_install_msstore_winget')
        .with_environment(['HTTPS_PROXY=http://proxy.example.com:8080', 'HTTP_PROXY=http://proxy.example.com:8080'])
    end
  end

  context 'with retry settings' do
    let(:params) { { retry_count: 5, retry_interval: 30 } }

    it { is_expected.to compile.with_all_deps }

    it 'forwards tries and try_sleep to the install exec' do
      is_expected.to contain_exec('winget_install_msstore_winget')
        .with_tries(5)
        .with_try_sleep(30)
    end
  end

  context 'with fail_on_error => false' do
    let(:params) { { fail_on_error: false } }

    it { is_expected.to compile.with_all_deps }

    it 'accepts exit code 1 so a failed attempt does not fail the run' do
      is_expected.to contain_exec('winget_install_msstore_winget').with_returns([0, 1])
    end
  end

  context 'with accept_source_agreements => false' do
    let(:params) { { accept_source_agreements: false } }

    it { is_expected.to compile.with_all_deps }

    it 'still declares the install exec (kept for interface consistency)' do
      is_expected.to contain_exec('winget_install_msstore_winget')
    end
  end

  context 'with a pinned version' do
    let(:params) { { ensure: '1.8.2391' } }

    it { is_expected.to compile.with_all_deps }

    it 'keeps the presence guard since cdn always serves latest' do
      exec = catalogue.resource('Exec[winget_install_msstore_winget]')
      expect(exec[:unless]).to match(%r{Get-AppxPackage -AllUsers Microsoft\.DesktopAppInstaller})
      expect(exec[:unless]).not_to match(%r{-match})
    end
  end

  context 'with deprecated version parameter' do
    let(:params) { { version: '1.8.2391' } }

    it { is_expected.to compile.with_all_deps }

    it 'keeps the presence guard since cdn always serves latest' do
      exec = catalogue.resource('Exec[winget_install_msstore_winget]')
      expect(exec[:unless]).to match(%r{Get-AppxPackage -AllUsers Microsoft\.DesktopAppInstaller})
      expect(exec[:unless]).not_to match(%r{-match})
    end
  end

  context 'with ensure => absent' do
    let(:params) { { ensure: 'absent' } }

    it { is_expected.to compile.with_all_deps }

    it 'removes App Installer instead of installing it' do
      is_expected.to contain_exec('winget_uninstall_msstore_winget')
        .with_command(%r{Remove-AppxPackage -AllUsers})
        .with_onlyif(%r{Get-AppxPackage -AllUsers Microsoft\.DesktopAppInstaller})
    end

    it 'declares no install exec' do
      is_expected.not_to contain_exec('winget_install_msstore_winget')
    end
  end
end
