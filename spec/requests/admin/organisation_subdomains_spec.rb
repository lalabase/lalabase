# frozen_string_literal: true

require 'rails_helper'

# What: the instance admin sets the subdomain an organisation is shown under
#   (doc/org_subdomains_plan.md, S1, decided 2026-11-16: only the instance admin).
RSpec.describe 'Admin organisation subdomain', type: :request do
  let(:admin_beuser) { create(:beuser) }
  let(:organisation) { create(:organisation) }

  def log_in_admin
    post admin_log_in_path, params: { email: admin_beuser.email, password: admin_beuser.password }
    expect(response).to redirect_to(admin_dashboard_path)
  end

  context 'with organisation subdomains switched on' do
    before { allow(Organisations::Hosts).to receive(:parent_domain).and_return('example.test') }

    it 'shows the form with the current name' do
      OrganisationSubdomain.create!(organisation: organisation, subdomain: 'kunde')
      log_in_admin

      get admin_organisation_path(organisation)

      expect(response.body).to include('id="organisation-subdomain"')
      expect(response.body).to include('value="kunde"')
      expect(response.body).to include('kunde.example.test')
    end

    it 'sets the subdomain' do
      log_in_admin

      patch subdomain_admin_organisation_path(organisation), params: { organisation_subdomain: { subdomain: 'Kunde' } }

      expect(response).to redirect_to(admin_organisation_path(organisation))
      expect(organisation.reload.current_subdomain.subdomain).to eq('kunde')
    end

    it 'names the old name and the end of its hold after a change' do
      OrganisationSubdomain.create!(organisation: organisation, subdomain: 'alt')
      log_in_admin

      patch subdomain_admin_organisation_path(organisation), params: { organisation_subdomain: { subdomain: 'neu' } }
      follow_redirect!

      expect(response.body).to include('alt.example.test')
      expect(response.body).to include(I18n.l(OrganisationSubdomain.find_by!(subdomain: 'alt').held_until.to_date))
    end

    it 'refuses a reserved name and says why' do
      log_in_admin

      patch subdomain_admin_organisation_path(organisation), params: { organisation_subdomain: { subdomain: 'admin' } }
      follow_redirect!

      expect(organisation.reload.current_subdomain).to be_nil
      expect(response.body).to include(CGI.escapeHTML(I18n.t('activerecord.errors.models.organisation_subdomain.attributes.subdomain.exclusion')))
    end

    it 'is closed without an admin session' do
      patch subdomain_admin_organisation_path(organisation), params: { organisation_subdomain: { subdomain: 'kunde' } }

      expect(organisation.reload.current_subdomain).to be_nil
    end

    it 'is closed to a signed-in member of the organisation' do
      user = create(:user)
      ActsAsTenant.with_tenant(organisation) { create(:membership, user: user, organisation: organisation, active: true) }
      sign_in user

      patch subdomain_admin_organisation_path(organisation), params: { organisation_subdomain: { subdomain: 'kunde' } }

      expect(organisation.reload.current_subdomain).to be_nil
    end
  end

  it 'says the feature is off and offers no form while no tenant domain is set' do
    allow(Organisations::Hosts).to receive(:parent_domain).and_return(nil)
    log_in_admin

    get admin_organisation_path(organisation)

    expect(response.body).to include('id="organisation-subdomain"')
    expect(response.body).not_to include('name="organisation_subdomain[subdomain]"')
  end
end
