# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/winget/facts'

RSpec.describe PuppetX::Winget::Facts do
  before(:each) do
    PuppetX::Winget::PathResolver.reset!
    described_class.instance_variable_set(:@winget_path, nil) if described_class.instance_variable_defined?(:@winget_path)
  end

  after(:each) do
    PuppetX::Winget::PathResolver.reset!
  end

  describe '.winget_path' do
    context 'when winget is absent' do
      before(:each) do
        allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return(nil)
      end

      it 'returns nil' do
        expect(described_class.winget_path).to be_nil
      end
    end

    context 'when winget is present' do
      before(:each) do
        allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return(
          'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.8.2391_x64__8wekyb3d8bbwe/winget.exe'
        )
      end

      it 'returns the resolved path' do
        expect(described_class.winget_path).to eq(
          'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.8.2391_x64__8wekyb3d8bbwe/winget.exe'
        )
      end
    end

    context 'when the resolver raises an error' do
      before(:each) do
        allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_raise(StandardError.new('boom'))
      end

      it 'returns nil and does not raise' do
        expect(described_class.winget_path).to be_nil
      end
    end
  end

  describe '.winget_version' do
    let(:winget_exe) do
      'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.8.2391_x64__8wekyb3d8bbwe/winget.exe'
    end

    context 'when winget is absent' do
      before(:each) do
        allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return(nil)
      end

      it 'returns nil' do
        expect(described_class.winget_version).to be_nil
      end
    end

    context 'when the executable does not exist' do
      before(:each) do
        allow(described_class).to receive(:winget_path).and_return(winget_exe)
        allow(File).to receive(:exist?).with(winget_exe).and_return(false)
      end

      it 'returns nil' do
        expect(described_class.winget_version).to be_nil
      end
    end

    context 'when winget --version fails' do
      before(:each) do
        allow(described_class).to receive(:winget_path).and_return(winget_exe)
        allow(File).to receive(:exist?).with(winget_exe).and_return(true)
        allow(Puppet::Util::Execution).to receive(:execute).and_return(
          Puppet::Util::Execution::ProcessOutput.new('', 1)
        )
      end

      it 'returns nil' do
        expect(described_class.winget_version).to be_nil
      end
    end

    context 'when winget --version succeeds with v prefix' do
      before(:each) do
        allow(described_class).to receive(:winget_path).and_return(winget_exe)
        allow(File).to receive(:exist?).with(winget_exe).and_return(true)
        allow(Puppet::Util::Execution).to receive(:execute).and_return(
          Puppet::Util::Execution::ProcessOutput.new("v1.8.2391\n", 0)
        )
      end

      it 'returns the version without the v prefix' do
        expect(described_class.winget_version).to eq('1.8.2391')
      end
    end

    context 'when winget --version succeeds without v prefix' do
      before(:each) do
        allow(described_class).to receive(:winget_path).and_return(winget_exe)
        allow(File).to receive(:exist?).with(winget_exe).and_return(true)
        allow(Puppet::Util::Execution).to receive(:execute).and_return(
          Puppet::Util::Execution::ProcessOutput.new("1.8.2391\n", 0)
        )
      end

      it 'returns the version as-is' do
        expect(described_class.winget_version).to eq('1.8.2391')
      end
    end

    context 'when winget --version returns empty output' do
      before(:each) do
        allow(described_class).to receive(:winget_path).and_return(winget_exe)
        allow(File).to receive(:exist?).with(winget_exe).and_return(true)
        allow(Puppet::Util::Execution).to receive(:execute).and_return(
          Puppet::Util::Execution::ProcessOutput.new("\n", 0)
        )
      end

      it 'returns nil' do
        expect(described_class.winget_version).to be_nil
      end
    end

    context 'when execution raises an error' do
      before(:each) do
        allow(described_class).to receive(:winget_path).and_return(winget_exe)
        allow(File).to receive(:exist?).with(winget_exe).and_return(true)
        allow(Puppet::Util::Execution).to receive(:execute).and_raise(StandardError.new('boom'))
      end

      it 'returns nil and does not raise' do
        expect(described_class.winget_version).to be_nil
      end
    end

    context 'with an explicit path override' do
      before(:each) do
        allow(File).to receive(:exist?).with(winget_exe).and_return(true)
        allow(Puppet::Util::Execution).to receive(:execute).and_return(
          Puppet::Util::Execution::ProcessOutput.new('v1.8.2391', 0)
        )
      end

      it 'uses the given path without calling the resolver' do
        expect(PuppetX::Winget::PathResolver).not_to receive(:winget_path)
        expect(described_class.winget_version(winget_exe)).to eq('1.8.2391')
      end
    end
  end

  describe 'fact files' do
    let(:lib_root) { File.expand_path('../../../lib', __dir__) }

    it 'defines a winget_path fact confined to windows that delegates to the helper' do
      content = File.read(File.join(lib_root, 'facter', 'winget_path.rb'))
      expect(content).to include("Facter.add('winget_path')")
      expect(content).to include('PuppetX::Winget::Facts.winget_path')
    end

    it 'defines a winget_version fact confined to windows that delegates to the helper' do
      content = File.read(File.join(lib_root, 'facter', 'winget_version.rb'))
      expect(content).to include("Facter.add('winget_version')")
      expect(content).to include('PuppetX::Winget::Facts.winget_version')
    end

    it 'defines a winget_upgrades fact confined to windows that delegates to the helper' do
      content = File.read(File.join(lib_root, 'facter', 'winget_upgrades.rb'))
      expect(content).to include("Facter.add('winget_upgrades')")
      expect(content).to include('PuppetX::Winget::Facts.winget_upgrades')
    end
  end

  describe '.winget_upgrades' do
    let(:winget_exe) do
      'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.8.2391_x64__8wekyb3d8bbwe/winget.exe'
    end
    let(:upgrade_output) do
      <<~OUTPUT
        Name              Id                      Version   Available   Source
        --------------------------------------------------------------------
        Git               Git.Git                 2.40.0    2.41.0      winget
        Notepad++         Notepad++.Notepad++     8.5.4     8.6.0       winget
        2 upgrades available.
      OUTPUT
    end

    context 'when winget is absent' do
      before(:each) do
        allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return(nil)
      end

      it 'returns an empty array' do
        expect(described_class.winget_upgrades).to eq([])
      end
    end

    context 'when the executable does not exist' do
      before(:each) do
        allow(described_class).to receive(:winget_path).and_return(winget_exe)
        allow(File).to receive(:exist?).with(winget_exe).and_return(false)
      end

      it 'returns an empty array' do
        expect(described_class.winget_upgrades).to eq([])
      end
    end

    context 'when winget upgrade fails' do
      before(:each) do
        allow(described_class).to receive(:winget_path).and_return(winget_exe)
        allow(File).to receive(:exist?).with(winget_exe).and_return(true)
        allow(Puppet::Util::Execution).to receive(:execute).and_return(
          Puppet::Util::Execution::ProcessOutput.new('', 1),
        )
      end

      it 'returns an empty array' do
        expect(described_class.winget_upgrades).to eq([])
      end
    end

    context 'when upgrades are available' do
      before(:each) do
        allow(described_class).to receive(:winget_path).and_return(winget_exe)
        allow(File).to receive(:exist?).with(winget_exe).and_return(true)
        allow(Puppet::Util::Execution).to receive(:execute).and_return(
          Puppet::Util::Execution::ProcessOutput.new(upgrade_output, 0),
        )
      end

      it 'returns the upgradable package IDs' do
        expect(described_class.winget_upgrades).to eq(['Git.Git', 'Notepad++.Notepad++'])
      end

      it 'queries winget non-interactively' do
        expect(Puppet::Util::Execution).to receive(:execute).with(
          [winget_exe, 'upgrade', '--accept-source-agreements', '--disable-interactivity'],
          failonfail: false, combine: true,
        ).and_return(
          Puppet::Util::Execution::ProcessOutput.new(upgrade_output, 0),
        )
        expect(described_class.winget_upgrades).to eq(['Git.Git', 'Notepad++.Notepad++'])
      end
    end

    context 'when execution raises an error' do
      before(:each) do
        allow(described_class).to receive(:winget_path).and_return(winget_exe)
        allow(File).to receive(:exist?).with(winget_exe).and_return(true)
        allow(Puppet::Util::Execution).to receive(:execute).and_raise(StandardError.new('boom'))
      end

      it 'returns an empty array and does not raise' do
        expect(described_class.winget_upgrades).to eq([])
      end
    end

    context 'with an explicit path override' do
      before(:each) do
        allow(File).to receive(:exist?).with(winget_exe).and_return(true)
        allow(Puppet::Util::Execution).to receive(:execute).and_return(
          Puppet::Util::Execution::ProcessOutput.new(upgrade_output, 0),
        )
      end

      it 'uses the given path without calling the resolver' do
        expect(PuppetX::Winget::PathResolver).not_to receive(:winget_path)
        expect(described_class.winget_upgrades(winget_exe)).to eq(['Git.Git', 'Notepad++.Notepad++'])
      end
    end

    context 'when WINGET_UPGRADES_ENABLED disables the fact' do
      before(:each) do
        allow(ENV).to receive(:fetch).with('WINGET_UPGRADES_ENABLED', nil).and_return('false')
        allow(File).to receive(:exist?).with(winget_exe).and_return(true)
      end

      it 'returns [] without shelling out' do
        expect(Puppet::Util::Execution).not_to receive(:execute)
        expect(described_class.winget_upgrades(winget_exe)).to eq([])
      end
    end
  end

  describe '.upgrades_enabled?' do
    it 'is enabled by default' do
      allow(ENV).to receive(:fetch).with('WINGET_UPGRADES_ENABLED', nil).and_return(nil)
      expect(described_class.upgrades_enabled?).to be true
    end

    it 'treats false-like values as disabled' do
      %w[false 0 no off FALSE No OFF].each do |value|
        allow(ENV).to receive(:fetch).with('WINGET_UPGRADES_ENABLED', nil).and_return(value)
        expect(described_class.upgrades_enabled?).to be(false), "expected #{value.inspect} to disable the fact"
      end
    end

    it 'treats other values as enabled' do
      %w[true 1 yes].each do |value|
        allow(ENV).to receive(:fetch).with('WINGET_UPGRADES_ENABLED', nil).and_return(value)
        expect(described_class.upgrades_enabled?).to be(true), "expected #{value.inspect} to keep the fact enabled"
      end
    end
  end

  describe '.parse_winget_upgrade' do
    it 'returns an empty array for nil or empty output' do
      expect(described_class.parse_winget_upgrade(nil)).to eq([])
      expect(described_class.parse_winget_upgrade('')).to eq([])
    end

    it 'returns an empty array when no upgrades are available' do
      expect(described_class.parse_winget_upgrade("No applicable update found.\n")).to eq([])
    end

    it 'parses a French-localized table' do
      output = <<~OUTPUT
        Nom               Id                      Version   Disponible  Source
        --------------------------------------------------------------------
        Git               Git.Git                 2.40.0    2.41.0      winget
      OUTPUT
      expect(described_class.parse_winget_upgrade(output)).to eq(['Git.Git'])
    end

    it 'deduplicates IDs and skips footer lines' do
      output = <<~OUTPUT
        Name              Id                      Version   Available   Source
        --------------------------------------------------------------------
        Git               Git.Git                 2.40.0    2.41.0      winget
        Git               Git.Git                 2.40.0    2.41.0      winget
        2 upgrades available.
      OUTPUT
      expect(described_class.parse_winget_upgrade(output)).to eq(['Git.Git'])
    end

    it 'parses output with a second explicit-targeting table' do
      # winget prints a second table with its own header when some upgrades
      # require explicit targeting (unknown versions). Both tables are
      # parsed, and neither header's `Id` cell leaks in as a package ID.
      output = <<~OUTPUT
        Name              Id                      Version   Available   Source
        --------------------------------------------------------------------
        Git               Git.Git                 2.40.0    2.41.0      winget
        The following packages have an upgrade available, but require explicit targeting:
        Name              Id                      Version   Available   Source
        --------------------------------------------------------------------
        Foo               Foo.Foo                 1.0       2.0         winget
        2 upgrades available.
      OUTPUT
      expect(described_class.parse_winget_upgrade(output)).to eq(['Git.Git', 'Foo.Foo'])
    end

    it 'parses real-world output with collapsed single-space gaps' do
      # winget shrinks inter-column gaps to one space for long names
      # (truncated with `…`): a whitespace split reads the installed version
      # as the ID (`6.0.35`) and drops the glued rows.
      output = <<~OUTPUT
        Name                                               Id                                Version       Available     Source
        -----------------------------------------------------------------------------------------------------------------------
        MariaDB 10.5 (x64)                                 MariaDB.Server                    10.5.9.0      13.0.2.0      winget
        Microsoft .NET 6.0.35 - Windows Server Hosting     Microsoft.DotNet.HostingBundle.6  6.0.35        6.0.36        winget
        Microsoft ASP.NET Core 6.0.35 - Shared Framework … Microsoft.DotNet.AspNetCore.6     6.0.35        6.0.36        winget
        Microsoft Edge WebView2 Runtime                    Microsoft.EdgeWebView2Runtime     154.0.4258.62 155.0.4283.45 winget
        Microsoft Windows Desktop Runtime - 6.0.35 (x64)   Microsoft.DotNet.DesktopRuntime.6 6.0.35        6.0.36        winget
        Node.js                                            OpenJS.NodeJS.22                  22.16.0       22.23.2       winget
        6 upgrades available.
      OUTPUT
      expected = [
        'MariaDB.Server',
        'Microsoft.DotNet.HostingBundle.6',
        'Microsoft.DotNet.AspNetCore.6',
        'Microsoft.EdgeWebView2Runtime',
        'Microsoft.DotNet.DesktopRuntime.6',
        'OpenJS.NodeJS.22',
      ]
      expect(described_class.parse_winget_upgrade(output)).to eq(expected)
    end
  end
end
