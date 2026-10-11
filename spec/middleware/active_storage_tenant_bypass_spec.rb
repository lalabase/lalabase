# frozen_string_literal: true

require 'rails_helper'

# Regression guard for the ActiveStorageTenantBypass middleware
# (config/initializers/acts_as_tenant.rb).
#
# Historical bug: For bypass paths, the middleware set the GLOBAL flag
# `ActsAsTenant.configuration.require_tenant = false` and reset it after the
# request. On a multi-threaded server (Puma), the tenant requirement was thus
# disabled for ALL threads running in parallel as long as any
# ActiveStorage request was running — a race that sporadically lifts the app's
# central isolation guarantee. The bypass must take effect thread-locally
# (ActsAsTenant.without_tenant), never via global state.
#
# Limits of this file: it drives the middleware with a lambda app, so it proves the
# middleware in isolation and nothing about what reaches a controller. Until
# 2026-08-23 it was green while the bypass was dead in production (inserted before
# ActionDispatch::Executor, whose CurrentAttributes reset wiped it). The placement is
# pinned below; what the controller actually sees is measured in
# spec/requests/active_storage/tenant_bypass_in_controller_spec.rb.
RSpec.describe ActiveStorageTenantBypass do
  let(:organisation) { create(:organisation) }

  def env_for(path)
    { 'PATH_INFO' => path }
  end

  def middleware_with(app)
    described_class.new(app)
  end

  describe 'Platz im Middleware-Stack' do
    # ActionDispatch::Executor resets every CurrentAttributes on entering the request,
    # and ActsAsTenant stores `unscoped` there. Before the Executor this middleware sets
    # a flag that is gone before any controller code runs.
    it 'sitzt hinter ActionDispatch::Executor, sonst löscht dessen Reset den Bypass' do
      stack = Rails.application.middleware.map(&:klass)

      expect(stack.index(described_class)).to be > stack.index(ActionDispatch::Executor)
    end
  end

  describe 'Bypass-Pfad (/rails/active_storage)' do
    it 'erlaubt tenant-lose Queries auf tenanted Models' do
      app = ->(_env) { [200, {}, [Project.count.to_s]] }

      expect do
        middleware_with(app).call(env_for('/rails/active_storage/blobs/abc'))
      end.not_to raise_error
    end

    it 'lässt die Tenant-Pflicht anderer Threads unangetastet (kein globaler Flag-Flip)' do
      # Core of the race bug: While the bypass request is running, ANOTHER
      # thread (= parallel request) must not lose the require_tenant
      # enforcement. The global config flip broke exactly that.
      require_tenant_seen_by_other_thread = nil

      app = lambda do |_env|
        require_tenant_seen_by_other_thread =
          Thread.new { ActsAsTenant.configuration.require_tenant }.value
        [200, {}, ['ok']]
      end

      middleware_with(app).call(env_for('/rails/active_storage/blobs/abc'))

      expect(require_tenant_seen_by_other_thread).to be(true)
    end

    it 'stellt den Tenant des aufrufenden Threads nach dem Request wieder her' do
      ActsAsTenant.current_tenant = organisation
      app = ->(_env) { [200, {}, ['ok']] }

      middleware_with(app).call(env_for('/rails/active_storage/blobs/abc'))

      expect(ActsAsTenant.current_tenant).to eq(organisation)
    ensure
      ActsAsTenant.current_tenant = nil
    end

    it 'lässt die globale require_tenant-Konfiguration nach dem Request unverändert' do
      app = ->(_env) { [200, {}, ['ok']] }

      middleware_with(app).call(env_for('/rails/active_storage/blobs/abc'))

      expect(ActsAsTenant.configuration.require_tenant).to be(true)
    end
  end

  describe 'normaler Pfad (kein Bypass)' do
    it 'erzwingt die Tenant-Pflicht weiterhin' do
      app = ->(_env) { [200, {}, [Project.count.to_s]] }

      expect do
        middleware_with(app).call(env_for('/organisations'))
      end.to raise_error(ActsAsTenant::Errors::NoTenantSet)
    end
  end
end
