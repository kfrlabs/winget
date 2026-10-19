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

  it 'sets no proxy environment by default' do
    exec = catalogue.resource('Exec[winget_install_github_winget]')
    expect(exec[:environment]).to be_nil
  end

  context 'with proxy' do
    let(:params) { { proxy: 'http://proxy.example.com:8080' } }

    it { is_expected.to compile.with_all_deps }

    it 'exports the proxy for the download' do
      is_expected.to contain_exec('winget_install_github_winget')
        .with_environment(['HTTPS_PROXY=http://proxy.example.com:8080', 'HTTP_PROXY=http://proxy.example.com:8080'])
    end
  end

  context 'with retry settings' do
    let(:params) { { retry_count: 5, retry_interval: 30 } }

    it { is_expected.to compile.with_all_deps }

    it 'forwards tries and try_sleep to the install exec' do
      is_expected.to contain_exec('winget_install_github_winget')
        .with_tries(5)
        .with_try_sleep(30)
    end
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

  context 'with deprecated version parameter' do
    let(:params) { { version: '1.8.2391' } }

    it { is_expected.to compile.with_all_deps }

    it 'pins the download from the version parameter' do
      is_expected.to contain_exec('winget_install_github_winget')
        .with_command(%r{releases/download/v1\.8\.2391/})
    end

    it 'guards on the installed version so the pin converges' do
      is_expected.to contain_exec('winget_install_github_winget')
        .with_unless(%r{-match '\^1\\.8\\.2391\(\\.|\$\)'})
    end
  end

  context 'with ensure => absent' do
    let(:params) { { ensure: 'absent' } }

    it { is_expected.to compile.with_all_deps }

    it 'removes App Installer instead of installing it' do
      is_expected.to contain_exec('winget_uninstall_github_winget')
        .with_command(%r{Remove-AppxPackage -AllUsers})
        .with_onlyif(%r{Get-AppxPackage -AllUsers Microsoft\.DesktopAppInstaller})
    end

    it 'also removes the staged provisioned package (Remove-AppxPackage alone fails with 0x80070032 on staged images)' do
      exec = catalogue.resource('Exec[winget_uninstall_github_winget]')
      expect(exec[:command]).to match(%r{Remove-AppxProvisionedPackage -Online})
      expect(exec[:command]).to match(%r{still installed})
      expect(exec[:onlyif]).to match(%r{Get-AppxProvisionedPackage -Online})
    end

    it 'declares no install exec' do
      is_expected.not_to contain_exec('winget_install_github_winget')
    end
  end

  context 'download hardening (issue #39)' do
    let(:command) { catalogue.resource('Exec[winget_install_github_winget]')[:command] }

    it { is_expected.to compile.with_all_deps }

    it 'downloads into a per-run unique directory instead of a fixed temp file' do
      expect(command).to match(%r{\[guid\]::NewGuid})
      expect(command).not_to match(%r{Join-Path \$env:TEMP 'winget\.msixbundle'})
    end

    it 'restricts the download directory to SYSTEM and Administrators' do
      expect(command).to match(%r{SetAccessRuleProtection})
      expect(command).to match(%r{NT AUTHORITY\\SYSTEM})
      expect(command).to match(%r{BUILTIN\\Administrators})
    end

    it 'removes the download directory on success and on failure' do
      expect(command).to match(%r{finally \{ Remove-Item -Recurse -Force .*\$workDir \}})
    end

    it 'fails closed unless the bundle signature is a valid Microsoft one' do
      expect(command).to match(%r{Get-AuthenticodeSignature})
      expect(command).to match(%r{O=Microsoft Corporation})
    end

    it 'disables the progress bar that slows down Invoke-WebRequest on PS 5.1' do
      expect(command).to match(%r{\$ProgressPreference = 'SilentlyContinue'})
    end
  end
end
