# frozen_string_literal: true

require 'rails_helper'

# CVE-2026-40295 (GHSA-jp94-3292-c3xv). With :timeoutable on, Devise's FailureApp answered a
# non-GET request that arrived after the session had timed out with a redirect to the raw
# Referer header, and the Referer is whatever the sender says it is. A page with an
# auto-submitting cross-origin form could send a visitor with an expired session anywhere.
# Rails' own open-redirect guard never sees this: the FailureApp is a separate
# ActionController::Metal app with its own copy of that setting. devise 5.0.4 strips scheme
# and host the way store_location_for always did; this spec pins that we stay on our host.
RSpec.describe 'Session timeout redirect', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }

  before do
    sign_in user
    # Any signed-in request records last_request_at; the timeout is measured from it.
    get session_touch_path, headers: { 'Accept' => 'application/json' }
    expect(response).to have_http_status(:ok)
  end

  it 'stays on our host when the timed-out request is a POST with a foreign Referer' do
    travel_to(Time.current + user.timeout_in + 1.minute) do
      patch user_registration_path,
            params: { user: { first_name: 'Nobody' } },
            headers: { 'Referer' => 'https://evil.example/phish?x=1' }
    end

    expect(response).to have_http_status(:redirect)
    target = URI.parse(response.location)
    expect(target.host).to eq(request.host)
    expect(target.path).to eq('/phish')
  end
end
