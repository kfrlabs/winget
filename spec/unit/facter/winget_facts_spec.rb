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
          double('output', exitstatus: 1, stdout: '', stderr: 'error')
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
          double('output', exitstatus: 0, stdout: "v1.8.2391\n")
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
          double('output', exitstatus: 0, stdout: "1.8.2391\n")
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
          double('output', exitstatus: 0, stdout: "\n")
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
          double('output', exitstatus: 0, stdout: 'v1.8.2391')
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
  end
end
