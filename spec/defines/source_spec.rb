# frozen_string_literal: true

require 'spec_helper'

describe 'winget::source' do
  let(:facts) do
    {
      # Legacy facts: facterdb provides them and rspec-puppet stubs
      # Facter from them, which the exec providers use for confinement.
      # Without them no exec provider is suitable on Puppet 7.
      'operatingsystem' => 'windows',
      'osfamily' => 'windows',
      'winget_path' => 'C:/Program Files/WindowsApps/Microsoft.DesktopAppInstaller_1.8.2391_x64__8wekyb3d8bbwe/winget.exe',
      os: {
        family: 'windows',
        name: 'windows',
        release: { major: '10', full: '10' },
        architecture: 'x86_64',
      },
    }
  end
  let(:title) { 'contoso' }
  let(:params) { { url: 'https://winget.contoso.example.com/cache' } }

  it { is_expected.to compile.with_all_deps }

  it 'adds the source guarded by source list' do
    is_expected.to contain_exec('winget-source-add-contoso')
      .with_command(%r{source add --name 'contoso' --arg 'https://winget\.contoso\.example\.com/cache'})
      .with_unless(%r{source list})
  end

  it 'uses explicit exit codes in the source list guard' do
    is_expected.to contain_exec('winget-source-add-contoso')
      .with_unless(%r{if \(.*Select-String.*\) \{\s*exit 0\s*\} else \{\s*exit 1\s*\}})
  end

  it 'accepts source agreements by default for non-interactive runs' do
    is_expected.to contain_exec('winget-source-add-contoso')
      .with_command(%r{--accept-source-agreements})
  end

  context 'with a private REST source' do
    let(:params) do
      {
        url: 'https://winget.contoso.example.com/cache',
        source_type: 'Microsoft.Rest',
        trust_level: 'trusted',
        explicit: true,
      }
    end

    it { is_expected.to compile.with_all_deps }

    it 'passes type, trust level and explicit flags' do
      is_expected.to contain_exec('winget-source-add-contoso')
        .with_command(%r{--type 'Microsoft\.Rest'})
        .with_command(%r{--trust-level 'trusted'})
        .with_command(%r{--explicit})
    end

    it 'removes a stale source before re-adding when attributes drift (issue #38)' do
      is_expected.to contain_exec('winget-source-remove-stale-contoso')
        .with_onlyif(%r{source export})
        .with_onlyif(%r{Arg -ne 'https://winget\.contoso\.example\.com/cache'})
        .with_onlyif(%r{Type -ne 'Microsoft\.Rest'})
        .with_onlyif(%r{TrustLevel.*Trusted})
        .with_onlyif(%r{Explicit})
        .with_before('Exec[winget-source-add-contoso]')
    end
  end

  context 'with default attributes (issue #38)' do
    it 'still declares the stale removal comparing the url' do
      stale = catalogue.resource('Exec', 'winget-source-remove-stale-contoso')
      expect(stale[:onlyif]).to match(%r{Arg -ne 'https://winget\.contoso\.example\.com/cache'})
      # Unset attributes are not compared (presence-only for those).
      expect(stale[:onlyif]).not_to match(%r{Type -ne})
      expect(stale[:onlyif]).not_to match(%r{TrustLevel})
    end

    it 'converges an explicit source back to non-explicit' do
      stale = catalogue.resource('Exec', 'winget-source-remove-stale-contoso')
      expect(stale[:onlyif]).to match(%r{Explicit})
    end
  end

  context 'with a Sensitive header' do
    # NB: a Sensitive value cannot travel through the rspec-puppet params
    # hash (it is not serializable into the test manifest), so the header
    # is built with Sensitive() in Puppet DSL instead.
    let(:params) { { ensure: 'absent' } }
    let(:pre_condition) do
      <<~PUPPET
        winget::source { 'sensitive-source':
          url    => 'https://winget.contoso.example.com/cache',
          header => Sensitive('s3cr3t'),
        }
      PUPPET
    end

    it { is_expected.to compile.with_all_deps }

    it 'never puts the unwrapped header on the command line' do
      command = catalogue.resource('Exec', 'winget-source-add-sensitive-source')[:command]
      expect(command).not_to match(%r{s3cr3t})
    end

    it 'references the header via an environment variable in the command' do
      is_expected.to contain_exec('winget-source-add-sensitive-source')
        .with_command(%r{--header \$env:WINGET_SOURCE_HEADER})
    end

    it 'passes the header through the environment parameter only' do
      exec = catalogue.resource('Exec', 'winget-source-add-sensitive-source')
      environment = exec[:environment]
      environment = environment.unwrap if environment.respond_to?(:unwrap)
      expect(environment).to eq(['WINGET_SOURCE_HEADER=s3cr3t'])
    end

    it 'keeps the environment parameter Sensitive so the secret is redacted in catalogs and reports' do
      exec = catalogue.resource('Exec', 'winget-source-add-sensitive-source')
      expect(exec.sensitive_parameters.map(&:to_sym)).to include(:environment)
    end
  end

  context 'with a Sensitive header from a Hiera lookup (eyaml-simulated, issue #69)' do
    # NB: a Sensitive value cannot travel through the rspec-puppet params
    # hash (it is not serializable into the test manifest), and a raw YAML
    # Hiera value cannot produce a Sensitive value either — hiera-eyaml (an
    # encrypted value looked up as Sensitive) is the supported Hiera path.
    # A Sensitive built from a variable simulates exactly what such a lookup
    # returns: a genuine Sensitive value, not a literal in the resource body.
    # A Deferred-wrapped header was evaluated as an alternative and is NOT
    # supported: the define unwraps the header while the catalog compiles
    # (`if $header` / `${header.unwrap}`), so a Deferred value fails
    # compilation (e.g. NoMethodError for an undefined `dispatcher` method;
    # verified on Puppet 8.10 / rspec-puppet 5) — both
    # in rspec-puppet and in a real `puppet apply --noop` compile. There is
    # intentionally no Deferred spec: this context is the closest meaningful
    # regression test (the plain-string rejection below covers the negative
    # side).
    let(:params) { { ensure: 'absent' } }
    let(:pre_condition) do
      <<~PUPPET
        class hiera_sim {
          $header_from_hiera = Sensitive('s3cr3t-from-hiera')
          winget::source { 'hiera-source':
            url    => 'https://winget.contoso.example.com/cache',
            header => $header_from_hiera,
          }
        }
        include hiera_sim
      PUPPET
    end

    it { is_expected.to compile.with_all_deps }

    it 'never puts the unwrapped header on the command line' do
      command = catalogue.resource('Exec', 'winget-source-add-hiera-source')[:command]
      expect(command).not_to match(%r{s3cr3t-from-hiera})
    end

    it 'references the header via an environment variable in the command' do
      is_expected.to contain_exec('winget-source-add-hiera-source')
        .with_command(%r{--header \$env:WINGET_SOURCE_HEADER})
    end

    it 'passes the header through the environment parameter only' do
      exec = catalogue.resource('Exec', 'winget-source-add-hiera-source')
      environment = exec[:environment]
      environment = environment.unwrap if environment.respond_to?(:unwrap)
      expect(environment).to eq(['WINGET_SOURCE_HEADER=s3cr3t-from-hiera'])
    end

    it 'keeps the environment parameter Sensitive so the secret is redacted in catalogs and reports' do
      exec = catalogue.resource('Exec', 'winget-source-add-hiera-source')
      expect(exec.sensitive_parameters.map(&:to_sym)).to include(:environment)
    end
  end

  context 'with a plain-string header' do
    let(:params) do
      {
        url: 'https://winget.contoso.example.com/cache',
        header: 's3cr3t',
      }
    end

    it { expect { catalogue }.to raise_error(Puppet::Error) }
  end

  context 'without url' do
    let(:params) { {} }

    it { expect { catalogue }.to raise_error(Puppet::Error, %r{url is required}) }
  end

  context 'with ensure => absent' do
    let(:params) { { ensure: 'absent' } }

    it { is_expected.to compile.with_all_deps }

    it 'removes the source only when listed' do
      is_expected.to contain_exec('winget-source-remove-contoso')
        .with_command(%r{source remove --name 'contoso'})
        .with_onlyif(%r{source list})
      is_expected.not_to contain_exec('winget-source-add-contoso')
    end

    it 'declares no stale-attribute removal for ensure => absent (issue #38)' do
      is_expected.not_to contain_exec('winget-source-remove-stale-contoso')
    end

    it 'uses explicit exit codes in the source list guard' do
      is_expected.to contain_exec('winget-source-remove-contoso')
        .with_onlyif(%r{if \(.*Select-String.*\) \{\s*exit 0\s*\} else \{\s*exit 1\s*\}})
    end
  end

  context 'with quotes and regex metacharacters in title and url (issue #41)' do
    let(:title) { "foo.bar+c++(x)'s" }
    let(:params) { { url: "https://example.com/a'b" } }

    it { is_expected.to compile.with_all_deps }

    it 'doubles single quotes in PowerShell single-quoted literals' do
      command = catalogue.resource('Exec', "winget-source-add-#{title}")[:command]
      expect(command).to include("--name 'foo.bar+c++(x)''s'")
      expect(command).to include("--arg 'https://example.com/a''b'")
    end

    it 'escapes the name as regex in the list guard' do
      guard = catalogue.resource('Exec', "winget-source-add-#{title}")[:unless]
      expect(guard).to include("[regex]::Escape('foo.bar+c++(x)''s')")
      # A different name differing only by regex metacharacters must not match.
      expect(guard).not_to match(%r{\^foo\.bar})
    end
  end

  context 'without winget (fresh bootstrap)' do
    let(:facts) do
      {
        'operatingsystem' => 'windows',
        'osfamily' => 'windows',
        os: {
          family: 'windows',
          name: 'windows',
          release: { major: '10', full: '10' },
          architecture: 'x86_64',
        },
      }
    end

    it { is_expected.to compile.with_all_deps }
    it { is_expected.to have_exec_resource_count(0) }
  end

  context 'with a double quote in the title (issue #74)' do
    let(:title) { 'con"toso' }

    it { expect { catalogue }.to raise_error(Puppet::Error, %r{double quotes}) }
  end

  context 'with a double quote in the url (issue #74)' do
    let(:params) { { url: 'https://winget.contoso.example.com/ca"che' } }

    it { expect { catalogue }.to raise_error(Puppet::Error, %r{double quotes}) }
  end

  context 'with a double quote in the source_type (issue #74)' do
    let(:params) { { url: 'https://winget.contoso.example.com/cache', source_type: 'Microsoft."Rest' } }

    it { expect { catalogue }.to raise_error(Puppet::Error, %r{double quotes}) }
  end

end
