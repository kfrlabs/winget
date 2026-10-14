# frozen_string_literal: true

# winget package provider for Puppet.
# Uses the Windows Package Manager (winget) to manage packages on Windows.
#
# This provider:
# - Confines to Windows only
# - Is NOT the default provider (explicit opt-in only)
# - Requires winget to be installed; returns unsuitable with clear message if absent
# - Supports: installable, uninstallable, upgradeable, versionable, install_options, uninstall_options, holdable
#   (hold/unhold map to `winget pin add/remove`; `mark => hold` excludes the
#   package from `winget upgrade --all` while explicit upgrades still work)
# - Appends non-interactive flags AFTER the subcommand, using only flags
#   documented for that subcommand (install/upgrade: package+source
#   agreements, no-interactivity, exact, silent; uninstall: minus package
#   agreements; show/list: source agreements, no-interactivity, exact)
# - Source selectable (winget vs msstore) via install_options
#
# @api private

require 'puppet/provider/package'

# winget exit codes (defined once, guarded to avoid redefinition warnings)
# https://learn.microsoft.com/en-us/windows/package-manager/winget/exit-codes
# rubocop:disable Style/ClassAndModuleChildren
unless defined?(::PuppetX::Winget::Provider::EXIT_SUCCESS)
  module PuppetX
    module Winget
      module Provider
        EXIT_SUCCESS = 0
        EXIT_NO_APPLICABLE_INSTALLER = 0x8A150001  # Already installed (for install)
        EXIT_NO_UPGRADE_AVAILABLE = 0x8A150002     # No upgrade available
        EXIT_REBOOT_REQUIRED = 0x8A150003          # Reboot required
        EXIT_USER_CANCELLED = 0x8A150004           # User cancelled
        EXIT_INVALID_ARGUMENT = 0x8A150005         # Invalid argument
        EXIT_NOT_FOUND = 0x8A150006                # Package not found
        EXIT_HASH_MISMATCH = 0x8A150007            # Hash mismatch
        EXIT_NETWORK_ERROR = 0x8A150008            # Network error
        EXIT_SOURCE_ERROR = 0x8A150009             # Source error
        EXIT_BLOCKED_BY_POLICY = 0x8A15000A        # Blocked by policy
        EXIT_INSTALLER_FAILED = 0x8A15000B         # Installer failed
        EXIT_NO_INSTALLED_PACKAGE_FOUND = 0x8A150014 # No installed package found matching input criteria (upgrade of absent package)
        EXIT_UPDATE_NOT_APPLICABLE = 0x8A15002B      # No applicable upgrade (upgrade lists a version winget deems not newer)

        # Non-interactive flags per subcommand, verified against
        # https://learn.microsoft.com/en-us/windows/package-manager/winget/.
        # These are subcommand options: they must follow the subcommand and
        # only flags documented for that subcommand may be used, otherwise
        # winget fails with "Argument name was not recognized".
        INSTALL_FLAGS = ['--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity', '--exact', '--silent'].freeze
        UPGRADE_FLAGS = INSTALL_FLAGS
        UNINSTALL_FLAGS = ['--accept-source-agreements', '--disable-interactivity', '--exact', '--silent'].freeze
        SHOW_FLAGS = ['--accept-source-agreements', '--disable-interactivity', '--exact'].freeze
        LIST_FLAGS = ['--accept-source-agreements', '--disable-interactivity'].freeze
        PIN_FLAGS = ['--accept-source-agreements', '--disable-interactivity', '--exact'].freeze
        PIN_LIST_FLAGS = ['--accept-source-agreements', '--disable-interactivity'].freeze
      end
    end
  end
end
# rubocop:enable Style/ClassAndModuleChildren

