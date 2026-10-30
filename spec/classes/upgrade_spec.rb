# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/winget/facts'

describe 'winget::upgrade' do
  let(:live_table) do
    <<~OUTPUT
      Name              Id                      Version   Available   Source
      --------------------------------------------------------------------
      Git               Git.Git                 2.40.0    2.41.0      winget
    OUTPUT
  end
  before(:each) do
    # The class enumerates on demand through the `winget::upgrades` function;
    # stub the raw runner helper so catalog tests exercise the real function
    # delegate (uncached enumeration + parsing) and the manifest logic
    # (live rows vs. fact fallback) instead of shelling out. `nil` simulates
    # absent/failed enumeration (fallback to the fact); table text simulates
    # a successful query. Note rspec-puppet caches compiled catalogs by
    # node/facts/params, which cannot see Ruby stubs: contexts that vary only
    # the stubbed rows must use distinct facts (see below) or they share the
    # first-compiled catalog.
    PuppetX::Winget::Facts.reset!
    allow(PuppetX::Winget::Facts).to receive(:run_upgrade).and_return(nil)
  end
  after(:each) do
    PuppetX::Winget::Facts.reset!
  end
  on_supported_os(
    hardwaremodels: ['x86_64'],
    supported_os: [
      { 'operatingsystem' => 'windows', 'operatingsystemrelease' => ['10', '11', '2019', '2022', '2025'] },
    ],
  ).each do |os, os_facts|
    context "on #{os}" do
      let(:facts) do
        os_facts.merge('winget_upgrades' => [
                         { 'id' => 'Git.Git', 'current_version' => '2.40.0', 'available_version' => '2.41.0' },
                         { 'id' => 'Notepad++.Notepad++', 'current_version' => '8.5.4', 'available_version' => '8.6.0' },
                       ])
      end

      it { is_expected.to compile.with_all_deps }
      it { is_expected.to contain_class('winget::upgrade') }

      it 'declares one latest package per upgradable ID' do
        is_expected.to contain_package('Git.Git').with_ensure('latest').with_provider('winget')
        is_expected.to contain_package('Notepad++.Notepad++').with_ensure('latest').with_provider('winget')
      end

      it 'sets no schedule by default' do
        is_expected.to contain_package('Git.Git').without_schedule
      end

      context 'with live on-demand enumeration and no fact rows' do
        # Distinct dummy fact keeps a unique RSpec::Puppet catalog cache key:
        # without it this context shares byte-identical facts+code with the
        # undef-fact context below, so the second catalog reuses the first
        # (stub differences are invisible to the cache key).
        let(:facts) { os_facts.merge('winget_test_context' => 'live-enumeration') }

        before(:each) do
          allow(PuppetX::Winget::Facts).to receive(:run_upgrade).and_return(live_table)
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_package('Git.Git').with_ensure('latest').with_provider('winget') }
      end

      context 'when live enumeration wins over stale fact rows' do
        let(:facts) do
          os_facts.merge('winget_upgrades' => [
            { 'id' => 'Stale.Stale', 'current_version' => '1.0', 'available_version' => '2.0' },
          ])
        end

        before(:each) do
          allow(PuppetX::Winget::Facts).to receive(:run_upgrade).and_return(live_table)
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_package('Git.Git').with_ensure('latest') }
        it { is_expected.not_to contain_package('Stale.Stale') }
      end

      context 'when live enumeration succeeds with no rows (authoritative, no fallback)' do
        let(:facts) do
          os_facts.merge(
            'winget_test_context' => 'live-empty-authoritative',
            'winget_upgrades' => [
              { 'id' => 'Stale.Stale', 'current_version' => '1.0', 'available_version' => '2.0' },
            ],
          )
        end

        before(:each) do
          allow(PuppetX::Winget::Facts).to receive(:run_upgrade).and_return("No applicable update found.\n")
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to have_package_resource_count(0) }
      end

      context 'with unusable rows (missing id) skipped' do
        let(:facts) do
          os_facts.merge(
            'winget_test_context' => 'unusable-rows',
            'winget_upgrades' => [
              { 'id' => 'Git.Git', 'current_version' => '2.40.0', 'available_version' => '2.41.0' },
              { 'current_version' => '1.0', 'available_version' => '2.0' },
              { 'id' => nil, 'current_version' => '1.0', 'available_version' => '2.0' },
              { 'id' => '', 'current_version' => '1.0', 'available_version' => '2.0' },
              nil,
              42,
              ['Git.Git'],
            ],
          )
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_package('Git.Git').with_ensure('latest') }
        it { is_expected.to have_package_resource_count(1) }
      end

      context 'with an empty upgrades fact' do
        let(:facts) { os_facts.merge('winget_upgrades' => []) }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to have_package_resource_count(0) }
      end

      context 'with an undef upgrades fact (pluginsync pending)' do
        let(:facts) { os_facts }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to have_package_resource_count(0) }
      end

      context 'when a target is already declared elsewhere' do
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
          is_expected.to contain_package('Notepad++.Notepad++').with_ensure('latest')
        end
      end

      context 'with exclude' do
        let(:params) { { exclude: ['git.git'] } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_package('Git.Git') }
        it { is_expected.to contain_package('Notepad++.Notepad++').with_ensure('latest') }
      end

      context 'with only' do
        let(:params) { { only: ['NOTEPAD++.NOTEPAD++'] } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_package('Git.Git') }
        it { is_expected.to contain_package('Notepad++.Notepad++').with_ensure('latest') }
      end

      context 'with an external schedule' do
        let(:params) { { package_schedule: 'maintenance-window' } }
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
        it { is_expected.to contain_package('Notepad++.Notepad++').with_schedule('maintenance-window') }
      end

      context 'with manage_schedule' do
        let(:params) { { manage_schedule: true } }

        it { is_expected.to compile.with_all_deps }

        it do
          is_expected.to contain_schedule('winget-upgrade-window').with(
            period: 'weekly',
            range: '3 - 5',
            weekday: 'Sunday',
            repeat: 1,
          )
        end

        it { is_expected.to contain_package('Git.Git').with_schedule('winget-upgrade-window') }
      end

      context 'with manage_schedule and a custom schedule name' do
        let(:params) do
          {
            manage_schedule: true,
            package_schedule: 'custom-window',
            schedule_period: 'daily',
            schedule_range: '2 - 4',
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_schedule('custom-window').with_period('daily').with_range('2 - 4') }
        it { is_expected.to contain_package('Git.Git').with_schedule('custom-window') }
      end

      context 'with pinned packages' do
        let(:facts) do
          os_facts.merge(
            'winget_upgrades' => [
              { 'id' => 'Git.Git', 'current_version' => '2.40.0', 'available_version' => '2.41.0' },
              { 'id' => 'Google.Chrome', 'current_version' => '120.0', 'available_version' => '121.0' },
            ],
            'winget_pins' => ['google.chrome'],
          )
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_package('Git.Git').with_ensure('latest') }
        it { is_expected.not_to contain_package('Google.Chrome') }
      end

      context 'with respect_pins => false' do
        let(:facts) do
          os_facts.merge(
            'winget_upgrades' => [
              { 'id' => 'Git.Git', 'current_version' => '2.40.0', 'available_version' => '2.41.0' },
              { 'id' => 'Google.Chrome', 'current_version' => '120.0', 'available_version' => '121.0' },
            ],
            'winget_pins' => ['google.chrome'],
          )
        end
        let(:params) { { respect_pins: false } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_package('Google.Chrome').with_ensure('latest') }
      end

      context 'with an undef pins fact (older agent)' do
        let(:facts) do
          os_facts.merge('winget_upgrades' => [
                           { 'id' => 'Git.Git', 'current_version' => '2.40.0', 'available_version' => '2.41.0' },
                         ])
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_package('Git.Git').with_ensure('latest') }
      end

      context 'with malformed pins entries skipped' do
        let(:facts) do
          os_facts.merge(
            'winget_upgrades' => [
              { 'id' => 'Git.Git', 'current_version' => '2.40.0', 'available_version' => '2.41.0' },
              { 'id' => 'Google.Chrome', 'current_version' => '120.0', 'available_version' => '121.0' },
            ],
            'winget_pins' => ['google.chrome', nil, '', 42, ['nested']],
          )
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_package('Git.Git').with_ensure('latest') }
        it { is_expected.not_to contain_package('Google.Chrome') }
      end

      context 'with legacy String IDs (pre-structured fact)' do
        let(:facts) do
          os_facts.merge('winget_upgrades' => ['Git.Git'])
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_package('Git.Git').with_ensure('latest') }
      end

      context 'with reboot_resource' do
        let(:params) { { reboot_resource: 'maintenance-reboot' } }
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
        it { is_expected.to contain_package('Notepad++.Notepad++').with_notify('Reboot[maintenance-reboot]') }
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
