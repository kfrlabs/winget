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
end