Puppet::Type.type(:package).provide(:winget, parent: Puppet::Provider::Package) do
  # @api private
  desc 'Windows Package Manager (winget) provider for the package type.'

  confine operatingsystem: :windows

  # Not the default provider; explicit opt-in required.
  # NOTE: do NOT call `defaultfor []` here. An empty-array argument to
  # `defaultfor` crashes puppet-strings' YARD provider handler
  # (NoMethodError: undefined method `[]' for nil:NilClass in
  # provider_handler.rb#populate_provider_data), because the empty
  # array literal is parsed with a single nil child, which bypasses
  # the handler's `kvps.count >= 1` guard. Simply omitting `defaultfor`
  # already means this provider is never selected by default, so no
  # call is needed to achieve that behavior.

  has_feature :installable, :uninstallable, :upgradeable, :versionable, :install_options, :uninstall_options, :holdable

  # Include exit code constants
  include PuppetX::Winget::Provider

  # @!scope self
  class << self
    # @return [String, nil] Memoized path to winget.exe
    def winget_path
      @winget_path ||= resolve_winget_path
    end

    # Reset memoized state (for testing)
    def reset!
      @winget_path = nil
      @instances_list = nil
      @pins_list = nil
      @suitability_warned = nil
      PuppetX::Winget::PathResolver.reset!
    end

    # Clear the class-level `winget list` cache without touching the
    # memoized path. Called after a successful install/uninstall/upgrade
    # so the next lookup observes the new state.
    def clear_list_cache!
      @instances_list = nil
    end

    # Clear the class-level `winget pin list` cache without touching the
    # memoized path. Called after a successful hold/unhold, and alongside
    # the list cache after install/uninstall/upgrade (pins follow the
    # package lifecycle) so the next lookup observes the new state.
    def clear_pins_cache!
      @pins_list = nil
    end

    # Prefetch installed packages once for all resources in the catalog.
    # Puppet calls this hook (when present) with every `package` resource
    # using this provider before evaluating them individually, so 50
    # `package` resources share a single `winget list` instead of 50.
    # Resources keep working without prefetch too: `installed_entry`
    # falls back to the class-level cache below.
    # @param resources [Hash] Map of resource name -> resource
    def prefetch(resources)
      list = instances_list
      resources.each do |name, resource|
        provider = resource.provider
        next unless provider.is_a?(self)

        key = (name || resource[:name]).to_s.downcase
        provider.installed_entry = list[key]
      end
    rescue StandardError => e
      Puppet.debug("winget prefetch failed: #{e.message}")
    end

    private

    def resolve_winget_path
      require 'puppet_x/winget/path_resolver'
      PuppetX::Winget::PathResolver.winget_path
    end
  end

  # Check if winget is available; called during provider suitability check.
  # The warning is emitted only once per process: Puppet calls this hook
  # for every resource, which would otherwise flood the log.
  def self.suitable?(*)
    path = winget_path
    if path.nil?
      unless @suitability_warned
        Puppet.warning(_('winget provider is unsuitable: winget.exe not found in WindowsApps. Ensure winget is installed and the SYSTEM account can read %ProgramFiles%\\WindowsApps.'))
        @suitability_warned = true
      end
      Puppet.debug('winget provider is unsuitable: winget.exe not found')
      return false
    end
    true
  rescue StandardError => e
    unless @suitability_warned
      Puppet.warning(_('winget provider suitability check failed: %{error}') % { error: e.message })
      @suitability_warned = true
    end
    Puppet.debug("winget provider suitability check failed: #{e.message}")
    false
  end

  # Execute a winget command with the non-interactive flags supported by
  # the given subcommand. Flags always follow the subcommand: winget does
  # not accept them in front of it.
  # @param args [Array<String>] Command arguments (subcommand first, then options)
  # @return [Puppet::Util::Execution::ProcessOutput] Combined command output (a String) with exitstatus
  def winget_exec(*args)
    flags = case args.first
            when 'install', 'upgrade'
              PuppetX::Winget::Provider::INSTALL_FLAGS
            when 'uninstall'
              PuppetX::Winget::Provider::UNINSTALL_FLAGS
            when 'show'
              PuppetX::Winget::Provider::SHOW_FLAGS
            when 'list'
              PuppetX::Winget::Provider::LIST_FLAGS
            else
              []
            end
    cmd = [self.class.winget_path, *args, *flags]
    Puppet::Util::Execution.execute(cmd, failonfail: false, combine: true)
  end

  # Parse winget list output into a hash of package info
  # winget list output is localized, may have spinners, truncated columns, unicode
  # We parse the table format, skipping header/separator lines.
  # Columns are sliced at the header offsets (fixed-width table) instead of
  # split on whitespace: winget shrinks the gap between two columns to a
  # single space for long names (truncated with `…`), which shifts a
  # whitespace split and corrupts every field after the name.
  # @param output [String] Raw output from `winget list`
  # @return [Hash{String => Hash}] Map of package id (lowercase) -> { name, version, source, id }
  def parse_winget_list(output)
    packages = {}
    return packages if output.nil? || output.empty?

    lines = output.lines.map(&:chomp).reject(&:empty?)

    # Find the header line (contains "Id" and "Version" - Name might be localized)
    header_idx = lines.find_index { |line| line.match?(%r{Id.*Version}i) }
    return packages unless header_idx

    header = lines[header_idx]
    id_start = header.index(%r{\bId\b}i)
    version_start = header.index(%r{\bVersion\b}i)
    return packages unless id_start && version_start && version_start > id_start

    source_match = header.match(%r{\S+}, version_start + 'Version'.length)
    source_start = source_match&.begin(0)

    # Data starts after header and separator line
    data_lines = lines[(header_idx + 2)..] || []

    data_lines.each do |line|
      # Skip separator lines (--- or ===)
      next if line.match?(%r{^[-=]+\s*$})
      next if line.length < version_start

      name = line[0...id_start]&.strip
      id = line[id_start...version_start]&.strip
      version = source_start ? line[version_start...source_start]&.strip : line[version_start..]&.strip
      source = source_start ? line[source_start..]&.strip : nil
      source = 'winget' if source.nil? || source.empty?

      next if name.nil? || id.nil? || version.nil?
      next if name.empty? || id.empty? || version.empty?
      next if id.match?(%r{\s})

      packages[id.downcase] = {
        name: name,
        version: version,
        source: source,
        id: id
      }
    end

    packages
  end

  # Query the current state of the package.
  # The `mark` property (holdable feature, backed by `winget pin`) is only
  # reported when the resource manages it: plain package resources therefore
  # never pay for an extra `winget pin list` process.
  # @return [Hash, nil] Current package properties or nil if not installed
  def query
    pkg = installed_entry
    return nil unless pkg

    result = {
      name: pkg[:id],
      ensure: pkg[:version],
      provider: :winget
    }
    result[:mark] = pinned? ? :hold : :none if mark_managed?
    result
  end

  # Whether the resource manages the `mark` property (holdable feature).
  # @return [Boolean] True when `mark` is set on the resource
  def mark_managed?
    !resource[:mark].nil?
  end

  # Whether the package is currently pinned (`winget pin list`).
  # @return [Boolean] True when a pin exists for the package
  def pinned?
    self.class.pins_list.key?(resource[:name].downcase)
  end

  # Place a hold on the package (`winget pin add`). A pinned package is
  # excluded from `winget upgrade --all` but still allows an explicit
  # `winget upgrade --id` (i.e. `ensure => latest` on this resource keeps
  # working: the hold only blocks unattended bulk upgrades).
  def hold
    return nil if pinned?

    output = pin_exec('add')
    unless output.exitstatus == PuppetX::Winget::Provider::EXIT_SUCCESS
      raise Puppet::Error, _('Failed to pin package \'%{name}\': %{output}') % { name: resource[:name], output: output }
    end
    self.class.clear_pins_cache!
    clear_installed_entry!
    nil
  end

  # Release the hold on the package (`winget pin remove`).
  def unhold
    return nil unless pinned?

    output = pin_exec('remove')
    unless output.exitstatus == PuppetX::Winget::Provider::EXIT_SUCCESS
      raise Puppet::Error, _('Failed to unpin package \'%{name}\': %{output}') % { name: resource[:name], output: output }
    end
    self.class.clear_pins_cache!
    clear_installed_entry!
    nil
  end

  # Execute a `winget pin` subcommand non-interactively for this resource.
  # @param action [String] Pin subcommand ('add' or 'remove')
  # @return [Puppet::Util::Execution::ProcessOutput] Combined command output with exitstatus
  def pin_exec(action)
    args = ['pin', action, '--id', resource[:name], *PuppetX::Winget::Provider::PIN_FLAGS]
    Puppet::Util::Execution.execute([self.class.winget_path, *args], failonfail: false, combine: true)
  end

  # Installed package entry from `winget list`. Prefetched once per run
  # via `self.prefetch` (single `winget list` for the whole catalog) and
  # otherwise served from the class-level `instances_list` cache, so N
  # `package` resources share one listing instead of running N listings.
  # A prefetched absent package (nil) is kept as-is and does not re-list.
  # @return [Hash, nil] Package info or nil if not installed
  attr_writer :installed_entry

  def installed_entry
    return @installed_entry if defined?(@installed_entry)

    @installed_entry = self.class.instances_list[resource[:name].downcase]
  end

  # Drop the per-instance entry so the next lookup re-reads the (cleared)
  # class-level cache and observes the new state.
  def clear_installed_entry!
    remove_instance_variable(:@installed_entry) if defined?(@installed_entry)
  end

  # Get list of all installed packages via winget list, cached at class
  # level for the duration of the run. Use `clear_list_cache!` (or
  # `reset!` in tests) to invalidate.
  # @return [Hash] Map of package id (lowercase) -> package info
  def self.instances_list
    return @instances_list if defined?(@instances_list) && !@instances_list.nil?

    @instances_list = fetch_instances_list
  end

  # Single uncached `winget list` run. Never raises: returns {} when
  # winget is unsuitable or the listing fails.
  # @return [Hash] Map of package id (lowercase) -> package info
  def self.fetch_instances_list
    return {} unless suitable?

    output = Puppet::Util::Execution.execute([winget_path, 'list', *PuppetX::Winget::Provider::LIST_FLAGS], failonfail: false, combine: true)
    return {} unless output.exitstatus == PuppetX::Winget::Provider::EXIT_SUCCESS

    provider = new
    provider.parse_winget_list(output)
  rescue StandardError => e
    Puppet.debug("winget list failed: #{e.message}")
    {}
  end

  # Get the set of pinned package IDs, cached at class level for the
  # duration of the run. Keys are lowercase IDs. Use `clear_pins_cache!`
  # (or `reset!` in tests) to invalidate. Never raises: returns {} when
  # winget is unsuitable or the listing fails.
  # @return [Hash{String => true}] Pinned package IDs (lowercase)
  def self.pins_list
    return @pins_list if defined?(@pins_list) && !@pins_list.nil?

    @pins_list = fetch_pins_list
  end

  # Single uncached `winget pin list` run. Pin table parsing is shared with
  # the `winget_pins` fact helper so the provider and the facts agree on
  # pin state.
  # @return [Hash{String => true}] Pinned package IDs (lowercase)
  def self.fetch_pins_list
    return {} unless suitable?

    require 'puppet_x/winget/facts'
    ids = PuppetX::Winget::Facts.pinned_ids(winget_path)
    ids.each_with_object({}) { |id, memo| memo[id.downcase] = true }
  rescue StandardError => e
    Puppet.debug("winget pin list failed: #{e.message}")
    {}
  end

  # Return all installed packages as provider instances
  def self.instances
    instances_list.map do |_id, pkg|
      new(name: pkg[:id], ensure: pkg[:version], provider: :winget)
    end
  end

  # Install a package
  # @param version [String] Version to install, or :latest
  def install
    version = resource[:ensure]
    args = ['install', '--id', resource[:name]]

    # Handle version pinning
    if version.is_a?(String) && version != 'latest' && version != 'present' && version != 'installed'
      args << '--version' << version
    end

    # Source selection via install_options
    source = install_options_source
    args << '--source' << source if source

    # Additional install_options (filter out hash options we already handled)
    extra_args = resource[:install_options]
    if extra_args.is_a?(Array)
      extra_args.each_with_index do |opt, i|
        next if opt.is_a?(Hash) && (opt.key?(:source) || opt.key?('source'))
        next if opt.is_a?(String) && opt.match?(%r{^--source([= ].*)?$})
        next if i.positive? && extra_args[i - 1] == '--source'
        args << opt
      end
    end

    output = winget_exec(*args)
    handle_exit_code(output, 'install')
    self.class.clear_list_cache!
    self.class.clear_pins_cache!
    clear_installed_entry!
    hold if resource[:mark] == :hold
  end

  # Uninstall a package
  def uninstall
    args = ['uninstall', '--id', resource[:name]]

    # Additional uninstall_options
    extra_args = resource[:uninstall_options]
    args.concat(extra_args) if extra_args.is_a?(Array)

    output = winget_exec(*args)
    handle_exit_code(output, 'uninstall')
    self.class.clear_list_cache!
    self.class.clear_pins_cache!
    clear_installed_entry!
  end

  # Upgrade a package to latest version.
  # Puppet calls `update` for `ensure => latest` even when the package is
  # absent: `winget upgrade` then fails with 0x8A150014 ("No installed
  # package found matching input criteria"). Fall back to `install` so
  # `latest` installs a missing package instead of failing.
  def update
    args = ['upgrade', '--id', resource[:name]]

    # Source selection via install_options
    source = install_options_source
    args << '--source' << source if source

    # Additional install_options (filter out hash options we already handled)
    extra_args = resource[:install_options]
    if extra_args.is_a?(Array)
      extra_args.each_with_index do |opt, i|
        next if opt.is_a?(Hash) && (opt.key?(:source) || opt.key?('source'))
        next if opt.is_a?(String) && opt.match?(%r{^--source([= ].*)?$})
        next if i.positive? && extra_args[i - 1] == '--source'
        args << opt
      end
    end

    output = winget_exec(*args)
    if output.exitstatus == PuppetX::Winget::Provider::EXIT_NO_INSTALLED_PACKAGE_FOUND
      Puppet.debug("winget upgrade found no installed package #{resource[:name]}, falling back to install")
      install
    else
      handle_exit_code(output, 'upgrade')
      hold if resource[:mark] == :hold
    end
    self.class.clear_list_cache!
    self.class.clear_pins_cache!
    clear_installed_entry!
  end

  # Get the latest available version of a package.
  # When winget advertises a version its own upgrade deems not newer than
  # the installed one (e.g. 7zip '26.04' available vs '26.04.00.0'
  # installed), report the installed version so `ensure => latest` stays in
  # sync instead of attempting (and logging) an upgrade on every run.
  # @return [String, nil] Latest version or nil if not found/error
  def latest
    return nil unless self.class.suitable?

    args = ['show', '--id', resource[:name]]
    source = install_options_source
    args << '--source' << source if source

    output = winget_exec(*args)
    return nil unless output.exitstatus == PuppetX::Winget::Provider::EXIT_SUCCESS

    # Parse version from winget show output
    match = output.match(%r{Version:\s+([\d.]+)}i)
    return nil unless match

    candidate = match[1]
    current = installed_entry && installed_entry[:version]
    return current if current && !version_newer?(candidate, current)

    candidate
  rescue StandardError => e
    Puppet.debug("winget show failed: #{e.message}")
    nil
  end

  private

  # Compare winget versions with numeric semantics: trailing zero segments
  # are insignificant, so '26.04' and '26.04.00.0' compare equal. Falls back
  # to plain string inequality for versions Gem cannot parse.
  # @return [Boolean] True when candidate is strictly newer than current
  def version_newer?(candidate, current)
    Gem::Version.new(candidate) > Gem::Version.new(current)
  rescue ArgumentError
    candidate != current
  end

  # Extract source from install_options hash/array
  # install_options can be: ['--source=winget'] or [{ source: 'winget' }] or ['--source', 'winget']
  # @return [String, nil] Source name or nil for default
  def install_options_source
    opts = resource[:install_options]
    return nil unless opts.is_a?(Array)

    opts.each_with_index do |opt, i|
      case opt
      when String
        if opt.match?(%r{^--source[= ](.+)$})
          return Regexp.last_match(1)
        elsif opt == '--source' && opts[i + 1].is_a?(String)
          return opts[i + 1]
        end
      when Hash
        return opt[:source] if opt.key?(:source)
        return opt['source'] if opt.key?('source')
      end
    end
    nil
  end

  # Map winget exit codes to idempotent behavior with meaningful errors
  # @param output [Puppet::Util::Execution::ProcessOutput]
  # @param action [String] Action name for error messages
  def handle_exit_code(output, action)
    case output.exitstatus
    when PuppetX::Winget::Provider::EXIT_SUCCESS
      # Success
      nil
    when PuppetX::Winget::Provider::EXIT_NO_APPLICABLE_INSTALLER
      # Already installed (during install) - idempotent success
      return nil if action == 'install'
      raise Puppet::Error, _('winget %{action} failed: %{output}') % { action: action, output: output }
    when PuppetX::Winget::Provider::EXIT_NO_UPGRADE_AVAILABLE
      # No upgrade available - idempotent success for upgrade
      return nil if action == 'upgrade'
      raise Puppet::Error, _('winget %{action} failed: %{output}') % { action: action, output: output }
    when PuppetX::Winget::Provider::EXIT_UPDATE_NOT_APPLICABLE
      # winget listed an upgrade but its own version comparison finds
      # nothing newer (e.g. 7zip '26.04' available vs '26.04.00.0'
      # installed): idempotent success for upgrade
      return nil if action == 'upgrade'
      raise Puppet::Error, _('winget %{action} failed: %{output}') % { action: action, output: output }
    when PuppetX::Winget::Provider::EXIT_REBOOT_REQUIRED
      # Reboot required - treat as success but warn
      Puppet.warning(_('winget %{action} succeeded but a reboot is required') % { action: action })
      nil
    when PuppetX::Winget::Provider::EXIT_NOT_FOUND
      raise Puppet::Error, _('Package \'%{name}\' not found in winget source') % { name: resource[:name] }
    when PuppetX::Winget::Provider::EXIT_NO_INSTALLED_PACKAGE_FOUND
      raise Puppet::Error, _('Package \'%{name}\' is not installed') % { name: resource[:name] }
    when PuppetX::Winget::Provider::EXIT_BLOCKED_BY_POLICY
      raise Puppet::Error, _('winget %{action} blocked by policy: %{output}') % { action: action, output: output }
    when PuppetX::Winget::Provider::EXIT_HASH_MISMATCH
      raise Puppet::Error, _('winget %{action} failed: installer hash mismatch') % { action: action }
    when PuppetX::Winget::Provider::EXIT_NETWORK_ERROR
      raise Puppet::Error, _('winget %{action} failed: network error') % { action: action }
    when PuppetX::Winget::Provider::EXIT_SOURCE_ERROR
      raise Puppet::Error, _('winget %{action} failed: source error') % { action: action }
    when PuppetX::Winget::Provider::EXIT_INSTALLER_FAILED
      raise Puppet::Error, _('winget %{action} failed: installer error: %{output}') % { action: action, output: output }
    when PuppetX::Winget::Provider::EXIT_USER_CANCELLED
      raise Puppet::Error, _('winget %{action} cancelled by user') % { action: action }
    when PuppetX::Winget::Provider::EXIT_INVALID_ARGUMENT
      raise Puppet::Error, _('winget %{action} failed: invalid argument: %{output}') % { action: action, output: output }
    else
      raise Puppet::Error, _('winget %{action} failed with exit code %{code}: %{output}') % { action: action, code: output.exitstatus, output: output }
    end
  end
end
