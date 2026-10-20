# frozen_string_literal: true

# What: Guard spec — in deployed environments Puma may listen on its Unix socket
#   and on nothing else. No TCP listener, on any interface, on any port.
# Why (history): config/puma.rb carried `port ENV.fetch('PORT', 3000)` at the top
#   level. Puma reads that as `bind tcp://0.0.0.0:3000` and ADDS it to the Unix
#   socket bound further down instead of replacing it, so staging and production
#   each ran a second, public listener that nobody proxied to. On 2026-08-14 both
#   were reachable from the open internet: production answered 200 on
#   http://<ip>:3000/ for a request carrying `Host: lalabase.com`, and staging's
#   freshly installed Basic Auth was bypassed completely by adding
#   `X-Forwarded-Proto: https`. Every access rule nginx enforces — Basic Auth,
#   TLS, rate limits — lives one layer above that listener and was simply skipped.
# Contract:
#   * staging and production bind the Unix socket and register no `port`
#   * no bind in those environments uses a tcp:// URL
#   * development keeps its TCP port (that is what `bin/dev` talks to)
#   * the Docker image (LALABASE_CONTAINER=1, exact value) listens on its port
#     instead of a socket; any other value leaves the socket in place
# Note: this evaluates the real config file through a recording DSL rather than
#   grepping it, so any future spelling of a TCP listener — `port`, `bind
#   'tcp://…'`, a computed value — is caught, not just the literal that broke.
require 'rails_helper'

# Records what the config file declares instead of executing it: binds, and
# the pid, state and process model that tell the public Puma and the operator
# console apart. Everything else Puma's DSL offers (threads, plugins) is
# irrelevant here and gets swallowed.
class PumaConfigProbe
  attr_reader :binds, :ports, :pidfile_path, :state_file, :worker_count, :content_length_limit

  def initialize
    @binds = []
    @ports = []
    @preloaded = false
  end

  def bind(url)
    @binds << url
  end

  def port(value, host = nil)
    @ports << [value, host]
  end

  def pidfile(path)
    @pidfile_path = path
  end

  def state_path(path)
    @state_file = path
  end

  def workers(count)
    @worker_count = count
  end

  def preload_app!
    @preloaded = true
  end

  def http_content_length_limit(bytes)
    @content_length_limit = bytes
  end

  def preloaded?
    @preloaded
  end

  # The probe evaluates config/puma.rb under a release path that does not exist
  # here, so its requires of the operator console and the demo resolve to nowhere.
  # Rails has loaded those files already.
  def require(path)
    path.end_with?('lib/lalabase/operator_console', 'lib/lalabase/demo') || super
  end

  def method_missing(_name, *_args, &_block)
    nil
  end

  def respond_to_missing?(_name, _include_private = false)
    true
  end
end

