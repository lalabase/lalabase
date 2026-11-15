# frozen_string_literal: true

require 'rails_helper'

# Where the logo in the sidebar leads. With two or more organisations it is the start of
# the level above them, the inbox above the organisations (user, 2026-11-14; navigation
# plan D8, ApplicationController#level_home_path); with one it stays that organisation's
# start page, because a cockpit of one tile is a detour.
RSpec.describe 'The logo in the sidebar', type: :request do
  let(:user) { create(:user) }
  let(:first_org) { create(:organisation) }

  def member_of(organisation)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation,
                          role: create(:admin_role, organisation: organisation), active: true)
    end
  end

  def brand_link_href
    Nokogiri::HTML(response.body).at_css('a[data-brand-link]')&.[]('href')
  end

  before do
    member_of(first_org)
    sign_in user
  end

  it 'leads to the inbox above the organisations from a page of an organisation, for someone in two' do
    member_of(create(:organisation))

    get organisation_root_path(organisation_id: first_org.id)

    expect(brand_link_href).to eq(all_inboxes_path)
  end

  it 'leads to the inbox above the organisations from the cockpit, for someone in two' do
    member_of(create(:organisation))

    get select_organisation_path

    expect(response).to have_http_status(:ok)
    expect(brand_link_href).to eq(all_inboxes_path)
  end

  it 'stays on the organisation start page for someone in one organisation' do
    get organisation_root_path(organisation_id: first_org.id)

    expect(brand_link_href).to eq(organisation_root_path(organisation_id: first_org.id))
  end

  it 'counts only active memberships' do
    other = create(:organisation)
    ActsAsTenant.with_tenant(other) do
      create(:membership, user: user, organisation: other,
                          role: create(:admin_role, organisation: other), active: false)
    end

    get organisation_root_path(organisation_id: first_org.id)

    expect(brand_link_href).to eq(organisation_root_path(organisation_id: first_org.id))
  end

  it 'leads to the inbox above the organisations from the account area as well' do
    member_of(create(:organisation))

    get edit_user_registration_path

    expect(brand_link_href).to eq(all_inboxes_path)
  end
end

# Signed out, no page renders the application layout, so the rule is asked directly.
RSpec.describe NavigationHelper, type: :helper do
  it 'leads the logo to the root for a visitor who is not signed in' do
    allow(helper).to receive(:user_signed_in?).and_return(false)

    expect(helper.brand_link_path).to eq(root_path)
  end
end
