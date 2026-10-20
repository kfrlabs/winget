# frozen_string_literal: true

require 'spec_helper'

describe 'winget::configure' do
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
  let(:title) { 'C:/Configs/workstation.winget' }

  it { is_expected.to compile.with_all_deps }

  it 'applies the configuration guarded by configure test' do
    is_expected.to contain_exec('winget-configure-C:/Configs/workstation.winget')
      .with_command(%r{configure -f 'C:/Configs/workstation\.winget'})
      .with_unless(%r{configure test -f 'C:/Configs/workstation\.winget'})
  end

  context 'with an explicit source' do
    let(:title) { 'baseline' }
    let(:params) { { source: 'https://configs.contoso.example.com/workstation.winget' } }

    it { is_expected.to compile.with_all_deps }

    it 'uses the given source instead of the title' do
      is_expected.to contain_exec('winget-configure-baseline')
        .with_command(%r{configure -f 'https://configs\.contoso\.example\.com/workstation\.winget'})
    end
  end

  context "with a quote in source (issue #41)" do
    let(:title) { 'baseline' }
    let(:params) { { source: "C:/Configs/a'b.winget" } }

    it { is_expected.to compile.with_all_deps }

    it 'doubles single quotes in configure commands' do
      command = catalogue.resource('Exec', 'winget-configure-baseline')[:command]
      expect(command).to include("configure -f 'C:/Configs/a''b.winget'")
      guard = catalogue.resource('Exec', 'winget-configure-baseline')[:unless]
      expect(guard).to include("configure test -f 'C:/Configs/a''b.winget'")
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

  context 'with an http:// source (issue #40)' do
    let(:title) { 'baseline' }
    let(:params) { { source: 'http://configs.contoso.example.com/workstation.winget' } }

    it { expect { catalogue }.to raise_error(Puppet::Error, %r{must use https://}) }
  end

  context 'with a relative-path source (issue #40)' do
    let(:title) { 'baseline' }
    let(:params) { { source: 'configs/workstation.winget' } }

    it { expect { catalogue }.to raise_error(Puppet::Error, %r{must be an absolute local path}) }
  end

  context 'with a UNC share source (issue #40)' do
    let(:title) { 'baseline' }
    let(:params) { { source: '\\\\fileserver\\share\\workstation.winget' } }

    it { is_expected.to compile.with_all_deps }

    it 'passes the UNC path to configure' do
      is_expected.to contain_exec('winget-configure-baseline')
        .with_command(%r{configure -f '\\\\fileserver\\share\\workstation\.winget'})
    end
  end

  context 'with an old winget without configure test (issue #40)' do
    let(:facts) do
      {
        'operatingsystem' => 'windows',
        'osfamily' => 'windows',
        'winget_path' => 'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.8.2391_x64__8wekyb3d8bbwe/winget.exe',
        'winget_version' => '1.5.2201',
        os: {
          family: 'windows',
          name: 'windows',
          release: { major: '10', full: '10' },
          architecture: 'x86_64',
        },
      }
    end

    it { is_expected.to compile.with_all_deps }
    it { is_expected.to contain_exec('winget-configure-C:/Configs/workstation.winget') }
  end

  context 'with a custom timeout (issue #40)' do
    let(:params) { { timeout: 600 } }

    it { is_expected.to compile.with_all_deps }

    it 'forwards the timeout to the configure exec' do
      is_expected.to contain_exec('winget-configure-C:/Configs/workstation.winget').with_timeout(600)
    end
  end

  context 'with the default timeout' do
    it 'keeps the historical 1800 s timeout' do
      is_expected.to contain_exec('winget-configure-C:/Configs/workstation.winget').with_timeout(1800)
    end
  end
end
