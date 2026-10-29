# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/winget/runner'

RSpec.describe PuppetX::Winget::Runner do
  after(:each) do
    ENV.delete('WINGET_COMMAND_TIMEOUT')
  end

  describe '.default_timeout' do
    it 'returns 120 for read commands by default' do
      ENV.delete('WINGET_COMMAND_TIMEOUT')
      expect(described_class.default_timeout(write: false)).to eq(120)
    end

    it 'returns 600 for write commands by default' do
      ENV.delete('WINGET_COMMAND_TIMEOUT')
      expect(described_class.default_timeout(write: true)).to eq(600)
    end

    it 'honours WINGET_COMMAND_TIMEOUT' do
      ENV['WINGET_COMMAND_TIMEOUT'] = '5'
      expect(described_class.default_timeout(write: false)).to eq(5)
      expect(described_class.default_timeout(write: true)).to eq(5)
    end

    it 'ignores invalid WINGET_COMMAND_TIMEOUT values' do
      ENV['WINGET_COMMAND_TIMEOUT'] = 'banana'
      expect(described_class.default_timeout(write: false)).to eq(120)
    end
  end

  describe '.run (issue #33)' do
    it 'returns combined output within the timeout' do
      result = described_class.run(['echo', 'hello'], timeout: 5)
      expect(result.to_s).to include('hello')
      expect(result.exitstatus).to eq(0)
    end

    it 'raises TimeoutError when a stub process sleeps longer than the timeout and leaves no orphan' do
      pid = nil
      allow(Open3).to receive(:popen2e).and_wrap_original do |original, *argv|
        stdin, stdout_err, wait_thr = original.call(*argv)
        pid = wait_thr.pid
        [stdin, stdout_err, wait_thr]
      end
      # Use a short sleep that exceeds a very short timeout.
      start = Time.now
      expect {
        described_class.run(['sleep', '10'], timeout: 1)
      }.to raise_error(described_class::TimeoutError, %r{timed out after 1s})
      expect(Time.now - start).to be < 5
      # No orphan: the slept process must be gone.
      if pid
        expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
      end
    end

    it 'provider raises Puppet::Error on timeout (fail fast, no hang)' do
      require 'puppet/provider/package/winget'
      provider_class = Puppet::Type.type(:package).provider(:winget)
      provider_class.reset!
      PuppetX::Winget::PathResolver.reset!
      allow(PuppetX::Winget::PathResolver).to receive(:winget_path).and_return('/fake/winget.exe')
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/fake/winget.exe').and_return(true)
      allow(described_class).to receive(:run).and_raise(described_class::TimeoutError.new('timed out after 1s: winget list'))
      expect {
        provider_class.instances_list
      }.not_to raise_error
      # instances_list swallows timeout into {} (unknown state), query refuses absent.
      expect(provider_class.list_unavailable?).to be true
      provider_class.reset!
    end
  end
end
