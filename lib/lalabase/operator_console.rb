# frozen_string_literal: true

require 'ipaddr'

module Lalabase
  # The internal process that loads the operator console
  # (doc/oss_core_split_plan.md 9.1).
  #
  # The console is a private engine, loaded through Gemfile.operator in a
  # SECOND Puma on the same release. That process listens on its own Unix
  # socket and is reached through an SSH tunnel only. So it sees `localhost` as
  # its host and plain HTTP instead of TLS, and its pages have to load their
  # assets from that host, not from the public one. This module holds the
  # handful of settings that differ from the public process:
  # config/initializers/operator_console.rb applies them, and config/puma.rb
  # asks the same question for the socket.
  #
  # Plain Ruby: config/puma.rb loads this file before Rails.
  module OperatorConsole
    ENV_FLAG = 'OPERATOR_CONSOLE'
    # The only value that switches it on. Ruby treats every set string as true,
    # so `OPERATOR_CONSOLE=0`, `=false` or a blanked unit line would otherwise
    # count as on.
    ENABLED_VALUE = '1'
    ENGINE = 'Lalabase::Operator::Engine'
    # What the tunnel presents as the host. Rails matches a String entry with an
    # optional :port; an IPv6 address arrives bracketed ([::1]:3101), which only
    # an IPAddr entry matches.
    LOCAL_HOSTS = ['localhost', '127.0.0.1', IPAddr.new('::1')].freeze

    # The flag is set, but this process did not load the engine.
    class EngineMissing < StandardError; end

    class << self
      def enabled?(env = ENV)
        env[ENV_FLAG].to_s.strip == ENABLED_VALUE
      end

      # Own name, so a browser never hands one process the other's cookie. Per
      # environment, because cookies ignore the port: a staging and a production
      # tunnel both live on localhost.
      def session_key(rails_env)
        "_lalabase_operator_#{rails_env}_session"
      end

      # dotenv loads the shared .env after Puma has picked its socket, so a flag
      # found there would reach the public process too and switch its TLS off.
      # Only the console loads the engine; without it the flag is a mistake.
      def require_engine!
        return if Object.const_defined?(ENGINE)

        raise EngineMissing, "#{ENV_FLAG} is set, but #{ENGINE} is not loaded. Only the operator console " \
                             'sets the flag, and it starts with BUNDLE_GEMFILE=Gemfile.operator. Check the ' \
                             "shared .env and the unit for a stray #{ENV_FLAG}."
      end

      # config: Rails.application.config, from an initializer. The SSL, Static
      # and HostAuthorization middlewares and the session store read these
      # values when the stack is built afterwards. The asset host is the
      # exception: actionpack copies it into config.action_controller before any
      # initializer runs, so the copy is cleared as well (ActionController::Base
      # takes it over when it loads, which is later).
      def apply!(config, env:)
        allow_local_hosts(config)
        # The tunnel carries plain HTTP; a redirect to https or a Secure cookie
        # would lock the operator out.
        config.force_ssl = false
        config.assume_ssl = false
        # The page comes from http://localhost:<tunnel port>. With an asset host
        # the browser would fetch the importmap's module scripts and the icon
        # fonts cross-origin, and the public host sends no CORS headers for
        # them: no Turbo, no confirm dialogs. Mails keep the public host.
        config.action_mailer.asset_host ||= config.asset_host
        config.asset_host = nil
        config.action_controller.asset_host = nil
        # So Rails serves public/ (the precompiled assets) itself. That is its
        # default, restated because no nginx is in front that could take over if
        # an environment switched it off.
        config.public_file_server.enabled = true
        config.session_store :cookie_store, key: session_key(env)
        config
      end

      private

      # nil (development) and [] (Rails' default elsewhere) both mean "every host
      # is allowed". Adding localhost would narrow that to localhost, or raise on
      # nil; only an actual list gains the tunnel's hosts.
      def allow_local_hosts(config)
        hosts = config.hosts
        return if Array(hosts).empty?

        hosts.concat(LOCAL_HOSTS - hosts)
      end
    end
  end
end
