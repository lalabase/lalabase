# frozen_string_literal: true

ENV['DISABLE_SPRING'] = 'true'

require_relative 'boot'

require 'rails/all'

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Lalabase
  PRODUCT_NAME = 'Lalabase'

  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 7.2

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Set default locale to German
    config.i18n.default_locale = :de
    config.i18n.available_locales = %i[de en]

    # Host authorization: in development we allow everything,
    # in production it is restricted in config/environments/production.rb.
    # Solid Queue is the only job backend (all environments; Sidekiq removed 2026-06)
    config.active_job.queue_adapter = :solid_queue

    # Mails are delivered through our own job, which keeps its arguments out of
    # the log: Devise hands the raw token over as an argument, and ActiveJob
    # logs arguments at INFO (see app/jobs/mail_delivery_job.rb).
    config.action_mailer.delivery_job = 'MailDeliveryJob'
    config.active_storage.replace_on_assign_to_many = true
    config.active_storage.queues.purge = :default

    # Durable protection against leaked file links: signed blob/representation URLs
    # (rails_blob_path & co.) NEVER expired by default — a leaked link would open
    # the file forever. With an expiry date a leaked link dies after minutes.
    # The API/MCP path passes its own (shorter) expires_in and is unaffected.
    config.active_storage.urls_expire_in = 15.minutes

    # BMP, ICO and PSD reach libvips only through its ImageMagick delegation. Our own libvips
    # build carries no magick, and Rails 8.0.5.1 blocks the delegation as untrusted anyway
    # (CVE-2026-66066). Listing them as variable would keep promising a variant that can no
    # longer be produced: every request for one raises Vips::Error instead of falling back to
    # the original. Guard: spec/config/active_storage_variable_content_types_spec.rb
    config.active_storage.variable_content_types -= %w[
      image/bmp
      image/vnd.microsoft.icon
      image/vnd.adobe.photoshop
    ]

    # Actors::BaseActor behaviour on an UNEXPECTED error (not a domain/validation
    # failure): re-raise to fail loudly, or log + return a failure Result.
    # Default mirrors the historical hardcoded rule (re-raise outside production).
    # Lifted to config so the decision is explicit and a single environment can
    # override it — e.g. staging.rb may set this to false to behave like prod.
    config.x.actors.reraise_unexpected = !Rails.env.production?

    config.autoload_paths += %W[#{config.root}/app/controllers]

    # ViewComponent configuration
    config.view_component.previews.paths << "#{Rails.root.join('spec/components/previews')}"
  end
end