RSpec.describe 'config/puma.rb bindings' do
  def config_path
    Rails.root.join('config/puma.rb')
  end

  # Where config/puma.rb sits on our servers: inside a Capistrano release.
  def release_config = '/srv/lalabase/releases/20260101000000/config/puma.rb'

  def probe(rails_env, console_flag: nil, container_flag: nil, path: release_config)
    previous = ENV.fetch('RAILS_ENV', nil)
    previous_console = ENV.fetch(Lalabase::OperatorConsole::ENV_FLAG, nil)
    previous_container = ENV.fetch('LALABASE_CONTAINER', nil)
    ENV['RAILS_ENV'] = rails_env
    ENV[Lalabase::OperatorConsole::ENV_FLAG] = console_flag
    ENV['LALABASE_CONTAINER'] = container_flag
    PumaConfigProbe.new.tap { |p| p.instance_eval(File.read(config_path), path.to_s) }
  ensure
    ENV['RAILS_ENV'] = previous
    ENV[Lalabase::OperatorConsole::ENV_FLAG] = previous_console
    ENV['LALABASE_CONTAINER'] = previous_container
  end

  %w[staging production].each do |rails_env|
    # The operator console is a second Puma on the same release
    # (doc/oss_core_split_plan.md 9.1). Same rule, own socket: it must never
    # take the public socket from under nginx, and never open a port either.
    context "as the operator console in #{rails_env}" do
      subject(:config) { probe(rails_env, console_flag: '1') }

      let(:public_config) { probe(rails_env) }

      it 'binds its own Unix socket and nothing else' do
        expect(config.ports).to be_empty
        expect(config.binds).to be_one
        expect(config.binds.first).to start_with('unix://').and include('/puma-operator.sock?')
      end

      # Puma creates a Unix socket with umask 0 (mode 0777) unless the bind says
      # otherwise. The public socket stays open for nginx; the console's is for
      # the deploy user alone, which the SSH tunnel and the health gate run as.
      it 'opens its socket to the deploy user only' do
        expect(config.binds.first).to end_with('?umask=0077')
        expect(public_config.binds.first).to end_with('/puma.sock')
      end

      it 'leaves the public socket, pid and state file to the public process' do
        expect(config.binds).not_to include(public_config.binds.first)
        expect(config.pidfile_path).to end_with('/puma-operator.pid')
        expect(config.state_file).to end_with('/puma-operator.state')
        expect(public_config.pidfile_path).to end_with('/puma.pid')
        expect(public_config.state_file).to end_with('/puma.state')
      end

      # One operator, one process. Cluster mode with a single worker would run a
      # second full Rails, the master, for nothing.
      it 'runs as a single process, the public Puma as a cluster' do
        expect([config.worker_count, config.preloaded?]).to eq([0, false])
        expect([public_config.worker_count, public_config.preloaded?]).to eq([2, true])
      end
    end

    # The socket and the Rails settings answer "is this the console?" with the
    # same predicate (Lalabase::OperatorConsole.enabled?). Ruby treats every set
    # string as true; a blanked or "off" flag must not move the public process
    # onto the console's socket, away from nginx.
    context "with a flag other than 1 in #{rails_env}" do
      ['', ' ', '0', 'false'].each do |value|
        it "binds the public socket for #{value.inspect}" do
          expect(probe(rails_env, console_flag: value).binds).to eq(probe(rails_env).binds)
        end
      end
    end

    context "in #{rails_env}" do
      subject(:config) { probe(rails_env) }

      it 'registers no TCP port' do
        expect(config.ports).to be_empty,
                                "config/puma.rb declares `port #{config.ports.map(&:first).join(', ')}` in " \
                                "#{rails_env}. Puma adds that as a public listener on 0.0.0.0 NEXT TO the " \
                                'Unix socket; nginx proxies to the socket, so the port only exposes the app ' \
                                'past TLS and past every nginx access rule.'
      end

      it 'binds the Unix socket only' do
        expect(config.binds).to be_one
        expect(config.binds.first).to start_with('unix://')
      end

      it 'binds nothing over tcp' do
        expect(config.binds.grep(%r{\Atcp://})).to be_empty
      end
    end
  end

  # The Docker image (LALABASE_CONTAINER=1 in its Dockerfile) runs production
  # without nginx and without a deploy root: the published port is the way in,
  # and the container's network is the boundary the socket is on our servers.
  context 'the deploy root' do
    it 'is read off the Capistrano release the file sits in' do
      expect(probe('production').binds).to eq(['unix:///srv/lalabase/shared/tmp/sockets/puma.sock'])
    end

    it 'is read off the current symlink as well' do
      config = probe('production', path: '/srv/lalabase/current/config/puma.rb')
      expect(config.binds).to eq(['unix:///srv/lalabase/shared/tmp/sockets/puma.sock'])
    end

    it 'does not exist outside a release: production then listens on its port' do
      config = probe('production', path: config_path)
      expect(config.binds).to be_empty
      expect(config.ports).not_to be_empty
    end
  end

  context 'in the Docker container' do
    subject(:config) { probe('production', container_flag: '1') }

    it 'listens on its port and binds no deployment socket' do
      expect(config.ports.map(&:first)).to eq([ENV.fetch('PORT', 3000)])
      expect(config.binds).to be_empty
      expect(config.pidfile_path).to be_nil
    end

    # Only the exact value: our servers must not move onto a TCP port because
    # a line was blanked or meant as "off".
    ['', ' ', '0', 'false', 'true'].each do |value|
      it "keeps the Unix socket for #{value.inspect}" do
        expect(probe('production', container_flag: value).binds).to eq(probe('production').binds)
      end
    end
  end

  context 'in development' do
    subject(:config) { probe('development') }

    it 'keeps the TCP port bin/dev connects to' do
      expect(config.ports).not_to be_empty
    end

    it 'binds no deployment socket' do
      expect(config.binds).to be_empty
    end
  end

  # Puma reads a whole body into a temporary file before Rails can refuse it, so the
  # demo's upload limit (Lalabase::Demo::UploadLimit) protects the disk only here.
  describe 'the body limit of the public demo' do
    def probe_demo(flag)
      flag_was = ENV.fetch(Lalabase::Demo::ENV_FLAG, nil)
      ENV[Lalabase::Demo::ENV_FLAG] = flag
      probe('production', container_flag: '1')
    ensure
      ENV[Lalabase::Demo::ENV_FLAG] = flag_was
    end

    it 'is the upload limit in demo mode, and Puma\'s own default otherwise' do
      expect(probe_demo(Lalabase::Demo::ENABLED_VALUE).content_length_limit).to eq(Lalabase::Demo::MAX_UPLOAD_BYTES)
      expect(probe_demo(nil).content_length_limit).to be_nil
    end
  end
end
