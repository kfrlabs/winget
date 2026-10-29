# frozen_string_literal: true

require 'spec_helper'

describe 'winget::sources' do
  on_supported_os(
    hardwaremodels: ['x86_64'],
    supported_os: [
      { 'operatingsystem' => 'windows', 'operatingsystemrelease' => ['10', '11', '2019', '2022', '2025'] },
    ],
  ).each do |os, os_facts|
    context "on #{os}" do
      let(:facts) do
        os_facts.merge(
          'winget_path' => 'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.8.2391_x64__8wekyb3d8bbwe/winget.exe',
        )
      end

      it { is_expected.to compile.with_all_deps }
      it { is_expected.to have_winget__source_resource_count(0) }

      context 'with a double quote in default_sources (issue #74)' do
        let(:params) { { default_sources: ['msstore', 'a"b'], reset_defaults: true } }

        it { expect { catalogue }.to raise_error(Puppet::Error, %r{double quotes}) }
      end

      context 'with a double quote in an entries key (issue #74)' do
        let(:params) { { entries: { 'con"toso' => 'https://winget.contoso.example.com/cache' } } }

        it { expect { catalogue }.to raise_error(Puppet::Error, %r{double quotes}) }
      end

      context 'with a shorthand URL entry' do
        let(:params) { { entries: { 'contoso' => 'https://winget.contoso.example.com/cache' } } }

        it { is_expected.to compile.with_all_deps }

        it 'declares the source with the URL' do
          is_expected.to contain_winget__source('contoso')
            .with_ensure('present')
            .with_url('https://winget.contoso.example.com/cache')
        end
      end

      context 'with a full source hash' do
        let(:params) do
          {
            entries: {
              'partners' => {
                'url'         => 'https://winget.partners.example.com/cache',
                'source_type' => 'Microsoft.Rest',
                'trust_level' => 'trusted',
                'explicit'    => true,
              },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }

        it 'forwards every attribute to the defined type' do
          is_expected.to contain_winget__source('partners')
            .with_url('https://winget.partners.example.com/cache')
            .with_source_type('Microsoft.Rest')
            .with_trust_level('trusted')
            .with_explicit(true)
        end
      end

      context 'with reset_defaults' do
        let(:params) do
          {
            entries: { 'contoso' => 'https://winget.contoso.example.com/cache' },
            reset_defaults: true,
          }
        end

        it { is_expected.to compile.with_all_deps }

        it 'declares a guarded reset exec' do
          is_expected.to contain_exec('winget-source-reset')
            .with_command(%r{source reset --force})
            .with_onlyif(%r{source list})
        end

        it 'orders the reset before the declared sources' do
          is_expected.to contain_winget__source('contoso').that_requires('Exec[winget-source-reset]')
        end
      end

      context 'without reset_defaults' do
        let(:params) { { entries: { 'contoso' => 'https://winget.contoso.example.com/cache' } } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_exec('winget-source-reset') }
      end

      context 'without winget (fresh bootstrap)' do
        let(:facts) { os_facts }
        let(:params) { { entries: { 'contoso' => 'https://winget.contoso.example.com/cache' } } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to have_winget__source_resource_count(0) }
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
end
