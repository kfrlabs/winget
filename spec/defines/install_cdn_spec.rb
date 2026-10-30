# frozen_string_literal: true

require 'spec_helper'

describe 'winget::install::cdn' do
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
    is_expected.to contain_exec('winget_install_cdn_winget')
      .with_command(%r{Add-AppxProvisionedPackage -Online -PackagePath .* -SkipLicense})
  end

  it 'guards on presence since msstore always serves latest' do
    is_expected.to contain_exec('winget_install_cdn_winget')
      .with_unless(%r{Get-AppxPackage -AllUsers Microsoft\.DesktopAppInstaller})
  end

  it 'fails the run on error by default' do
    is_expected.to contain_exec('winget_install_cdn_winget').with_returns([0])
  end

  it 'sets no proxy environment by default' do
    exec = catalogue.resource('Exec[winget_install_cdn_winget]')
    expect(exec[:environment]).to be_nil
  end

  context 'with proxy' do
    let(:params) { { proxy: 'http://proxy.example.com:8080' } }

    it { is_expected.to compile.with_all_deps }

    it 'exports the proxy for the download' do
      exec = catalogue.resource('Exec[winget_install_cdn_winget]')
      environment = exec[:environment]
      environment = environment.unwrap if environment.respond_to?(:unwrap)
      expect(environment).to eq(['HTTPS_PROXY=http://proxy.example.com:8080', 'HTTP_PROXY=http://proxy.example.com:8080'])
    end

    it 'keeps the environment parameter Sensitive so credentials are redacted in catalogs and reports' do
      exec = catalogue.resource('Exec[winget_install_cdn_winget]')
      expect(exec.sensitive_parameters.map(&:to_sym)).to include(:environment)
    end
  end

  context 'with Sensitive proxy containing credentials' do
    # NB: a Sensitive value cannot travel through the rspec-puppet params
    # hash (it is not serializable into the test manifest), so the proxy
    # is built with Sensitive() in Puppet DSL instead.
    let(:params) { { ensure: 'absent' } }
    let(:pre_condition) do
      <<~PUPPET
        winget::install::cdn { 'sensitive':
          proxy => Sensitive('http://user:pass@host:8080'),
        }
      PUPPET
    end

    it { is_expected.to compile.with_all_deps }

    it 'exports the unwrapped proxy for the download' do
      exec = catalogue.resource('Exec[winget_install_cdn_sensitive]')
      environment = exec[:environment]
      environment = environment.unwrap if environment.respond_to?(:unwrap)
      expect(environment).to eq(['HTTPS_PROXY=http://user:pass@host:8080', 'HTTP_PROXY=http://user:pass@host:8080'])
    end

    it 'keeps the environment parameter Sensitive so credentials are redacted in catalogs and reports' do
      exec = catalogue.resource('Exec[winget_install_cdn_sensitive]')
      expect(exec.sensitive_parameters.map(&:to_sym)).to include(:environment)
    end

    it 'never puts the credentials on the command line' do
      command = catalogue.resource('Exec[winget_install_cdn_sensitive]')[:command]
      expect(command).not_to match(%r{user:pass})
    end
  end

  context 'with retry settings' do
    let(:params) { { retry_count: 5, retry_interval: 30 } }

    it { is_expected.to compile.with_all_deps }

    it 'forwards tries and try_sleep to the install exec' do
      is_expected.to contain_exec('winget_install_cdn_winget')
        .with_tries(5)
        .with_try_sleep(30)
    end
  end

  context 'with fail_on_error => false' do
    let(:params) { { fail_on_error: false } }

    it { is_expected.to compile.with_all_deps }

    it 'accepts exit code 1 so a failed attempt does not fail the run' do
      is_expected.to contain_exec('winget_install_cdn_winget').with_returns([0, 1])
    end
  end

  context 'with accept_source_agreements => false' do
    let(:params) { { accept_source_agreements: false } }

    it { is_expected.to compile.with_all_deps }

    it 'still declares the install exec (kept for interface consistency)' do
      is_expected.to contain_exec('winget_install_cdn_winget')
    end
  end

  context 'with a pinned version' do
    let(:params) { { ensure: '1.8.2391' } }

    it { is_expected.to compile.with_all_deps }

    it 'keeps the presence guard since cdn always serves latest' do
      exec = catalogue.resource('Exec[winget_install_cdn_winget]')
      expect(exec[:unless]).to match(%r{Get-AppxPackage -AllUsers Microsoft\.DesktopAppInstaller})
      expect(exec[:unless]).not_to match(%r{-match})
    end
  end

  context 'with invalid ensure values (issue #45)' do
    context "with ensure => 'presnt'" do
      let(:params) { { ensure: 'presnt' } }

      it { expect { catalogue }.to raise_error(Puppet::Error, %r{parameter 'ensure'}) }
    end

    context "with ensure => 'Latest '" do
      let(:params) { { ensure: 'Latest ' } }

      it { expect { catalogue }.to raise_error(Puppet::Error, %r{parameter 'ensure'}) }
    end

    context 'with ensure => empty string' do
      let(:params) { { ensure: '' } }

      it { expect { catalogue }.to raise_error(Puppet::Error, %r{parameter 'ensure'}) }
    end
  end

  context 'with accepted ensure spellings (issue #45)' do
    context "with ensure => '2024.1'" do
      let(:params) { { ensure: '2024.1' } }

      it { is_expected.to compile.with_all_deps }
    end
  end

  context 'with deprecated version parameter' do
    let(:params) { { version: '1.8.2391' } }

    it { is_expected.to compile.with_all_deps }

    it 'keeps the presence guard since cdn always serves latest' do
      exec = catalogue.resource('Exec[winget_install_cdn_winget]')
      expect(exec[:unless]).to match(%r{Get-AppxPackage -AllUsers Microsoft\.DesktopAppInstaller})
      expect(exec[:unless]).not_to match(%r{-match})
    end
  end

  context 'with ensure => absent' do
    let(:params) { { ensure: 'absent' } }

    it { is_expected.to compile.with_all_deps }

    it 'removes App Installer instead of installing it' do
      is_expected.to contain_exec('winget_uninstall_cdn_winget')
        .with_command(%r{Remove-AppxPackage -AllUsers})
        .with_onlyif(%r{Get-AppxPackage -AllUsers Microsoft\.DesktopAppInstaller})
    end

    it 'also removes the staged provisioned package (Remove-AppxPackage alone fails with 0x80070032 on staged images)' do
      exec = catalogue.resource('Exec[winget_uninstall_cdn_winget]')
      expect(exec[:command]).to match(%r{Remove-AppxProvisionedPackage -Online})
      expect(exec[:command]).to match(%r{still installed})
    end

    it 'fires when only a provisioned package remains' do
      exec = catalogue.resource('Exec[winget_uninstall_cdn_winget]')
      expect(exec[:onlyif]).to match(%r{Get-AppxProvisionedPackage -Online})
    end

    it 'declares no install exec' do
      is_expected.not_to contain_exec('winget_install_cdn_winget')
    end
  end

  context 'download hardening (issue #39)' do
    let(:command) { catalogue.resource('Exec[winget_install_cdn_winget]')[:command] }

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
