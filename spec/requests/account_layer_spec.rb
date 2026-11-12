# frozen_string_literal: true

require 'rails_helper'

# The account layer (common/_account_layer, Belegungstabelle F47): on a page of an
# organisation, a click on the reader's name raises the pages of "Mein Konto" over the
# sidebar. Until 2026-11-12 the name opened a small menu of four entries, a second list
# of the account area that did not agree with the sidebar of an account page (no billing
# accounts, no API tokens, no way to the other organisations).
#
# What a request can hold: there is ONE list, the layer and the account page's sidebar
# show the same entries, the layer waits hidden beside what it covers, and the name is a
# link that works without a script. The opening, the slide and the keyboard are the
# browser's (spec/system/account_layer_spec.rb).
RSpec.describe 'Account layer of the sidebar', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, email: 'lena@example.com') }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation),
                          active: true)
    end
    sign_in user
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  def sidebar
    doc.at_css('#sidebar')
  end

  def account_pages
    [select_organisation_path, edit_user_registration_path, billing_accounts_path, user_data_export_path,
     users_personal_access_tokens_path, edit_user_preferences_path]
  end

  describe 'on a page of an organisation' do
    before { get organisation_root_path(organisation_id: organisation.id) }

    it 'makes the name the handle of the layer, and a plain link to the account without a script' do
      expect(response).to have_http_status(:ok)
      expect(sidebar['data-controller'].to_s.split).to include('sidebar-layer')

      trigger = sidebar.at_css('[data-sidebar-layer-target="trigger"]')
      expect(trigger.name).to eq('a')
      expect(trigger['href']).to eq(edit_user_registration_path)
      expect(trigger['data-action']).to eq('click->sidebar-layer#toggle')
      expect(trigger['aria-controls']).to eq('account-layer')
      expect(trigger.text.squish).to eq('lena')
      expect(trigger['aria-label']).to include(I18n.t('navigation.account_section'), 'lena')
      # The short menu of its own is gone: no disclosure hangs on the name any more.
      expect(trigger.ancestors('details')).to be_empty
      expect(sidebar.css('details').flat_map { |details| details.css('a').map { |a| a['href'] } })
        .not_to include(user_data_export_path, edit_user_preferences_path)
    end

    it 'holds the layer hidden, with every page of the account and the way out' do
      layer = sidebar.at_css('nav#account-layer[data-sidebar-layer-target="panel"]')

      expect(layer['hidden']).not_to be_nil
      expect(layer['aria-label']).to eq(I18n.t('navigation.account_section'))
      expect(layer.css('[data-account-nav-list] a').map { |a| a['href'] }).to eq(account_pages)
      logout = layer.css('a').find { |a| a['href'] == destroy_user_session_path }
      expect(logout['data-turbo-method']).to eq('delete')
      expect(layer.at_css('button[data-action="sidebar-layer#close"]')['aria-label']).to eq(I18n.t('views.common.close'))
      # In the layer the reader has not left the organisation: nothing leads "back" to it.
      expect(layer.text).not_to include(I18n.t('navigation.back_to_organisation'))
    end

    # The layer covers the app's navigation and the utility row; the script makes that
    # part inert while the layer is up. The name and the layer itself must stay outside
    # of it, or opening the layer would switch off its own handle.
    it 'marks what the layer covers, and keeps the name and the layer out of it' do
      covered = sidebar.css('[data-sidebar-layer-target="covered"]')

      expect(covered.size).to eq(1)
      # Both things the layer lies on: the organisation's navigation and the utility row.
      expect(covered.first.css('a').map { |a| a['href'].to_s }).to include(a_string_starting_with("/org/#{organisation.id}"))
      expect(covered.first.at_css('[data-theme-set]')).to be_present
      expect(covered.first.at_css('#account-layer')).to be_nil
      expect(covered.first.at_css('[data-sidebar-layer-target="trigger"]')).to be_nil
      expect(covered.first.parent.at_css('> #account-layer')).to be_present
    end

    it 'shows the news in the layer only while the news are in the navigation' do
      news = organisation_changelog_path(organisation_id: organisation.id)
      expect(sidebar.css('a').map { |a| a['href'] }).not_to include(news)

      stub_const('ApplicationHelper::CHANGELOG_IN_NAVIGATION', true)
      get organisation_root_path(organisation_id: organisation.id)

      expect(sidebar.css('#account-layer [data-account-nav-list] a').map { |a| a['href'] }).to eq(account_pages + [news])
    end
  end

  describe 'on a page of the account' do
    before do
      get organisation_root_path(organisation_id: organisation.id)
      get edit_user_preferences_path
    end

    it 'shows the same list as the sidebar itself, with no layer over it' do
      expect(response).to have_http_status(:ok)
      expect(sidebar.css('[data-account-nav-list] a').map { |a| a['href'] }).to eq(account_pages)
      expect(sidebar.at_css('#account-layer')).to be_nil
      expect(sidebar['data-controller'].to_s.split).not_to include('sidebar-layer')
      expect(sidebar.at_css('[data-sidebar-layer-target="trigger"]')).to be_nil
      expect(sidebar.css('a.sidebar-row--active').map { |a| a['href'] }).to eq([edit_user_preferences_path])
    end

    it 'keeps the way back to the organisation and signing out beside the name' do
      hrefs = sidebar.css('a').map { |a| a['href'] }

      expect(hrefs).to include(organisation_projects_path(organisation_id: organisation.id), destroy_user_session_path)
      expect(sidebar.text).to include(I18n.t('navigation.back_to_organisation'))
    end
  end
end
