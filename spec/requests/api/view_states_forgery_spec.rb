# frozen_string_literal: true

require 'rails_helper'

# /api/view_states answers a signed-in browser through its session cookie, so a
# write needs the page's authenticity token like every other session write.
# Until 2026-11-20 the controller skipped the check whenever the format was
# JSON, and the format comes from the address: a form on another site that
# posted to /api/view_states/<key>.json (with _method=patch) wrote into the
# victim's view state. CodeQL alert rb/csrf-protection-disabled.
#
# Request specs run with forgery protection off; it is switched on here. The
# control sends the same request WITH the page's token and goes through, so
# the refusal cannot come from anything but the token.
RSpec.describe 'Api::ViewStates: forgery protection', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  around do |example|
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  before do
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, organisation: organisation, title: 'account_admin')
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    sign_in user
    get organisation_projects_path(organisation)
    follow_redirect! while response.redirect?
    expect(response).to have_http_status(:ok)
  end

  def page_token
    Nokogiri::HTML(response.body).at('meta[name="csrf-token"]')&.[]('content').tap do |token|
      expect(token).to be_present
    end
  end

  def stored_state
    ActsAsTenant.without_tenant { ViewState.find_by(user: user, key: 'sidebar')&.state }
  end

  it 'refuses a JSON write without a token' do
    patch '/api/view_states/sidebar.json', params: { state: { collapsed: 'true' } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(stored_state).to be_nil
  end

  it 'takes the same write with the page token' do
    token = page_token
    patch '/api/view_states/sidebar.json', params: { state: { collapsed: 'true' } },
                                           headers: { 'X-CSRF-Token' => token }

    expect(response).to have_http_status(:ok)
    expect(stored_state).to eq('collapsed' => 'true')
  end
end
