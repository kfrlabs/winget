# frozen_string_literal: true

# PathResolver locates the winget executable.
# It handles:
# - Expanding ProgramFiles from the environment (no hardcoded paths)
# - 32-bit Ruby on 64-bit Windows (ProgramFiles vs ProgramW6432)
# - Both x64 and arm64 variants
# - Selecting the highest version using Gem::Version comparison
# - SYSTEM context fallbacks: PATH lookup and per-user App Execution Aliases
# - Memoization to avoid repeated filesystem scans
# - Never raises at catalog load time; returns nil when winget is absent
#
# WindowsApps ACL caveat: The SYSTEM account (under which the Puppet agent runs)
# may not have read access to the WindowsApps directory by default. When the
# directory listing fails, the resolver falls back to PATH and well-known
# App Execution Alias locations before giving up.
# rubocop:disable Style/ClassAndModuleChildren
module PuppetX
  module Winget
    # PathResolver locates the winget executable.
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
          from_windows_apps || from_path || from_user_alias
        rescue StandardError
          # Never raise at catalog load time; log and return nil
          nil
        end

        # Primary lookup: WindowsApps folders. Checks both ProgramFiles and
        # ProgramW6432 so 32-bit Ruby on 64-bit Windows still finds the
        # 64-bit WindowsApps directory.
        def from_windows_apps
          candidates = []
          program_roots.each do |program_files|
            next unless program_files

            base_dir = File.join(program_files, 'WindowsApps')
            next unless Dir.exist?(base_dir)

            # Pattern matches both x64 and arm64 variants
            pattern = File.join(base_dir, 'Microsoft.DesktopAppInstaller_*_*__8wekyb3d8bbwe', 'winget.exe')
            begin
              candidates.concat(Dir.glob(pattern))
            rescue StandardError
              next
            end
          end
          return nil if candidates.empty?

          # Select the highest version using Gem::Version for proper comparison
          candidates.max_by { |path| extract_version(path) }
        rescue StandardError
          nil
        end

        # Fallback 1: winget on PATH (App Execution Alias for the current
        # user, admin installs, or custom locations).
        def from_path
          hit = which('winget.exe') || which('winget')
          return nil unless hit && File.exist?(hit)

          hit
        rescue StandardError
          nil
        end

        # Fallback 2: per-user App Execution Aliases. The SYSTEM account has
        # no alias of its own, but interactive users' aliases exist on disk
        # and are executable when the ACLs allow it.
        def from_user_alias
          local = ENV['LOCALAPPDATA']
          if local
            candidate = File.join(local, 'Microsoft', 'WindowsApps', 'winget.exe')
            return candidate if File.exist?(candidate)
          end

          begin
            hits = Dir.glob('C:/Users/*/AppData/Local/Microsoft/WindowsApps/winget.exe')
          rescue StandardError
            hits = []
          end
          hits.find { |path| File.exist?(path) }
        rescue StandardError
          nil
        end

        # Candidate Program Files roots, deduplicated.
        def program_roots
          [ENV['ProgramFiles'], ENV['ProgramW6432']].compact.uniq
        end

        # PATH lookup without hard dependency on Puppet at load time.
        def which(cmd)
          if defined?(Puppet::Util) && Puppet::Util.respond_to?(:which)
            hit = Puppet::Util.which(cmd)
            return hit if hit
          else
            begin
              require 'puppet/util'
              if Puppet::Util.respond_to?(:which)
                hit = Puppet::Util.which(cmd)
                return hit if hit
              end
            rescue LoadError, StandardError
              nil
            end
          end

          # Manual PATH scan when Puppet::Util is unavailable.
          scan_path(cmd)
        rescue StandardError
          nil
        end

        # Minimal `which`: first executable match on PATH.
        def scan_path(cmd)
          path_env = ENV['PATH']
          return nil unless path_env

          names = [cmd, "#{cmd}.exe"].uniq
          path_env.split(File::PATH_SEPARATOR).each do |dir|
            next if dir.nil? || dir.empty?

            names.each do |name|
              candidate = File.join(dir, name)
              begin
                return candidate if File.file?(candidate) && File.executable?(candidate)
              rescue StandardError
                next
              end
            end
          end
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
