# frozen_string_literal: true

require 'spec_helper'

describe 'winget::settings' do
  let(:settings_file) do
    'C:/Windows/System32/config/systemprofile/AppData/Local/Packages/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe/LocalState/settings.json'
  end

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

      it 'manages an (empty by default) settings file' do
        is_expected.to contain_file(settings_file).with_ensure('file').with_content('{}')
      end

      context 'with settings' do
        let(:params) do
          {
            config: {
              'telemetry' => { 'disable' => true },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }

        it 'writes the settings as JSON' do
          is_expected.to contain_file(settings_file).with_content(%r{"telemetry":\{"disable":true\}})
        end
      end

      context 'with experimental features' do
        let(:params) { { experimental_features: { 'resume' => true } } }

        it { is_expected.to compile.with_all_deps }

        it 'merges them under the experimentalFeatures key' do
          is_expected.to contain_file(settings_file).with_content(%r{"experimentalFeatures":\{"resume":true\}})
        end
      end

      context 'with a custom settings_path' do
        let(:params) { { settings_path: 'C:/Configs/winget-settings.json' } }

        it { is_expected.to compile.with_all_deps }

        it 'manages the given path instead of the SYSTEM default' do
          is_expected.to contain_file('C:/Configs/winget-settings.json')
          is_expected.not_to contain_file(settings_file)
        end
      end

      context 'without winget (fresh bootstrap)' do
        let(:facts) { os_facts }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_file(settings_file) }
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
