# frozen_string_literal: true

# Litmus acceptance test for the winget module.
# Run with: bundle exec rake 'litmus:acceptance:parallel'
# Requires a provisioned Windows target (see README "Acceptance Testing").
require 'spec_helper_acceptance'

describe 'winget class' do
  it 'applies with no errors' do
    pp = <<-PUPPET
    class { 'winget':
      ensure => present,
    }
    PUPPET

    apply_manifest(pp, catch_failures: true)
    apply_manifest(pp, catch_changes: true)
  end

  describe package('Git.Git') do
    it { is_expected.to be_installed }
  end
end
