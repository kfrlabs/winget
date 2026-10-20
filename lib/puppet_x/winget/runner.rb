# frozen_string_literal: true

require 'open3'

# Shared winget command runner with a timeout.
#
# Every winget invocation goes through here so a stuck `winget`
# (unreachable source, interactive prompt, hung installer) cannot block
# the Puppet agent forever. Read-only commands default to 120 s, mutating
# commands (`install`, `upgrade`, `uninstall`) to 600 s; override both with
# `WINGET_COMMAND_TIMEOUT` (seconds).
#
# On timeout the whole process tree is killed (`taskkill /T /F` on
# Windows, `KILL` on POSIX) and a `TimeoutError` is raised. Callers decide:
# the provider turns it into a `Puppet::Error`, facts swallow it and return
# `nil`/`[]` (facts never raise).
# rubocop:disable Style/ClassAndModuleChildren
module PuppetX
  module Winget
    # Runner executes winget commands with a timeout, killing the process
    # tree on expiry so a hung winget cannot block the Puppet agent.
    class Runner
      READ_TIMEOUT = 120
      WRITE_TIMEOUT = 600

      # Raised when a winget command exceeds its timeout.
      class TimeoutError < StandardError; end

      class << self
        # Default timeout in seconds, honouring `WINGET_COMMAND_TIMEOUT`.
        # @param write [Boolean] True for mutating commands
        # @return [Integer]
        def default_timeout(write: false)
          env = ENV.fetch('WINGET_COMMAND_TIMEOUT', nil)
          if env&.strip&.match?(%r{\A\d+\z}) && Integer(env).positive?
            return Integer(env)
          end

          write ? WRITE_TIMEOUT : READ_TIMEOUT
        rescue StandardError
          write ? WRITE_TIMEOUT : READ_TIMEOUT
        end

        # Run a winget command with a timeout.
        # @param argv [Array<String>] Command and arguments
        # @param timeout [Integer, nil] Seconds (nil uses {.default_timeout})
        # @param write [Boolean] True for mutating commands (longer default)
        # @return [Puppet::Util::Execution::ProcessOutput] Combined output with exitstatus
        # @raise [TimeoutError] When the timeout expires (process tree killed)
        def run(argv, timeout: nil, write: false)
          timeout ||= default_timeout(write: write)
          require 'puppet/util/execution'

          stdin, stdout_err, wait_thr = Open3.popen2e(*argv)
          pid = wait_thr.pid
          output = +''
          reader = Thread.new do
            output << stdout_err.read.to_s
          rescue StandardError
            nil
          end

          if wait_thr.join(timeout).nil?
            kill_tree(pid)
            # Reap the killed child: without this join the pid lingers as a
            # zombie (reaped only when `wait_thr` happens to be scheduled),
            # leaking one zombie per timed-out command in the long-lived
            # agent and making "no orphan" assertions racy. Bounded so a
            # wedged reaper cannot hang the agent (KILL is reliable; this
            # returns immediately in practice).
            begin
              wait_thr.join(5)
            rescue StandardError
              nil
            end
            begin
              stdout_err.close
            rescue StandardError
              nil
            end
            reader.kill
            begin
              reader.join
            rescue StandardError
              nil
            end
            raise TimeoutError, "winget command timed out after #{timeout}s: #{argv.join(' ')}"
          end

          reader.join
          exitstatus = wait_thr.value.exitstatus
          Puppet::Util::Execution::ProcessOutput.new(output, exitstatus || 1)
        ensure
          begin
            stdin.close unless stdin.nil? || stdin.closed?
          rescue StandardError
            nil
          end
          begin
            stdout_err.close unless stdout_err.nil? || stdout_err.closed?
          rescue StandardError
            nil
          end
        end

        private

        # Kill a timed-out process tree. Never raises.
        def kill_tree(pid)
          return if pid.nil?

          if Gem.win_platform?
            system('taskkill', '/T', '/F', '/PID', pid.to_s, out: File::NULL, err: File::NULL)
          else
            begin
              Process.kill('KILL', pid)
            rescue StandardError
              nil
            end
          end
        rescue StandardError
          nil
        end
      end
    end
  end
end
# rubocop:enable Style/ClassAndModuleChildren
