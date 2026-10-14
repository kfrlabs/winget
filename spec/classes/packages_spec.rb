# frozen_string_literal: true

require 'spec_helper'

describe 'winget::packages' do
  on_supported_os(
    hardwaremodels: ['x86_64'],
    supported_os: [
      { 'operatingsystem' => 'windows', 'operatingsystemrelease' => ['10', '11', '2019', '2022', '2025'] },
    ],
  ).each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      it { is_expected.to compile.with_all_deps }
      it { is_expected.to have_package_resource_count(0) }

      context 'with a shorthand string entry' do
        let(:params) { { packages: { 'Git.Git' => 'installed' } } }

        it { is_expected.to compile.with_all_deps }

        it 'declares the package with the winget provider' do
          is_expected.to contain_package('Git.Git').with_ensure('installed').with_provider('winget')
        end
      end

      context 'with structured install parameters' do
        let(:params) do
          {
            packages: {
              'Git.Git' => {
                'ensure'       => '2.44.0',
                'scope'        => 'machine',
                'architecture' => 'x64',
                'source'       => 'winget',
              },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }

        it 'translates structured keys into install_options flags' do
          is_expected.to contain_package('Git.Git')
            .with_ensure('2.44.0')
            .with_provider('winget')
            .with_install_options(['--scope', 'machine', '--architecture', 'x64', '--source', 'winget'])
        end
      end

      context 'with location, override, locale, installer_type and extra options' do
        let(:params) do
          {
            packages: {
              'Git.Git' => {
                'ensure'          => 'installed',
                'location'        => 'C:/Tools/Git',
                'override'        => '/SILENT /NORESTART',
                'locale'          => 'en-US',
                'installer_type'  => 'exe',
                'install_options' => ['--force'],
              },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }

        it 'appends extra install_options after the structured flags' do
          is_expected.to contain_package('Git.Git').with_install_options(
            ['--location', 'C:/Tools/Git', '--override', '/SILENT /NORESTART', '--installer-type', 'exe', '--locale', 'en-US', '--force'],
          )
        end
      end

      context 'with hold => true' do
        let(:params) { { packages: { 'Git.Git' => { 'ensure' => 'installed', 'hold' => true } } } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_package('Git.Git').with_mark('hold') }
      end

      context 'with hold => false' do
        let(:params) { { packages: { 'Git.Git' => { 'ensure' => 'installed', 'hold' => false } } } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_package('Git.Git').with_mark('none') }
      end

      context 'with hold on an absent package' do
        let(:params) { { packages: { 'Git.Git' => { 'ensure' => 'absent', 'hold' => true } } } }

        it { expect { catalogue }.to raise_error(Puppet::Error, %r{hold cannot be combined with ensure}) }
      end

      context 'without hold' do
        let(:params) { { packages: { 'Git.Git' => 'installed' } } }

        it 'leaves any existing pin alone (no mark managed)' do
          is_expected.to contain_package('Git.Git').without_mark
        end
      end

      context 'with an uninstall entry' do
        let(:params) do
          {
            packages: {
              'Old.App' => {
                'ensure'            => 'absent',
                'uninstall_options' => ['--preserve-data'],
              },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }

        it 'declares the absent package with uninstall options' do
          is_expected.to contain_package('Old.App')
            .with_ensure('absent')
            .with_provider('winget')
            .with_uninstall_options(['--preserve-data'])
        end
      end

      context 'with a class-level schedule' do
        let(:params) do
          {
            packages: { 'Git.Git' => 'latest' },
            schedule: 'maintenance-window',
          }
        end
        let(:pre_condition) do
          <<~PUPPET
            schedule { 'maintenance-window':
              period => weekly,
              range  => '3 - 5',
              repeat => 1,
            }
          PUPPET
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_package('Git.Git').with_schedule('maintenance-window') }
      end

      context 'with a per-package schedule override' do
        let(:params) do
          {
            packages: { 'Git.Git' => { 'ensure' => 'latest', 'schedule' => 'fast-lane' } },
            schedule: 'maintenance-window',
          }
        end
        let(:pre_condition) do
          <<~PUPPET
            schedule { 'maintenance-window':
              period => weekly,
              range  => '3 - 5',
              repeat => 1,
            }
            schedule { 'fast-lane':
              period => daily,
              repeat => 1,
            }
          PUPPET
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_package('Git.Git').with_schedule('fast-lane') }
      end

      context 'with reboot_resource' do
        let(:params) do
          {
            packages: { 'Git.Git' => 'latest' },
            reboot_resource: 'maintenance-reboot',
          }
        end
        let(:pre_condition) do
          <<~PUPPET
            define reboot($when = pending) {
              notify { "reboot-stub-${title}": }
            }
            reboot { 'maintenance-reboot':
              when => pending,
            }
          PUPPET
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_package('Git.Git').with_notify('Reboot[maintenance-reboot]') }
      end

      context 'when a package is already declared elsewhere' do
        let(:params) { { packages: { 'Git.Git' => 'latest' } } }
        let(:pre_condition) do
          <<~PUPPET
            package { 'Git.Git':
              ensure   => present,
              provider => winget,
            }
          PUPPET
        end

        it { is_expected.to compile.with_all_deps }

        it 'leaves the existing declaration alone instead of failing duplicately' do
          is_expected.to contain_package('Git.Git').with_ensure('present')
        end
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
