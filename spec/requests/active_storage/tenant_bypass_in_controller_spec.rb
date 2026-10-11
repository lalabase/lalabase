# frozen_string_literal: true

require 'rails_helper'

# What:  The ActiveStorage tenant bypass reaches the controller thread-locally and
#        never flips the process-wide require_tenant switch.
# Type:  Request spec (security guard, 2026-08-23).
# Why:   spec/middleware/active_storage_tenant_bypass_spec.rb drives the middleware with a
#        lambda app and was green while the bypass was dead in production: the middleware
#        sat BEFORE ActionDispatch::Executor, which resets every CurrentAttributes
#        (ActsAsTenant stores `unscoped` there) on entering the request. The only thing
#        that kept /rails/active_storage alive was the process-wide
#        `configuration.require_tenant = false` in active_storage_tenant_patch.rb, the
#        exact race the middleware claims to have fixed (spike plan E4, second review
#        finding 1). This spec measures inside a real controller action, where it counts.
RSpec.describe 'ActiveStorage tenant bypass inside the controller', type: :request do
  let(:path) { '/rails/active_storage/direct_uploads' }
  let(:json_headers) { { 'Content-Type' => 'application/json', 'Accept' => 'application/json' } }
  let(:payload) do
    { blob: { filename: 'shot.png', byte_size: 5, checksum: 'XUFAKrxLKna5cZ2REBfFkg==',
              content_type: 'image/png' } }.to_json
  end

  before { sign_in create(:user) }

  # Observes tenant state at the moment the controller does its work.
  def observe_inside_action
    seen = {}
    allow(ActiveStorage::Blob).to receive(:create_before_direct_upload!).and_wrap_original do |m, **args|
      seen[:unscoped] = ActsAsTenant.unscoped?
      seen[:require_tenant] = ActsAsTenant.configuration.require_tenant
      seen[:other_thread_require_tenant] = Thread.new { ActsAsTenant.configuration.require_tenant }.value
      seen[:tenant_query] = Project.count # would raise NoTenantSet without a working bypass
      m.call(**args)
    end
    post path, params: payload, headers: json_headers
    expect(response).to have_http_status(:ok)
    seen
  end

  it 'lifts the tenant requirement thread-locally where the controller runs' do
    expect(observe_inside_action[:unscoped]).to be(true)
  end

  it 'never flips the process-wide require_tenant switch, not even for the request itself' do
    expect(observe_inside_action[:require_tenant]).to be(true)
  end

  it 'leaves parallel threads under the tenant requirement while the request runs' do
    expect(observe_inside_action[:other_thread_require_tenant]).to be(true)
  end

  it 'still lets the controller read tenant-scoped models without a tenant' do
    expect(observe_inside_action[:tenant_query]).to be_an(Integer)
  end

  it 'leaves the configuration untouched after the request' do
    observe_inside_action
    expect(ActsAsTenant.configuration.require_tenant).to be(true)
    expect(ActsAsTenant.unscoped?).to be_falsey
  end
end
