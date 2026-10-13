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

  it 'falls back to provisioning when Add-AppxPackage fails under SYSTEM' do
    is_expected.to contain_exec('winget_install_msstore_winget')
      .with_command(%r{Add-AppxProvisionedPackage -Online -PackagePath .* -SkipLicense})
  end

  it 'guards on presence since msstore always serves latest' do
    is_expected.to contain_exec('winget_install_msstore_winget')
      .with_unless(%r{Get-AppxPackage -AllUsers Microsoft\.DesktopAppInstaller})
  end
end
