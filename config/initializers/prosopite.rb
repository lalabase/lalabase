# frozen_string_literal: true

if Rails.env.development? || Rails.env.test?
  require 'prosopite'

  Prosopite.min_n_queries = 2 # From 2 identical queries onward → N+1 detected
  Prosopite.ignore_queries = [
    /pg_type/,              # PostgreSQL internal queries
    /schema_migrations/,    # Rails schema queries
    /pg_advisory/,          # Advisory locks are not data queries
    /pg_try_advisory/,      # Try variant of the advisory locks
    /solid_queue_jobs/,     # Solid Queue framework-internal job queries (perform_later)
    /SELECT 1 AS one FROM "organisations" INNER JOIN "memberships"/, # acts_as_tenant validation
    /active_storage_attachments/ # ActiveStorage per-record attachment queries (inherent to attach/purge)
  ]

  if Rails.env.development?
    Prosopite.raise = false
    # log/ does not necessarily exist on fresh checkouts/CI runners → ensure it does,
    # otherwise the boot dies (e.g. `rails importmap:auto_pin` in CI) with Errno::ENOENT.
    log_path = Rails.root.join('log/prosopite.log')
    log_path.dirname.mkpath
    Prosopite.prosopite_logger = Logger.new(log_path)

    # Scan per request so that N+1s in a browser session end up in log/prosopite.log.
    require 'prosopite/middleware/rack'
    Rails.application.config.middleware.use Prosopite::Middleware::Rack
  end

  Prosopite.raise = true if Rails.env.test?
end
