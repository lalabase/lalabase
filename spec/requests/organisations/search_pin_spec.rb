# frozen_string_literal: true

require 'rails_helper'

# Stage 2b: toggling the per-user, per-org "pin global search as a persistent inline bar"
# preference. Trivial single write that re-renders the "Suche" nav item (#global-search-nav)
# via Turbo Stream so the inline bar appears/disappears in place.
RSpec.describe 'Organisations::SearchPins', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }

  before do
    ActsAsTenant.current_tenant = organisation
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    end
    sign_in user
  end

  def patch_pin(headers = { 'Accept' => 'text/vnd.turbo-stream.html' })
    patch organisation_search_pin_path(organisation_id: organisation.id), headers: headers
  end

  it 'toggles the search pin on and off for the user + org' do
    patch_pin
    expect(response).to have_http_status(:ok)
    expect(user.reload.sidebar_pins.global_pinned?(organisation, 'search')).to be true

    patch_pin
    expect(user.reload.sidebar_pins.global_pinned?(organisation, 'search')).to be false
  end

  # Whole-chain probe: the pin written to JSONB must come back out through the
  # partial (pinned => inline bar + unpin label) in the SAME turbo_stream response.
  it 'replaces the search nav item and renders the pinned inline bar' do
    patch_pin

    expect(response.media_type).to eq('text/vnd.turbo-stream.html')
    expect(response.body).to include('global-search-nav')
    expect(response.body).to include('global-search-inline-bar')
    expect(response.body).to include(I18n.t('navigation.unpin_search', locale: :de))
  end

  it 'isolates the pin per organisation' do
    other_org = create(:organisation)
    ActsAsTenant.with_tenant(other_org) do
      create(:membership, user: user, organisation: other_org,
                          role: create(:admin_role, organisation: other_org), active: true)
    end

    patch_pin

    expect(user.reload.sidebar_pins.global_pinned?(organisation, 'search')).to be true
    expect(user.sidebar_pins.global_pinned?(other_org, 'search')).to be false
  end

  it 'redirects to the organisation root for plain HTML requests' do
    patch organisation_search_pin_path(organisation_id: organisation.id)

    expect(response).to redirect_to(organisation_root_path(organisation_id: organisation.id))
    expect(user.reload.sidebar_pins.global_pinned?(organisation, 'search')).to be true
  end

  it 'forbids toggling for a user without search access (gate)' do
    viewer = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: viewer, organisation: organisation,
                          role: create(:role, organisation: organisation, title: 'no_access'), active: true)
    end
    sign_in viewer

    patch_pin

    expect(response).to have_http_status(:forbidden)
    expect(viewer.reload.sidebar_pins.global_pinned?(organisation, 'search')).to be false
  end
end
