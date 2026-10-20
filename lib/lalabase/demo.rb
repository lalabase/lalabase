# frozen_string_literal: true

module Lalabase
  # Demo mode: a public instance that anybody enters with one published login,
  # the signed-in person of the Nordlicht fiction (Lalabase::Demo::World).
  #
  # Off unless LALABASE_DEMO=1. Everything that changes in demo mode asks
  # enabled? when it runs, not at boot: the mail interceptor, the restrictions
  # (DemoRestrictions), the sign-in page, the banner, the lockout and the
  # per-address login throttle, the upload limits and budget, and the throttle on
  # everything that calls a model. An instance without the flag behaves as before.
  #
  # The nightly reset (Lalabase::Demo::Reset) needs a second latch, the marker
  # that `bin/rails lalabase:demo:setup` writes (Lalabase::Demo::Setup).
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
    # The hour (UTC) of the nightly reset (DemoResetJob). The banner reads it from
    # here; spec/config/recurring_schedule_spec.rb holds config/recurring.yml to it.
    RESET_HOUR_UTC = 3
    # The one language of the demo: the world is written in it (Lalabase::Demo::Reset),
    # and every page speaks it, whatever the browser, the address or a profile asks for
    # (ApplicationController#request_locale).
    LOCALE = :en
    # The second latch of the reset (Lalabase::Demo::Reset): a row in system_settings
    # that only `bin/rails lalabase:demo:setup` writes, and only on an instance
    # without organisations. The flag alone never empties a database.
    MARKER_KEY = 'demo_instance'
    # The largest request body a visitor may send, and what a direct upload may be.
    # Disk space on a public instance is shared by everybody, and the demo is no
    # file host. Plain numbers: config/puma.rb reads them before Rails is loaded.
    MAX_UPLOAD_BYTES = 5 * 1024 * 1024
    # What all stored files of the demo may add up to until the next reset. The
    # per-address throttles follow a header a client can set; this one cannot be
    # walked around.
    STORAGE_BUDGET_BYTES = 1024 * 1024 * 1024
    # A body above this size carries a file; below it, a form or a message.
    LARGE_BODY_BYTES = 64 * 1024
    UPLOAD_CONTENT_TYPES = %w[image/png image/jpeg image/gif image/webp application/pdf].freeze

    class << self
      def enabled?(env = ENV)
        env[ENV_FLAG].to_s.strip == ENABLED_VALUE
      end

      def login_email = Fiction.email(Fiction::SIGNED_IN)
      def login_name = Fiction.full_name(Fiction::SIGNED_IN)

      def published_login?(email)
        enabled? && email.is_a?(String) && email.strip.casecmp?(login_email)
      end

      def marked? = SystemSetting.exists?(key: MARKER_KEY)

      # Both latches: the flag and the marker. Asked by the reset itself, not only by
      # the job that schedules it.
      def resettable? = enabled? && marked?

      # Whether `adding` more bytes would take the stored files past the budget.
      def storage_full?(adding = 0)
        ActiveStorage::Blob.sum(:byte_size) + adding > STORAGE_BUDGET_BYTES
      end

      # The clock reads the same in both languages, so no locale format.
      def reset_time = format('%02d:00', RESET_HOUR_UTC)
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

    # Refuses a request body above MAX_UPLOAD_BYTES in demo mode, and any body that
    # carries a file once the stored files have reached STORAGE_BUDGET_BYTES. Covers
    # every way a file comes in: the byte channel of direct uploads, and the forms that
    # post a file themselves (documents, comment attachments).
    #
    # Puma has read the body by then (into a temporary file, and it turns a chunked
    # body into one with a length), so this is the answer, not the disk protection:
    # config/puma.rb sets the same limit for Puma itself in demo mode.
    class UploadLimit
      def initialize(app)
        @app = app
      end

      def call(env)
        return @app.call(env) unless Demo.enabled? && refused?(env['CONTENT_LENGTH'].to_i)

        [413, { 'content-type' => 'text/plain' }, ["Request too large for the demo.\n"]]
      end

      private

      def refused?(length)
        length > MAX_UPLOAD_BYTES || (length > LARGE_BODY_BYTES && Demo.storage_full?(length))
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
