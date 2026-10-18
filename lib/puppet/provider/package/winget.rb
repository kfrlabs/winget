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

# winget exit codes (verified against
# https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-manager/winget/returnCodes.md
# via `winget error --output`. Hex literals below are the unsigned form of
# the (signed decimal) codes winget reports.)
# rubocop:disable Style/ClassAndModuleChildren
unless defined?(::PuppetX::Winget::Provider::EXIT_SUCCESS)
  module PuppetX
    module Winget
      module Provider
        EXIT_SUCCESS = 0
        EXIT_NO_APPLICABLE_INSTALLER = 0x8A150010  # None of the installers are applicable for the current system
        EXIT_INSTALLER_HASH_MISMATCH = 0x8A150011  # The installer file's hash does not match the manifest
        EXIT_NO_APPLICATIONS_FOUND = 0x8A150014    # No packages found (unknown ID; upgrade of an absent package)
        EXIT_NO_MANIFEST_FOUND = 0x8A150017        # No manifest found matching the criteria (unknown ID in source)
        EXIT_UPDATE_NOT_APPLICABLE = 0x8A15002B      # No applicable update found (nothing newer)
        EXIT_BLOCKED_BY_POLICY = 0x8A15003A          # Operation is blocked by Group Policy
        EXIT_DOWNLOAD_FAILED = 0x8A150008            # Downloading installer failed
        EXIT_PACKAGE_ALREADY_INSTALLED = 0x8A150061  # Found at least one version of the package installed
        EXIT_INSTALL_ALREADY_INSTALLED = 0x8A15010D  # Another version of this application is already installed
        EXIT_INSTALL_REBOOT_REQUIRED_TO_FINISH = 0x8A150109 # Restart your PC to finish installation
        EXIT_INSTALL_REBOOT_REQUIRED_FOR_INSTALL = 0x8A15010A # Installation failed. Restart your PC then try again
        EXIT_INSTALL_REBOOT_INITIATED = 0x8A15010B # Your PC will restart to finish installation
        EXIT_INSTALL_CANCELLED_BY_USER = 0x8A15010C  # You cancelled the installation
        EXIT_INSTALL_BLOCKED_BY_POLICY = 0x8A15010F  # Organization policies are preventing installation
        # Kept for callers referencing the previous name: upgrade of an
        # absent package (`winget upgrade` reports "No packages found").
        EXIT_NO_INSTALLED_PACKAGE_FOUND = 0x8A150014

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
      @list_unavailable = nil
      @pins_list = nil
      @suitability_warned = nil
      PuppetX::Winget::PathResolver.reset!
    end

    # Whether the most recent `winget list` attempt failed (non-zero exit
    # or raised an error) while winget itself was suitable. When true, the
    # installed package state for this run is unknown: `query` refuses to
    # report "absent" so Puppet does not attempt spurious installs on top
    # of packages that are, in fact, already there.
    # @return [Boolean]
    def list_unavailable?
      @list_unavailable == true
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
  # not accept them in front of it. Every call goes through
  # `PuppetX::Winget::Runner` so a hung winget cannot block the agent;
  # mutating subcommands get the longer write timeout.
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
    require 'puppet_x/winget/runner'
    write = ['install', 'upgrade', 'uninstall'].include?(args.first.to_s)
    begin
      PuppetX::Winget::Runner.run(cmd, write: write)
    rescue PuppetX::Winget::Runner::TimeoutError => e
      raise Puppet::Error, _('winget %{action} timed out: %{error}') % { action: args.first, error: e.message }
    end
  end

  # Parse winget list output into a hash of package info
  # winget list output is localized, may have spinners, truncated columns, unicode
  # Tables are discovered structurally and sliced positionally via the shared
  # facts helper, so localized headers parse like the English/French ones.
  # @param output [String] Raw output from `winget list`
  # @return [Hash{String => Hash}] Map of package id (lowercase) -> { name, version, source, id }
  def parse_winget_list(output)
    require 'puppet_x/winget/facts'
    PuppetX::Winget::Facts.parse_winget_list(output)
  end

  # Query the current state of the package.
  # The `mark` property (holdable feature, backed by `winget pin`) is only
  # reported when the resource manages it: plain package resources therefore
  # never pay for an extra `winget pin list` process.
  # Raises when the last `winget list` attempt failed outright (see
  # `self.list_unavailable?`): reporting "absent" in that case would make
  # Puppet attempt a pointless (and potentially disruptive) reinstall of a
  # package that may well already be present.
  # @return [Hash, nil] Current package properties or nil if not installed
  def query
    pkg = installed_entry
    if self.class.list_unavailable?
      raise Puppet::Error, _('Cannot determine whether package %{name} is installed: winget list failed this run') % { name: resource[:name] }
    end

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
  # Timed out calls raise `Puppet::Error` like other provider commands.
  # @param action [String] Pin subcommand ('add' or 'remove')
  # @return [Puppet::Util::Execution::ProcessOutput] Combined command output with exitstatus
  def pin_exec(action)
    args = ['pin', action, '--id', resource[:name], *PuppetX::Winget::Provider::PIN_FLAGS]
    require 'puppet_x/winget/runner'
    begin
      PuppetX::Winget::Runner.run([self.class.winget_path, *args], write: true)
    rescue PuppetX::Winget::Runner::TimeoutError => e
      raise Puppet::Error, _('winget pin %{action} timed out: %{error}') % { action: action, error: e.message }
    end
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
  # `reset!` in tests) to invalidate. A failed `winget list` (non-zero
  # exit, or a raised error) is never cached: `@list_unavailable` is set so
  # `query` can refuse to report "absent" instead of silently treating a
  # transient listing failure as "nothing installed" (which would make
  # Puppet attempt pointless reinstalls of everything).
  # @return [Hash] Map of package id (lowercase) -> package info
  def self.instances_list
    return @instances_list if defined?(@instances_list) && !@instances_list.nil?

    result = fetch_instances_list
    @list_unavailable = result.nil?
    @instances_list = result
    result || {}
  end

  # Single uncached `winget list` run.
  # @return [Hash, nil] Map of package id (lowercase) -> package info when
  #   winget is unsuitable (nothing to list) or the listing succeeded (an
  #   empty Hash is a legitimate "nothing installed" result then); `nil`
  #   when winget is suitable but the listing itself failed or raised, so
  #   the caller can tell a real failure apart from a genuinely empty list.
  def self.fetch_instances_list
    return {} unless suitable?

    require 'puppet_x/winget/runner'
    begin
      output = PuppetX::Winget::Runner.run([winget_path, 'list', *PuppetX::Winget::Provider::LIST_FLAGS])
    rescue PuppetX::Winget::Runner::TimeoutError => e
      Puppet.warning(_('winget list timed out; installed package state is unknown this run, no changes will be attempted: %{error}') % { error: e.message })
      return nil
    end
    unless output.exitstatus == PuppetX::Winget::Provider::EXIT_SUCCESS
      Puppet.warning(_('winget list failed with exit code %{code}; installed package state is unknown this run, no changes will be attempted: %{output}') % { code: output.exitstatus, output: output })
      return nil
    end

    provider = new
    provider.parse_winget_list(output)
  rescue StandardError => e
    Puppet.warning(_('winget list failed: %{error}; installed package state is unknown this run, no changes will be attempted') % { error: e.message })
    nil
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

  # Install a package.
  # With a pinned version (`ensure => '2.40.0'`) and a different version
  # already installed, `winget install --version` would answer "another
  # version is already installed" (0x8A15010D), which is an idempotent
  # success for a plain install: the pin would never converge. The version
  # change is therefore done explicitly (see `change_version`).
  def install
    wanted = pinned_version
    current = wanted && installed_entry && installed_entry[:version]
    return change_version(wanted, current) if current && version_differs?(wanted, current)

    perform_install(wanted)
  end

  # Run `winget install` and refresh the cached state.
  # @param version [String, nil] Pinned version to install, nil for the default
  def perform_install(version)
    args = ['install', '--id', resource[:name]]
    args << '--version' << version if version
    args.concat(install_option_args)

    output = winget_exec(*args)
    handle_exit_code(output, 'install')
    refresh_after_change
  end

  # Move an installed package to another pinned version. A newer version is
  # a regular `winget upgrade --version`; winget cannot downgrade in place,
  # so an older plain-numeric version is installed after removing the
  # current one. Non-plain versions (suffixes like `.windows.1`, `-rc1`,
  # leading `v`) never trigger the destructive uninstall: Gem treats
  # suffixed versions as pre-releases, so a suffix change is not a real
  # downgrade and uninstalling would risk data loss for no benefit. Those
  # fall back to `install --version` (previous behaviour, idempotent when
  # winget reports "another version is installed").
  # @param wanted [String] Pinned version from `ensure`
  # @param current [String] Installed version
  def change_version(wanted, current)
    if version_newer?(wanted, current)
      args = ['upgrade', '--id', resource[:name], '--version', wanted]
      args.concat(install_option_args)
      output = winget_exec(*args)
      handle_exit_code(output, 'upgrade')
      refresh_after_change
    elsif plain_downgrade?(wanted, current)
      Puppet.notice("winget: downgrading #{resource[:name]} from #{current} to #{wanted} (uninstall, then install)")
      uninstall
      perform_install(wanted)
    else
      Puppet.notice("winget: not uninstalling #{resource[:name]} to move from #{current} to #{wanted} (non-plain version, falling back to install --version)")
      perform_install(wanted)
    end
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
  # absent: `winget upgrade` then fails with 0x8A150014 ("No packages
  # found"). Fall back to `install` so `latest` installs a missing package
  # instead of failing.
  def update
    args = ['upgrade', '--id', resource[:name]]
    args.concat(install_option_args)

    output = winget_exec(*args)
    if output.exitstatus == PuppetX::Winget::Provider::EXIT_NO_APPLICATIONS_FOUND
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

    candidate = parse_show_version(output)
    return nil unless candidate

    current = installed_entry && installed_entry[:version]
    return current if current && !version_newer?(candidate, current)

    candidate
  rescue StandardError => e
    Puppet.debug("winget show failed: #{e.message}")
    nil
  end

  private

  # Pinned version requested through `ensure => 'x.y.z'`.
  # @return [String, nil] The version, or nil for installed/present/latest
  def pinned_version
    version = resource[:ensure]
    version.is_a?(String) ? version : nil
  end

  # Source selection followed by the extra `install_options`, shared by
  # install, upgrade and version changes. Hash/`--source` entries are
  # skipped: the source is emitted once, first.
  # @return [Array] Arguments to append after `--id <name>`
  def install_option_args
    args = []
    source = install_options_source
    args << '--source' << source if source

    extra_args = resource[:install_options]
    if extra_args.is_a?(Array)
      extra_args.each_with_index do |opt, i|
        next if opt.is_a?(Hash) && (opt.key?(:source) || opt.key?('source'))
        next if opt.is_a?(String) && opt.match?(%r{^--source([= ].*)?$})
        next if i.positive? && extra_args[i - 1] == '--source'
        args << opt
      end
    end
    args
  end

  # Drop every cached view of the package state after a successful change
  # so the next lookup observes it, then re-apply the hold if requested.
  def refresh_after_change
    self.class.clear_list_cache!
    self.class.clear_pins_cache!
    clear_installed_entry!
    hold if resource[:mark] == :hold
  end

  # Whether two versions differ, with the numeric semantics of
  # `version_newer?` ('26.04' equals '26.04.00.0'); plain string inequality
  # for versions Gem cannot parse.
  # @return [Boolean]
  def version_differs?(wanted, current)
    Gem::Version.new(wanted) != Gem::Version.new(current)
  rescue ArgumentError
    wanted != current
  end

  # Extract the version from `winget show` output. The label is localized
  # (`Version:`, `Version :`, `Versión:`, ...), so match any single word
  # containing "ersi" followed by a colon at the start of a line.
  # @param output [String] Raw `winget show` output
  # @return [String, nil] The advertised version, nil when not found
  def parse_show_version(output)
    require 'puppet_x/winget/facts'
    PuppetX::Winget::Facts.output_lines(output).each do |line|
      match = line.match(%r{\A\s*[[:alpha:]]*ersi[[:alpha:]]*[[:space:]]*:[[:space:]]*(\S+)}i)
      return match[1] if match
    end
    nil
  end

  # Compare winget versions with numeric semantics: trailing zero segments
  # are insignificant, so '26.04' and '26.04.00.0' compare equal. Falls back
  # to plain string inequality for versions Gem cannot parse.
  # @return [Boolean] True when candidate is strictly newer than current
  def version_newer?(candidate, current)
    Gem::Version.new(candidate) > Gem::Version.new(current)
  rescue ArgumentError
    candidate != current
  end

  # Whether a version string is a plain dotted numeric (`1.2.3`), the only
  # shape allowed to trigger the destructive uninstall-then-install
  # downgrade. Anything else (suffixes, leading `v`, ranges) falls back to
  # `install --version`.
  # @return [Boolean]
  def plain_numeric_version?(version)
    version.is_a?(String) && version.match?(%r{\A\d+(\.\d+)*\z})
  end

  # Whether moving from current to wanted is a real downgrade: both plain
  # numeric and wanted strictly lower.
  # @return [Boolean]
  def plain_downgrade?(wanted, current)
    return false unless plain_numeric_version?(wanted) && plain_numeric_version?(current)

    Gem::Version.new(wanted) < Gem::Version.new(current)
  rescue ArgumentError
    false
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
    when PuppetX::Winget::Provider::EXIT_PACKAGE_ALREADY_INSTALLED,
         PuppetX::Winget::Provider::EXIT_INSTALL_ALREADY_INSTALLED
      # Already installed (during install) - idempotent success
      return nil if action == 'install'
      raise Puppet::Error, _('winget %{action} failed: %{output}') % { action: action, output: output }
    when PuppetX::Winget::Provider::EXIT_UPDATE_NOT_APPLICABLE
      # winget listed an upgrade but its own version comparison finds
      # nothing newer (e.g. 7zip '26.04' available vs '26.04.00.0'
      # installed): idempotent success for upgrade
      return nil if action == 'upgrade'
      raise Puppet::Error, _('winget %{action} failed: %{output}') % { action: action, output: output }
    when PuppetX::Winget::Provider::EXIT_INSTALL_REBOOT_REQUIRED_TO_FINISH,
         PuppetX::Winget::Provider::EXIT_INSTALL_REBOOT_REQUIRED_FOR_INSTALL,
         PuppetX::Winget::Provider::EXIT_INSTALL_REBOOT_INITIATED
      # Reboot required - treat as success but warn
      Puppet.warning(_('winget %{action} succeeded but a reboot is required') % { action: action })
      nil
    when PuppetX::Winget::Provider::EXIT_NO_APPLICATIONS_FOUND
      # 0x8A150014 means "No packages found": unknown ID for install
      # (not in any source), or absent package for uninstall/upgrade.
      # (`update` intercepts this code before reaching here and falls back
      # to `install`, so upgrade only lands here in edge cases.)
      raise Puppet::Error, _('Package \'%{name}\' not found in winget source') % { name: resource[:name] } if action == 'install'
      raise Puppet::Error, _('Package \'%{name}\' is not installed') % { name: resource[:name] }
    when PuppetX::Winget::Provider::EXIT_NO_MANIFEST_FOUND
      raise Puppet::Error, _('Package \'%{name}\' not found in winget source') % { name: resource[:name] }
    when PuppetX::Winget::Provider::EXIT_NO_APPLICABLE_INSTALLER
      raise Puppet::Error, _('winget %{action} failed: no applicable installer for the current system: %{output}') % { action: action, output: output }
    when PuppetX::Winget::Provider::EXIT_BLOCKED_BY_POLICY,
         PuppetX::Winget::Provider::EXIT_INSTALL_BLOCKED_BY_POLICY
      raise Puppet::Error, _('winget %{action} blocked by policy: %{output}') % { action: action, output: output }
    when PuppetX::Winget::Provider::EXIT_INSTALLER_HASH_MISMATCH
      raise Puppet::Error, _('winget %{action} failed: installer hash mismatch') % { action: action }
    when PuppetX::Winget::Provider::EXIT_DOWNLOAD_FAILED
      raise Puppet::Error, _('winget %{action} failed: downloading installer failed') % { action: action }
    when PuppetX::Winget::Provider::EXIT_INSTALL_CANCELLED_BY_USER
      raise Puppet::Error, _('winget %{action} cancelled by user') % { action: action }
    else
      raise Puppet::Error, _('winget %{action} failed with exit code %{code}: %{output}') % { action: action, code: output.exitstatus, output: output }
    end
  end
end
