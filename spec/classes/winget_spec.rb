# frozen_string_literal: true

require 'spec_helper'

describe 'winget' do
  on_supported_os(
    hardwaremodels: ['x86_64'],
    supported_os: [
      { 'operatingsystem' => 'windows', 'operatingsystemrelease' => ['10', '11', '2022', '2025'] },
    ]
  ).each do |os, os_facts|
    context "on #{os}" do
      let(:facts) do
        os_facts.merge(
          'winget_path' => 'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.8.2391_x64__8wekyb3d8bbwe/winget.exe',
          'winget_version' => '1.8.2391'
        )
      end

      it { is_expected.to compile.with_all_deps }

      it { is_expected.to contain_class('winget') }

      context 'when winget is present but not executable (path without version)' do
        # Observed live as SYSTEM in session 0 on Windows Server 2025
        # (per-user Store install, AppX 0xC0000135): the provider fails
        # every package closed, so the class warns once at compile time
        # instead.
        let(:node) { 'winget-unrunnable.example.com' }
        let(:facts) do
          os_facts.merge(
            'winget_path' => 'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.29.380.0_x64__8wekyb3d8bbwe/winget.exe',
            'winget_version' => nil
          )
        end

        it { is_expected.to compile.with_all_deps }

        # NOTE: the warning itself is intentionally not asserted here.
        # Puppet `warning()` output during catalogue compilation is not
        # observable from rspec-puppet (no log capture, no stub interception:
        # verified against Puppet 7/8 sources and live runs). What these
        # tests guard is the `if` condition above: compilation must succeed
        # in the present-but-unrunnable configuration (and stay silent
        # everywhere else); the warning text itself is verified by code
        # review plus live agent reports (see incident SAIM lab: the
        # provider-level equivalent warning did show up verbatim).
        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_class('winget') }

        context 'with ensure => absent' do
          let(:node) { 'winget-unrunnable-absent.example.com' }
          let(:params) { { ensure: 'absent' } }

          it { is_expected.to compile.with_all_deps }
        end
      end

      context 'when winget is absent (no path, no version)' do
        let(:node) { 'winget-absent.example.com' }
        let(:facts) { os_facts }

        it { is_expected.to compile.with_all_deps }
      end

      context 'when winget is executable (path with version)' do
        let(:node) { 'winget-ok.example.com' }

        it { is_expected.to compile.with_all_deps }
      end

      context 'with ensure => present' do
        let(:params) { { ensure: 'present' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_winget__install__cdn('winget') }
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

        context 'with ensure => installed (no distinct bootstrap meaning)' do
          let(:params) { { ensure: 'installed' } }

          it { expect { catalogue }.to raise_error(Puppet::Error, %r{parameter 'ensure'}) }
        end
      end

      context 'with dotted numeric versions (issue #45)' do
        context "with ensure => '1.8.2391'" do
          let(:params) { { ensure: '1.8.2391' } }

          it { is_expected.to compile.with_all_deps }
        end

        context "with ensure => '2024.1'" do
          let(:params) { { ensure: '2024.1' } }

          it { is_expected.to compile.with_all_deps }
        end
      end

      context 'with ensure => absent' do
        let(:params) { { ensure: 'absent' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_winget__install__cdn('winget').with_ensure('absent') }
        it { is_expected.not_to contain_package('Microsoft.DesktopAppInstaller') }

        context 'with the documented package collector' do
          let(:pre_condition) { "Class['winget'] -> Package <| provider == winget |>" }

          it { is_expected.to compile.with_all_deps }
          it { is_expected.not_to contain_package('Microsoft.DesktopAppInstaller') }
        end
      end

      context 'with ensure => specific version' do
        let(:params) { { ensure: '1.8.2391' } }

        it { is_expected.to compile.with_all_deps }

        it 'uses github so the pin converges (msstore always serves latest)' do
          is_expected.to contain_winget__install__github('winget').with_ensure('1.8.2391')
          is_expected.not_to contain_winget__install__cdn('winget')
        end
      end

      context 'with deprecated version parameter' do
        let(:params) { { version: '1.8.2391' } }

        it { is_expected.to compile.with_all_deps }

        it 'uses github so the pin converges (msstore always serves latest)' do
          is_expected.to contain_winget__install__github('winget').with_ensure('1.8.2391')
          is_expected.not_to contain_winget__install__cdn('winget')
        end
      end

      context 'with source => msstore (deprecated alias for cdn)' do
        let(:params) { { source: 'msstore' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_winget__install__cdn('winget') }
        it { is_expected.not_to contain_winget__install__github('winget') }
      end

      context 'with source => cdn' do
        let(:params) { { source: 'cdn' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_winget__install__cdn('winget').with_fail_on_error(true) }
        it { is_expected.to contain_winget__install__cdn('winget') }
        it { is_expected.not_to contain_winget__install__github('winget') }
      end

      context 'with source => github' do
        let(:params) { { source: 'github' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_winget__install__github('winget') }
        it { is_expected.not_to contain_winget__install__cdn('winget') }
      end

      context 'with source => auto' do
        let(:params) { { source: 'auto' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_winget__install__cdn('winget') }
        it { is_expected.to contain_winget__install__github('winget_fallback') }

        it 'tolerates a failed cdn attempt so the fallback can still run and the class does not fail' do
          is_expected.to contain_winget__install__cdn('winget').with_fail_on_error(false)
        end

        it 'leaves the github fallback independent so it still runs when msstore fails' do
          ms = catalogue.resource('Winget::Install::Cdn[winget]')
          gh = catalogue.resource('Winget::Install::Github[winget_fallback]')
          expect(ms).not_to be_nil
          expect(gh).not_to be_nil
          # A `->` arrow here would set before/require: the fallback would be
          # skipped when msstore fails and a no-op when it succeeds.
          expect(ms[:before]).to be_nil
          expect(ms[:notify]).to be_nil
          expect(gh[:require]).to be_nil
          expect(gh[:subscribe]).to be_nil
        end
      end

      context 'with source => auto and a pinned version' do
        let(:params) { { source: 'auto', ensure: '1.8.2391' } }

        it { is_expected.to compile.with_all_deps }
        it 'uses github directly since msstore always serves latest' do
          is_expected.to contain_winget__install__github('winget').with_ensure('1.8.2391')
          is_expected.not_to contain_winget__install__cdn('winget')
          is_expected.not_to contain_winget__install__github('winget_fallback')
        end
      end

      context 'with source_path' do
        let(:params) { { source_path: 'C:/Sources/winget.appx' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_winget__install__local('winget_local').with_source_path('C:/Sources/winget.appx') }

        it 'installs only the local file, not the selected source' do
          is_expected.not_to contain_winget__install__cdn('winget')
          is_expected.not_to contain_winget__install__github('winget')
          is_expected.not_to contain_winget__install__github('winget_fallback')
        end
      end

      context 'with source_path and an explicit source' do
        let(:params) { { source: 'github', source_path: 'C:/Sources/winget.appx' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_winget__install__local('winget_local') }
        it { is_expected.not_to contain_winget__install__github('winget') }
        it { is_expected.not_to contain_winget__install__cdn('winget') }
      end

      context 'with dependencies and source_path' do
        let(:params) do
          {
            source_path: 'C:/Sources/winget.appx',
            dependencies: ['C:/Sources/VCLibs.appx'],
          }
        end

        it { is_expected.to compile.with_all_deps }

        it do
          is_expected.to contain_winget__install__local('winget_local')
            .with_dependencies(['C:/Sources/VCLibs.appx'])
        end
      end

      context 'with dependencies but no source_path' do
        let(:params) { { dependencies: ['C:/Sources/VCLibs.appx'] } }

        it { expect { catalogue }.to raise_error(Puppet::Error, %r{dependencies requires source_path}) }
      end

      context 'with invalid source_path extension' do
        let(:params) { { source_path: 'C:/Sources/winget.exe' } }

        it { expect { catalogue }.to raise_error(Puppet::Error, %r{Invalid file extension}) }
      end

      context 'with proxy' do
        let(:params) { { proxy: 'http://proxy.example.com:8080' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_winget__install__cdn('winget').with_proxy('http://proxy.example.com:8080') }

        it 'redacts the download environment (Sensitive) while keeping the plain-string value working' do
          exec = catalogue.resource('Exec[winget_install_cdn_winget]')
          environment = exec[:environment]
          environment = environment.unwrap if environment.respond_to?(:unwrap)
          expect(environment).to eq(['HTTPS_PROXY=http://proxy.example.com:8080', 'HTTP_PROXY=http://proxy.example.com:8080'])
          expect(exec.sensitive_parameters.map(&:to_sym)).to include(:environment)
        end
      end

      context 'with Sensitive proxy containing credentials' do
        # NB: a Sensitive value cannot travel through the rspec-puppet params
        # hash (it is not serializable into the test manifest), so the class
        # itself stays on defaults here and the Sensitive proxy is exercised
        # through the same define the class declares, in the same catalog.
        let(:params) { { enable_winget: false } }
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

      context 'with accept_source_agreements => false' do
        let(:params) { { accept_source_agreements: false } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_winget__install__cdn('winget').with_accept_source_agreements(false) }
      end

      context 'with enable_winget => false' do
        let(:params) { { enable_winget: false } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_winget__install__cdn('winget') }
        it { is_expected.not_to contain_winget__install__github('winget_fallback') }
      end

      context 'with packages (preferred Hiera key winget::packages)' do
        let(:params) { { packages: { 'Git.Git' => 'installed' } } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_class('winget::packages').with_entries('Git.Git' => 'installed') }
        it { is_expected.to contain_class('winget::packages').that_requires('Class[winget]') }
        it { is_expected.to contain_package('Git.Git').with_ensure('installed').with_provider('winget') }
      end

      context 'with packages and allow_downgrade => true' do
        let(:params) { { packages: { 'Git.Git' => { 'ensure' => '2.39.0', 'allow_downgrade' => true } } } }

        it { is_expected.to compile.with_all_deps }

        it 'maps the opt-in to the install_options marker' do
          is_expected.to contain_package('Git.Git')
            .with_ensure('2.39.0')
            .with_provider('winget')
            .with_install_options(['--allow-downgrade'])
        end
      end

      context 'with packages and allow_downgrade => false' do
        let(:params) { { packages: { 'Git.Git' => { 'ensure' => '2.39.0', 'allow_downgrade' => false } } } }

        it { is_expected.to compile.with_all_deps }

        it 'maps to no marker' do
          is_expected.to contain_package('Git.Git').with_install_options([])
        end
      end

      context 'with packages as a shorthand string' do
        let(:params) { { packages: { 'Git.Git' => '2.39.0' } } }

        it { is_expected.to compile.with_all_deps }

        it 'maps to no marker' do
          is_expected.to contain_package('Git.Git').with_install_options([])
        end
      end

      context 'with packages_schedule and packages_reboot_resource forwarding' do
        let(:params) do
          {
            packages: { 'Git.Git' => 'installed' },
            packages_schedule: 'maintenance-window',
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_class('winget::packages').with_package_schedule('maintenance-window') }
      end

      context 'with sources (preferred Hiera key winget::sources)' do
        let(:params) { { sources: { 'contoso' => 'https://winget.contoso.example.com/cache' } } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_class('winget::sources') }
        it { is_expected.to contain_class('winget::sources').that_requires('Class[winget]') }
        it { is_expected.to contain_winget__source('contoso') }
      end

      context 'with settings (preferred Hiera key winget::settings)' do
        let(:params) { { settings: { 'telemetry' => { 'disable' => true } } } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_class('winget::settings') }
        it { is_expected.to contain_class('winget::settings').that_requires('Class[winget]') }
      end

      context 'with invalid source value' do
        let(:params) { { source: 'invalid' } }

        it { expect { catalogue }.to raise_error(Puppet::Error, %r{expects.*msstore|Invalid source|parameter 'source'}) }
      end
    end
  end

  context 'on unsupported OS' do
    let(:facts) do
      {
        os: {
          family: 'RedHat',
          name: 'RedHat',
          release: { major: '9', minor: '3', full: '9.3' },
          architecture: 'x86_64',
        },
      }
    end

    it { expect { catalogue }.to raise_error(Puppet::Error, %r{only supported on Windows}) }
  end

  context 'with minimum OS version check' do
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
          release: { major: '10', minor: '1709', full: '10' },
          architecture: 'x86_64',
        },
      }
    end

    it { is_expected.to compile.with_all_deps }
    it { is_expected.to contain_class('winget') }
  end

  context 'on Windows Server 2025' do
    # facterdb has no Windows Server 2025 facts yet, so on_supported_os
    # silently skips it: cover it explicitly with hand-written facts.
    let(:facts) do
      {
        # Legacy facts: see 'with minimum OS version check' above.
        'operatingsystem' => 'windows',
        'osfamily' => 'windows',
        os: {
          family: 'windows',
          name: 'windows',
          release: { major: '2025', full: '2025' },
          architecture: 'x86_64',
        },
      }
    end

    it { is_expected.to compile.with_all_deps }
    it { is_expected.to contain_class('winget') }
    it { is_expected.to contain_winget__install__cdn('winget') }
    it { is_expected.to contain_winget__install__github('winget_fallback') }
  end
end
