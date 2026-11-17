# frozen_string_literal: true

require 'rails_helper'

# What: the login hand-off between the main host and an organisation host, walked with
#   real sign-ins and the per-host cookie jar of the test browser
#   (doc/org_subdomains_plan.md, S3).
# Why (binding): a person signs in on the main host only; the session reaches an
#   organisation host through a single-use token bound to that host and to the browser that
#   began it. A claim address opened in another browser signs nobody in (no login CSRF),
#   and signing out on one host ends the session on every host.
RSpec.describe 'Session hand-off between hosts', :ci_guard, type: :request do
  let(:domain) { 'example.test' }
  let(:org_host) { "kunde.#{domain}" }
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:org_page) { organisation_root_path(organisation) }

  before do
    ActsAsTenant.current_tenant = nil
    allow(Organisations::Hosts).to receive(:parent_domain).and_return(domain)
    OrganisationSubdomain.create!(organisation: organisation, subdomain: 'kunde')
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) { create(:membership, user: user, organisation: organisation, active: true) }
    end
  end

  def location_path
    URI(response.location).request_uri
  end

  def location_host
    URI(response.location).host
  end

  # The hand-off up to the claim address on the organisation host; signs in on the main
  # host on the way when the browser has no session there.
  def walk_to_claim(sign_in_on_main: true)
    host! org_host
    get org_page
    expect(response.location).to eq("http://#{org_host}#{session_handoff_start_path(to: org_page)}")

    follow_redirect!
    expect(location_host).to eq(domain)
    expect(location_path).to start_with('/session/handoff?')

    follow_redirect!
    if sign_in_on_main
      expect(response.location).to end_with(new_user_session_path)
      host! domain
      post user_session_path, params: { user: { email: user.email, password: 'password123' } }
      expect(location_path).to start_with('/session/handoff?')
      follow_redirect!
    end
    expect(location_host).to eq(org_host)
    expect(location_path).to start_with('/session/claim?token=')
    response.location
  end

  it 'carries the session from the main host to the organisation host' do
    claim_url = walk_to_claim

    get claim_url
    expect(response.location).to eq("http://#{org_host}#{org_page}")

    follow_redirect!
    expect(response).to have_http_status(:ok)
  end

  it 'needs no second sign-in when the main host has a session' do
    claim_url = walk_to_claim
    get claim_url

    # A second organisation host's page in the same browser: the main host still knows it.
    other = create(:organisation)
    OrganisationSubdomain.create!(organisation: other, subdomain: 'zweite')
    Prosopite.pause do
      ActsAsTenant.with_tenant(other) { create(:membership, user: user, organisation: other, active: true) }
    end
    host! "zweite.#{domain}"
    get organisation_root_path(other)
    follow_redirect!
    follow_redirect!

    expect(location_host).to eq("zweite.#{domain}")
    expect(location_path).to start_with('/session/claim?token=')
  end

  it 'signs nobody in when the claim address is opened in another browser' do
    claim_url = walk_to_claim

    victim = open_session
    victim.get claim_url
    expect(victim.response.location).to eq("http://#{domain}/")

    victim.host! org_host
    victim.get org_page
    expect(victim.response.location).to start_with("http://#{org_host}/session/start")
  end

  it 'counts a token once' do
    claim_url = walk_to_claim
    get claim_url
    delete destroy_user_session_path # ends the session made by the first claim

    get claim_url
    expect(response.location).to eq("http://#{domain}/")
  end

  it 'ends the session on every host when one host signs out' do
    get walk_to_claim
    host! org_host
    get org_page
    expect(response).to have_http_status(:ok)

    delete destroy_user_session_path

    host! domain
    get select_organisation_path
    expect(response.location).to end_with(new_user_session_path)
  end

  describe 'the steps on the wrong host' do
    it 'answers the start and the claim on the main host with 404' do
      host! domain
      get session_handoff_start_path(to: '/')
      expect(response).to have_http_status(:not_found)

      get session_claim_path(token: 'x')
      expect(response).to have_http_status(:not_found)
    end

    it 'mints no token on an organisation host' do
      sign_in user
      host! org_host

      # A page: it belongs to the main host and goes there.
      get session_handoff_path(target: org_host, to: '/', state: 'a' * 64)
      expect(location_host).to eq(domain)

      # Not a page (a script's request): refused where it is.
      get session_handoff_path(target: org_host, to: '/', state: 'a' * 64), xhr: true
      expect(response).to have_http_status(:not_found)
      expect(SessionHandoff.count).to eq(0)
    end

    it 'mints nothing for a host that is no organisation host' do
      sign_in user
      host! domain

      get session_handoff_path(target: 'evil.example', to: '/', state: 'a' * 64)
      expect(response).to have_http_status(:not_found)
      get session_handoff_path(target: "niemand.#{domain}", to: '/', state: 'a' * 64)
      expect(response).to have_http_status(:not_found)
      expect(SessionHandoff.count).to eq(0)
    end

    it 'mints nothing without a state digest' do
      sign_in user
      host! domain

      get session_handoff_path(target: org_host, to: '/', state: 'not-a-digest')
      expect(response).to have_http_status(:not_found)
      expect(SessionHandoff.count).to eq(0)
    end

    it 'turns an address into a path' do
      sign_in user
      host! domain
      get session_handoff_path(target: org_host, to: '//evil.example/x', state: 'a' * 64)

      expect(SessionHandoff.last.path).to eq('/')
    end

    it 'refuses HEAD for the token and the claim' do
      sign_in user
      host! domain
      head session_handoff_path(target: org_host, to: '/', state: 'a' * 64)
      expect(response).to have_http_status(:method_not_allowed)
      expect(SessionHandoff.count).to eq(0)
    end
  end

  describe 'the account pages on an organisation host' do
    before { host! org_host }

    it 'sends the sign-in form to the main host' do
      get new_user_session_path

      expect(response.location).to eq("http://#{domain}#{new_user_session_path}")
    end

    it 'refuses a sign-in posted there' do
      post user_session_path, params: { user: { email: user.email, password: 'password123' } }

      expect(response).to have_http_status(:not_found)
    end

    it 'sends a page above the organisations to the main host' do
      get select_organisation_path

      expect(response.location).to eq("http://#{domain}#{select_organisation_path}")
    end
  end
end
