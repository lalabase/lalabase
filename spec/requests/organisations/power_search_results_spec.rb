# frozen_string_literal: true

require 'rails_helper'

# The search RESULTS page (power_search#index) carries an INLINE search form so the query
# and project scope can be refined and re-run in place — no detour back through the sidebar
# overlay. It reuses the shared `_global_search_form` partial, which prefills itself from
# params, so the current query stays visible (it matters most on a "no results" page).
RSpec.describe 'Power search results page', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
    get organisation_power_search_path(organisation_id: organisation.id, power_search_query: 'rechnung')
  end

  it 'renders an inline search form prefilled with the current query (refine in place)' do
    expect(response).to have_http_status(:ok)
    doc = Nokogiri::HTML(response.body)
    # Scope to <main>: the body-level overlay ALSO holds a power_search_query input, but the
    # point here is the visible inline form on the results page itself.
    input = doc.at_css('main input[name="power_search_query"]')
    expect(input).to be_present
    expect(input[:value]).to eq('rechnung')
  end

  it 'posts the inline search back to power_search so it re-runs in place' do
    doc = Nokogiri::HTML(response.body)
    form = doc.at_css('main form')
    expect(form).to be_present
    expect(form['action']).to eq(organisation_power_search_path(organisation_id: organisation.id))
    expect(form['method']).to eq('post')
  end
end
