# frozen_string_literal: true

require 'rails_helper'

# What: "Zurück" of an account page (AccountReturn, NavigationHelper#account_return_path,
#       navigation plan D5): the page the reader came from, kept as a path when the account
#       area is entered, else the reader's home (ApplicationController#user_home_path).
# Why:  the way back is read from a header the client sends. A foreign host, a path a
#       browser reads as a host, a path too long for the session cookie, and a request that
#       is no page must never become the way back.
RSpec.describe 'The way back out of the account area', :ci_guard, type: :request do
  let(:user) { create(:user) }
  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Sued AG') }
  let(:host) { 'http://www.example.com' }

  before do
    [north, south].each do |org|
      ActsAsTenant.with_tenant(org) do
        create(:membership, user: user, organisation: org, role: create(:admin_role, organisation: org), active: true)
      end
    end
    ActsAsTenant.current_tenant = nil
    sign_in user
  end

  def visit_account(path = edit_user_preferences_path, referer: nil, headers: {})
    headers = headers.merge('Referer' => referer) if referer
    get path, headers: headers
    expect(response).to have_http_status(:ok)
  end

  # The href of "Zurück", read from the account sidebar (proved present first).
  def back_href
    middle = Nokogiri::HTML(response.body).at_css('[data-account-sidebar]')
    expect(middle).to be_present
    back = middle.css('a').find { |a| a.text.squish == I18n.t('navigation.account_back') }
    back['href']
  end

  def home
    user_home_path_for(user)
  end

  def user_home_path_for(person)
    organisation_root_path(person.home_organisation)
  end

  let(:north_tickets) { "/org/#{north.id}/projects?view=board" }

  it 'leads to the page of an organisation the reader came from, with its query' do
    visit_account(referer: "#{host}#{north_tickets}")
    expect(back_href).to eq(north_tickets)
    expect(session[AccountReturn::SESSION_KEY]).to eq(north_tickets)
  end

  it 'leads to the cockpit when the reader came from there' do
    visit_account(referer: "#{host}#{select_organisation_path}")
    expect(back_href).to eq(select_organisation_path)
  end

  it 'leads to the narrowed inbox above the organisations when the reader came from there' do
    narrowed = all_inboxes_path(org: south.id)
    visit_account(referer: "#{host}#{narrowed}")
    expect(back_href).to eq(narrowed)
  end

  it 'keeps the first way back while the reader moves on through the account' do
    visit_account(referer: "#{host}#{north_tickets}")
    visit_account(edit_user_registration_path, referer: "#{host}#{edit_user_preferences_path}")
    expect(back_href).to eq(north_tickets)
    visit_account(users_personal_access_tokens_path, referer: "#{host}#{edit_user_registration_path}")
    expect(back_href).to eq(north_tickets)
  end

  it 'replaces an old way back when the account is entered again from elsewhere' do
    visit_account(referer: "#{host}#{north_tickets}")
    visit_account(referer: "#{host}#{select_organisation_path}")
    expect(back_href).to eq(select_organisation_path)
  end

  describe 'return paths sharing the session cookie' do
    %i[management account].each do |first|
      it "keeps both maximum-length paths when #{first} is entered first" do
        base = "#{north_tickets}&q="
        longest = base + ('x' * (ReturnPath::MAX_RETURN_PATH_BYTES - base.bytesize))
        visits = {
          management: -> { get organisation_memberships_path(north), headers: { 'Referer' => "#{host}#{longest}" } },
          account: -> { visit_account(referer: "#{host}#{longest}") }
        }
        [first, (visits.keys - [first]).first].each do |area|
          visits.fetch(area).call
          expect(response).to have_http_status(:ok)
        end

        # Read both values back from the browser cookie on a subsequent request.
        visit_account(edit_user_registration_path, referer: "#{host}#{edit_user_preferences_path}")
        expect(back_href).to eq(longest)
        expect(session[Organisations::ManagementReturn::SESSION_KEY]).to eq(longest)
      end
    end
  end

  describe 'rejected account forms' do
    {
      profile: { page: :edit_user_registration_path, target: :user_registration_path, method: :put,
                 params: { user: { first_name: 'Changed', current_password: 'wrong-password' } } },
      password: { page: :edit_user_registration_password_path, target: :user_registration_path, method: :put,
                  params: { account_tab: 'password', user: { password: 'new-password123', password_confirmation: 'new-password123',
                                                             current_password: 'wrong-password' } } },
      display: { page: :edit_user_registration_path, target: :user_registration_display_path, method: :patch,
                 params: { user: { email_visibility: 'contact', contact_email: 'invalid' } } }
    }.each do |name, form|
      it "keeps the original return after a rejected #{name} update and another account page" do
        page = public_send(form[:page])
        target = public_send(form[:target])
        visit_account(page, referer: "#{host}#{north_tickets}")
        public_send(form[:method], target, params: form[:params], headers: { 'Referer' => "#{host}#{page}" })
        expect(response).to have_http_status(:unprocessable_content)
        expect(back_href).to eq(north_tickets)

        visit_account(referer: "#{host}#{target}")
        expect(back_href).to eq(north_tickets)
      end
    end
  end

  describe 'falls back to the reader home' do
    it 'on a direct visit without a referer' do
      visit_account
      expect(back_href).to eq(home)
      expect(session[AccountReturn::SESSION_KEY]).to be_nil
    end

    it 'on a direct visit after an earlier way back' do
      visit_account(referer: "#{host}#{north_tickets}")
      visit_account
      expect(back_href).to eq(home)
    end

    it 'for a path no GET route answers' do
      visit_account(referer: "#{host}/not-an-app-page")
      expect(back_href).to eq(home)
      expect(session[AccountReturn::SESSION_KEY]).to be_nil
    end

    it 'for a referer of a foreign host' do
      visit_account(referer: "https://elsewhere.example.com#{north_tickets}")
      expect(back_href).to eq(home)
    end

    it 'for a referer whose path starts with two slashes' do
      visit_account(referer: "#{host}//elsewhere.example.com/org/#{north.id}")
      expect(back_href).to eq(home)
      expect(session[AccountReturn::SESSION_KEY]).to be_nil
    end

    it 'for a referer that is itself an account page' do
      visit_account(referer: "#{host}#{edit_user_registration_path}")
      expect(back_href).to eq(home)
    end

    it 'for a path longer than the shared size limit' do
      long = "#{north_tickets}&q=#{'x' * ReturnPath::MAX_RETURN_PATH_BYTES}"
      visit_account(referer: "#{host}#{long}")
      expect(back_href).to eq(home)
      expect(session[AccountReturn::SESSION_KEY]).to be_nil
    end

    it 'for a path just within the limit it still leads back' do
      base = "#{north_tickets}&q="
      fitting = base + ('x' * (ReturnPath::MAX_RETURN_PATH_BYTES - base.bytesize))
      visit_account(referer: "#{host}#{fitting}")
      expect(back_href).to eq(fitting)
    end
  end

  # The one rule of what may be followed, shared with the management area.
  describe 'ReturnPath.path?' do
    it 'accepts a path of this host within the limit, and nothing else' do
      expect(ReturnPath.path?('/org/1/projects?view=board')).to be(true)
      expect(ReturnPath.path?("/#{'x' * (ReturnPath::MAX_RETURN_PATH_BYTES - 1)}")).to be(true)
      expect(ReturnPath.path?("/#{'x' * ReturnPath::MAX_RETURN_PATH_BYTES}")).to be(false)
      expect(ReturnPath.path?('//elsewhere.example.com/org/1')).to be(false)
      expect(ReturnPath.path?('https://elsewhere.example.com/org/1')).to be(false)
      expect(ReturnPath.path?('org/1')).to be(false)
      expect(ReturnPath.path?(nil)).to be(false)
    end

    it 'does not follow a stored value that is no path' do
      visit_account(referer: "#{host}#{north_tickets}")
      # A value the session could only hold if the rule above had let it in.
      allow_any_instance_of(ActionDispatch::Request::Session).to receive(:[]).and_call_original
      allow_any_instance_of(ActionDispatch::Request::Session).to receive(:[]).with(AccountReturn::SESSION_KEY)
                                                                             .and_return('//elsewhere.example.com/x')
      get edit_user_preferences_path, headers: { 'Referer' => "#{host}#{edit_user_registration_path}" }
      expect(back_href).to eq(home)
    end
  end

  it 'keeps a path and never a host' do
    visit_account(referer: "#{host}#{north_tickets}")
    stored = session[AccountReturn::SESSION_KEY]
    expect(stored).to start_with('/')
    expect(stored).not_to include('example.com', '//')
  end

  describe 'requests that are no page keep nothing' do
    before { visit_account(referer: "#{host}#{north_tickets}") }

    it 'a frame load' do
      get edit_user_registration_path, headers: { 'Referer' => "#{host}#{select_organisation_path}", 'Turbo-Frame' => 'some_frame' }
      expect(session[AccountReturn::SESSION_KEY]).to eq(north_tickets)
    end

    it 'a stream request' do
      get edit_user_registration_path, headers: { 'Referer' => "#{host}#{select_organisation_path}",
                                                  'Accept' => 'text/vnd.turbo-stream.html, text/html' }
      expect(session[AccountReturn::SESSION_KEY]).to eq(north_tickets)
    end

    it 'a write' do
      patch user_preferences_path, params: { user_preferences: {} },
                                   headers: { 'Referer' => "#{host}#{select_organisation_path}" }
      expect(session[AccountReturn::SESSION_KEY]).to eq(north_tickets)
    end
  end

  # The management area shares ReturnPath; a path below the organisation that no route
  # answers is no way out of it either (review PR 3 round 1).
  it 'keeps no way out of the management area for a path no route answers' do
    get organisation_memberships_path(north), headers: { 'Referer' => "#{host}/org/#{north.id}/gibt-es-nicht" }
    expect(response).to have_http_status(:ok)
    expect(session[Organisations::ManagementReturn::SESSION_KEY]).to be_nil
  end

  it 'leaves the way out of the management area alone' do
    get organisation_memberships_path(north), headers: { 'Referer' => "#{host}/org/#{north.id}/projects" }
    expect(session[Organisations::ManagementReturn::SESSION_KEY]).to eq("/org/#{north.id}/projects")
    visit_account(referer: "#{host}#{north_tickets}")
    expect(session[Organisations::ManagementReturn::SESSION_KEY]).to eq("/org/#{north.id}/projects")
  end
end
