# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/winget/facts'

RSpec.describe PuppetX::Winget::Facts do
  before(:each) do
    PuppetX::Winget::PathResolver.reset!
    described_class.reset!
    described_class.instance_variable_set(:@winget_path, nil) if described_class.instance_variable_defined?(:@winget_path)
  end

  after(:each) do
    PuppetX::Winget::PathResolver.reset!
    described_class.reset!
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
      expect(content).to include('confine kernel: :windows')
    end

    it 'defines a winget_pins fact confined to windows that delegates to the helper' do
      content = File.read(File.join(lib_root, 'facter', 'winget_pins.rb'))
      expect(content).to include("Facter.add('winget_pins')")
      expect(content).to include('PuppetX::Winget::Facts.pinned_ids')
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

      it 'returns structured rows' do
        expect(described_class.winget_upgrades).to eq([
          { 'id' => 'Git.Git', 'current_version' => '2.40.0', 'available_version' => '2.41.0' },
          { 'id' => 'Notepad++.Notepad++', 'current_version' => '8.5.4', 'available_version' => '8.6.0' },
        ])
      end

      it 'queries winget non-interactively' do
        expect(Puppet::Util::Execution).to receive(:execute).with(
          [winget_exe, 'upgrade', '--accept-source-agreements', '--disable-interactivity'],
          failonfail: false, combine: true,
        ).and_return(
          Puppet::Util::Execution::ProcessOutput.new(upgrade_output, 0),
        )
        expect(described_class.winget_upgrades).to eq([
          { 'id' => 'Git.Git', 'current_version' => '2.40.0', 'available_version' => '2.41.0' },
          { 'id' => 'Notepad++.Notepad++', 'current_version' => '8.5.4', 'available_version' => '8.6.0' },
        ])
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
        expect(described_class.winget_upgrades(winget_exe)).to eq([
          { 'id' => 'Git.Git', 'current_version' => '2.40.0', 'available_version' => '2.41.0' },
          { 'id' => 'Notepad++.Notepad++', 'current_version' => '8.5.4', 'available_version' => '8.6.0' },
        ])
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

    it 'parses current and available versions' do
      output = <<~OUTPUT
        Name              Id                      Version   Available   Source
        --------------------------------------------------------------------
        Git               Git.Git                 2.40.0    2.41.0      winget
        Notepad++         Notepad++.Notepad++     8.5.4     8.6.0       winget
        2 upgrades available.
      OUTPUT
      expect(described_class.parse_winget_upgrade(output)).to eq([
        { 'id' => 'Git.Git', 'current_version' => '2.40.0', 'available_version' => '2.41.0' },
        { 'id' => 'Notepad++.Notepad++', 'current_version' => '8.5.4', 'available_version' => '8.6.0' },
      ])
    end

    it 'parses a French-localized table (Disponible)' do
      output = <<~OUTPUT
        Nom               Id                      Version   Disponible  Source
        --------------------------------------------------------------------
        Git               Git.Git                 2.40.0    2.41.0      winget
      OUTPUT
      expect(described_class.parse_winget_upgrade(output)).to eq([
        { 'id' => 'Git.Git', 'current_version' => '2.40.0', 'available_version' => '2.41.0' },
      ])
    end

    it 'deduplicates rows across the explicit-targeting table' do
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
        Git               Git.Git                 2.40.0    2.41.0      winget
        Foo               Foo.Foo                 1.0       2.0         winget
      OUTPUT
      expect(described_class.parse_winget_upgrade(output)).to eq([
        { 'id' => 'Git.Git', 'current_version' => '2.40.0', 'available_version' => '2.41.0' },
        { 'id' => 'Foo.Foo', 'current_version' => '1.0', 'available_version' => '2.0' },
      ])
    end

    it 'keeps rows with nil versions when the table has no Available column' do
      output = <<~OUTPUT
        Name              Id                      Version   Source
        --------------------------------------------------------------------
        Git               Git.Git                 2.40.0    winget
      OUTPUT
      expect(described_class.parse_winget_upgrade(output)).to eq([
        { 'id' => 'Git.Git', 'current_version' => nil, 'available_version' => nil },
      ])
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
      expect(described_class.parse_winget_upgrade(output)).to eq([
        { 'id' => 'MariaDB.Server', 'current_version' => '10.5.9.0', 'available_version' => '13.0.2.0' },
        { 'id' => 'Microsoft.DotNet.HostingBundle.6', 'current_version' => '6.0.35', 'available_version' => '6.0.36' },
        { 'id' => 'Microsoft.DotNet.AspNetCore.6', 'current_version' => '6.0.35', 'available_version' => '6.0.36' },
        { 'id' => 'Microsoft.EdgeWebView2Runtime', 'current_version' => '154.0.4258.62', 'available_version' => '155.0.4283.45' },
        { 'id' => 'Microsoft.DotNet.DesktopRuntime.6', 'current_version' => '6.0.35', 'available_version' => '6.0.36' },
        { 'id' => 'OpenJS.NodeJS.22', 'current_version' => '22.16.0', 'available_version' => '22.23.2' },
      ])
    end
  end

  describe '.winget_upgrades with execution contexts' do
    let(:winget_exe) do
      'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.8.2391_x64__8wekyb3d8bbwe/winget.exe'
    end
    let(:upgrade_output) do
      <<~OUTPUT
        Name              Id                      Version   Available   Source
        --------------------------------------------------------------------
        Git               Git.Git                 2.40.0    2.41.0      winget
      OUTPUT
    end

    context 'when upgrades are available' do
      before(:each) do
        allow(described_class).to receive(:winget_path).and_return(winget_exe)
        allow(File).to receive(:exist?).with(winget_exe).and_return(true)
        allow(Puppet::Util::Execution).to receive(:execute).and_return(
          Puppet::Util::Execution::ProcessOutput.new(upgrade_output, 0),
        )
      end

      it 'returns structured rows' do
        expect(described_class.winget_upgrades).to eq([
          { 'id' => 'Git.Git', 'current_version' => '2.40.0', 'available_version' => '2.41.0' },
        ])
      end
    end

    context 'when WINGET_UPGRADES_ENABLED disables the fact' do
      before(:each) do
        allow(ENV).to receive(:fetch).with('WINGET_UPGRADES_ENABLED', nil).and_return('false')
      end

      it 'returns [] without shelling out' do
        expect(Puppet::Util::Execution).not_to receive(:execute)
        expect(described_class.winget_upgrades(winget_exe)).to eq([])
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
  end

  describe '.pinned_ids and .parse_pin_list' do
    let(:winget_exe) do
      'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.8.2391_x64__8wekyb3d8bbwe/winget.exe'
    end
    let(:pin_output) do
      <<~OUTPUT
        Name              Id                      Version   Pin
        --------------------------------------------------------------------
        Git               Git.Git                 2.40.0    Pinning
        Google Chrome     Google.Chrome           120.0     Blocking
      OUTPUT
    end

    it 'returns an empty array for nil or empty output' do
      expect(described_class.parse_pin_list(nil)).to eq([])
      expect(described_class.parse_pin_list('')).to eq([])
    end

    it 'returns an empty array when no table is present' do
      expect(described_class.parse_pin_list("No pins exist.\n")).to eq([])
    end

    it 'parses pinned IDs' do
      expect(described_class.parse_pin_list(pin_output)).to eq(['Git.Git', 'Google.Chrome'])
    end

    context 'when pins exist' do
      before(:each) do
        allow(described_class).to receive(:winget_path).and_return(winget_exe)
        allow(File).to receive(:exist?).with(winget_exe).and_return(true)
        allow(Puppet::Util::Execution).to receive(:execute).and_return(
          Puppet::Util::Execution::ProcessOutput.new(pin_output, 0),
        )
      end

      it 'returns the pinned IDs' do
        expect(described_class.pinned_ids).to eq(['Git.Git', 'Google.Chrome'])
      end

      it 'lists pins non-interactively' do
        expect(Puppet::Util::Execution).to receive(:execute).with(
          [winget_exe, 'pin', 'list', '--accept-source-agreements', '--disable-interactivity'],
          failonfail: false, combine: true,
        ).and_return(
          Puppet::Util::Execution::ProcessOutput.new(pin_output, 0),
        )
        expect(described_class.pinned_ids).to eq(['Git.Git', 'Google.Chrome'])
      end
    end

    context 'when winget is absent' do
      before(:each) do
        allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return(nil)
      end

      it 'returns an empty array' do
        expect(described_class.pinned_ids).to eq([])
      end
    end

    context 'when pin list fails (old winget without pin support)' do
      before(:each) do
        allow(described_class).to receive(:winget_path).and_return(winget_exe)
        allow(File).to receive(:exist?).with(winget_exe).and_return(true)
        allow(Puppet::Util::Execution).to receive(:execute).and_return(
          Puppet::Util::Execution::ProcessOutput.new('Invalid argument', 0x8A150002),
        )
      end

      it 'returns an empty array' do
        expect(described_class.pinned_ids).to eq([])
      end
    end
  end

  describe 'memoized command output' do
    let(:winget_exe) do
      'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.8.2391_x64__8wekyb3d8bbwe/winget.exe'
    end

    before(:each) do
      allow(described_class).to receive(:winget_path).and_return(winget_exe)
      allow(File).to receive(:exist?).with(winget_exe).and_return(true)
    end

    it 'memoizes the winget upgrade call within a run' do
      output = <<~OUTPUT
        Name              Id                      Version   Available   Source
        --------------------------------------------------------------------
        Git               Git.Git                 2.40.0    2.41.0      winget
      OUTPUT
      expect(Puppet::Util::Execution).to receive(:execute).once.and_return(
        Puppet::Util::Execution::ProcessOutput.new(output, 0),
      )
      expect(described_class.winget_upgrades).to eq([
        { 'id' => 'Git.Git', 'current_version' => '2.40.0', 'available_version' => '2.41.0' },
      ])
      expect(described_class.winget_upgrades).to eq([
        { 'id' => 'Git.Git', 'current_version' => '2.40.0', 'available_version' => '2.41.0' },
      ])
    end

    it 'runs fresh again after reset!' do
      first = Puppet::Util::Execution::ProcessOutput.new("No applicable update found.\n", 0)
      second_output = <<~OUTPUT
        Name              Id                      Version   Available   Source
        --------------------------------------------------------------------
        Git               Git.Git                 2.40.0    2.41.0      winget
      OUTPUT
      second = Puppet::Util::Execution::ProcessOutput.new(second_output, 0)
      allow(Puppet::Util::Execution).to receive(:execute).and_return(first, second)
      expect(described_class.winget_upgrades).to eq([])
      described_class.reset!
      expect(described_class.winget_upgrades).to eq([
        { 'id' => 'Git.Git', 'current_version' => '2.40.0', 'available_version' => '2.41.0' },
      ])
    end
  end
end
