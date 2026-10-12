# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/winget/path_resolver'

RSpec.describe PuppetX::Winget::PathResolver do
  before(:each) do
    described_class.reset!
    ENV['ProgramFiles'] = 'C:/Program Files'
  end

  after(:each) do
    described_class.reset!
  end

  describe '.winget_path' do
    context 'when winget is not installed' do
      before(:each) do
        allow(Dir).to receive(:exist?).and_return(false)
      end

      it 'returns nil' do
        expect(described_class.winget_path).to be_nil
      end
    end

    context 'when WindowsApps directory does not exist' do
      before(:each) do
        allow(Dir).to receive(:exist?).with('C:/Program Files').and_return(true)
        allow(Dir).to receive(:exist?).with('C:/Program Files/WindowsApps').and_return(false)
      end

      it 'returns nil' do
        expect(described_class.winget_path).to be_nil
      end
    end

    context 'when winget executables are found' do
      let(:winget_paths) do
        [
          'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.0.0.0_x64__8wekyb3d8bbwe/winget.exe',
          'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.2.3456.0_x64__8wekyb3d8bbwe/winget.exe',
          'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.1.0.0_arm64__8wekyb3d8bbwe/winget.exe'
        ]
      end

      before(:each) do
        allow(Dir).to receive(:exist?).with('C:/Program Files').and_return(true)
        allow(Dir).to receive(:exist?).with('C:/Program Files/WindowsApps').and_return(true)
        allow(Dir).to receive(:glob).and_return(winget_paths)
      end

      it 'returns the highest version (x64)' do
        expect(described_class.winget_path).to eq(
          'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.2.3456.0_x64__8wekyb3d8bbwe/winget.exe'
        )
      end

      it 'memoizes the result' do
        described_class.winget_path
        expect(Dir).to have_received(:glob).once
        described_class.winget_path
      end

      context 'with arm64 highest version' do
        let(:winget_paths) do
          [
            'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.0.0.0_x64__8wekyb3d8bbwe/winget.exe',
            'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_2.0.0.0_arm64__8wekyb3d8bbwe/winget.exe'
          ]
        end

        it 'returns the arm64 version when higher' do
          expect(described_class.winget_path).to eq(
            'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_2.0.0.0_arm64__8wekyb3d8bbwe/winget.exe'
          )
        end
      end
    end

    context 'when Dir.glob raises an error' do
      before(:each) do
        allow(Dir).to receive(:exist?).with('C:/Program Files').and_return(true)
        allow(Dir).to receive(:exist?).with('C:/Program Files/WindowsApps').and_return(true)
        allow(Dir).to receive(:glob).and_raise(StandardError.new('Permission denied'))
      end

      it 'returns nil and does not raise' do
        expect(described_class.winget_path).to be_nil
      end
    end

    context 'when ProgramFiles is not set' do
      before(:each) do
        ENV.delete('ProgramFiles')
      end

      it 'returns nil' do
        expect(described_class.winget_path).to be_nil
      end
    end

    context 'version comparison' do
      it 'correctly compares versions using Gem::Version' do
        paths = [
          'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.10.0.0_x64__8wekyb3d8bbwe/winget.exe',
          'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.2.0.0_x64__8wekyb3d8bbwe/winget.exe'
        ]
        allow(Dir).to receive(:exist?).with('C:/Program Files').and_return(true)
        allow(Dir).to receive(:exist?).with('C:/Program Files/WindowsApps').and_return(true)
        allow(Dir).to receive(:glob).and_return(paths)

        # 1.10.0.0 > 1.2.0.0 with Gem::Version
        expect(described_class.winget_path).to eq(
          'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.10.0.0_x64__8wekyb3d8bbwe/winget.exe'
        )
      end
    end
  end

  describe '.reset!' do
    it 'clears the memoized path' do
      allow(Dir).to receive(:exist?).with('C:/Program Files').and_return(true)
      allow(Dir).to receive(:exist?).with('C:/Program Files/WindowsApps').and_return(true)
      allow(Dir).to receive(:glob).and_return(['C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.0.0.0_x64__8wekyb3d8bbwe/winget.exe'])

      described_class.winget_path
      described_class.reset!

      allow(Dir).to receive(:glob).and_return([])
      expect(described_class.winget_path).to be_nil
    end
  end
end
