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
        allow(File).to receive(:exist?).and_call_original
        winget_paths.each do |p|
          allow(File).to receive(:exist?).with(p).and_return(true)
        end
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

      it 'reuses the cached path without re-scanning' do
        cached = 'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.2.3456.0_x64__8wekyb3d8bbwe/winget.exe'
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with(cached).and_return(true)
        described_class.winget_path
        described_class.winget_path
        expect(Dir).to have_received(:glob).once
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

    context 'when ProgramFiles uses Windows backslashes' do
      # Regression test: ENV paths come back with backslashes on Windows
      # (e.g. 'C:\Program Files'). Dir.glob treats backslashes as escapes,
      # so the resolver must normalize the pattern to forward slashes,
      # otherwise from_windows_apps silently finds nothing and falls back
      # to a per-user alias that SYSTEM cannot execute (winget_version nil).
      before(:each) do
        ENV['ProgramFiles'] = 'C:\\Program Files'
        ENV['ProgramW6432'] = 'C:\\Program Files'
        allow(Dir).to receive(:exist?).and_return(true)
        allow(Dir).to receive(:glob) do |pattern|
          expect(pattern).not_to include('\\')
          ['C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.29.290.0_x64__8wekyb3d8bbwe/winget.exe']
        end
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with('C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.29.290.0_x64__8wekyb3d8bbwe/winget.exe').and_return(true)
      end

      it 'normalizes the glob pattern and resolves the real exe' do
        expect(described_class.winget_path).to eq(
          'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.29.290.0_x64__8wekyb3d8bbwe/winget.exe'
        )
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

    context 'when only a per-user App Execution Alias exists' do
      # Regression test: per-user profile aliases (LOCALAPPDATA, C:/Users/*)
      # must be ignored. The alias file exists on disk but SYSTEM cannot
      # execute another user's AppX alias, so resolving to it reports a
      # winget_path that fails on every invocation.
      before(:each) do
        allow(Dir).to receive(:exist?).and_return(false)
        ENV['LOCALAPPDATA'] = 'C:/Users/jdoe/AppData/Local'
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?)
          .with('C:/Users/jdoe/AppData/Local/Microsoft/WindowsApps/winget.exe')
          .and_return(true)
        allow(Dir).to receive(:glob)
          .with('C:/Users/*/AppData/Local/Microsoft/WindowsApps/winget.exe')
          .and_return(['C:/Users/jdoe/AppData/Local/Microsoft/WindowsApps/winget.exe'])
      end

      after(:each) do
        ENV.delete('LOCALAPPDATA')
      end

      it 'ignores the user-profile alias and returns nil' do
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
        allow(File).to receive(:exist?).and_call_original
        paths.each do |p|
          allow(File).to receive(:exist?).with(p).and_return(true)
        end

        # 1.10.0.0 > 1.2.0.0 with Gem::Version
        expect(described_class.winget_path).to eq(
          'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.10.0.0_x64__8wekyb3d8bbwe/winget.exe'
        )
      end
    end
    context 'when the cached path is deleted between calls' do
      let(:old_path) do
        'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.0.0.0_x64__8wekyb3d8bbwe/winget.exe'
      end
      let(:new_path) do
        'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.2.3456.0_x64__8wekyb3d8bbwe/winget.exe'
      end

      before(:each) do
        allow(Dir).to receive(:exist?).and_return(true)
        allow(Dir).to receive(:glob).and_return([old_path], [new_path])
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with(old_path).and_return(true)
        allow(File).to receive(:exist?).with(new_path).and_return(true)
      end

      it 're-resolves instead of returning the stale path' do
        expect(described_class.winget_path).to eq(old_path)
        allow(File).to receive(:exist?).with(old_path).and_return(false)
        expect(described_class.winget_path).to eq(new_path)
        expect(Dir).to have_received(:glob).twice
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
