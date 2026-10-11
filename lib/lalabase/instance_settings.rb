# frozen_string_literal: true

require 'active_support/core_ext/object/blank'

module Lalabase
  # The production settings that name the host an instance answers on.
  #
  # Our own servers run without any of these variables and get exactly the
  # values production.rb carried before this module existed: lalabase.com, its
  # asset host, TLS and a log file. A self-hosted instance (the Docker image)
  # sets LALABASE_HOST and gets its own host everywhere instead, no asset host,
  # and logs on stdout.
  #
  # ASSET_HOST, LALABASE_FORCE_SSL and RAILS_LOG_TO_STDOUT count only once
  # LALABASE_HOST is set. Two of them are common lines in Rails and Heroku
  # templates, and production.rb never read them: a stray one in our servers'
  # shared .env must stay as inert as it was. The container's compose file is what insists on
  # LALABASE_HOST, not this module: an unset value has to keep meaning "our
  # servers", or every deploy would need a new line in the shared .env first.
  #
  # Plain Ruby: config/environments/production.rb loads this file before Rails
  # has set up autoloading. Pinned by spec/config/instance_settings_spec.rb.
  module InstanceSettings
    HOST_VAR = 'LALABASE_HOST'
    ASSET_HOST_VAR = 'ASSET_HOST'
    FORCE_SSL_VAR = 'LALABASE_FORCE_SSL'
    LOG_TO_STDOUT_VAR = 'RAILS_LOG_TO_STDOUT'
    MAILER_HOST_VAR = 'MAILER_DEFAULT_URL_HOST'

    # What our servers answer on. Only used while LALABASE_HOST is unset.
    OWN_HOST = 'lalabase.com'
    OWN_HOSTS = ['lalabase.com', 'www.lalabase.com', /.*\.lalabase\.com/].freeze
    OWN_ASSET_HOST = 'https://lalabase.com'
    OWN_CABLE_URL = 'wss://lalabase.com/cable'
    OWN_CABLE_ORIGINS = ['https://lalabase.com', 'https://www.lalabase.com'].freeze

    # Values that switch TLS off or stdout-only logging on. Ruby treats every
    # set string as true, so `LALABASE_FORCE_SSL=` must not count as "false".
    OFF_VALUES = %w[0 false no].freeze
    ON_VALUES = %w[1 true yes].freeze

    class << self
      def self_hosted?(env = ENV)
        !host_value(env).nil?
      end

      def host(env = ENV)
        host_value(env) || OWN_HOST
      end

      # config.hosts. A String entry matches the host with any port, so
      # LALABASE_HOST=localhost also admits localhost:3000.
      def hosts(env = ENV)
        self_hosted?(env) ? [bare_host(env)] : OWN_HOSTS.dup
      end

      # A self-hosted instance serves its assets itself unless ASSET_HOST
      # names a CDN; set but empty means the same as unset.
      def asset_host(env = ENV)
        return OWN_ASSET_HOST unless self_hosted?(env)

        env[ASSET_HOST_VAR].to_s.strip.presence
      end

      # nil lets Action Cable connect to the host the page came from, over ws
      # or wss to match it. That is right for any self-hosted instance.
      def cable_url(env = ENV)
        self_hosted?(env) ? nil : OWN_CABLE_URL
      end

      def cable_origins(env = ENV)
        return OWN_CABLE_ORIGINS.dup unless self_hosted?(env)

        [%r{\Ahttps?://#{Regexp.escape(bare_host(env))}(:\d+)?\z}]
      end

      # Off only for an explicit 0/false/no on a self-hosted instance: a
      # missing or blank value keeps TLS, and our servers always keep it.
      def force_ssl?(env = ENV)
        return true unless self_hosted?(env)

        !OFF_VALUES.include?(env[FORCE_SSL_VAR].to_s.strip.downcase)
      end

      def protocol(env = ENV)
        force_ssl?(env) ? 'https' : 'http'
      end

      def mailer_host(env = ENV)
        env[MAILER_HOST_VAR].to_s.strip.presence || host(env)
      end

      # Mails cannot use relative image paths. Our servers keep Rails' default
      # (the asset host); a self-hosted instance points at itself.
      def mailer_asset_host(env = ENV)
        self_hosted?(env) ? "#{protocol(env)}://#{host(env)}" : nil
      end

      # A container's log is its stdout; a file inside it only fills the layer.
      # Our servers keep their files (rake pundit:warnings reads one).
      def log_to_file?(env = ENV)
        return true unless self_hosted?(env)

        !ON_VALUES.include?(env[LOG_TO_STDOUT_VAR].to_s.strip.downcase)
      end

      private

      def host_value(env)
        env[HOST_VAR].to_s.strip.presence
      end

      # LALABASE_HOST may carry a port (localhost:3000) for links and mails;
      # the host check and the cable origin match the port separately.
      def bare_host(env)
        host(env).sub(/:\d+\z/, '')
      end
    end
  end
end
