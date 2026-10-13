# frozen_string_literal: true

require 'spec_helper'

describe 'winget' do
  on_supported_os(
    hardwaremodels: ['x86_64'],
    supported_os: [
      { 'operatingsystem' => 'windows', 'operatingsystemrelease' => ['10', '11', '2019', '2022', '2025'] },
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

      context 'with ensure => present' do
        let(:params) { { ensure: 'present' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_winget__install__msstore('winget') }
      end

      context 'with ensure => absent' do
        let(:params) { { ensure: 'absent' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_package('Microsoft.DesktopAppInstaller').with_ensure('absent') }
      end

      context 'with ensure => specific version' do
        let(:params) { { ensure: '1.8.2391' } }

        it { is_expected.to compile.with_all_deps }

        it 'uses github so the pin converges (msstore always serves latest)' do
          is_expected.to contain_winget__install__github('winget').with_ensure('1.8.2391')
          is_expected.not_to contain_winget__install__msstore('winget')
        end
      end

      context 'with deprecated version parameter' do
        let(:params) { { version: '1.8.2391' } }

        it { is_expected.to compile.with_all_deps }

        it 'uses github so the pin converges (msstore always serves latest)' do
          is_expected.to contain_winget__install__github('winget').with_ensure('1.8.2391')
          is_expected.not_to contain_winget__install__msstore('winget')
        end
      end

      context 'with source => msstore' do
        let(:params) { { source: 'msstore' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_winget__install__msstore('winget') }
        it { is_expected.not_to contain_winget__install__github('winget') }
      end

      context 'with source => github' do
        let(:params) { { source: 'github' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_winget__install__github('winget') }
        it { is_expected.not_to contain_winget__install__msstore('winget') }
      end

      context 'with source => auto' do
        let(:params) { { source: 'auto' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_winget__install__msstore('winget') }
        it { is_expected.to contain_winget__install__github('winget_fallback') }

        it 'leaves the github fallback independent so it still runs when msstore fails' do
          ms = catalogue.resource('Winget::Install::Msstore[winget]')
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
          is_expected.not_to contain_winget__install__msstore('winget')
          is_expected.not_to contain_winget__install__github('winget_fallback')
        end
      end

      context 'with source_path' do
        let(:params) { { source_path: 'C:/Sources/winget.appx' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_winget__install__local('winget_local').with_source_path('C:/Sources/winget.appx') }

        it 'installs only the local file, not the selected source' do
          is_expected.not_to contain_winget__install__msstore('winget')
          is_expected.not_to contain_winget__install__github('winget')
          is_expected.not_to contain_winget__install__github('winget_fallback')
        end
      end

      context 'with source_path and an explicit source' do
        let(:params) { { source: 'github', source_path: 'C:/Sources/winget.appx' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_winget__install__local('winget_local') }
        it { is_expected.not_to contain_winget__install__github('winget') }
        it { is_expected.not_to contain_winget__install__msstore('winget') }
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
        it { is_expected.to contain_winget__install__msstore('winget').with_proxy('http://proxy.example.com:8080') }
      end

      context 'with accept_source_agreements => false' do
        let(:params) { { accept_source_agreements: false } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_winget__install__msstore('winget').with_accept_source_agreements(false) }
      end

      context 'with enable_winget => false' do
        let(:params) { { enable_winget: false } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_winget__install__msstore('winget') }
        it { is_expected.not_to contain_winget__install__github('winget_fallback') }
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
    it { is_expected.to contain_winget__install__msstore('winget') }
    it { is_expected.to contain_winget__install__github('winget_fallback') }
  end
end
