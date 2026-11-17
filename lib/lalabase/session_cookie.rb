# frozen_string_literal: true

module Lalabase
  # The options of the application's session cookie (doc/org_subdomains_plan.md, S3).
  #
  # Host-only, as Rails makes it, so an organisation host and the main host each keep a
  # session of their own. Under TLS it carries the __Host- prefix: a browser refuses such a
  # cookie when it names a domain, so no other host below the same domain (stage, demo,
  # stats, any organisation's host) can plant one that the main host would read as its own.
  # Named per environment, so production and staging never read each other's cookie.
  #
  # Plain Ruby, read by config/initializers/session_store.rb; pinned by
  # spec/lib/lalabase/session_cookie_spec.rb.
  module SessionCookie
    def self.options(rails_env:, secure:)
      name = "lalabase_#{rails_env}_session"
      { key: secure ? "__Host-#{name}" : "_#{name}", secure: secure, same_site: :lax }
    end
  end
end
