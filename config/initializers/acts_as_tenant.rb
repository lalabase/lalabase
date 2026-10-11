# frozen_string_literal: true

ActsAsTenant.configure do |config|
  config.require_tenant = true
end

# Create a middleware to handle ActiveStorage requests
# This ensures ActiveStorage operations don't fail due to missing tenant
class ActiveStorageTenantBypass
  def initialize(app)
    @app = app
  end

  def call(env)
    if bypass_tenant_check?(env['PATH_INFO'])
      # Lift it THREAD-LOCALLY, never via ActsAsTenant.configuration.require_tenant:
      # that config flag is process-wide state — toggling it per request, on
      # multi-threaded Puma, suspended the tenant requirement for ALL parallel
      # requests (race). without_tenant uses CurrentAttributes and is scoped to the
      # current thread (guard: spec/middleware/active_storage_tenant_bypass_spec.rb).
      ActsAsTenant.without_tenant { @app.call(env) }
    else
      @app.call(env)
    end
  end

  private

  def bypass_tenant_check?(path)
    path.start_with?('/rails/active_storage')
  end
end

# AFTER ActionDispatch::Executor, never before it: the Executor resets every
# CurrentAttributes on entering the request, and without_tenant stores its
# `unscoped` flag in ActsAsTenant::Current. Inserted before the Executor (as it
# was until 2026-08-23) the bypass was wiped before the first line of controller
# code and only the process-wide switch in active_storage_tenant_patch.rb kept
# these requests alive. Guard: spec/requests/active_storage/tenant_bypass_in_controller_spec.rb
Rails.application.config.middleware.insert_after(ActionDispatch::Executor, ActiveStorageTenantBypass)
