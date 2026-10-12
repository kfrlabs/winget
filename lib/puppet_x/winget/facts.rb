# frozen_string_literal: true

require 'puppet_x/winget/path_resolver'

# Facts helper for winget facts.
#
# Centralizes the logic behind the `winget_path`, `winget_version` and
# `winget_upgrades` facts so it can be unit tested without depending on the
# Facter confine context. Helpers never raise: they return nil/[] when winget
# is absent or when any error occurs. Note `winget_upgrades` shells out to
# `winget upgrade` (source round-trips, a few seconds) while the other two
# are fast.
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

        # @param path [String, nil] Optional override for the winget path (testing)
        # @return [Array<String>] Package IDs with an available upgrade ([] when absent/error)
        def winget_upgrades(path = nil)
          winget = path || winget_path
          return [] unless winget && File.exist?(winget)

          require 'puppet/util/execution'
          output = Puppet::Util::Execution.execute(
            [winget, 'upgrade', '--accept-source-agreements', '--disable-interactivity'],
            failonfail: false, combine: true,
          )
          parse_winget_upgrade(output.to_s)
        rescue StandardError
          []
        end

        # Parse `winget upgrade` table output into package IDs.
        # Same table layout as `winget list` plus an `Available` column; the
        # header match is language-agnostic (Nom/Disponible on French systems).
        # Footers (e.g. "3 upgrades available.") contain spaces and are skipped:
        # package IDs never contain spaces.
        # @param output [String, nil] Raw output from `winget upgrade`
        # @return [Array<String>] Deduplicated package IDs
        def parse_winget_upgrade(output)
          ids = []
          return ids if output.nil? || output.empty?

          lines = output.lines.map(&:chomp).reject(&:empty?)

          header_idx = lines.find_index { |line| line.match?(%r{Id.*Version}i) }
          return ids unless header_idx

          data_lines = lines[(header_idx + 2)..] || []
          data_lines.each do |line|
            next if line.match?(%r{^[-=]+\s*$})

            parts = line.split(%r{\s{2,}})
            next if parts.size < 2

            id = parts[1]&.strip
            next if id.nil? || id.empty?
            next if id.match?(%r{\s})

            ids << id unless ids.include?(id)
          end

          ids
        end
      end
    end
  end
end
# rubocop:enable Style/ClassAndModuleChildren
