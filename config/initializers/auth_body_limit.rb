# frozen_string_literal: true

# The body limit of the sign-in door of clients (/api/auth/), in front of
# Rack::MethodOverride like the provisioning limit and for the same reason: it
# is the first middleware that reads a body. Limit and reason:
# Lalabase::AuthBodyLimit.
require 'lalabase/auth_body_limit'
Rails.application.config.middleware.insert_before(Rack::MethodOverride, Lalabase::AuthBodyLimit)
