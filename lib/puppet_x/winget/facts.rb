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
        # Columns are sliced at the header offsets (fixed-width table) instead
        # of split on whitespace: winget shrinks the gap between two columns
        # to a single space for long names (truncated with `…`), so a
        # whitespace split shifts every column (the installed version is then
        # read as the ID) or glues ID and version together (package skipped).
        # The header match stays language-agnostic (Nom / Disponible on French
        # systems). Rows shorter than the Version column (e.g. the "N upgrades
        # available." footer) are skipped: package IDs never contain spaces.
        # `winget upgrade` may print several tables (upgrades, then packages
        # requiring explicit targeting when some versions are unknown), each
        # with its own header: every table is parsed with its own offsets so
        # a later header's `Id` cell is never mistaken for a package ID.
        # @param output [String, nil] Raw output from `winget upgrade`
        # @return [Array<String>] Deduplicated package IDs
        def parse_winget_upgrade(output)
          ids = []
          return ids if output.nil? || output.empty?

          lines = output.lines.map(&:chomp).reject(&:empty?)

          header_indices = lines.each_index.select { |i| table_header?(lines[i]) }
          return ids if header_indices.empty?

          header_indices.each do |header_idx|
            id_start, version_start = column_offsets(lines[header_idx])
            next unless id_start && version_start

            data_lines = lines[(header_idx + 2)..] || []
            data_lines.each do |line|
              break if table_header?(line)
              next if line.match?(%r{^[-=]+\s*$})
              next if line.length < version_start

              id = line[id_start...version_start]&.strip
              next if id.nil? || id.empty?
              next if id.match?(%r{\s})

              ids << id unless ids.include?(id)
            end
          end

          ids
        end

        # Whether a line is a winget table header (and not a data row that
        # merely mentions "Id" and "Version"): the Id column cell must read
        # exactly `Id`.
        # @param line [String] Candidate output line
        # @return [Boolean] True when the line opens a result table
        def table_header?(line)
          return false unless line.match?(%r{Id.*Version}i)

          id_start, version_start = column_offsets(line)
          return false unless id_start && version_start

          line[id_start...version_start]&.strip&.match?(%r{\AId\z}i) || false
        end

        # Locate the Id and Version column starts in a winget table header.
        # @param header [String] Header line containing `Id` and `Version`
        # @return [Array<(Integer, nil)>] Id/Version offsets, nils when absent
        def column_offsets(header)
          id_start = header.index(%r{\bId\b}i)
          version_start = header.index(%r{\bVersion\b}i)
          return [nil, nil] unless id_start && version_start && version_start > id_start

          [id_start, version_start]
        end
      end
    end
  end
end
# rubocop:enable Style/ClassAndModuleChildren
