# frozen_string_literal: true

# Facts helper for winget facts.
#
# Centralizes the logic behind the `winget_path` and `winget_version` facts so
# it can be unit tested without depending on the Facter confine context.
# Both methods are fast and never raise: they return nil when winget is absent
# or when any error occurs.
# rubocop:disable Style/ClassAndModuleChildren
module PuppetX
  module Winget
    # Facts resolves winget facts using the shared path resolver.
    class Facts
      class << self
        # @return [String, nil] Absolute path to winget.exe, or nil if absent
        def winget_path
          PuppetX::Winget::PathResolver.winget_path
        rescue StandardError
          nil
        end

        # @param path [String, nil] Optional override for the winget path (testing)
        # @return [String, nil] winget version (e.g. '1.8.2391'), or nil if absent
        def winget_version(path = nil)
          winget = path || winget_path
          return nil unless winget && File.exist?(winget)

          require 'puppet/util/execution'
          output = Puppet::Util::Execution.execute([winget, '--version'], failonfail: false, combine: true)
          return nil unless output.exitstatus.zero?

          version = output.strip.sub(%r{\Av}, '')
          version.empty? ? nil : version
        rescue StandardError
          nil
        end
      end
    end
  end
end
# rubocop:enable Style/ClassAndModuleChildren
