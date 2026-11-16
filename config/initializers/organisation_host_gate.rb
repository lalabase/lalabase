# frozen_string_literal: true

# Organisation subdomains (doc/org_subdomains_plan.md, S2): the gate answers unknown and
# old subdomains and keeps the main host's doors off an organisation's host. Behind the
# executor (it reads the database) and the host check, in front of the form parsing of
# Rack::MethodOverride, so a refused request costs no body parsing.
#
# Explicit require: initializers run before the autoloader serves lib/ (same as
# Lalabase::ProvisioningBodyLimit).
require 'lalabase/organisation_host_gate'
Rails.application.config.middleware.insert_before(Rack::MethodOverride, Lalabase::OrganisationHostGate)
