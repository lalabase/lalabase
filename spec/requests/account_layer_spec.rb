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

  # The pages of NavigationHelper::ACCOUNT_PAGES, written out: a reordered or shrunk list is red.
  # Since PR 3 of the navigation plan without "Alle Organisationen" and "Gesamt-Inbox".
  def account_pages
    [edit_user_registration_path, billing_accounts_path, user_data_export_path,
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
      expect(layer.text).not_to include(I18n.t('navigation.account_back'))
      expect(layer.css('a').pluck('href')).not_to include(select_organisation_path, all_inboxes_path)
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
  end

  describe 'on a page of the management area' do
    it 'keeps the name the handle of the layer' do
      get organisation_memberships_path(organisation)
      expect(response).to have_http_status(:ok)
      expect(sidebar['data-controller'].to_s.split).to include('sidebar-layer')
      expect(sidebar.at_css('[data-sidebar-layer-target="trigger"]')['aria-controls']).to eq('account-layer')
      expect(sidebar.at_css('nav#account-layer[hidden]')).to be_present
    end
  end

  # Navigation plan, finding 6: once the cockpit shows the level's sidebar, only the layer
  # leads to the account from there. The level gets the layer of an organisation's page.
  describe 'on the level above the organisations', :real_transactions do
    let(:other) { create(:organisation, name: 'Sued AG') }

    before do
      ActsAsTenant.with_tenant(other) do
        create(:membership, user: user, organisation: other, role: create(:admin_role, organisation: other), active: true)
      end
      ActsAsTenant.current_tenant = nil
    end

    # Since PR 3 the same list everywhere: the level has its own sidebar for its pages.
    def level_account_pages
      account_pages
    end

    { 'the cockpit' => -> { select_organisation_path }, 'the inbox' => -> { all_inboxes_path } }.each do |where, path|
      it "makes the name the handle of a hidden layer on #{where}, a plain link without a script" do
        get instance_exec(&path)
        expect(response).to have_http_status(:ok)
        expect(sidebar.at_css('[data-all-inboxes-nav]')).to be_present
        expect(sidebar['data-controller'].to_s.split).to include('sidebar-layer')

        trigger = sidebar.at_css('[data-sidebar-layer-target="trigger"]')
        expect(trigger.name).to eq('a')
        expect(trigger['href']).to eq(edit_user_registration_path)
        expect(trigger['data-action']).to eq('click->sidebar-layer#toggle')
        expect(trigger['aria-controls']).to eq('account-layer')
        expect(trigger.text.squish).to eq('lena')

        layer = sidebar.at_css('nav#account-layer[data-sidebar-layer-target="panel"]')
        expect(layer['hidden']).not_to be_nil
        expect(layer.css('[data-account-nav-list] a').map { |a| a['href'] }).to eq(level_account_pages)
        expect(layer.css('a').find { |a| a['href'] == destroy_user_session_path }['data-turbo-method']).to eq('delete')
      end

      it "marks what the layer covers on #{where}: the level's sidebar and the utility row, not the name" do
        get instance_exec(&path)
        covered = sidebar.css('[data-sidebar-layer-target="covered"]')
        expect(covered.size).to eq(1)
        expect(covered.first.at_css('[data-all-inboxes-nav]')).to be_present
        expect(covered.first.at_css('[data-theme-set]')).to be_present
        expect(covered.first.at_css('#account-layer, [data-sidebar-layer-target="trigger"]')).to be_nil
        expect(covered.first.parent.at_css('> #account-layer')).to be_present
      end
    end
  end

  describe 'on a page of the account' do
    before do
      get organisation_root_path(organisation_id: organisation.id)
      get edit_user_preferences_path
    end

    it 'shows "Zurück", then the label of the account, then the pages, with no layer over it' do
      expect(response).to have_http_status(:ok)
      middle = sidebar.at_css('[data-account-sidebar]')
      expect(middle).to be_present
      rows = middle.css('a').map { |a| a.text.squish }
      expect(rows.first).to eq(I18n.t('navigation.account_back'))
      expect(middle.text.squish.index(I18n.t('navigation.account_section').upcase) ||
             middle.text.squish.index(I18n.t('navigation.account_section'))).to be > middle.text.squish.index(rows.first)
      expect(middle.css('[data-account-nav-list] a').map { |a| a['href'] }).to eq(account_pages)
      expect(middle.css('[data-account-nav-list] a').map { |a| a.text.squish })
        .not_to include(I18n.t('navigation.all_organisations'), I18n.t('navigation.all_inboxes'))
      expect(sidebar.at_css('#account-layer')).to be_nil
      expect(sidebar['data-controller'].to_s.split).not_to include('sidebar-layer')
      expect(sidebar.css('a.sidebar-row--active').map { |a| a['href'] }).to eq([edit_user_preferences_path])
    end

    it 'shows the name without a handle, and signing out above it' do
      expect(sidebar.at_css('[data-sidebar-layer-target="trigger"], [aria-controls="account-layer"]')).to be_nil
      name = sidebar.at_css('[data-account-name]')
      expect(name.text.squish).to eq('lena')
      expect(name.at_css('.bi-chevron-down')).to be_nil
      foot = name.parent
      logout = foot.css('a').find { |a| a['href'] == destroy_user_session_path }
      expect(logout['data-turbo-method']).to eq('delete')
      expect(foot.to_html.index(destroy_user_session_path)).to be < foot.to_html.index('data-account-name')
      expect(sidebar.text).not_to include('Zurück zur Organisation')
    end
  end

  # Every page of the account marks its entry, the pages below "Profil" included; the
  # row comes from NavigationHelper::ACCOUNT_PAGES, not from typed paths.
  describe 'the marked row of every page of the account' do
    {
      'edit_user_registration_path' => 'edit_user_registration_path',
      'edit_user_registration_password_path' => 'edit_user_registration_path',
      'new_account_deletion_path' => 'edit_user_registration_path',
      'billing_accounts_path' => 'billing_accounts_path',
      'user_data_export_path' => 'user_data_export_path',
      'users_personal_access_tokens_path' => 'users_personal_access_tokens_path',
      'new_users_personal_access_token_path' => 'users_personal_access_tokens_path',
      'edit_user_preferences_path' => 'edit_user_preferences_path'
    }.each do |page, entry|
      it "marks the entry of #{entry} on #{page}" do
        get public_send(page)
        follow_redirect! while response.redirect? # the billing list leads to the one account there is
        expect(response).to have_http_status(:ok)
        list = sidebar.at_css('[data-account-sidebar] [data-account-nav-list]')
        expect(list.css('a').map { |a| a['href'] }).to eq(account_pages)
        expect(list.css('a.sidebar-row--active').map { |a| a['href'] }).to eq([public_send(entry)])
        expect(list.css('a[aria-current="page"]').map { |a| a['href'] }).to eq([public_send(entry)])
      end
    end
  end
end
