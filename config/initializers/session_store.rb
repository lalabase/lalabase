# frozen_string_literal: true

# The session cookie of the application: host-only, __Host- under TLS, one name per
# environment (Lalabase::SessionCookie, doc/org_subdomains_plan.md S3). The new name signed
# everybody out once. The operator console sets its own name (Lalabase::OperatorConsole);
# this file leaves it alone.
#
# Explicit requires: initializers run before the autoloader serves lib/.
require 'lalabase/operator_console'
require 'lalabase/session_cookie'

unless Lalabase::OperatorConsole.enabled?
  Rails.application.config.session_store :cookie_store,
                                         **Lalabase::SessionCookie.options(
                                           rails_env: Rails.env, secure: Rails.application.config.force_ssl
                                         )
end
