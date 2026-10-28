# frozen_string_literal: true

require 'puppet_x/winget/path_resolver'

# Facts helper for winget facts.
#
# Centralizes the logic behind the `winget_path`, `winget_version`,
# `winget_upgrades` and `winget_pins` facts so it
# can be unit tested without depending on the Facter confine context.
# Helpers never raise: they return nil/[] when winget is absent or when any
# error occurs. Note `winget_upgrades` shells out
# to `winget upgrade` (source round-trips, a few seconds) with memoized
# output per resolution for gated rows and pin list output, and per process
# for forced rows, separated per mode (forced vs. gated, see {.upgrade_output}).
# It runs on demand only: the
# `winget::upgrades` function (called by `Class['winget::upgrade']`) forces
# an uncached on-demand enumeration (no per-process memoization, so one
# server process never reuses node A's rows for node B),
# while the `winget_upgrades` fact itself is opt-in
# inventory (`WINGET_UPGRADES_ENABLED=true`, disabled by default so agent
# runs that do not declare the class never pay the cost). `winget_pins` is
# a fast local `winget pin list` query and stays always enabled.
# rubocop:disable-next Style/ClassAndModuleChildren
module PuppetX
  module Winget
    # Facts resolves winget facts using the shared path resolver.
    class Facts
      # Length of the literal 'Version' table header word.
      # @deprecated No longer used in offset math (offsets are positional
      #   since locale-independent parsing); kept so existing references
      #   keep working.
      VERSION_HEADER_LENGTH = 7
      # A winget table separator row: the dashes/equals line under a
      # header. Three characters minimum so short stray lines are not
      # mistaken for table boundaries (row skipping still tolerates any
      # length, see the parsers below).
      SEPARATOR_RE = %r{\A\s*[-=]{3,}\s*\z}.freeze
      # Header cells are segmented on 2+ spaces or tabs (the first cell
      # is anchored at the line start). Data rows keep being sliced at
      # the resulting offsets: winget may shrink inter-column gaps to a
      # single space for long names, so rows must never be segmented.
      HEADER_CELL_SPLIT_RE = %r{\s{2,}|\t+}.freeze
      class << self
        # Clear memoized command output (primarily for testing).
        def reset!
          @upgrade_output_forced = nil
          @upgrade_output_gated = nil
          @pins_output = nil
        end

        # Clear the per-resolution caches (gated upgrade output and pin
        # list output). Called at the start of each fact resolution so two
        # consecutive resolutions re-run `winget upgrade` / `winget pin
        # list` instead of reusing stale process-global output, while
        # repeated helper calls within one resolution still share a single
        # invocation. The forced (on-demand function) cache is untouched:
        # server-side callers use the uncached {.run_upgrade} per
        # compilation (see the `winget::upgrades` function), never the
        # memoized forced output across nodes.
        def clear_resolution_cache!
          @upgrade_output_gated = nil
          @pins_output = nil
        end

        # Normalize winget command output to UTF-8 so table parsing and
        # message interpolation never raise
        # `Encoding::CompatibilityError` ("incompatible character encodings:
        # IBM437 and UTF-8"). Winget writes in the OEM console codepage
        # (IBM437/850/...) while Puppet strings are UTF-8; package names with
        # accents, truncation ellipsis or box-drawing separators otherwise
        # break parsing and mark every package unknown.
        # @param text [String, nil] Raw command output
        # @return [String] UTF-8 string with undecodable bytes replaced
        def normalize_output(text)
          str = text.to_s
          return str if str.encoding == Encoding::UTF_8 && str.valid_encoding?

          str.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '?')
        rescue StandardError
          str.scrub('?')
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

          require 'puppet_x/winget/runner'
          output = PuppetX::Winget::Runner.run([winget, '--version'])
          return nil unless output.exitstatus.zero?

          version = normalize_output(output).strip.sub(%r{\Av}, '')
          version.empty? ? nil : version
        rescue StandardError
          nil
        end

        # Whether the opt-in `winget_upgrades` inventory fact may run.
        # Disabled by default so agent runs that do not declare
        # `Class['winget::upgrade']` never pay for a `winget upgrade`
        # source round-trip: set `WINGET_UPGRADES_ENABLED` to a true-like
        # value (`true`, `1`, `yes`, `on`) to keep the fact populated for
        # PuppetDB inventory. Anything else (including unset) disables the
        # fact (it returns `[]` without shelling out).
        # `Class['winget::upgrade']` does not need the fact: it enumerates
        # on demand through the `winget::upgrades` function, falling back
        # to the fact rows for server-side compilation.
        # @return [Boolean] True only when the inventory fact may shell out
        def upgrades_enabled?
          value = ENV.fetch('WINGET_UPGRADES_ENABLED', nil)
          return false if value.nil?

          value.to_s.strip.match?(%r{\A(true|1|yes|on)\z}i)
        rescue StandardError
          false
        end

        # Raw `winget upgrade` output, memoized per resolution and per mode so
        # the `winget_upgrades` fact only shells out once per resolution. Forced (on-demand
        # function) and gated (opt-in fact) rows use separate caches: a
        # forced enumeration must never satisfy a later gated fact call when
        # the inventory gate is disabled, and a gated `nil` (disabled/absent)
        # must never satisfy a later forced call. Gated hits re-check
        # {.upgrades_enabled?} so toggling the opt-in off hides stale rows.
        # Only memoized for the default (nil) path: explicit path
        # overrides (used in tests) always run fresh.
        # Per-resolution scoping: each fact resolution calls
        # {.clear_resolution_cache!} first, so consecutive resolutions
        # re-run winget while repeated calls within one resolution share a
        # single invocation.
        # Per-process memoization is safe on agents (one node per process)
        # but not on Puppet Server, where one server process compiles
        # catalogs for many nodes: cached forced output from node A must
        # never satisfy node B. Server-side callers must therefore use the
        # uncached {.run_upgrade} per compilation (as the `winget::upgrades`
        # function does) or call {.reset!} once per catalog, never the
        # memoized forced cache across nodes.
        # Cost note: when the opt-in fact is enabled on an agent that also
        # declares `Class['winget::upgrade']`, the agent pays for two
        # `winget upgrade` runs per agent run (one gated fact, one on-demand
        # function enumeration; separate caches). Cache the fact with a TTL
        # or leave it disabled (the class still enumerates on demand) to
        # avoid the double cost.
        # @param path [String, nil] Optional override for the winget path (testing)
        # @param force [Boolean] Bypass the opt-in inventory gate (function path)
        # @return [String, nil] Raw command output, or nil when disabled/absent/failed
        def upgrade_output(path = nil, force: false)
          return run_upgrade(path, force: force) unless path.nil?

          if force
            @upgrade_output_forced = run_upgrade(nil, force: true) if @upgrade_output_forced.nil?
            @upgrade_output_forced
          else
            return nil unless upgrades_enabled?

            @upgrade_output_gated = run_upgrade(nil, force: false) if @upgrade_output_gated.nil?
            @upgrade_output_gated
          end
        end

        # Single uncached `winget upgrade` run. Never raises (timeout returns
        # nil like any other failure so a hung winget cannot stall the agent).
        # The inventory gate ({.upgrades_enabled?}) is skipped when `force`
        # is true: the `winget::upgrades` function enumerates on demand for
        # `Class['winget::upgrade']`, so the class works without the opt-in
        # fact. `--accept-source-agreements` is kept deliberately: without
        # it winget can prompt (or stall where nothing answers), reintroducing
        # the hang this module guards against with `PuppetX::Winget::Runner`
        # timeouts; the agreements accepted on enumeration match the provider
        # and task behavior for the upgrades the class then applies.
        # @param path [String, nil] Optional override for the winget path (testing)
        # @param force [Boolean] Bypass the opt-in inventory gate (function path)
        # @return [String, nil] Raw command output, or nil when disabled/absent/failed
        def run_upgrade(path, force: false)
          return nil unless force || upgrades_enabled?

          winget = path || winget_path
          return nil unless winget && File.exist?(winget)

          require 'puppet_x/winget/runner'
          output = PuppetX::Winget::Runner.run(
            [winget, 'upgrade', '--accept-source-agreements', '--disable-interactivity'],
          )
          return nil unless output.exitstatus.zero?

          normalize_output(output.to_s)
        rescue StandardError
          nil
        end

        # @param path [String, nil] Optional override for the winget path (testing)
        # @param force [Boolean] Bypass the opt-in inventory gate (function path)
        # @return [Array<Hash>] Upgrade rows with 'id', 'current_version' and
        #   'available_version' keys ([] when absent/error/disabled)
        def winget_upgrades(path = nil, force: false)
          parse_winget_upgrade(upgrade_output(path, force: force))
        rescue StandardError
          []
        end

        # Parse `winget upgrade` table output into structured rows with the
        # installed and available versions. Tables are discovered
        # structurally (the separator row anchors the header above it) and
        # columns are sliced positionally at the header cell offsets
        # (fixed-width table) instead of split on whitespace: winget
        # shrinks the gap between two columns to a single space for long
        # names (truncated with `…`), so a whitespace split shifts every
        # column (the installed version is then read as the ID) or glues ID
        # and version together (package skipped). Header words are never
        # matched to find a table, so localized headers (German `Quelle`,
        # Spanish `Versión`, ...) parse like the English/French ones; the
        # `Id` second cell is only a debug-level sanity check. Rows
        # shorter than the Version column (e.g. the "N upgrades available."
        # footer) are skipped: package IDs never contain spaces.
        # `winget upgrade` may print several tables (upgrades, then packages
        # requiring explicit targeting when some versions are unknown), each
        # with its own header: every table is parsed within its own bounds
        # so a later header's cells are never mistaken for package IDs.
        # The 4th column of a 5+-column upgrade table (English `Available`,
        # French `Disponible`, ...) holds versions as single tokens, so the
        # available cell is read as the first token at its offset (the
        # Source column may follow on the same row). An exactly-4-column
        # table only yields versions when its 4th cell reads as an
        # Available word (see {.available_offset}); other 4-column tables
        # yield rows with nil versions.
        # Short rows are sliced leniently (Ruby slicing never raises): a
        # row that ends inside the Available column still yields its
        # current version with a nil available version. Deduplication is
        # case-insensitive (first-seen casing wins); package IDs never
        # contain spaces.
        # @param output [String, nil] Raw output from `winget upgrade`
        # @return [Array<Hash>] Deduplicated rows ('id', 'current_version', 'available_version')
        def parse_winget_upgrade(output)
          rows = []
          seen = []
          return rows if output.nil? || output.empty?

          lines = output_lines(output)

          headers = header_indices(lines)
          return rows if headers.empty?

          headers.each_with_index do |header_idx, pos|
            table_end = headers[pos + 1] || lines.length
            id_start, version_start = column_offsets(lines[header_idx])
            next unless id_start && version_start

            available_start = available_offset(lines[header_idx], version_start)
            data_lines = lines[(header_idx + 2)...table_end] || []
            data_lines.each do |line|
              next if line.match?(%r{^\s*[-=]+\s*$})
              next if display_width(line) < version_start

              id = display_substring(line, id_start, version_start)&.strip
              next if id.nil? || id.empty?
              next if id.match?(%r{\s})
              next if seen.include?(id.downcase)

              seen << id.downcase
              current = nil
              available = nil
              if available_start
                current = display_substring(line, version_start, available_start)&.strip
                current = nil if current.nil? || current.empty?
                rest = display_substring(line, available_start, nil)&.strip
                available = (rest.nil? || rest.empty?) ? nil : rest.split(%r{\s+}).first
              end
              rows << { 'id' => id, 'current_version' => current, 'available_version' => available }
            end
          end

          rows
        end

        # Raw `winget pin list` output, memoized per resolution (nil path only;
        # explicit path overrides always run fresh). Each fact resolution
        # calls {.clear_resolution_cache!} first, so consecutive resolutions
        # re-run winget while repeated calls within one resolution share a
        # single invocation. Never raises.
        # @param path [String, nil] Optional override for the winget path (testing)
        # @return [String, nil] Raw command output, or nil when absent/failed
        def pins_output(path = nil)
          return run_pins(path) unless path.nil?

          @pins_output = run_pins(nil) if @pins_output.nil?
          @pins_output
        end

        # Single uncached `winget pin list` run. A non-zero exit (old winget
        # without `pin`, or any failure, including timeout) is treated as
        # "no pins". Never raises.
        # @param path [String, nil] Optional override for the winget path (testing)
        # @return [String, nil] Raw command output, or nil when absent/failed
        def run_pins(path)
          winget = path || winget_path
          return nil unless winget && File.exist?(winget)

          require 'puppet_x/winget/runner'
          output = PuppetX::Winget::Runner.run(
            [winget, 'pin', 'list', '--accept-source-agreements', '--disable-interactivity'],
          )
          return nil unless output.exitstatus.zero?

          normalize_output(output.to_s)
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
        # structural, positional technique as the upgrade parser (see
        # {.header_indices}): the pin table carries extra trailing columns
        # (pin type), but the Id cell is sliced between the Id and Version
        # header offsets. Deduplication is case-insensitive (first-seen
        # casing wins). Output without a recognizable table (e.g. "No
        # pins exist") yields [].
        # @param output [String, nil] Raw output from `winget pin list`
        # @return [Array<String>] Deduplicated pinned package IDs
        def parse_pin_list(output)
          ids = []
          seen = []
          return ids if output.nil? || output.empty?

          lines = output_lines(output)

          headers = header_indices(lines)
          return ids if headers.empty?

          headers.each_with_index do |header_idx, pos|
            table_end = headers[pos + 1] || lines.length
            id_start, version_start = column_offsets(lines[header_idx])
            next unless id_start && version_start

            data_lines = lines[(header_idx + 2)...table_end] || []
            data_lines.each do |line|
              next if line.match?(%r{^\s*[-=]+\s*$})
              next if display_width(line) < version_start

              id = display_substring(line, id_start, version_start)&.strip
              next if id.nil? || id.empty?
              next if id.match?(%r{\s})
              next if seen.include?(id.downcase)

              seen << id.downcase
              ids << id
            end
          end

          ids
        end

        # Parse `winget list` table output into a hash of package info.
        # Shared with the provider so both agree on installed state (see
        # `parse_winget_list` in lib/puppet/provider/package/winget.rb).
        # A 5+-column table reads the version between the Version and 4th
        # cell offsets and the source from the 5th cell; a 4-column table
        # reads them from the 3rd/4th cells; fewer columns default the
        # source to 'winget'.
        # @param output [String, nil] Raw output from `winget list`
        # @return [Hash{String => Hash}] Map of package id (lowercase) -> { name, version, source, id }
        def parse_winget_list(output)
          packages = {}
          return packages if output.nil? || output.empty?

          lines = output_lines(output)

          headers = header_indices(lines)
          return packages if headers.empty?

          headers.each_with_index do |header_idx, pos|
            table_end = headers[pos + 1] || lines.length
            offsets = header_cell_offsets(lines[header_idx])
            next if offsets.length < 3

            id_start = offsets[1]
            version_start = offsets[2]
            data_lines = lines[(header_idx + 2)...table_end] || []
            data_lines.each do |line|
              next if line.match?(%r{^\s*[-=]+\s*$})
              next if display_width(line) < version_start

              name = display_substring(line, 0, id_start)&.strip
              id = display_substring(line, id_start, version_start)&.strip
              if offsets.length >= 5
                version = display_substring(line, version_start, offsets[3])&.strip
                source = display_substring(line, offsets[4], nil)&.strip
              elsif offsets.length == 4
                version = display_substring(line, version_start, offsets[3])&.strip
                source = display_substring(line, offsets[3], nil)&.strip
              else
                version = display_substring(line, version_start, nil)&.strip
                source = nil
              end
              source = 'winget' if source.nil? || source.empty?

              next if name.nil? || id.nil? || version.nil?
              next if name.empty? || id.empty? || version.empty?
              next if id.match?(%r{\s})

              packages[id.downcase] = {
                name: name,
                version: version,
                source: source,
                id: id,
              }
            end
          end

          packages
        end

        # Split raw winget output into non-blank lines, discarding the
        # progress spinner frames winget redraws with carriage returns
        # (`\r`). Only the text after the last carriage return of a line is
        # what ends up on screen, and it is the only text whose columns line
        # up with the table header offsets. A leading BOM is stripped so it
        # never shifts the first column. Input is normalized to UTF-8 first
        # (see {.normalize_output}): every parser funnels through here, so
        # OEM-codepage output can never raise an encoding error downstream.
        # @param output [String, nil] Raw command output
        # @return [Array<String>] Non-blank lines without spinner frames
        def output_lines(output)
          normalize_output(output).lines.map { |line| strip_progress(line.chomp).delete_prefix("\uFEFF") }.reject { |line| line.strip.empty? }
        end

        # Keep only the last visible segment of a line redrawn with `\r`.
        # @param line [String] Line without its trailing newline
        # @return [String] The visible text ('' when nothing is visible)
        def strip_progress(line)
          return line unless line.include?("\r")

          line.split("\r").reverse.find { |segment| !segment.strip.empty? } || ''
        end

        # Whether a line is a winget table separator (the dashes/equals
        # row under a header). Kept lenient on `=` (some outputs use it)
        # but strict on length (see {SEPARATOR_RE}).
        # @param line [String] Candidate output line
        # @return [Boolean] True when the line is a table separator row
        def separator?(line)
          line.match?(SEPARATOR_RE)
        end

        # Segment a header line into [text, offset] cells on 2+ spaces or
        # tabs. The first cell is anchored at the line start (leading empty
        # segments are skipped). Offsets are display columns (headers are
        # ASCII in all observed locales, so display equals character and
        # UTF-16 offsets here); data rows are sliced with display_slice /
        # Get-DisplaySubstring so CJK/emoji names align on both sides.
        # @param header [String] Table header line
        # @return [Array<Array(String, Integer)>] Cell text with its start offset
        def header_cells(header)
          cells = []
          pos = 0
          header.split(HEADER_CELL_SPLIT_RE).each do |text|
            next if text.empty?

            idx = header.index(text, pos)
            break if idx.nil?

            cells << [text, idx]
            pos = idx + text.length
          end
          cells
        end

        # Start offsets of the header cells (see {.header_cells}).
        # Display columns equal character offsets here (headers are ASCII
        # in all observed locales), so the same numbers serve both.
        # @param header [String] Table header line
        # @return [Array<Integer>] Cell start offsets in column order
        def header_cell_offsets(header)
          header_cells(header).map { |(_text, idx)| idx }
        end

        # Wide character ranges (East Asian Width W/F): CJK, Hiragana,
        # Katakana, Hangul, fullwidth forms and planes 2-3. Anything else
        # (including accents and the `…` truncation marker) is single width,
        # except astral-plane characters (emoji) which terminals render wide.
        WIDE_RANGES = [
          [0x1100, 0x115F], [0x2329, 0x232A], [0x2E80, 0x303E],
          [0x3041, 0x33FF], [0x3400, 0x4DBF], [0x4E00, 0xA4CF],
          [0xAC00, 0xD7A3], [0xF900, 0xFAFF], [0xFE10, 0xFE19],
          [0xFE30, 0xFE4F], [0xFF00, 0xFF60], [0xFFE0, 0xFFE6],
          [0x20000, 0x2FFFD], [0x30000, 0x3FFFD],
          [0x1F300, 0x1FAFF], [0x2600, 0x27BF], [0x2B00, 0x2BFF]
        ].freeze

        # Whether a codepoint occupies two terminal columns.
        # @param ord [Integer] Unicode codepoint
        # @return [Boolean]
        def wide_char?(ord)
          return true if ord >= 0x10000

          WIDE_RANGES.any? { |first, last| ord.between?(first, last) }
        end

        # Terminal display width of a string (wide chars count 2).
        # @param str [String, nil]
        # @return [Integer]
        def display_width(str)
          width = 0
          str.to_s.each_codepoint do |ord|
            width += wide_char?(ord) ? 2 : 1
          end
          width
        end

        # Slice a line by display columns (winget pads by display width,
        # not by character count, so CJK names shift character offsets).
        # @param line [String] Data row
        # @param start_display [Integer] Display column where the slice starts
        # @param length_display [Integer, nil] Display width (nil restores to end)
        # @return [String] Slice text
        def display_slice(line, start_display, length_display = nil)
          result = +''
          col = 0
          line.to_s.each_char do |ch|
            w = wide_char?(ch.ord) ? 2 : 1
            if length_display.nil?
              result << ch if col >= start_display
            elsif col >= start_display && col < start_display + length_display
              result << ch
            end
            col += w
            break if !length_display.nil? && col >= start_display + length_display
          end
          result
        end

        # Display-width-aware substring from start display column to end
        # display column (exclusive), mirroring `line[start...end]` semantics.
        # @return [String]
        def display_substring(line, start_display, end_display = nil)
          return display_slice(line, start_display, nil) if end_display.nil?

          display_slice(line, start_display, end_display - start_display)
        end

        # Indices of the table header lines: the visible line directly
        # above a separator row with at least three cells
        # ([Name, Id, Version, ...]). Positional and locale-independent:
        # header words are never matched to find a table. A second cell
        # other than `Id` only logs a debug-level sanity note, it never
        # rejects the table. The separator must reach the Version column:
        # a short stray line such as `---` under a data row is a row to
        # skip, not a table boundary (the row above it would otherwise
        # shadow the real table as a false header).
        # @param lines [Array<String>] Visible output lines (see {.output_lines})
        # @return [Array<Integer>] Header line indices in table order
        def header_indices(lines)
          indices = []
          lines.each_index do |i|
            next if i + 1 >= lines.length
            next unless separator?(lines[i + 1])

            cells = header_cells(lines[i])
            next if cells.length < 3
            next if lines[i + 1].strip.length < cells[2][1]

            unless cells[1][0].match?(%r{\AId\z}i)
              Puppet.debug("winget: unexpected second header cell #{cells[1][0].inspect}, parsing table positionally") if defined?(Puppet)
            end
            indices << i
          end
          indices
        end

        # @deprecated Prefer separator-anchored discovery via
        #   {.header_indices}. Kept (structurally, same callers) for
        #   compatibility: true when the line segments into at least three
        #   cells whose second cell reads exactly `Id`.
        # @param line [String] Candidate output line
        # @return [Boolean] True when the line looks like a result table header
        def table_header?(line)
          cells = header_cells(line)
          cells.length >= 3 && cells[1][0].match?(%r{\AId\z}i)
        end

        # Locate the Id and Version column starts positionally: the 2nd
        # and 3rd header cells ([Name, Id, Version, ...]), whatever words
        # the locale uses.
        # @param header [String] Table header line
        # @return [Array<(Integer, nil)>] Id/Version offsets, nils when absent
        def column_offsets(header)
          offsets = header_cell_offsets(header)
          return [nil, nil] if offsets.length < 3

          [offsets[1], offsets[2]]
        end

        # Locate the Available column start positionally: the 4th header
        # cell of a 5+-column table (a column such as Source follows it).
        # An exactly-4-column table ([Name, Id, Version, X]) only carries
        # versions when X reads as an Available word (English `Available`,
        # French `Disponible`); otherwise (e.g. Source) it has no Available
        # column. Other locales' 4-column Available words are not matched:
        # real `winget upgrade` tables always carry Source, so that shape
        # is theoretical and stays positional-only.
        # @param header [String] Header line of a `winget upgrade` table
        # @param _version_start [Integer, nil] Unused; kept so the
        #   two-argument call form keeps working (frozen signature)
        # @return [Integer, nil] Offset of the Available column, nil when absent
        def available_offset(header, _version_start = nil)
          cells = header_cells(header)
          return nil if cells.length < 4
          return cells[3][1] if cells.length >= 5

          cells[3][0].strip.match?(%r{\b(Available|Disponible)\b}i) ? cells[3][1] : nil
        end
      end
    end
  end
end
