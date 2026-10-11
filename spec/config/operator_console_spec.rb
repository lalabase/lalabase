# frozen_string_literal: true

# What: the settings the operator console process needs and the public process
#   must not get (Lalabase::OperatorConsole, doc/oss_core_split_plan.md 9.1),
#   and the initializer that applies them.
# Why: the console is reached through an SSH tunnel: localhost, plain HTTP, no
#   nginx. With the public settings it would answer 403 (host), redirect to
#   https (force_ssl) or load its scripts from the public host, which sends no
#   CORS headers for them (asset_host). Each of those is invisible in the test
#   environment, which allows everything, so the module is tested on its own
#   against a config object.
# Contract:
#   * only OPERATOR_CONSOLE=1 switches it on; blank, 0 or false do not
#   * apply! allows the tunnel's hosts where the environment keeps a host list,
#     drops TLS and the asset host, serves public/, names a cookie per environment
#   * with the flag set, the initializer refuses to boot without the engine, so a
#     stray line in the shared .env cannot downgrade the public process
#   * the public process (no flag) keeps its own settings
require 'rails_helper'

RSpec.describe Lalabase::OperatorConsole do
  let(:flag) { described_class::ENV_FLAG }

  describe '.enabled?' do
    it 'is on for 1' do
      expect(described_class).to be_enabled(flag => '1')
    end

    it 'is off without the flag' do
      expect(described_class).not_to be_enabled({})
    end

    # Ruby treats every set string as true. A blanked unit line, or a .env line
    # meant as "off", must not switch the console on.
    ['', ' ', '0', 'false', 'no'].each do |value|
      it "is off for #{value.inspect}" do
        expect(described_class).not_to be_enabled(flag => value)
      end
    end
  end

  describe '.apply!' do
    let(:hosts) { ['lalabase.com', /.*\.lalabase\.com/] }

    # The parts of Rails.application.config the module touches, as production
    # sets them. By the time an initializer runs, actionpack has already copied
    # asset_host into action_controller and actionmailer into action_mailer
    # (their set_configs initializers). public_file_server is on by Rails'
    # default; it is off here to show apply! does not rely on that.
    # `session_store` records its arguments the way Rails would.
    let(:config) do
      ActiveSupport::OrderedOptions.new.tap do |c|
        c.hosts = hosts
        c.force_ssl = true
        c.assume_ssl = true
        c.asset_host = 'https://lalabase.com'
        c.action_controller = ActiveSupport::OrderedOptions.new.tap { |o| o.asset_host = 'https://lalabase.com' }
        c.action_mailer = ActiveSupport::OrderedOptions.new
        c.public_file_server = ActiveSupport::OrderedOptions.new.tap { |p| p.enabled = false }
        c.define_singleton_method(:session_store) { |store, **options| self.session_store_args = [store, options] }
      end
    end

    before { described_class.apply!(config, env: 'production') }

    # The real host check against the list apply! built: what counts is the
    # Host header a browser sends through the tunnel, not array membership.
    def host_allowed?(host)
      app = ActionDispatch::HostAuthorization.new(->(_env) { [200, {}, ['ok']] }, config.hosts)
      app.call(Rack::MockRequest.env_for('/', 'HTTP_HOST' => host)).first == 200
    end

    it 'allows the Host headers a tunnel presents, IPv6 included' do
      expect(%w[localhost:3101 127.0.0.1:3101 [::1]:3101]).to all(satisfy { |host| host_allowed?(host) })
    end

    it 'keeps the public hosts and still refuses any other' do
      expect(host_allowed?('lalabase.com')).to be(true)
      expect(host_allowed?('evil.example')).to be(false)
    end

    it 'does not add a host twice' do
      expect { described_class.apply!(config, env: 'production') }.not_to(change { config.hosts.size })
    end

    it 'drops TLS, because the tunnel carries plain HTTP' do
      expect(config.force_ssl).to be(false)
      expect(config.assume_ssl).to be(false)
    end

    it 'drops the asset host, so the page loads its scripts and fonts from the tunnel' do
      expect(config.asset_host).to be_nil
      expect(config.action_controller.asset_host).to be_nil
    end

    it 'keeps the public asset host for mails' do
      expect(config.action_mailer.asset_host).to eq('https://lalabase.com')
    end

    it 'serves public/ itself, because no nginx is in front' do
      expect(config.public_file_server.enabled).to be(true)
    end

    it 'names a session cookie of its own for the environment' do
      expect(config.session_store_args).to eq([:cookie_store, { key: '_lalabase_operator_production_session' }])
    end

    # Cookies ignore the port: a staging and a production tunnel both live on
    # localhost and would log each other out under one name.
    it 'gives staging and production different cookies' do
      expect(described_class.session_key('staging')).not_to eq(described_class.session_key('production'))
    end

    # development.rb sets nil, Rails' default elsewhere is []. Both mean "every
    # host is allowed"; adding localhost would narrow that, or raise on nil.
    [nil, []].each do |open_hosts|
      context "when the environment allows every host (#{open_hosts.inspect})" do
        let(:hosts) { open_hosts }

        it 'leaves the host list alone' do
          expect(config.hosts).to eq(open_hosts)
        end
      end
    end
  end

  describe 'config/initializers/operator_console.rb' do
    let(:initializer) { Rails.root.join('config/initializers/operator_console.rb') }

    context 'with the flag set' do
      before { allow(described_class).to receive(:enabled?).and_return(true) }

      it 'applies the console settings to the real config when the engine is loaded' do
        stub_const(described_class::ENGINE, Class.new)
        expect(described_class).to receive(:apply!).with(Rails.application.config, env: Rails.env)
        load initializer
      end

      # dotenv loads the shared .env after Puma has picked its socket, so a
      # stray OPERATOR_CONSOLE line there reaches the public process too. Only
      # the console loads the engine.
      # hide_const: the engine's CI runs core specs with the engine loaded.
      it 'refuses to boot without the engine' do
        hide_const(described_class::ENGINE)
        expect(described_class).not_to receive(:apply!)
        expect { load initializer }.to raise_error(described_class::EngineMissing, /Gemfile\.operator/)
      end
    end

    it 'does nothing without the flag' do
      allow(described_class).to receive(:enabled?).and_return(false)
      expect(described_class).not_to receive(:apply!)
      load initializer
    end
  end

  # This suite runs without the flag, so the real config must be the public one.
  describe 'the public process' do
    it 'runs without the flag' do
      expect(described_class).not_to be_enabled
    end

    it 'keeps its own session cookie' do
      key = Rails.application.config.session_options[:key]
      expect(key).to be_present
      expect(key).not_to start_with('_lalabase_operator')
    end
  end
end
