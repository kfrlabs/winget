# frozen_string_literal: true

# On-demand winget upgrade inventory for `Class['winget::upgrade']`.
#
# Runs `winget upgrade` fresh on every call (uncached, timeout-guarded by
# `PuppetX::Winget::Runner`) and returns
# the same structured rows as the opt-in `winget_upgrades` fact: one hash
# with `id`, `current_version` and `available_version` per upgradable
# package. Returns `undef` when winget is absent or the query fails (so the
# class can fall back to the fact rows); returns `[]` only when the query
# succeeds with no rows. Never raises.
#
# The class calls this function so enumeration happens only when the class
# is declared. The fact rows (`$facts['winget_upgrades']`) are only a
# fallback for server-side compilation (where this function runs on the
# server without winget) and standalone PuppetDB inventory.
#
# No per-process memoization here on purpose: on Puppet Server one server
# process compiles catalogs for many nodes, so a memoized forced output
# from node A must never satisfy node B. Each call shells out once per
# compilation (the class calls once); server-side callers that use the
# memoized `PuppetX::Winget::Facts.upgrade_output(force: true)` directly
# must call `PuppetX::Winget::Facts.reset!` once per catalog instead.
Puppet::Functions.create_function(:'winget::upgrades') do
  # @return [Optional[Array[Hash]]] Upgrade rows with `id`, `current_version` and
  #   `available_version` keys (`[]` on success with no rows, `undef` when
  #   absent/error/disabled)
  dispatch :upgrades do
    return_type 'Optional[Array[Hash]]'
  end

  def upgrades
    require 'puppet_x/winget/facts'

    # Uncached on purpose (see above): no cross-node reuse on Puppet Server.
    raw = PuppetX::Winget::Facts.run_upgrade(nil, force: true)
    return nil if raw.nil?

    PuppetX::Winget::Facts.parse_winget_upgrade(raw)
  rescue LoadError, StandardError
    # LoadError is a ScriptError, not a StandardError: without listing it
    # explicitly, a helper that cannot be loaded (partially deployed or
    # stale module lib on the server, duplicate module shadowing) fails
    # the whole catalog compilation with a 500 instead of degrading to
    # undef. The class already falls back to the fact rows with a warning.
    nil
  end
end
