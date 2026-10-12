# frozen_string_literal: true

# winget package provider for Puppet.
# Uses the Windows Package Manager (winget) to manage packages on Windows.
#
# This provider:
# - Confines to Windows only
# - Is NOT the default provider (explicit opt-in only)
# - Requires winget to be installed; returns unsuitable with clear message if absent
# - Supports: installable, uninstallable, upgradeable, versionable, install_options, uninstall_options
# - Always passes: --accept-package-agreements, --accept-source-agreements, --disable-interactivity, --exact, --silent
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
      end
    end
  end
end
# rubocop:enable Style/ClassAndModuleChildren

Puppet::Type.type(:package).provide(:winget, parent: Puppet::Provider::Package) do
  desc 'Windows Package Manager (winget) provider for the package type.'

  confine operatingsystem: :windows

  # Not the default provider; explicit opt-in required
  defaultfor []

  has_feature :installable, :uninstallable, :upgradeable, :versionable, :install_options, :uninstall_options

  # Include exit code constants
  include PuppetX::Winget::Provider

  class << self
    # @return [String, nil] Memoized path to winget.exe
    def winget_path
      @winget_path ||= resolve_winget_path
    end

    # Reset memoized path (for testing)
    def reset!
      @winget_path = nil
      PuppetX::Winget::PathResolver.reset!
    end

    private

    def resolve_winget_path
      require 'puppet_x/winget/path_resolver'
      PuppetX::Winget::PathResolver.winget_path
    end
  end

  # Check if winget is available; called during provider suitability check
  def self.suitable?(*)
    path = winget_path
    if path.nil?
      Puppet.warning(_('winget provider is unsuitable: winget.exe not found in WindowsApps. Ensure winget is installed and the SYSTEM account can read %ProgramFiles%\\WindowsApps.'))
      return false
    end
    true
  rescue StandardError => e
    Puppet.warning(_('winget provider suitability check failed: %{error}') % { error: e.message })
    false
  end

  # Execute a winget command with common flags
  # @param args [Array<String>] Command arguments (subcommand and options)
  # @return [Puppet::Util::Execution::ProcessOutput] Output object with stdout, stderr, exitstatus
  def winget_exec(*args)
    cmd = [self.class.winget_path, '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity', '--exact', '--silent', *args]
    Puppet::Util::Execution.execute(cmd, failonfail: false, combine: true)
  end

  # Parse winget list output into a hash of package info
  # winget list output is localized, may have spinners, truncated columns, unicode
  # We parse the table format, skipping header/separator lines
  # @param output [String] Raw output from `winget list`
  # @return [Hash{String => Hash}] Map of package id (lowercase) -> { name, version, source, id }
  def parse_winget_list(output)
    packages = {}
    return packages if output.nil? || output.empty?

    lines = output.lines.map(&:chomp).reject(&:empty?)

    # Find the header line (contains "Id" and "Version" - Name might be localized)
    header_idx = lines.find_index { |line| line.match?(%r{Id.*Version}i) }
    return packages unless header_idx

    # Data starts after header and separator line
    data_lines = lines[(header_idx + 2)..] || []

    data_lines.each do |line|
      # Skip separator lines (--- or ===)
      next if line.match?(%r{^[-=]+\s*$})

      # Parse fixed-width columns: Name | Id | Version | Source
      # winget list uses variable-width columns; split on 2+ spaces
      parts = line.split(%r{\s{2,}})
      next if parts.size < 3

      name = parts[0]&.strip
      id = parts[1]&.strip
      version = parts[2]&.strip
      source = parts[3]&.strip || 'winget'

      next if name.nil? || id.nil? || version.nil?
      next if name.empty? || id.empty? || version.empty?

      packages[id.downcase] = {
        name: name,
        version: version,
        source: source,
        id: id
      }
    end

    packages
  end

  # Query the current state of the package
  # @return [Hash, nil] Current package properties or nil if not installed
  def query
    packages = self.class.instances_list
    pkg = packages[resource[:name].downcase]
    return nil unless pkg

    {
      name: pkg[:id],
      ensure: pkg[:version],
      provider: :winget
    }
  end

  # Get list of all installed packages via winget list
  # @return [Hash] Map of package id (lowercase) -> package info
  def self.instances_list
    return {} unless suitable?

    output = Puppet::Util::Execution.execute([winget_path, 'list', '--silent'], failonfail: false, combine: true)
    return {} unless output.exitstatus == PuppetX::Winget::Provider::EXIT_SUCCESS

    provider = new
    provider.parse_winget_list(output.stdout)
  rescue StandardError => e
    Puppet.debug("winget list failed: #{e.message}")
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
      extra_args.each do |opt|
        next if opt.is_a?(Hash) && (opt.key?(:source) || opt.key?('source'))
        next if opt.is_a?(String) && opt.match?(%r{^--source[= ]})
        args << opt
      end
    end

    output = winget_exec(*args)
    handle_exit_code(output, 'install')
  end

  # Uninstall a package
  def uninstall
    args = ['uninstall', '--id', resource[:name]]

    # Additional uninstall_options
    extra_args = resource[:uninstall_options]
    args.concat(extra_args) if extra_args.is_a?(Array)

    output = winget_exec(*args)
    handle_exit_code(output, 'uninstall')
  end

  # Upgrade a package to latest version
  def update
    args = ['upgrade', '--id', resource[:name]]

    # Source selection via install_options
    source = install_options_source
    args << '--source' << source if source

    # Additional install_options (filter out hash options we already handled)
    extra_args = resource[:install_options]
    if extra_args.is_a?(Array)
      extra_args.each do |opt|
        next if opt.is_a?(Hash) && (opt.key?(:source) || opt.key?('source'))
        next if opt.is_a?(String) && opt.match?(%r{^--source[= ]})
        args << opt
      end
    end

    output = winget_exec(*args)
    handle_exit_code(output, 'upgrade')
  end

  # Get the latest available version of a package
  # @return [String, nil] Latest version or nil if not found/error
  def latest
    return nil unless self.class.suitable?

    args = ['show', '--id', resource[:name]]
    source = install_options_source
    args << '--source' << source if source

    output = winget_exec(*args)
    return nil unless output.exitstatus == PuppetX::Winget::Provider::EXIT_SUCCESS

    # Parse version from winget show output
    match = output.stdout.match(%r{Version:\s+([\d.]+)}i)
    match ? match[1] : nil
  rescue StandardError => e
    Puppet.debug("winget show failed: #{e.message}")
    nil
  end

  private

  # Extract source from install_options hash/array
  # install_options can be: ['--source=winget'] or [{ source: 'winget' }] or ['--source', 'winget']
  # @return [String, nil] Source name or nil for default
  def install_options_source
    opts = resource[:install_options]
    return nil unless opts.is_a?(Array)

    opts.each do |opt|
      case opt
      when String
        if opt.match?(%r{^--source[= ](.+)$})
          return Regexp.last_match(1)
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
      raise Puppet::Error, _('winget %{action} failed: %{output}') % { action: action, output: output.stdout }
    when PuppetX::Winget::Provider::EXIT_NO_UPGRADE_AVAILABLE
      # No upgrade available - idempotent success for upgrade
      return nil if action == 'upgrade'
      raise Puppet::Error, _('winget %{action} failed: %{output}') % { action: action, output: output.stdout }
    when PuppetX::Winget::Provider::EXIT_REBOOT_REQUIRED
      # Reboot required - treat as success but warn
      Puppet.warning(_('winget %{action} succeeded but a reboot is required') % { action: action })
      nil
    when PuppetX::Winget::Provider::EXIT_NOT_FOUND
      raise Puppet::Error, _('Package \'%{name}\' not found in winget source') % { name: resource[:name] }
    when PuppetX::Winget::Provider::EXIT_BLOCKED_BY_POLICY
      raise Puppet::Error, _('winget %{action} blocked by policy: %{output}') % { action: action, output: output.stdout }
    when PuppetX::Winget::Provider::EXIT_HASH_MISMATCH
      raise Puppet::Error, _('winget %{action} failed: installer hash mismatch') % { action: action }
    when PuppetX::Winget::Provider::EXIT_NETWORK_ERROR
      raise Puppet::Error, _('winget %{action} failed: network error') % { action: action }
    when PuppetX::Winget::Provider::EXIT_SOURCE_ERROR
      raise Puppet::Error, _('winget %{action} failed: source error') % { action: action }
    when PuppetX::Winget::Provider::EXIT_INSTALLER_FAILED
      raise Puppet::Error, _('winget %{action} failed: installer error: %{output}') % { action: action, output: output.stdout }
    when PuppetX::Winget::Provider::EXIT_USER_CANCELLED
      raise Puppet::Error, _('winget %{action} cancelled by user') % { action: action }
    when PuppetX::Winget::Provider::EXIT_INVALID_ARGUMENT
      raise Puppet::Error, _('winget %{action} failed: invalid argument: %{output}') % { action: action, output: output.stdout }
    else
      raise Puppet::Error, _('winget %{action} failed with exit code %{code}: %{output}') % { action: action, code: output.exitstatus, output: output.stdout }
    end
  end
end
