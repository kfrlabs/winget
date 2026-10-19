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

  it 'is a deprecated alias that still declares the cdn install' do
    is_expected.to contain_exec('winget_install_cdn_winget')
  end

  it 'declares no msstore-titled exec of its own' do
    is_expected.not_to contain_exec('winget_install_msstore_winget')
    is_expected.not_to contain_exec('winget_uninstall_msstore_winget')
  end

  context 'with ensure => absent' do
    let(:params) { { ensure: 'absent' } }

    it { is_expected.to compile.with_all_deps }

    it 'declares the cdn removal instead of installing' do
      is_expected.to contain_exec('winget_uninstall_cdn_winget')
      is_expected.not_to contain_exec('winget_install_cdn_winget')
    end
  end

  context 'with fail_on_error => false' do
    let(:params) { { fail_on_error: false } }

    it { is_expected.to compile.with_all_deps }

    it 'forwards fail_on_error to the cdn define' do
      is_expected.to contain_exec('winget_install_cdn_winget').with_returns([0, 1])
    end
  end
end
