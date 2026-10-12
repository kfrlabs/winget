# frozen_string_literal: true

# PathResolver locates the winget executable in the WindowsApps folder.
# It handles:
# - Expanding ProgramFiles from the environment (no hardcoded paths)
# - Both x64 and arm64 variants
# - Selecting the highest version using Gem::Version comparison
# - Memoization to avoid repeated filesystem scans
# - Never raises at catalog load time; returns nil when winget is absent
#
# WindowsApps ACL caveat: The SYSTEM account (under which the Puppet agent runs)
# may not have read access to the WindowsApps directory by default. This module
# does not modify ACLs; the caller must ensure the agent can read the folder.
# rubocop:disable Style/ClassAndModuleChildren
module PuppetX
  module Winget
    # PathResolver locates the winget executable in the WindowsApps folder.
    class PathResolver
      class << self
        # @return [String, nil] Absolute path to winget.exe, or nil if not found
        def winget_path
          @winget_path ||= resolve_winget_path
        end

        # Clear memoized value (primarily for testing)
        def reset!
          @winget_path = nil
        end

        private

        def resolve_winget_path
          program_files = ENV['ProgramFiles']
          return nil unless program_files

          base_dir = File.join(program_files, 'WindowsApps')
          return nil unless Dir.exist?(base_dir)

          # Pattern matches both x64 and arm64 variants
          pattern = File.join(base_dir, 'Microsoft.DesktopAppInstaller_*_*__8wekyb3d8bbwe', 'winget.exe')

          candidates = Dir.glob(pattern)
          return nil if candidates.empty?

          # Select the highest version using Gem::Version for proper comparison
          candidates.max_by { |path| extract_version(path) }
        rescue StandardError
          # Never raise at catalog load time; log and return nil
          nil
        end

        # Extract version from path like:
        # C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.2.3456.0_x64__8wekyb3d8bbwe\winget.exe
        # Returns Gem::Version or Gem::Version.new('0') on failure
        def extract_version(path)
          match = path.match(%r{Microsoft\.DesktopAppInstaller_([\d.]+)_})
          return Gem::Version.new('0') unless match

          Gem::Version.new(match[1])
        rescue StandardError
          Gem::Version.new('0')
        end
      end
    end
  end
end
# rubocop:enable Style/ClassAndModuleChildren
