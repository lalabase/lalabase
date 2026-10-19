# frozen_string_literal: true

module Lalabase
  # Demo mode: a public instance that anybody enters with one published login,
  # the signed-in person of the Nordlicht fiction (Lalabase::Demo::World).
  #
  # Off unless LALABASE_DEMO=1. Everything that changes in demo mode asks
  # enabled? when it runs, not at boot: the mail interceptor, the restrictions
  # (DemoRestrictions), the sign-in page, the banner, the lockout and the
  # per-address login throttle. An instance without the flag behaves as before.
  #
  # The published login is shared by every visitor at once, so it must not be
  # lockable, throttled per address, renamed or given a new password, and the
  # account must not reach outside the instance (mail, tokens, repositories).
  #
  # Explicit require in config/initializers/demo.rb: the interceptor is
  # registered before the autoloader serves lib/.
  module Demo
    ENV_FLAG = 'LALABASE_DEMO'
    # The only value that switches it on (same rule as Lalabase::OperatorConsole).
    ENABLED_VALUE = '1'
    # Shown on the sign-in page of the demo, so it is no secret. Only the
    # signed-in person of the fiction carries it; the others get a random one,
    # or a visitor could sign in as the account admin.
    PASSWORD = 'nordlicht-demo'

    class << self
      def enabled?(env = ENV)
        env[ENV_FLAG].to_s.strip == ENABLED_VALUE
      end

      def login_email = Fiction.email(Fiction::SIGNED_IN)
      def login_name = Fiction.full_name(Fiction::SIGNED_IN)

      def published_login?(email)
        enabled? && email.is_a?(String) && email.strip.casecmp?(login_email)
      end
    end

    # Drops every outgoing mail while demo mode is on. An invitation or a
    # notification would otherwise go out with this instance as its sender, to
    # any address a visitor types. Registered on every instance and asked per
    # mail, so the flag decides it, not the boot.
    module MailDrop
      def self.delivering_email(message)
        message.perform_deliveries = false if Demo.enabled?
      end
    end

    # X-Robots-Tag on every response in demo mode, attachments included: the
    # pages show whatever visitors wrote, and that should not end up in a search
    # engine.
    class NoIndex
      HEADER = 'x-robots-tag'
      VALUE = 'noindex, nofollow'

      def initialize(app)
        @app = app
      end

      def call(env)
        status, headers, body = @app.call(env)
        headers[HEADER] = VALUE if Demo.enabled?
        [status, headers, body]
      end
    end
  end
end
