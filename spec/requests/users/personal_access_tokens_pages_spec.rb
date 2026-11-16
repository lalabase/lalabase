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

  # A device signed in through an app (kind app_session) stands in the same list. It is
  # marked, it is revoked here, and it is never renamed or switched to read-only. The
  # personal token beside it is the control of every refusal.
  describe 'a device token' do
    let!(:personal) { create(:personal_access_token, user: user, organisations: [organisation], name: 'Mein Token') }
    let!(:device) { create(:personal_access_token, :app_session, user: user, name: 'iPhone') }

    def row(name)
      doc.css('main [data-token-list] > li').find { |li| li.at_css('h2').text.squish == name }
    end

    it 'is marked as an app in the list, a personal token is not' do
      get users_personal_access_tokens_path

      expect(row('iPhone').at_css('[data-token-kind="app_session"]').text.squish).to eq(key('index.kind_app_session'))
      expect(row('Mein Token').at_css('[data-token-kind]')).to be_nil
      expect_flat(doc.at_css('main [data-token-list]'))
    end

    it 'says that it expires after its last use and when it ends, with the days of the model' do
      get users_personal_access_tokens_path

      days = PersonalAccessToken::MAX_LIFETIME.in_days.to_i
      expect(row('iPhone').at_css('[data-token-expiry="sliding"]').text.squish)
        .to include(I18n.t('views.users.personal_access_tokens.index.expires_after_last_use', days: days))
      expect(row('iPhone').text).to include(key('index.ends_at'), I18n.l(device.ends_at.to_date))
      expect(row('Mein Token').at_css('[data-token-expiry="sliding"]')).to be_nil
      expect(row('Mein Token').text).to include(I18n.l(personal.expires_at, format: :short))
      expect(doc.at_css('main [data-explainer-point="devices"]').text.squish)
        .to eq(I18n.t('views.users.personal_access_tokens.index.explainer.point_devices', days: days))
    end

    it 'offers revoke but no rename, a personal token offers both' do
      get users_personal_access_tokens_path

      expect(row('iPhone').css('a').map { |link| link['href'] }).to eq([users_personal_access_token_path(device)])
      expect(row('Mein Token').css('a').map { |link| link['href'] })
        .to eq([edit_users_personal_access_token_path(personal), users_personal_access_token_path(personal)])
    end

    it 'is revoked from the list' do
      delete users_personal_access_token_path(device)

      expect(response).to redirect_to(users_personal_access_tokens_path)
      expect(device.reload).to be_revoked
      expect(personal.reload).not_to be_revoked
    end

    it 'refuses the rename form' do
      get edit_users_personal_access_token_path(device)
      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq(I18n.t('shared.errors.not_authorized'))

      get edit_users_personal_access_token_path(personal)
      expect(response).to have_http_status(:ok)
    end

    it 'refuses a PATCH: neither the name nor read-only changes' do
      patch users_personal_access_token_path(device),
            params: { personal_access_token: { name: 'Renamed', read_only: '1' } }

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq(I18n.t('shared.errors.not_authorized'))
      expect(device.reload).to have_attributes(name: 'iPhone', read_only: false)

      # The control: the same PATCH changes a personal token.
      patch users_personal_access_token_path(personal),
            params: { personal_access_token: { name: 'Renamed', read_only: '0' } }
      expect(response).to redirect_to(users_personal_access_tokens_path)
      expect(personal.reload).to have_attributes(name: 'Renamed', read_only: false)
    end
  end
end
