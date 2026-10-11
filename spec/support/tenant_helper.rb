# frozen_string_literal: true

# Helper module for working with multi-tenancy in tests
module TenantHelper
  # Sets up tenant context for a test
  def set_tenant(organisation)
    ActsAsTenant.current_tenant = organisation
    # Also set the tenant in session for controllers
    session[:current_organisation_id] = organisation.id if respond_to?(:session)
  end

  # Clears tenant context
  def clear_tenant
    ActsAsTenant.current_tenant = nil
    session[:current_organisation_id] = nil if respond_to?(:session)
  end
end

RSpec.configure do |config|
  config.include TenantHelper

  # Reset tenancy between examples
  config.after(:each) do
    ActsAsTenant.current_tenant = nil
  end
end
