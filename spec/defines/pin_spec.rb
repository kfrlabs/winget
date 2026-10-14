# frozen_string_literal: true

require 'spec_helper'

describe 'winget::pin' do
  let(:facts) do
    {
      # Legacy facts: facterdb provides them and rspec-puppet stubs
      # Facter from them, which the exec providers use for confinement.
      # Without them no exec provider is suitable on Puppet 7.
      'operatingsystem' => 'windows',
      'osfamily' => 'windows',
      'winget_path' => 'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.8.2391_x64__8wekyb3d8bbwe/winget.exe',
      os: {
        family: 'windows',
        name: 'windows',
        release: { major: '10', full: '10' },
        architecture: 'x86_64',
      },
    }
  end
  let(:title) { 'Google.Chrome' }

  it { is_expected.to compile.with_all_deps }

  it 'adds a plain pin guarded by pin list' do
    is_expected.to contain_exec('winget-pin-add-Google.Chrome')
      .with_command(%r{pin add --id 'Google\.Chrome' --exact})
      .with_unless(%r{pin list --id 'Google\.Chrome' --exact})
  end

  it 'adds a plain pin without version or blocking flags by default' do
    is_expected.to contain_exec('winget-pin-add-Google.Chrome')
      .with_command("C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command \"& 'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.8.2391_x64__8wekyb3d8bbwe/winget.exe' pin add --id 'Google.Chrome' --exact --accept-source-agreements --disable-interactivity\"")
  end

  context 'with a gating version' do
    let(:params) { { version: '120.*' } }

    it { is_expected.to compile.with_all_deps }

    it 'passes the version to pin add' do
      is_expected.to contain_exec('winget-pin-add-Google.Chrome')
        .with_command(%r{--version '120\.\*'})
    end
  end

  context 'with a blocking pin' do
    let(:params) { { blocking: true } }

    it { is_expected.to compile.with_all_deps }

    it 'passes --blocking to pin add' do
      is_expected.to contain_exec('winget-pin-add-Google.Chrome')
        .with_command(%r{--blocking})
    end
  end

  context 'with ensure => absent' do
    let(:params) { { ensure: 'absent' } }

    it { is_expected.to compile.with_all_deps }

    it 'removes the pin only when listed' do
      is_expected.to contain_exec('winget-pin-remove-Google.Chrome')
        .with_command(%r{pin remove --id 'Google\.Chrome' --exact})
        .with_onlyif(%r{pin list --id 'Google\.Chrome' --exact})
      is_expected.not_to contain_exec('winget-pin-add-Google.Chrome')
    end
  end

  context 'without winget (fresh bootstrap)' do
    let(:facts) do
      {
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

    it { is_expected.to compile.with_all_deps }
    it { is_expected.to have_exec_resource_count(0) }
  end
end
