# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/winget/path_resolver'
require 'puppet/provider/package/winget'

RSpec.describe Puppet::Type.type(:package).provider(:winget) do
  let(:resource) do
    Puppet::Type.type(:package).new(
      name: 'Git.Git',
      ensure: :installed,
      provider: :winget
    )
  end

  let(:provider) { described_class.new(resource) }

  before(:each) do
    described_class.reset!
    PuppetX::Winget::PathResolver.reset!
  end

  describe 'provider features' do
    it 'has installable feature' do
      expect(described_class.features).to include(:installable)
    end

    it 'has uninstallable feature' do
      expect(described_class.features).to include(:uninstallable)
    end

    it 'has upgradeable feature' do
      expect(described_class.features).to include(:upgradeable)
    end

    it 'has versionable feature' do
      expect(described_class.features).to include(:versionable)
    end

    it 'has install_options feature' do
      expect(described_class.features).to include(:install_options)
    end

    it 'has uninstall_options feature' do
      expect(described_class.features).to include(:uninstall_options)
    end
  end

  describe '.suitable?' do
    context 'when winget is not found' do
      before(:each) do
        allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return(nil)
      end

      it 'returns false' do
        expect(described_class.suitable?(resource)).to be false
      end

      it 'logs a warning' do
        expect(Puppet).to receive(:warning).with(/winget provider is unsuitable/)
        described_class.suitable?(resource)
      end
    end

    context 'when winget is found' do
      before(:each) do
        allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return('C:/Path/to/winget.exe')
      end

      it 'returns true' do
        expect(described_class.suitable?(resource)).to be true
      end
    end

    context 'when an error occurs during suitability check' do
      before(:each) do
        allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_raise(StandardError.new('Error'))
      end

      it 'returns false' do
        expect(described_class.suitable?(resource)).to be false
      end

      it 'logs a warning' do
        expect(Puppet).to receive(:warning).with(/winget provider suitability check failed/)
        described_class.suitable?(resource)
      end
    end
  end

  describe '#winget_exec' do
    let(:winget_path) { 'C:/Path/to/winget.exe' }

    before(:each) do
      allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return(winget_path)
    end

    it 'places the subcommand first and appends install flags' do
      expect(Puppet::Util::Execution).to receive(:execute).with(
        [winget_path, 'install', '--id', 'Git.Git', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity', '--exact', '--silent'],
        hash_including(failonfail: false, combine: true)
      ).and_return(Puppet::Util::Execution::ProcessOutput.new('', 0))

      provider.winget_exec('install', '--id', 'Git.Git')
    end

    it 'uses only show-supported flags for show' do
      expect(Puppet::Util::Execution).to receive(:execute).with(
        [winget_path, 'show', '--id', 'Git.Git', '--accept-source-agreements', '--disable-interactivity', '--exact'],
        hash_including(failonfail: false, combine: true)
      ).and_return(Puppet::Util::Execution::ProcessOutput.new('', 0))

      provider.winget_exec('show', '--id', 'Git.Git')
    end

    it 'uses only uninstall-supported flags for uninstall' do
      expect(Puppet::Util::Execution).to receive(:execute).with(
        [winget_path, 'uninstall', '--id', 'Git.Git', '--accept-source-agreements', '--disable-interactivity', '--exact', '--silent'],
        hash_including(failonfail: false, combine: true)
      ).and_return(Puppet::Util::Execution::ProcessOutput.new('', 0))

      provider.winget_exec('uninstall', '--id', 'Git.Git')
    end
  end

  describe '#parse_winget_list' do
    context 'with standard output' do
      let(:output) do
        <<~OUTPUT
          Name                  Id                            Version     Source
          --------------------------------------------------------------------------------
          Git                   Git.Git                       2.40.0      winget
          Visual Studio Code    Microsoft.VisualStudioCode    1.78.0      winget
        OUTPUT
      end

      it 'parses packages correctly' do
        result = provider.parse_winget_list(output)
        expect(result).to have_key('git.git')
        expect(result['git.git']).to eq({
          name: 'Git',
          version: '2.40.0',
          source: 'winget',
          id: 'Git.Git'
        })
        expect(result['microsoft.visualstudiocode']).to eq({
          name: 'Visual Studio Code',
          version: '1.78.0',
          source: 'winget',
          id: 'Microsoft.VisualStudioCode'
        })
      end
    end

    context 'with localized header (Id and Version)' do
      let(:output) do
        <<~OUTPUT
          Nom                   Id                   Version     Source
          ----------------------------------------------------------------
          Git                   Git.Git              2.40.0      winget
        OUTPUT
      end

      it 'finds header with Id and Version regardless of language' do
        result = provider.parse_winget_list(output)
        expect(result).to have_key('git.git')
      end
    end

    context 'with empty output' do
      it 'returns empty hash' do
        expect(provider.parse_winget_list('')).to eq({})
        expect(provider.parse_winget_list(nil)).to eq({})
      end
    end

    context 'with separator lines' do
      let(:output) do
        <<~OUTPUT
          Name                  Id                   Version     Source
          ================================================================
          Git                   Git.Git              2.40.0      winget
          ---
        OUTPUT
      end

      it 'skips separator lines' do
        result = provider.parse_winget_list(output)
        expect(result).to have_key('git.git')
        expect(result.size).to eq(1)
      end
    end

    context 'with truncated columns' do
      let(:output) do
        <<~OUTPUT
          Name                                        Id       Version  Source
          ----------------------------------------------------------------------
          Very Long Package Name That Gets Truncated  Some.Id  1.0.0    winget
        OUTPUT
      end

      it 'handles truncated columns' do
        result = provider.parse_winget_list(output)
        expect(result).to have_key('some.id')
      end
    end

    context 'with missing source column' do
      let(:output) do
        <<~OUTPUT
          Name                  Id                   Version
          ----------------------------------------------------------------
          Git                   Git.Git              2.40.0
        OUTPUT
      end

      it 'defaults source to winget' do
        result = provider.parse_winget_list(output)
        expect(result['git.git'][:source]).to eq('winget')
      end
    end

    context 'with single-space gaps between columns (long names)' do
      # winget shrinks inter-column gaps to one space (and truncates names
      # with `…`); columns stay aligned on the header offsets.
      let(:output) do
        <<~OUTPUT
          Name                                               Id                                Version         Source
          -----------------------------------------------------------------------------------------------------------------------
          MariaDB 10.5 (x64)                                 MariaDB.Server                    10.5.9.0        winget
          Microsoft ASP.NET Core 6.0.35 - Shared Framework … Microsoft.DotNet.AspNetCore.6     6.0.35          winget
          Microsoft Windows Desktop Runtime - 6.0.35 (x64)   Microsoft.DotNet.DesktopRuntime.6 6.0.35          winget
        OUTPUT
      end

      it 'reads IDs at the header offsets instead of shifting columns' do
        result = provider.parse_winget_list(output)
        expect(result.keys).to contain_exactly(
          'mariadb.server',
          'microsoft.dotnet.aspnetcore.6',
          'microsoft.dotnet.desktopruntime.6',
        )
        expect(result['microsoft.dotnet.aspnetcore.6'][:version]).to eq('6.0.35')
        expect(result['microsoft.dotnet.desktopruntime.6'][:version]).to eq('6.0.35')
      end
    end
  end

  describe '#install' do
    let(:winget_path) { 'C:/Path/to/winget.exe' }

    before(:each) do
      allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return(winget_path)
      allow(described_class).to receive(:suitable?).and_return(true)
    end

    context 'with ensure => installed' do
      it 'calls winget install with --id' do
        expect(provider).to receive(:winget_exec).with('install', '--id', 'Git.Git').and_return(
          Puppet::Util::Execution::ProcessOutput.new('', 0)
        )
        provider.install
      end
    end

    context 'with ensure => specific version' do
      let(:resource) do
        Puppet::Type.type(:package).new(
          name: 'Git.Git',
          ensure: '2.40.0',
          provider: :winget
        )
      end

      it 'calls winget install with --version' do
        expect(provider).to receive(:winget_exec).with('install', '--id', 'Git.Git', '--version', '2.40.0').and_return(
          Puppet::Util::Execution::ProcessOutput.new('', 0)
        )
        provider.install
      end
    end

    context 'with install_options source as hash with string key' do
      let(:resource) do
        Puppet::Type.type(:package).new(
          name: 'Git.Git',
          ensure: :installed,
          provider: :winget,
          install_options: [{ 'source' => 'msstore' }]
        )
      end

      it 'passes --source from install_options hash' do
        expect(provider).to receive(:winget_exec).with('install', '--id', 'Git.Git', '--source', 'msstore').and_return(
          Puppet::Util::Execution::ProcessOutput.new('', 0)
        )
        provider.install
      end
    end

    context 'with install_options as string array' do
      let(:resource) do
        Puppet::Type.type(:package).new(
          name: 'Git.Git',
          ensure: :installed,
          provider: :winget,
          install_options: ['--source', 'msstore']
        )
      end

      it 'passes --source from string array' do
        expect(provider).to receive(:winget_exec).with('install', '--id', 'Git.Git', '--source', 'msstore').and_return(
          Puppet::Util::Execution::ProcessOutput.new('', 0)
        )
        provider.install
      end
    end
  end

  describe '#uninstall' do
    let(:winget_path) { 'C:/Path/to/winget.exe' }

    before(:each) do
      allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return(winget_path)
      allow(described_class).to receive(:suitable?).and_return(true)
    end

    it 'calls winget uninstall with --id' do
      expect(provider).to receive(:winget_exec).with('uninstall', '--id', 'Git.Git').and_return(
        Puppet::Util::Execution::ProcessOutput.new('', 0)
      )
      provider.uninstall
    end

    context 'with uninstall_options' do
      let(:resource) do
        Puppet::Type.type(:package).new(
          name: 'Git.Git',
          ensure: :absent,
          provider: :winget,
          uninstall_options: ['--preserve-data']
        )
      end

      it 'passes uninstall_options' do
        expect(provider).to receive(:winget_exec).with('uninstall', '--id', 'Git.Git', '--preserve-data').and_return(
          Puppet::Util::Execution::ProcessOutput.new('', 0)
        )
        provider.uninstall
      end
    end
  end

  describe '#update' do
    let(:winget_path) { 'C:/Path/to/winget.exe' }

    before(:each) do
      allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return(winget_path)
      allow(described_class).to receive(:suitable?).and_return(true)
    end

    it 'calls winget upgrade with --id' do
      expect(provider).to receive(:winget_exec).with('upgrade', '--id', 'Git.Git').and_return(
        Puppet::Util::Execution::ProcessOutput.new('', 0)
      )
      provider.update
    end

    context 'when the package is not installed (0x8A150014)' do
      it 'falls back to install so ensure => latest works on absent packages' do
        upgrade_output = Puppet::Util::Execution::ProcessOutput.new(
          'No installed package found matching input criteria.', 0x8A150014
        )
        expect(provider).to receive(:winget_exec).with('upgrade', '--id', 'Git.Git').and_return(upgrade_output)
        expect(provider).to receive(:install)
        provider.update
      end
    end

    context 'when winget reports no applicable upgrade (0x8A15002B)' do
      it 'treats update as idempotent success instead of failing' do
        upgrade_output = Puppet::Util::Execution::ProcessOutput.new(
          'No available upgrade found.', 0x8A15002B
        )
        expect(provider).to receive(:winget_exec).with('upgrade', '--id', 'Git.Git').and_return(upgrade_output)
        expect(provider.update).to be_nil
      end
    end
  end

  describe '#latest' do
    let(:winget_path) { 'C:/Path/to/winget.exe' }

    before(:each) do
      allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return(winget_path)
      allow(described_class).to receive(:suitable?).and_return(true)
      allow(described_class).to receive(:instances_list).and_return({})
    end

    context 'when package is found' do
      it 'returns the latest version' do
        output = Puppet::Util::Execution::ProcessOutput.new("Version: 2.41.0\nOther info", 0)
        expect(provider).to receive(:winget_exec).with('show', '--id', 'Git.Git').and_return(output)
        expect(provider.latest).to eq('2.41.0')
      end
    end

    context 'when the advertised version is strictly newer than installed' do
      before(:each) do
        allow(described_class).to receive(:instances_list).and_return(
          'git.git' => { name: 'Git', version: '2.40.0', source: 'winget', id: 'Git.Git' },
        )
      end

      it 'returns the advertised version' do
        output = Puppet::Util::Execution::ProcessOutput.new("Version: 2.41.0\nOther info", 0)
        expect(provider).to receive(:winget_exec).with('show', '--id', 'Git.Git').and_return(output)
        expect(provider.latest).to eq('2.41.0')
      end
    end

    context 'when the advertised version is not newer than installed (7zip 26.04 vs 26.04.00.0)' do
      before(:each) do
        allow(described_class).to receive(:instances_list).and_return(
          'git.git' => { name: 'Git', version: '2.40.00.0', source: 'winget', id: 'Git.Git' },
        )
      end

      it 'returns the installed version so ensure => latest stays in sync' do
        output = Puppet::Util::Execution::ProcessOutput.new("Version: 2.40\nOther info", 0)
        expect(provider).to receive(:winget_exec).with('show', '--id', 'Git.Git').and_return(output)
        expect(provider.latest).to eq('2.40.00.0')
      end
    end

    context 'when query and latest run on the same resource' do
      it 'lists installed packages only once' do
        allow(Puppet::Util::Execution).to receive(:execute).and_return(
          Puppet::Util::Execution::ProcessOutput.new("Name     Id       Version\n-------------------------\nGit      Git.Git  2.40.0", 0),
        )
        expect(described_class).to receive(:instances_list).once.and_call_original
        provider.query
        provider.latest
      end
    end

    context 'when package is not found' do
      it 'returns nil' do
        output = Puppet::Util::Execution::ProcessOutput.new('Not found', 1)
        expect(provider).to receive(:winget_exec).with('show', '--id', 'Git.Git').and_return(output)
        expect(provider.latest).to be_nil
      end
    end

    context 'when winget is not suitable' do
      before(:each) do
        allow(described_class).to receive(:suitable?).and_return(false)
      end

      it 'returns nil' do
        expect(provider.latest).to be_nil
      end
    end
  end

  describe '#version_newer?' do
    it 'treats trailing zero segments as insignificant' do
      expect(provider.send(:version_newer?, '26.04', '26.04.00.0')).to be false
      expect(provider.send(:version_newer?, '2.41.0', '2.40.0')).to be true
      expect(provider.send(:version_newer?, '2.40.0', '2.41.0')).to be false
    end

    it 'falls back to string inequality for unparsable versions' do
      expect(provider.send(:version_newer?, 'abc', 'abc')).to be false
      expect(provider.send(:version_newer?, 'abd', 'abc')).to be true
    end
  end

  describe '#handle_exit_code' do
    let(:output) { Puppet::Util::Execution::ProcessOutput.new('error output', code) }

    context 'with EXIT_SUCCESS (0)' do
      let(:code) { 0 }
      it 'returns nil (success)' do
        expect(provider.send(:handle_exit_code, output, 'install')).to be_nil
      end
    end

    context 'with EXIT_NO_APPLICABLE_INSTALLER (already installed)' do
      let(:code) { 0x8A150001 }
      it 'returns nil for install (idempotent)' do
        expect(provider.send(:handle_exit_code, output, 'install')).to be_nil
      end
      it 'raises for other actions' do
        expect { provider.send(:handle_exit_code, output, 'upgrade') }.to raise_error(Puppet::Error)
      end
    end

    context 'with EXIT_NO_UPGRADE_AVAILABLE' do
      let(:code) { 0x8A150002 }
      it 'returns nil for upgrade (idempotent)' do
        expect(provider.send(:handle_exit_code, output, 'upgrade')).to be_nil
      end
      it 'raises for other actions' do
        expect { provider.send(:handle_exit_code, output, 'install') }.to raise_error(Puppet::Error)
      end
    end

    context 'with EXIT_REBOOT_REQUIRED' do
      let(:code) { 0x8A150003 }
      it 'warns but returns nil' do
        expect(Puppet).to receive(:warning).with(/reboot is required/)
        expect(provider.send(:handle_exit_code, output, 'install')).to be_nil
      end
    end

    context 'with EXIT_NOT_FOUND' do
      let(:code) { 0x8A150006 }
      it 'raises with package name' do
        expect { provider.send(:handle_exit_code, output, 'install') }.to raise_error(Puppet::Error, /not found in winget source/)
      end
    end

    context 'with EXIT_NO_INSTALLED_PACKAGE_FOUND (0x8A150014)' do
      let(:code) { 0x8A150014 }
      it 'raises a not-installed error instead of a raw exit code' do
        expect { provider.send(:handle_exit_code, output, 'upgrade') }.to raise_error(Puppet::Error, /is not installed/)
      end
    end

    context 'with EXIT_UPDATE_NOT_APPLICABLE (0x8A15002B)' do
      let(:code) { 0x8A15002B }
      it 'returns nil for upgrade (idempotent)' do
        expect(provider.send(:handle_exit_code, output, 'upgrade')).to be_nil
      end
      it 'raises for other actions' do
        expect { provider.send(:handle_exit_code, output, 'install') }.to raise_error(Puppet::Error)
      end
    end

    context 'with unknown exit code' do
      let(:code) { 999 }
      it 'raises with exit code' do
        expect { provider.send(:handle_exit_code, output, 'install') }.to raise_error(Puppet::Error, /exit code 999/)
      end
    end
  end

  describe '.instances' do
    let(:winget_path) { 'C:/Path/to/winget.exe' }

    before(:each) do
      allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return(winget_path)
      allow(described_class).to receive(:suitable?).and_return(true)
    end

    it 'returns provider instances for each installed package' do
      allow(Puppet::Util::Execution).to receive(:execute).and_return(
        Puppet::Util::Execution::ProcessOutput.new("Name     Id       Version\n-------------------------\nGit      Git.Git  2.40.0", 0),
      )
      instances = described_class.instances
      expect(instances.size).to eq(1)
      expect(instances.first.name).to eq('Git.Git')
      expect(instances.first.instance_variable_get(:@property_hash)[:ensure]).to eq('2.40.0')
    end

    it 'returns empty array when winget not suitable' do
      allow(described_class).to receive(:suitable?).and_return(false)
      expect(described_class.instances).to eq([])
    end
  end

  describe '#query' do
    let(:winget_path) { 'C:/Path/to/winget.exe' }

    before(:each) do
      allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return(winget_path)
      allow(described_class).to receive(:suitable?).and_return(true)
    end

    it 'returns current package state when installed' do
      allow(Puppet::Util::Execution).to receive(:execute).and_return(
        Puppet::Util::Execution::ProcessOutput.new("Name     Id       Version\n-------------------------\nGit      Git.Git  2.40.0", 0),
      )
      result = provider.query
      expect(result).to eq({ name: 'Git.Git', ensure: '2.40.0', provider: :winget })
    end

    it 'returns nil when not installed' do
      allow(Puppet::Util::Execution).to receive(:execute).and_return(
        Puppet::Util::Execution::ProcessOutput.new("Name     Id       Version\n-------------------------", 0),
      )
      expect(provider.query).to be_nil
    end
  end
end
