# frozen_string_literal: true

# Litmus acceptance test for the winget module.
# Run with: bundle exec rake 'litmus:acceptance:parallel'
# Requires a provisioned Windows target (see README "Acceptance Testing").
require 'spec_helper_acceptance'

describe 'winget module' do
  context 'bootstrap class' do
    it 'applies with no errors' do
      pp = <<-PUPPET
      class { 'winget':
        ensure => present,
      }
      PUPPET

      apply_manifest(pp, catch_failures: true)
      apply_manifest(pp, catch_changes: true)
    end

    describe command('winget --version') do
      its(:exit_status) { is_expected.to eq 0 }
    end
  end

  context 'package provider' do
    it 'installs a package via the winget provider' do
      pp = <<-PUPPET
      package { 'Git.Git':
        ensure   => present,
        provider => winget,
      }
      PUPPET

      apply_manifest(pp, catch_failures: true)
      apply_manifest(pp, catch_changes: true)
    end

    describe package('Git.Git') do
      it { is_expected.to be_installed }
    end
  end
end
