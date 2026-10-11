# config/environments/staging.rb
# frozen_string_literal: true

require 'active_support/core_ext/integer/time'
require 'dotenv'

Dotenv.load('.env', '.env.staging')

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot. This eager loads most of Rails and
  # your application in memory, allowing both threaded web servers
  # and those relying on copy on write to perform better.
  # Rake tasks automatically ignore this option for performance.
  config.eager_load = true

  # Full error reports are disabled and caching is turned on.
  config.consider_all_requests_local = false
  config.action_controller.perform_caching = true

  # Ensures that a master key has been made available in ENV["RAILS_MASTER_KEY"], config/master.key, or an environment
  # key such as config/credentials/production.key. This key is used to decrypt credentials (and other encrypted files).
  # config.require_master_key = true # Should normally be active in staging/production!

  # Disable serving static files from `public/`, relying on NGINX/Apache to do so instead.
  # Enable serving static files from public/ directory
  # This is critical for serving precompiled assets in staging
  config.public_file_server.enabled = true

  # Compress CSS using a preprocessor.
  # config.assets.css_compressor = :sass # Often handled via sassc-rails or cssbundling

  # Staging asset configuration optimized for Importmaps
  config.assets.compile = false    # Disable on-demand compilation (production-like)
  config.assets.digest = true      # Enable fingerprinting for security and caching

  # Enable static file serving in staging (Rails handles assets if NGINX doesn't)
  config.public_file_server.enabled = ENV['RAILS_SERVE_STATIC_FILES'].present? || true

  # Ensure Rails handles all asset requests, including controllers/
  config.public_file_server.headers = {
    'Cache-Control' => 'public, max-age=31557600', # 1 year
    'Expires' => 1.year.from_now.to_formatted_s(:rfc822)
  }
  config.assets.css_compressor = nil
  # config.assets.manifest = Rails.root.join('config', 'manifest.json') # Only needed for older Sprockets versions or special setups
  # config.assets.css_compressor = nil # Often handled via sassc-rails or cssbundling

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Specifies the header that your server uses for sending files.
  # config.action_dispatch.x_sendfile_header = "X-Sendfile" # for Apache
  config.action_dispatch.x_sendfile_header = 'X-Accel-Redirect' # for NGINX

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Mount Action Cable outside main process or domain.
  # config.action_cable.mount_path = nil
  # For staging server - configure ActionCable URL and allowed origins
  config.action_cable.url = 'wss://stage.lalabase.com/cable'
  config.action_cable.allowed_request_origins = [
    'https://stage.lalabase.com',
    'http://stage.lalabase.com',
    %r{https?://stage\.lalabase\.com}
  ]

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  # Can be used together with config.force_ssl for Strict-Transport-Security and secure cookies.
  # config.assume_ssl = true # Only enable when needed and understood

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == '/up' } } } # Useful when the health check runs over HTTP

  # Log to STDOUT by default -- COMMENTED OUT to enable file logging
  # config.logger = ActiveSupport::Logger.new($stdout)
  #                          .tap  { |logger| logger.formatter = ::Logger::Formatter.new }
  #                          .then { |logger| ActiveSupport::TaggedLogging.new(logger) }

  # Prepend all log lines with the following tags.
  config.log_tags = [:request_id]

  # "info" includes generic and useful information about system operation, but avoids logging too much
  # information to avoid inadvertent exposure of personally identifiable information (PII). If you
  # want to log everything, set the level to "debug".
  config.log_level = :debug # Changed from :debug to :info (more common for staging)
  logger = ActiveSupport::Logger.new(Rails.root.join('log/staging.log'), 1, 50.megabytes)
  logger.formatter = config.log_formatter
  config.logger = ActiveSupport::TaggedLogging.new(logger)

  # Use a different cache store in production.
  # config.cache_store = :mem_cache_store
  # Example:
  config.cache_store = :redis_cache_store, { url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/1') }

  # Use a real queuing backend for Active Job, mirroring production. Solid Queue
  # runs on the primary database: the queue connection is pinned to :primary in
  # config/initializers/solid_queue.rb (which Rails loads after this file), and
  # there is no separate :queue database in config/database.yml. A worker still
  # has to run (SOLID_QUEUE_IN_PUMA=1 in .env or a dedicated process).
  config.active_job.queue_adapter = :solid_queue
  # config.active_job.queue_name_prefix = "lalabase_staging" # Adjust if needed

  # Disable caching for Action Mailer templates even if Action Controller
  # caching is enabled.
  config.action_mailer.perform_caching = false

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  config.action_mailer.raise_delivery_errors = true # Or true, if desired

  # Configure default URL options for ActionMailer
  config.action_mailer.default_url_options = { host: 'stage.lalabase.com', protocol: 'https' }

  # Configure mail delivery method
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.perform_deliveries = true

  # SMTP configuration
  #
  # IONOS fallbacks, in this order, if delivery over smtp.ionos.de:587 fails.
  # (Rescued from config/environments/production_ionos_fix.rb, a file Rails never loaded
  # — it was a scratch note in config clothing. These three values existed nowhere else.)
  #   1. authentication: 'login' instead of 'plain' — IONOS does not always accept PLAIN.
  #   2. additionally openssl_verify_mode: 'none'.
  #   3. last resort only: port 465 with ssl: true, tls: false instead of 587/STARTTLS.
  #      Counter-experience on record: 587/STARTTLS is the standard, 465 is often blocked
  #      (docs/letzte_arbeiten/2025_09_04_01_letzte_arbeiten_email_notifications_fix.md).
  config.action_mailer.smtp_settings = {
    address: ENV['SMTP_ADDRESS'] || 'smtp.ionos.de',
    port: (ENV['SMTP_PORT'] || 587).to_i,
    domain: ENV['SMTP_DOMAIN'] || 'example.com',
    user_name: ENV['SMTP_USERNAME'] || 'noreply@example.com',
    # No password in the code, the same as production.rb. There used to be a
    # literal fallback here, and this repository is about to be published: a
    # secret in a public tree cannot be taken back. Without SMTP_PASSWORD in the
    # environment, sending fails with an authentication error in the log, and the
    # application still boots -- a missing mail password must not take it down.
    password: ENV.fetch('SMTP_PASSWORD', ''),
    authentication: 'plain',
    enable_starttls_auto: true
  }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Enable DNS rebinding protection and other `Host` header attacks.
  # See https://guides.rubyonrails.org/configuring.html#config-hosts
  # Add your allowed hosts here if needed. Important for security!
  # config.hosts = [
  #   "stage.lalabase.com", # Your domain
  #   IPAddr.new("10.0.0.2"), # Your server IP (optional, if needed)
  #   IPAddr.new("127.0.0.1"), # localhost
  #   IPAddr.new("::1") # localhost IPv6
  # ]
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
