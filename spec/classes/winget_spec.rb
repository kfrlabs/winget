# frozen_string_literal: true

require 'spec_helper'

describe 'winget' do
  on_supported_os(
    hardwaremodels: ['x86_64'],
    supported_os: [
      { 'operatingsystem' => 'windows', 'operatingsystemrelease' => ['10', '11', '2019', '2022'] },
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
        it { is_expected.to contain_winget__install__msstore('winget').with_ensure('1.8.2391') }
      end

      context 'with deprecated version parameter' do
        let(:params) { { version: '1.8.2391' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_winget__install__msstore('winget').with_ensure('1.8.2391') }
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
      end

      context 'with source_path' do
        let(:params) { { source_path: 'C:/Sources/winget.appx' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_winget__install__local('winget_local').with_source_path('C:/Sources/winget.appx') }
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
end
