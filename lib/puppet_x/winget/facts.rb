# frozen_string_literal: true

require 'puppet_x/winget/path_resolver'

# Facts helper for winget facts.
#
# Centralizes the logic behind the `winget_path`, `winget_version`,
# `winget_upgrades` and `winget_pins` facts so it
# can be unit tested without depending on the Facter confine context.
# Helpers never raise: they return nil/[] when winget is absent or when any
# error occurs. Note `winget_upgrades` shells out
# to `winget upgrade` (source round-trips, a few seconds) with a single
# memoized invocation per process, while `winget_pins` is a fast local
# `winget pin list` query. To avoid paying the upgrade cost on every agent
# run, either cache the fact with a TTL in facter.conf
# (`facts: { ttls: [{ winget_upgrades: "1 day" }] }`) or opt out entirely with
# `WINGET_UPGRADES_ENABLED=false` (the upgrade fact then returns []).
# rubocop:disable Style/ClassAndModuleChildren
module PuppetX
  module Winget
    # Facts resolves winget facts using the shared path resolver.
    class Facts
      # Length of the literal 'Version' table header word, used in column
      # offset math (a constant so the size is never recomputed).
      VERSION_HEADER_LENGTH = 7
      class << self
        # Clear memoized command output (primarily for testing).
        def reset!
          @upgrade_output = nil
          @pins_output = nil
        end

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

        # Whether the expensive `winget_upgrades`
        # fact may run. Opt out by setting `WINGET_UPGRADES_ENABLED` to a
        # false-like value (`false`, `0`, `no`, `off`). Anything else
        # (including unset) keeps the fact enabled for backward
        # compatibility.
        # @return [Boolean] False when the upgrade fact must return [] without shelling out
        def upgrades_enabled?
          value = ENV.fetch('WINGET_UPGRADES_ENABLED', nil)
          return true if value.nil?

          !value.strip.match?(%r{\A(false|0|no|off)\z}i)
        rescue StandardError
          true
        end

        # Raw `winget upgrade` output, memoized per process so the
        # `winget_upgrades` fact only shells out once.
        # Only memoized for the default (nil) path: explicit path
        # overrides (used in tests) always run fresh.
        # @param path [String, nil] Optional override for the winget path (testing)
        # @return [String, nil] Raw command output, or nil when disabled/absent/failed
        def upgrade_output(path = nil)
          return run_upgrade(path) unless path.nil?

          @upgrade_output = run_upgrade(nil) if @upgrade_output.nil?
          @upgrade_output
        end

        # Single uncached `winget upgrade` run. Never raises.
        # @param path [String, nil] Optional override for the winget path (testing)
        # @return [String, nil] Raw command output, or nil when disabled/absent/failed
        def run_upgrade(path)
          return nil unless upgrades_enabled?

          winget = path || winget_path
          return nil unless winget && File.exist?(winget)

          require 'puppet/util/execution'
          output = Puppet::Util::Execution.execute(
            [winget, 'upgrade', '--accept-source-agreements', '--disable-interactivity'],
            failonfail: false, combine: true,
          )
          output.to_s
        rescue StandardError
          nil
        end

        # @param path [String, nil] Optional override for the winget path (testing)
        # @return [Array<Hash>] Upgrade rows with 'id', 'current_version' and
        #   'available_version' keys ([] when absent/error/disabled)
        def winget_upgrades(path = nil)
          parse_winget_upgrade(upgrade_output(path))
        rescue StandardError
          []
        end

        # Parse `winget upgrade` table output into structured rows with the
        # installed and available versions. Columns are sliced at the header
        # offsets (fixed-width table) instead of split on whitespace: winget
        # shrinks the gap between two columns to a single space for long
        # names (truncated with `…`), so a whitespace split shifts every
        # column (the installed version is then read as the ID) or glues ID
        # and version together (package skipped). The header match stays
        # language-agnostic (Nom / Disponible on French systems). Rows
        # shorter than the Version column (e.g. the "N upgrades available."
        # footer) are skipped: package IDs never contain spaces.
        # `winget upgrade` may print several tables (upgrades, then packages
        # requiring explicit targeting when some versions are unknown), each
        # with its own header: every table is parsed with its own offsets so
        # a later header's `Id` cell is never mistaken for a package ID.
        # The Available column (English `Available`, French `Disponible`)
        # holds versions as single tokens, so the available cell is read as
        # the first token at its offset (the Source column may follow on the
        # same row). Tables without an Available column yield rows with nil
        # versions.
        # @param output [String, nil] Raw output from `winget upgrade`
        # @return [Array<Hash>] Deduplicated rows ('id', 'current_version', 'available_version')
        def parse_winget_upgrade(output)
          rows = []
          seen = []
          return rows if output.nil? || output.empty?

          lines = output_lines(output)

          header_indices = lines.each_index.select { |i| table_header?(lines[i]) }
          return rows if header_indices.empty?

          header_indices.each do |header_idx|
            id_start, version_start = column_offsets(lines[header_idx])
            next unless id_start && version_start

            available_start = available_offset(lines[header_idx], version_start)
            data_lines = lines[(header_idx + 2)..] || []
            data_lines.each do |line|
              break if table_header?(line)
              next if line.match?(%r{^[-=]+\s*$})
              next if line.length < version_start

              id = line[id_start...version_start]&.strip
              next if id.nil? || id.empty?
              next if id.match?(%r{\s})
              next if seen.include?(id)

              seen << id
              current = nil
              available = nil
              if available_start
                current = line[version_start...available_start]&.strip
                current = nil if current.nil? || current.empty?
                rest = line[available_start..]&.strip
                available = (rest.nil? || rest.empty?) ? nil : rest.split(%r{\s+}).first
              end
              rows << { 'id' => id, 'current_version' => current, 'available_version' => available }
            end
          end

          rows
        end

        # Raw `winget pin list` output, memoized per process (nil path only;
        # explicit path overrides always run fresh). Never raises.
        # @param path [String, nil] Optional override for the winget path (testing)
        # @return [String, nil] Raw command output, or nil when absent/failed
        def pins_output(path = nil)
          return run_pins(path) unless path.nil?

          @pins_output = run_pins(nil) if @pins_output.nil?
          @pins_output
        end

        # Single uncached `winget pin list` run. A non-zero exit (old winget
        # without `pin`, or any failure) is treated as "no pins". Never raises.
        # @param path [String, nil] Optional override for the winget path (testing)
        # @return [String, nil] Raw command output, or nil when absent/failed
        def run_pins(path)
          winget = path || winget_path
          return nil unless winget && File.exist?(winget)

          require 'puppet/util/execution'
          output = Puppet::Util::Execution.execute(
            [winget, 'pin', 'list', '--accept-source-agreements', '--disable-interactivity'],
            failonfail: false, combine: true,
          )
          return nil unless output.exitstatus.zero?

          output.to_s
        rescue StandardError
          nil
        end

        # @param path [String, nil] Optional override for the winget path (testing)
        # @return [Array<String>] Pinned package IDs ([] when absent/unsupported/error)
        def pinned_ids(path = nil)
          parse_pin_list(pins_output(path))
        rescue StandardError
          []
        end

        # Parse `winget pin list` table output into pinned package IDs. Same
        # fixed-width header-offset technique as the upgrade parser: the pin
        # table carries extra trailing columns (pin type), but the Id cell is
        # sliced between the Id and Version header offsets. Output without a
        # recognizable table (e.g. "No pins exist") yields [].
        # @param output [String, nil] Raw output from `winget pin list`
        # @return [Array<String>] Deduplicated pinned package IDs
        def parse_pin_list(output)
          ids = []
          return ids if output.nil? || output.empty?

          lines = output_lines(output)

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

        # Split raw winget output into non-blank lines, discarding the
        # progress spinner frames winget redraws with carriage returns
        # (`\r`). Only the text after the last carriage return of a line is
        # what ends up on screen, and it is the only text whose columns line
        # up with the table header offsets.
        # @param output [String, nil] Raw command output
        # @return [Array<String>] Non-blank lines without spinner frames
        def output_lines(output)
          output.to_s.lines.map { |line| strip_progress(line.chomp) }.reject { |line| line.strip.empty? }
        end

        # Keep only the last visible segment of a line redrawn with `\r`.
        # @param line [String] Line without its trailing newline
        # @return [String] The visible text ('' when nothing is visible)
        def strip_progress(line)
          return line unless line.include?("\r")

          line.split("\r").reverse.find { |segment| !segment.strip.empty? } || ''
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

        # Locate the Available column start in a `winget upgrade` table
        # header (English `Available`, French `Disponible`), searched after
        # the Version column.
        # @param header [String] Header line of a `winget upgrade` table
        # @param version_start [Integer] Offset of the Version column
        # @return [Integer, nil] Offset of the Available column, nil when absent
        def available_offset(header, version_start)
          tail = header[version_start + VERSION_HEADER_LENGTH..]
          return nil unless tail

          match = tail.match(%r{\b(Available|Disponible)\b}i)
          return nil unless match

          version_start + VERSION_HEADER_LENGTH + match.begin(0)
        end
      end
    end
  end
end
# rubocop:enable Style/ClassAndModuleChildren
