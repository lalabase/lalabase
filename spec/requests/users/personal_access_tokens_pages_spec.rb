# frozen_string_literal: true

require 'rails_helper'

# The four pages of the API tokens (Mein Konto › API-Tokens) in the shapes of the rest
# of the application (2026-11-12). Until then each built a title box of its own under a
# top gap of its own, the tokens and the form's sections were cards with hard shadows,
# and the submit buttons were built by hand. What the pages DO is held by
# personal_access_tokens_spec.rb; this file holds how they are put together, where a
# guard cannot see it: one head for the area, the crumb line on the pages below the
# list, flat rows, one main action per page.
RSpec.describe 'API token pages', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }
  let(:area) { I18n.t('navigation.settings_api_tokens') }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    sign_in user
    ActsAsTenant.current_tenant = organisation
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  def key(name)
    I18n.t("views.users.personal_access_tokens.#{name}")
  end

  # The title names the area on every page of it; a page below the list names itself in
  # the crumb line, with the way back to the list (organisations/shared/_section_crumb).
  def expect_area_head(page: nil)
    expect(response).to have_http_status(:ok)
    expect(doc.css('main h1').map { |h1| h1.text.squish }).to eq([area])
    crumb = doc.at_css('main [data-section-crumb]')
    return expect(crumb).to(be_nil) if page.nil?

    expect(crumb.at_css('a')['href']).to eq(users_personal_access_tokens_path)
    expect(crumb.at_css('a').text.squish).to end_with(area)
    expect(crumb.at_css('[aria-current="page"]').text.squish).to eq(page)
  end

  # No hard shadow written into the page: a hard shadow says "press me", and neither a
  # row nor a section of a form is pressed. The main action carries its token instead.
  def expect_flat(node = doc.at_css('main'))
    expect(node.to_html).not_to include('shadow-[')
  end

  def main_actions
    doc.css('main a, main button').select { |control| control['class'].to_s.include?('shadow-press') }
  end

  describe 'the list' do
    let!(:active) { create(:personal_access_token, user: user, organisations: [organisation], name: 'Aktiver Token') }
    let!(:expired) { create(:personal_access_token, :expired, user: user, organisations: [organisation], name: 'Alter Token') }
    let!(:revoked) { create(:personal_access_token, :revoked, user: user, organisations: [organisation], name: 'Widerrufener Token') }

    before { get users_personal_access_tokens_path }

    it 'has the area head, with the new token as its one main action' do
      expect_area_head
      expect(main_actions.map { |action| action['href'] }).to eq([new_users_personal_access_token_path])
      expect(doc.at_css('main').text).to include(key('index.subtitle'))
    end

    # Three tokens on purpose: the scope line read the organisations once per token
    # until 2026-11-12, which a list of one cannot show (Prosopite fails this example).
    it 'shows the tokens as flat rows of one list, each with its state' do
      rows = doc.css('main [data-token-list] > li')

      expect(rows.size).to eq(3)
      expect_flat(doc.at_css('main [data-token-list]'))
      states = rows.to_h { |row| [row.at_css('h2').text.squish, row.at_css('[data-token-state]')['data-token-state']] }
      expect(states).to eq('Aktiver Token' => 'active', 'Alter Token' => 'expired', 'Widerrufener Token' => 'revoked')
    end

    it 'offers rename and revoke only for a token that still works' do
      links = doc.css('main [data-token-list] a').map { |link| link['href'] }

      expect(links).to contain_exactly(edit_users_personal_access_token_path(active),
                                       users_personal_access_token_path(active))
    end
  end

  it 'says so, in a quiet frame, when there is no token yet' do
    get users_personal_access_tokens_path

    expect(doc.at_css('main [data-token-list]')).to be_nil
    expect(doc.at_css('main').text).to include(key('index.empty'))
    expect_flat
  end

  describe 'the form for a new token' do
    before { get new_users_personal_access_token_path }

    it 'keeps the area head and names itself in the crumb line' do
      expect_area_head(page: key('new.title'))
    end

    it 'is flat, with the submit as its one main action' do
      expect_flat
      expect(main_actions.map { |action| action.text.squish }).to eq([key('new.submit')])
      expect(main_actions.first['type']).to eq('submit')
    end
  end

  describe 'the rename form' do
    let(:token) { create(:personal_access_token, user: user, organisations: [organisation], name: 'Mein Token') }

    before { get edit_users_personal_access_token_path(token) }

    it 'keeps the area head and names itself in the crumb line' do
      expect_area_head(page: key('edit.title'))
    end

    it 'is flat, with the submit as its one main action, and says what a rename cannot change' do
      expect_flat
      expect(main_actions.map { |action| action.text.squish }).to eq([key('edit.submit')])
      expect(doc.at_css('main dl').text).to include(organisation.name, I18n.l(token.expires_at, format: :short))
    end
  end

  describe 'the page of a token just created' do
    before do
      post users_personal_access_tokens_path, params: {
        current_password: user.password,
        personal_access_token: { name: 'Neuer Token', expires_preset: '30', organisation_ids: [organisation.id],
                                 project_mode: { organisation.id => 'all' } }
      }
    end

    it 'keeps the area head and names itself in the crumb line' do
      expect_area_head(page: key('created.title'))
    end

    it 'shows the token once, in a field, with the copy as its one main action' do
      token = PersonalAccessToken.order(:created_at).last
      field = doc.at_css('main input[readonly][data-clipboard-target="source"]')

      expect(field['value']).to start_with(token.token_prefix)
      expect_flat
      expect(main_actions.map { |action| action.text.squish }).to eq([key('created.copy')])
      expect(main_actions.first['data-action']).to eq('click->clipboard#copy')
      expect(doc.at_css('main [role="alert"]').text).to include(key('created.warning_title'))
    end
  end
end
