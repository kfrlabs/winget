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
          'No packages found.', 0x8A150014
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

    context 'with EXIT_PACKAGE_ALREADY_INSTALLED (0x8A150061, already installed)' do
      let(:code) { 0x8A150061 }
      it 'returns nil for install (idempotent)' do
        expect(provider.send(:handle_exit_code, output, 'install')).to be_nil
      end
      it 'raises for other actions' do
        expect { provider.send(:handle_exit_code, output, 'upgrade') }.to raise_error(Puppet::Error)
      end
    end

    context 'with EXIT_INSTALL_ALREADY_INSTALLED (0x8A15010D, already installed)' do
      let(:code) { 0x8A15010D }
      it 'returns nil for install (idempotent)' do
        expect(provider.send(:handle_exit_code, output, 'install')).to be_nil
      end
      it 'raises for other actions' do
        expect { provider.send(:handle_exit_code, output, 'upgrade') }.to raise_error(Puppet::Error)
      end
    end

    context 'with reboot codes (0x8A150109/0x8A15010A/0x8A15010B)' do
      [0x8A150109, 0x8A15010A, 0x8A15010B].each do |reboot_code|
        it "warns but returns nil for 0x#{reboot_code.to_s(16).upcase}" do
          reboot_output = Puppet::Util::Execution::ProcessOutput.new('error output', reboot_code)
          expect(Puppet).to receive(:warning).with(/reboot is required/)
          expect(provider.send(:handle_exit_code, reboot_output, 'install')).to be_nil
        end
      end
    end

    context 'with internal/command errors (0x8A150001/0x8A150003 are failures, not success)' do
      [0x8A150001, 0x8A150003].each do |failure_code|
        it "raises with exit code for 0x#{failure_code.to_s(16).upcase}" do
          failure_output = Puppet::Util::Execution::ProcessOutput.new('error output', failure_code)
          expect { provider.send(:handle_exit_code, failure_output, 'install') }.to raise_error(Puppet::Error, /exit code/)
        end
      end
    end

    context 'with EXIT_NO_APPLICABLE_INSTALLER (0x8A150010)' do
      let(:code) { 0x8A150010 }
      it 'raises a no-applicable-installer error' do
        expect { provider.send(:handle_exit_code, output, 'install') }.to raise_error(Puppet::Error, /no applicable installer/)
      end
    end

    context 'with EXIT_NO_APPLICATIONS_FOUND (0x8A150014)' do
      let(:code) { 0x8A150014 }
      it 'raises not-found for install (unknown ID in source)' do
        expect { provider.send(:handle_exit_code, output, 'install') }.to raise_error(Puppet::Error, /not found in winget source/)
      end
      it 'raises a not-installed error for uninstall/upgrade instead of a raw exit code' do
        expect { provider.send(:handle_exit_code, output, 'upgrade') }.to raise_error(Puppet::Error, /is not installed/)
        expect { provider.send(:handle_exit_code, output, 'uninstall') }.to raise_error(Puppet::Error, /is not installed/)
      end
    end

    context 'with EXIT_NO_MANIFEST_FOUND (0x8A150017)' do
      let(:code) { 0x8A150017 }
      it 'raises with package name' do
        expect { provider.send(:handle_exit_code, output, 'install') }.to raise_error(Puppet::Error, /not found in winget source/)
      end
    end

    context 'with EXIT_BLOCKED_BY_POLICY (0x8A15003A)' do
      let(:code) { 0x8A15003A }
      it 'raises a policy error' do
        expect { provider.send(:handle_exit_code, output, 'install') }.to raise_error(Puppet::Error, /blocked by policy/)
      end
    end

    context 'with EXIT_INSTALLER_HASH_MISMATCH (0x8A150011)' do
      let(:code) { 0x8A150011 }
      it 'raises a hash mismatch error' do
        expect { provider.send(:handle_exit_code, output, 'install') }.to raise_error(Puppet::Error, /hash mismatch/)
      end
    end

    context 'with EXIT_DOWNLOAD_FAILED (0x8A150008)' do
      let(:code) { 0x8A150008 }
      it 'raises a download error' do
        expect { provider.send(:handle_exit_code, output, 'install') }.to raise_error(Puppet::Error, /downloading installer failed/)
      end
    end

    context 'with EXIT_INSTALL_CANCELLED_BY_USER (0x8A15010C)' do
      let(:code) { 0x8A15010C }
      it 'raises a cancelled error' do
        expect { provider.send(:handle_exit_code, output, 'install') }.to raise_error(Puppet::Error, /cancelled by user/)
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

  describe '.suitable? warning throttle' do
    before(:each) do
      allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return(nil)
    end

    it 'warns only once for repeated unsuitable checks' do
      expect(Puppet).to receive(:warning).once.with(%r{winget provider is unsuitable})
      allow(Puppet).to receive(:debug)
      expect(described_class.suitable?).to be false
      expect(described_class.suitable?).to be false
    end
  end

  describe '.instances_list caching' do
    let(:winget_path) { 'C:/Path/to/winget.exe' }
    let(:list_output) do
      <<~OUTPUT
        Name                  Id                   Version     Source
        ----------------------------------------------------------------
        Git                   Git.Git              2.40.0      winget
      OUTPUT
    end

    before(:each) do
      allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return(winget_path)
      allow(described_class).to receive(:suitable?).and_return(true)
    end

    it 'runs winget list only once for repeated lookups' do
      expect(Puppet::Util::Execution).to receive(:execute).once.and_return(
        Puppet::Util::Execution::ProcessOutput.new(list_output, 0),
      )
      described_class.instances_list
      described_class.instances_list
    end

    it 're-lists after clear_list_cache!' do
      expect(Puppet::Util::Execution).to receive(:execute).twice.and_return(
        Puppet::Util::Execution::ProcessOutput.new(list_output, 0),
      )
      described_class.instances_list
      described_class.clear_list_cache!
      described_class.instances_list
    end

    it 'does not cache a failed listing (non-zero exit) as an empty list' do
      allow(Puppet).to receive(:warning)
      expect(Puppet::Util::Execution).to receive(:execute).twice.and_return(
        Puppet::Util::Execution::ProcessOutput.new('Internal error', 0x8A150001),
      )
      expect(described_class.instances_list).to eq({})
      expect(described_class.list_unavailable?).to be true
      # A second call retries instead of serving a cached empty result.
      expect(described_class.instances_list).to eq({})
    end

    it 'does not cache a listing that raised' do
      allow(Puppet).to receive(:warning)
      allow(Puppet::Util::Execution).to receive(:execute).and_raise(StandardError.new('boom'))
      expect(described_class.instances_list).to eq({})
      expect(described_class.list_unavailable?).to be true
    end

    it 'marks the list available again once a listing succeeds' do
      allow(Puppet).to receive(:warning)
      allow(Puppet::Util::Execution).to receive(:execute).and_return(
        Puppet::Util::Execution::ProcessOutput.new('Internal error', 0x8A150001),
      )
      described_class.instances_list
      expect(described_class.list_unavailable?).to be true

      allow(Puppet::Util::Execution).to receive(:execute).and_return(
        Puppet::Util::Execution::ProcessOutput.new(list_output, 0),
      )
      described_class.instances_list
      expect(described_class.list_unavailable?).to be false
    end

    it 'query raises instead of reporting absent when the listing failed' do
      allow(Puppet).to receive(:warning)
      allow(Puppet::Util::Execution).to receive(:execute).and_return(
        Puppet::Util::Execution::ProcessOutput.new('Internal error', 0x8A150001),
      )
      resource = Puppet::Type.type(:package).new(name: 'Git.Git', ensure: :installed, provider: :winget)
      provider = described_class.new(resource)
      expect { provider.query }.to raise_error(Puppet::Error, %r{Cannot determine whether package})
    end
  end

  describe '.prefetch' do
    let(:winget_path) { 'C:/Path/to/winget.exe' }
    let(:list_output) do
      <<~OUTPUT
        Name                  Id                   Version     Source
        ----------------------------------------------------------------
        Git                   Git.Git              2.40.0      winget
        Foo                   Foo.Foo              1.0.0       winget
      OUTPUT
    end

    before(:each) do
      allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return(winget_path)
      allow(described_class).to receive(:suitable?).and_return(true)
    end

    it 'shares a single winget list across resources' do
      expect(Puppet::Util::Execution).to receive(:execute).once.and_return(
        Puppet::Util::Execution::ProcessOutput.new(list_output, 0),
      )
      resource_a = Puppet::Type.type(:package).new(name: 'Git.Git', ensure: :installed, provider: :winget)
      resource_b = Puppet::Type.type(:package).new(name: 'Foo.Foo', ensure: :installed, provider: :winget)
      described_class.prefetch('Git.Git' => resource_a, 'Foo.Foo' => resource_b)
      expect(resource_a.provider.installed_entry[:version]).to eq('2.40.0')
      expect(resource_b.provider.installed_entry[:version]).to eq('1.0.0')
      expect(resource_a.provider.query[:ensure]).to eq('2.40.0')
    end

    it 'caches absent entries without re-listing' do
      expect(Puppet::Util::Execution).to receive(:execute).once.and_return(
        Puppet::Util::Execution::ProcessOutput.new(list_output, 0),
      )
      missing = Puppet::Type.type(:package).new(name: 'Missing.Missing', ensure: :installed, provider: :winget)
      described_class.prefetch('Missing.Missing' => missing)
      expect(missing.provider.installed_entry).to be_nil
      expect(missing.provider.query).to be_nil
    end

    it 'matches IDs case-insensitively' do
      expect(Puppet::Util::Execution).to receive(:execute).once.and_return(
        Puppet::Util::Execution::ProcessOutput.new(list_output, 0),
      )
      resource = Puppet::Type.type(:package).new(name: 'git.git', ensure: :installed, provider: :winget)
      described_class.prefetch('git.git' => resource)
      expect(resource.provider.installed_entry[:version]).to eq('2.40.0')
      expect(resource.provider.query[:ensure]).to eq('2.40.0')
    end

    it 'skips resources managed by another provider' do
      expect(Puppet::Util::Execution).to receive(:execute).once.and_return(
        Puppet::Util::Execution::ProcessOutput.new(list_output, 0),
      )
      winget_resource = Puppet::Type.type(:package).new(name: 'Git.Git', ensure: :installed, provider: :winget)
      other = Puppet::Type.type(:package).new(name: 'Other', ensure: :installed)
      described_class.prefetch('Git.Git' => winget_resource, 'Other' => other)
      expect(winget_resource.provider.installed_entry[:version]).to eq('2.40.0')
    end

    it 'does not raise when the listing fails' do
      allow(described_class).to receive(:instances_list).and_raise(StandardError.new('boom'))
      resource = Puppet::Type.type(:package).new(name: 'Git.Git', ensure: :installed, provider: :winget)
      expect { described_class.prefetch('Git.Git' => resource) }.not_to raise_error
    end

    it 'leaves entries absent without raising when winget is unsuitable' do
      allow(described_class).to receive(:suitable?).and_return(false)
      allow(described_class).to receive(:instances_list).and_call_original
      allow(described_class).to receive(:fetch_instances_list).and_call_original
      resource = Puppet::Type.type(:package).new(name: 'Git.Git', ensure: :installed, provider: :winget)
      expect { described_class.prefetch('Git.Git' => resource) }.not_to raise_error
      expect(resource.provider.installed_entry).to be_nil
    end
  end

  describe 'ensure => latest full cycle' do
    let(:winget_path) { 'C:/Path/to/winget.exe' }

    before(:each) do
      allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return(winget_path)
      allow(described_class).to receive(:suitable?).and_return(true)
    end

    context 'when the package is absent' do
      let(:resource) do
        Puppet::Type.type(:package).new(
          name: 'Git.Git',
          ensure: :latest,
          provider: :winget
        )
      end

      it 'query is nil, latest advertises a version, update installs' do
        allow(described_class).to receive(:instances_list).and_return({})
        show_output = Puppet::Util::Execution::ProcessOutput.new("Version: 2.41.0\n", 0)
        expect(provider).to receive(:winget_exec).with('show', '--id', 'Git.Git').and_return(show_output)
        expect(provider.query).to be_nil
        expect(provider.latest).to eq('2.41.0')

        upgrade_output = Puppet::Util::Execution::ProcessOutput.new(
          'No packages found.', 0x8A150014
        )
        expect(provider).to receive(:winget_exec).with('upgrade', '--id', 'Git.Git').and_return(upgrade_output)
        expect(provider).to receive(:install)
        provider.update
      end
    end

    context 'when the package is outdated' do
      let(:resource) do
        Puppet::Type.type(:package).new(
          name: 'Git.Git',
          ensure: :latest,
          provider: :winget
        )
      end

      it 'latest returns the candidate and update upgrades without reinstalling' do
        allow(described_class).to receive(:instances_list).and_return(
          'git.git' => { name: 'Git', version: '2.40.0', source: 'winget', id: 'Git.Git' },
        )
        show_output = Puppet::Util::Execution::ProcessOutput.new("Version: 2.41.0\n", 0)
        expect(provider).to receive(:winget_exec).with('show', '--id', 'Git.Git').and_return(show_output)
        expect(provider.latest).to eq('2.41.0')

        upgrade_output = Puppet::Util::Execution::ProcessOutput.new('', 0)
        expect(provider).to receive(:winget_exec).with('upgrade', '--id', 'Git.Git').and_return(upgrade_output)
        expect(provider).not_to receive(:install)
        provider.update
      end
    end

    context 'when the package is already at latest (trailing zero segments)' do
      let(:resource) do
        Puppet::Type.type(:package).new(
          name: 'Git.Git',
          ensure: :latest,
          provider: :winget
        )
      end

      it 'latest reports the installed version so the resource stays in sync' do
        allow(described_class).to receive(:instances_list).and_return(
          'git.git' => { name: 'Git', version: '2.40.00.0', source: 'winget', id: 'Git.Git' },
        )
        show_output = Puppet::Util::Execution::ProcessOutput.new("Version: 2.40\n", 0)
        expect(provider).to receive(:winget_exec).with('show', '--id', 'Git.Git').and_return(show_output)
        expect(provider.latest).to eq('2.40.00.0')
      end
    end

    context 'with a source in install_options' do
      let(:resource) do
        Puppet::Type.type(:package).new(
          name: 'Git.Git',
          ensure: :latest,
          provider: :winget,
          install_options: [{ 'source' => 'msstore' }]
        )
      end

      it 'passes --source to show' do
        show_output = Puppet::Util::Execution::ProcessOutput.new("Version: 2.41.0\n", 0)
        expect(provider).to receive(:winget_exec).with('show', '--id', 'Git.Git', '--source', 'msstore').and_return(show_output)
        expect(provider.latest).to eq('2.41.0')
      end

      it 'passes --source to upgrade' do
        upgrade_output = Puppet::Util::Execution::ProcessOutput.new('', 0)
        expect(provider).to receive(:winget_exec).with('upgrade', '--id', 'Git.Git', '--source', 'msstore').and_return(upgrade_output)
        provider.update
      end
    end

    context 'when show output has no parseable version' do
      it 'returns nil' do
        output = Puppet::Util::Execution::ProcessOutput.new('No version here', 0)
        expect(provider).to receive(:winget_exec).with('show', '--id', 'Git.Git').and_return(output)
        expect(provider.latest).to be_nil
      end
    end

    context 'cache invalidation' do
      let(:list_output) do
        <<~OUTPUT
          Name                  Id                   Version     Source
          ----------------------------------------------------------------
          Git                   Git.Git              2.40.0      winget
        OUTPUT
      end

      it 'install clears the list cache so the next lookup re-lists' do
        allow(Puppet::Util::Execution).to receive(:execute).and_return(
          Puppet::Util::Execution::ProcessOutput.new(list_output, 0),
        )
        described_class.instances_list
        allow(provider).to receive(:winget_exec).and_return(
          Puppet::Util::Execution::ProcessOutput.new('', 0),
        )
        provider.install
        described_class.instances_list
        expect(Puppet::Util::Execution).to have_received(:execute).twice
      end

      it 'update clears the per-instance entry so query observes the new state' do
        allow(described_class).to receive(:instances_list).and_return(
          'git.git' => { name: 'Git', version: '2.40.0', source: 'winget', id: 'Git.Git' },
        )
        expect(provider.query[:ensure]).to eq('2.40.0')
        allow(provider).to receive(:winget_exec).and_return(
          Puppet::Util::Execution::ProcessOutput.new('', 0),
        )
        provider.update
        allow(described_class).to receive(:instances_list).and_return(
          'git.git' => { name: 'Git', version: '2.41.0', source: 'winget', id: 'Git.Git' },
        )
        expect(provider.query[:ensure]).to eq('2.41.0')
      end
    end
  end

  describe 'first run before bootstrap (winget absent)' do
    it 'becomes suitable once winget appears: a nil path is re-resolved, not memoized' do
      allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return(nil, 'C:/Path/to/winget.exe')
      allow(Puppet).to receive(:warning)
      allow(Puppet).to receive(:debug)
      expect(described_class.suitable?).to be false
      expect(described_class.suitable?).to be true
    end

    it 'prefetch leaves entries absent without raising when winget is missing' do
      allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return(nil)
      allow(Puppet).to receive(:warning)
      allow(Puppet).to receive(:debug)
      resource = Puppet::Type.type(:package).new(name: 'Git.Git', ensure: :installed, provider: :winget)
      expect { described_class.prefetch('Git.Git' => resource) }.not_to raise_error
      expect(resource.provider.installed_entry).to be_nil
      expect(resource.provider.query).to be_nil
    end

    it 'install after bootstrap uses the fresh path (ordered Class[winget] -> Package converges in one run)' do
      allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return(nil, 'C:/Path/to/winget.exe')
      allow(Puppet).to receive(:warning)
      allow(Puppet).to receive(:debug)
      resource = Puppet::Type.type(:package).new(name: 'Git.Git', ensure: :installed, provider: :winget)
      described_class.prefetch('Git.Git' => resource)
      expect(resource.provider.query).to be_nil
      expect(Puppet::Util::Execution).to receive(:execute).with(
        ['C:/Path/to/winget.exe', 'install', '--id', 'Git.Git', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity', '--exact', '--silent'],
        hash_including(failonfail: false, combine: true)
      ).and_return(Puppet::Util::Execution::ProcessOutput.new('', 0))
      resource.provider.install
    end
  end

  describe 'holdable feature' do
    let(:winget_path) { 'C:/Path/to/winget.exe' }
    let(:list_output) do
      <<~OUTPUT
        Name                  Id                   Version     Source
        ----------------------------------------------------------------
        Git                   Git.Git              2.40.0      winget
      OUTPUT
    end
    let(:pin_output) do
      <<~OUTPUT
        Name                  Id                   Version   Pin
        ----------------------------------------------------------------
        Git                   Git.Git              2.40.0    Pinning
      OUTPUT
    end

    before(:each) do
      allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return(winget_path)
      allow(described_class).to receive(:suitable?).and_return(true)
      # run_pins guards on File.exist?: the fake Windows path never exists
      # on the Linux test runner without this stub.
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(winget_path).and_return(true)
    end

    it 'has holdable feature' do
      expect(described_class.features).to include(:holdable)
    end

    context 'when the resource does not manage mark' do
      it 'query reports no mark and spends no pin list call' do
        allow(Puppet::Util::Execution).to receive(:execute).and_return(
          Puppet::Util::Execution::ProcessOutput.new(list_output, 0),
        )
        expect(provider.query).to eq({ name: 'Git.Git', ensure: '2.40.0', provider: :winget })
        expect(Puppet::Util::Execution).to have_received(:execute).once
      end
    end

    context 'when the resource manages mark' do
      let(:resource) do
        Puppet::Type.type(:package).new(
          name: 'Git.Git',
          ensure: :installed,
          provider: :winget,
          mark: :hold
        )
      end

      it 'query reports hold when the package is pinned' do
        allow(Puppet::Util::Execution).to receive(:execute) do |cmd, *_args|
          if cmd.include?('pin')
            Puppet::Util::Execution::ProcessOutput.new(pin_output, 0)
          else
            Puppet::Util::Execution::ProcessOutput.new(list_output, 0)
          end
        end
        expect(provider.query).to include(mark: :hold)
      end

      it 'query reports none when the package is not pinned' do
        allow(Puppet::Util::Execution).to receive(:execute) do |cmd, *_args|
          if cmd.include?('pin')
            Puppet::Util::Execution::ProcessOutput.new("No pins exist.\n", 0)
          else
            Puppet::Util::Execution::ProcessOutput.new(list_output, 0)
          end
        end
        expect(provider.query).to include(mark: :none)
      end
    end

    describe '#hold' do
      it 'calls winget pin add non-interactively' do
        allow(described_class).to receive(:pins_list).and_return({})
        expect(Puppet::Util::Execution).to receive(:execute).with(
          [winget_path, 'pin', 'add', '--id', 'Git.Git', '--accept-source-agreements', '--disable-interactivity', '--exact'],
          hash_including(failonfail: false, combine: true)
        ).and_return(Puppet::Util::Execution::ProcessOutput.new('', 0))
        expect(provider.hold).to be_nil
      end

      it 'is idempotent when already pinned' do
        allow(described_class).to receive(:pins_list).and_return('git.git' => true)
        expect(Puppet::Util::Execution).not_to receive(:execute)
        expect(provider.hold).to be_nil
      end

      it 'raises a meaningful error when pinning fails' do
        allow(described_class).to receive(:pins_list).and_return({})
        allow(Puppet::Util::Execution).to receive(:execute).and_return(
          Puppet::Util::Execution::ProcessOutput.new('pin failed', 1),
        )
        expect { provider.hold }.to raise_error(Puppet::Error, %r{Failed to pin package})
      end
    end

    describe '#unhold' do
      it 'calls winget pin remove non-interactively' do
        allow(described_class).to receive(:pins_list).and_return('git.git' => true)
        expect(Puppet::Util::Execution).to receive(:execute).with(
          [winget_path, 'pin', 'remove', '--id', 'Git.Git', '--accept-source-agreements', '--disable-interactivity', '--exact'],
          hash_including(failonfail: false, combine: true)
        ).and_return(Puppet::Util::Execution::ProcessOutput.new('', 0))
        expect(provider.unhold).to be_nil
      end

      it 'is idempotent when not pinned' do
        allow(described_class).to receive(:pins_list).and_return({})
        expect(Puppet::Util::Execution).not_to receive(:execute)
        expect(provider.unhold).to be_nil
      end
    end

    describe 'install with mark => hold' do
      let(:resource) do
        Puppet::Type.type(:package).new(
          name: 'Git.Git',
          ensure: :installed,
          provider: :winget,
          mark: :hold
        )
      end

      before(:each) do
        allow(described_class).to receive(:pins_list).and_return({})
      end

      it 'pins the package after a successful install' do
        expect(provider).to receive(:winget_exec).with('install', '--id', 'Git.Git').and_return(
          Puppet::Util::Execution::ProcessOutput.new('', 0)
        )
        expect(provider).to receive(:pin_exec).with('add').and_return(
          Puppet::Util::Execution::ProcessOutput.new('', 0)
        )
        provider.install
      end
    end

    describe '.pins_list caching' do
      it 'runs winget pin list only once for repeated lookups' do
        expect(Puppet::Util::Execution).to receive(:execute).once.and_return(
          Puppet::Util::Execution::ProcessOutput.new(pin_output, 0),
        )
        described_class.pins_list
        described_class.pins_list
        expect(described_class.pins_list).to eq('git.git' => true)
      end

      it 're-lists after clear_pins_cache!' do
        expect(Puppet::Util::Execution).to receive(:execute).twice.and_return(
          Puppet::Util::Execution::ProcessOutput.new(pin_output, 0),
        )
        described_class.pins_list
        described_class.clear_pins_cache!
        described_class.pins_list
      end

      it 'returns an empty hash when winget is not suitable' do
        allow(described_class).to receive(:suitable?).and_return(false)
        expect(Puppet::Util::Execution).not_to receive(:execute)
        expect(described_class.pins_list).to eq({})
      end

      it 'returns an empty hash when pin list fails' do
        allow(Puppet::Util::Execution).to receive(:execute).and_return(
          Puppet::Util::Execution::ProcessOutput.new('boom', 1),
        )
        expect(described_class.pins_list).to eq({})
      end
    end

    describe 'install_options source pair form' do
      let(:resource) do
        Puppet::Type.type(:package).new(
          name: 'Git.Git',
          ensure: :installed,
          provider: :winget,
          install_options: ['--scope', 'machine', '--source', 'msstore']
        )
      end

      it 'extracts the source for show/upgrade and keeps both flags for install' do
        expect(provider.send(:install_options_source)).to eq('msstore')
        expect(provider).to receive(:winget_exec).with('install', '--id', 'Git.Git', '--source', 'msstore', '--scope', 'machine').and_return(
          Puppet::Util::Execution::ProcessOutput.new('', 0)
        )
        provider.install
      end
    end
  end
end
