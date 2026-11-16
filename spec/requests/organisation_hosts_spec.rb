# frozen_string_literal: true

require 'rails_helper'

# What: organisation subdomains at the door (doc/org_subdomains_plan.md, S2). The gate
#   answers unknown and old subdomains and keeps the main host's doors off an
#   organisation's host; a full page of an organisation moves to its host.
# Why (binding): the host never grants access. A page of an organisation moves to its host
#   only for an active member of it; anyone else gets what they got before, on whatever
#   host they asked, and learns no subdomain.
RSpec.describe 'Organisation hosts', :ci_guard, type: :request do
  let(:domain) { 'example.test' }
  let(:user) { create(:user) }
  let(:org_with_host) { create(:organisation) }
  let(:org_without_host) { create(:organisation) }

  before do
    ActsAsTenant.current_tenant = nil
    allow(Organisations::Hosts).to receive(:parent_domain).and_return(domain)
    OrganisationSubdomain.create!(organisation: org_with_host, subdomain: 'kunde')
  end

  # Setup, not a request: one membership per organisation, each loading its own
  # organisation, is not an N+1 of the code under test.
  def member_of(*organisations, person: user)
    Prosopite.pause do
      organisations.each do |org|
        ActsAsTenant.with_tenant(org) { create(:membership, user: person, organisation: org, active: true) }
      end
    end
  end

  describe 'the gate' do
    it 'answers an unknown subdomain with 404' do
      host! "niemand.#{domain}"
      get '/'

      expect(response).to have_http_status(:not_found)
    end

    it 'answers a host two labels deep with 404' do
      host! "a.kunde.#{domain}"
      get '/'

      expect(response).to have_http_status(:not_found)
    end

    it 'answers an expired hold like an unknown name' do
      OrganisationSubdomain.create!(organisation: org_with_host, subdomain: 'uralt', held_until: 1.minute.ago)
      host! "uralt.#{domain}"
      get '/'

      expect(response).to have_http_status(:not_found)
    end

    context 'with an old name the organisation still holds' do
      before do
        OrganisationSubdomain.create!(organisation: org_with_host, subdomain: 'alt', held_until: 30.days.from_now)
        host! "alt.#{domain}"
      end

      it 'sends a GET to the same path on the current host' do
        get '/org/x/tickets?view=list'

        expect(response).to have_http_status(:found)
        expect(response.location).to eq("http://kunde.#{domain}/org/x/tickets?view=list")
      end

      it 'answers anything but GET and HEAD with 404' do
        post '/users/sign_in', params: { user: { email: 'a@example.com', password: 'x' } }

        expect(response).to have_http_status(:not_found)
      end

      it 'sends a GET to the main host once the organisation has no subdomain' do
        OrganisationSubdomain.where(subdomain: 'kunde').delete_all
        get '/x'

        expect(response.location).to eq("http://#{domain}/x")
      end
    end

    %w[/api/v1/me /api/mcp /admin /admin/login /webhooks/email /up].each do |path|
      it "keeps #{path} of the main host off an organisation's host" do
        host! "kunde.#{domain}"
        get path

        expect(response).to have_http_status(:not_found)
      end
    end

    it 'leaves the main host alone' do
      host! domain
      get '/up'

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'the page of an organisation' do
    it "moves to the organisation's host for an active member" do
      member_of(org_with_host)
      sign_in user
      host! domain

      get organisation_root_path(org_with_host, tab: 'x')

      expect(response).to have_http_status(:found)
      expect(response.location).to eq("http://kunde.#{domain}#{organisation_root_path(org_with_host, tab: 'x')}")
    end

    it 'moves to the main host when its organisation has no subdomain' do
      member_of(org_with_host, org_without_host)
      sign_in user
      host! "kunde.#{domain}"

      get organisation_root_path(org_without_host)

      expect(response.location).to eq("http://#{domain}#{organisation_root_path(org_without_host)}")
    end

    it 'stays where it is on its own host' do
      member_of(org_with_host)
      sign_in user
      host! "kunde.#{domain}"

      get organisation_root_path(org_with_host)

      expect(response).to have_http_status(:ok)
    end

    it 'does not move a frame or a stream' do
      member_of(org_with_host)
      sign_in user
      host! domain

      get organisation_root_path(org_with_host), headers: { 'Turbo-Frame' => 'content' }
      expect(response).to have_http_status(:ok)

      # The page has no stream format: what matters is that it answers here.
      get organisation_root_path(org_with_host), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      expect(response).not_to have_http_status(:found)
    end

    it 'tells no subdomain to someone who is not a member' do
      member_of(org_without_host)
      sign_in user
      host! domain

      get organisation_root_path(org_with_host)

      expect(response.location).to eq("http://#{domain}#{select_organisation_path}")
    end

    it 'tells no subdomain to a member whose membership is switched off' do
      ActsAsTenant.with_tenant(org_with_host) do
        create(:membership, user: user, organisation: org_with_host, active: false)
      end
      member_of(org_without_host)
      sign_in user
      host! domain

      get organisation_root_path(org_with_host)

      expect(response.location).to eq("http://#{domain}#{select_organisation_path}")
    end

    it "gives a non-member on an organisation's host nothing of that organisation" do
      member_of(org_without_host)
      sign_in user
      host! "kunde.#{domain}"

      get '/'

      expect(response.location).to eq("http://kunde.#{domain}#{organisation_root_path(org_without_host)}")
    end

    it 'does nothing while organisation subdomains are off' do
      allow(Organisations::Hosts).to receive(:parent_domain).and_return(nil)
      member_of(org_with_host)
      sign_in user
      host! domain

      get organisation_root_path(org_with_host)

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'the start of a session on an organisation host' do
    it "opens the host's organisation, not the person's first one" do
      member_of(org_without_host, org_with_host)
      sign_in user
      host! "kunde.#{domain}"

      get '/'

      expect(response.location).to end_with(organisation_root_path(org_with_host))
    end
  end
end
