# frozen_string_literal: true

require 'rails_helper'

# The lane state ?edit=<person id> of the people page: a full visit opens the edit
# form of that row in the lane. It is the way in for a link from outside the page
# (the pencil of a card above the organisations): until it existed the form opened
# only inside the lane frame. The state opens a form only for a row the viewer may
# read AND update; everything else is the list, with the parameter named as
# unresolved, the way an unreadable person_id is.
RSpec.describe 'Organisations::People, the lane state ?edit=', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def role_with(*actions, title: nil)
    role = create(:role, organisation: organisation, **{ title: title }.compact)
    actions.each { |action| create(:permission, role: role, category: 'people', action: action, allowed: true) }
    role
  end

  def member_with(role, first_name: 'Max')
    user = create(:user, first_name: first_name, last_name: "Muster#{SecureRandom.hex(2)}")
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    user
  end

  let(:manager) { member_with(role_with('manage_people')) }
  let(:viewer) { member_with(role_with('view_people')) }
  let!(:person) { create(:person, organisation: organisation, name: 'Doris Dienstleister', phone: '+49 30 1234567') }
  let!(:other) { create(:person, organisation: organisation, name: 'Emil Extern') }

  let(:frame_headers) { { 'Turbo-Frame' => Organisations::PeopleController::DETAIL_FRAME_ID } }

  def page
    Nokogiri::HTML(response.body)
  end

  def wrapper
    page.at_css('.people-page')
  end

  # The parameters the page names as not opened (layout-toggle takes them out of the address).
  def unresolved
    data = wrapper['data-layout-toggle-unresolved-selection-value']
    data ? JSON.parse(data) : {}
  end

  # The form in the lane: the row it would save, or nil when the lane holds no form.
  def form_action
    page.at_css('.people-lane form.people-form, .people-lane form[action*="/people"]')&.[]('action')
  end

  def expect_list_without_form(id)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Doris Dienstleister', 'Emil Extern')
    expect(page.at_css('#person_name')).to be_nil
    expect(wrapper['class']).not_to include('show-content')
    expect(unresolved).to eq('edit' => id)
  end

  describe 'a full visit by a writer' do
    before { sign_in manager }

    it 'renders the page with the form of that person in the lane' do
      get organisation_people_path(organisation, edit: person.id)

      expect(response).to have_http_status(:ok)
      expect(wrapper['class']).to include('show-content')
      expect(page.at_css('#person_name')['value']).to eq('Doris Dienstleister')
      expect(page.at_css('#person_phone')['value']).to eq('+49 30 1234567')
      expect(form_action).to start_with(organisation_person_path(organisation, person))
      # The list stays beside it, and nothing is unresolved.
      expect(response.body).to include('Emil Extern')
      expect(unresolved).to eq({})
    end

    it 'names the state among the form parameters of the lane, so a row click and the close take it away' do
      get organisation_people_path(organisation, edit: person.id)

      expect(JSON.parse(wrapper['data-lane-params'])['form']).to eq(%w[new user_id edit])
    end

    # The "+" opens the empty form in place and writes ?new=person: the form of the
    # row must leave the address with it, or a reload would show that row again.
    it 'lets the "+" take the state out of the address' do
      get organisation_people_path(organisation, edit: person.id)

      add = page.at_css('.people-head [data-controller~="lane-link"]')
      expect(JSON.parse(add['data-lane-link-remove-value'])).to eq(%w[person_id member_id user_id edit])
    end

    # Nothing on the page writes ?edit=; a page that came without it keeps the lists
    # it always had.
    it 'leaves the lane parameters of a page without the state as they were' do
      get organisation_people_path(organisation)

      expect(JSON.parse(wrapper['data-lane-params'])['form']).to eq(%w[new user_id])
      add = page.at_css('.people-head [data-controller~="lane-link"]')
      expect(JSON.parse(add['data-lane-link-remove-value'])).to eq(%w[person_id member_id user_id])
    end

    it 'moves the organisation of the session, as every full page of an organisation does' do
      create(:membership, user: manager, organisation: other_organisation, active: true,
                          role: create(:role, organisation: other_organisation))
      get organisation_people_path(other_organisation)
      expect(session[:current_organisation_id]).to eq(other_organisation.id)

      get organisation_people_path(organisation, edit: person.id)

      expect(session[:current_organisation_id]).to eq(organisation.id)
    end

    it 'answers a lane request of the same address with the form alone' do
      get organisation_people_path(organisation, edit: person.id), headers: frame_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to start_with(%(<turbo-frame id="#{Organisations::PeopleController::DETAIL_FRAME_ID}">))
      expect(page.at_css('#person_name')['value']).to eq('Doris Dienstleister')
      expect(response.body).not_to include('Emil Extern')
    end

    it 'opens the person, not the form, when the address names a person as well' do
      get organisation_people_path(organisation, person_id: other.id, edit: person.id)

      expect(response.body).to include('selected-row')
      expect(page.at_css('#person_name')).to be_nil
      expect(unresolved).to eq('edit' => person.id)
    end

    it 'opens the form of the row, not an empty one, when the address asks for a new person as well' do
      get organisation_people_path(organisation, edit: person.id, new: 'person')

      expect(page.at_css('#person_name')['value']).to eq('Doris Dienstleister')
      expect(form_action).to start_with(organisation_person_path(organisation, person))
    end

    it 'keeps the list state of the address' do
      get organisation_people_path(organisation, edit: person.id, q: 'doris')

      expect(page.at_css('#person_name')['value']).to eq('Doris Dienstleister')
      expect(response.body).not_to include('Emil Extern')
    end

    # The address opened the form, so leaving it must change the address: a visit of
    # the page with the person open, not a load of the lane's frame under ?edit=.
    it 'leaves the form by a visit of the page with the person open' do
      get organisation_people_path(organisation, edit: person.id, q: 'doris')

      ways_out = page.css('.people-form-wrap a.people-icon-action, .people-form-wrap a.people-quiet-action')
      expect(ways_out.size).to eq(2)
      ways_out.each do |link|
        expect(link['href']).to eq(organisation_people_path(organisation, q: 'doris', person_id: person.id))
        expect(link['data-turbo-frame']).to eq('_top')
      end
    end

    it 'leaves the form by the same visit when the lane asked for the address' do
      get organisation_people_path(organisation, edit: person.id), headers: frame_headers

      link = page.at_css('.people-form-wrap a.people-quiet-action')
      expect(link['href']).to eq(organisation_people_path(organisation, person_id: person.id))
      expect(link['data-turbo-frame']).to eq('_top')
    end
  end

  describe 'a full visit of edit, without a frame' do
    it 'redirects a writer to the address with edit=' do
      sign_in manager

      get edit_organisation_person_path(organisation, person)

      expect(response).to redirect_to(organisation_people_path(organisation, edit: person.id))
    end

    it 'carries the list state along' do
      sign_in manager

      get edit_organisation_person_path(organisation, person, q: 'doris', kind: 'contacts')

      expect(response).to redirect_to(organisation_people_path(organisation, q: 'doris', kind: 'contacts', edit: person.id))
    end

    it 'still answers the frame with the form alone, and its way out stays in the frame' do
      sign_in manager

      get edit_organisation_person_path(organisation, person), headers: frame_headers

      expect(response).to have_http_status(:ok)
      expect(page.at_css('#person_name')['value']).to eq('Doris Dienstleister')
      link = page.at_css('.people-form-wrap a.people-quiet-action')
      expect(link['href']).to eq(organisation_person_path(organisation, person))
      expect(link['data-turbo-frame']).to be_nil
    end

    it 'refuses a reader as before (403), with and without a frame' do
      sign_in viewer

      get edit_organisation_person_path(organisation, person)
      expect(response).to have_http_status(:forbidden)

      get edit_organisation_person_path(organisation, person), headers: frame_headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'what the state does not open' do
    it 'renders the list for a reader and names the parameter as unresolved' do
      sign_in viewer

      get organisation_people_path(organisation, edit: person.id)

      expect_list_without_form(person.id)
    end

    it 'answers the lane request of a reader with the empty lane' do
      sign_in viewer

      get organisation_people_path(organisation, edit: person.id), headers: frame_headers

      expect(response).to have_http_status(:ok)
      expect(page.at_css('#person_name')).to be_nil
      expect(page.at_css('#person-display-placeholder')).to be_present
    end

    it 'renders the list for the id of a row of another organisation' do
      foreign = ActsAsTenant.with_tenant(other_organisation) { create(:person, organisation: other_organisation, name: 'Fremde Frau') }
      sign_in manager

      get organisation_people_path(organisation, edit: foreign.id)

      expect_list_without_form(foreign.id)
      expect(response.body).not_to include('Fremde Frau')
    end

    it 'renders the list for an id that names nothing' do
      missing = SecureRandom.uuid
      sign_in manager

      get organisation_people_path(organisation, edit: missing)

      expect_list_without_form(missing)
    end

    it 'renders the list for a malformed id' do
      sign_in manager

      get organisation_people_path(organisation, edit: 'not-an-id')

      expect_list_without_form('not-an-id')
    end

    it 'takes a list or a hash in place of the id for no state at all' do
      sign_in manager

      get organisation_people_path(organisation), params: { edit: [person.id] }
      expect(response).to have_http_status(:ok)
      expect(page.at_css('#person_name')).to be_nil

      get organisation_people_path(organisation), params: { edit: { id: person.id } }
      expect(response).to have_http_status(:ok)
      expect(page.at_css('#person_name')).to be_nil
    end

    context 'with a row linked to a member the writer cannot see' do
      let(:project) { create(:project, organisation: organisation) }
      let(:stranger) { member_with(role_with, first_name: 'Sven') }
      let!(:hidden_row) { create(:person, organisation: organisation, user: stranger, phone: 'secret') }

      before do
        create(:project_permission, user: manager, project: project, tickets_access: :read_only)
        create(:project_permission, user: stranger, project: create(:project, organisation: organisation),
                                    tickets_access: :read_only)
        sign_in manager
      end

      it 'renders the list and shows nothing of the row' do
        get organisation_people_path(organisation, edit: hidden_row.id)

        expect_list_without_form(hidden_row.id)
        expect(response.body).not_to include('secret')
      end

      it 'answers the lane request like an id that names nothing' do
        get organisation_people_path(organisation, edit: hidden_row.id), headers: frame_headers
        hidden = response.body

        get organisation_people_path(organisation, edit: SecureRandom.uuid), headers: frame_headers

        expect(hidden).to eq(response.body)
        expect(hidden).not_to include('secret')
      end
    end
  end

  describe 'the addresses the page knew before' do
    before { sign_in manager }

    it 'opens a person with ?person_id=, a form with ?new=person, and names neither as unresolved' do
      get organisation_people_path(organisation, person_id: person.id)
      expect(response.body).to include('show-content', 'selected-row')
      expect(unresolved).to eq({})

      get organisation_people_path(organisation, new: 'person')
      expect(page.at_css('#person_name')['value']).to be_nil
      expect(unresolved).to eq({})
    end

    it 'still sends a full visit of show to the index with the person open' do
      get organisation_person_path(organisation, person)

      expect(response).to redirect_to(organisation_people_path(organisation, person_id: person.id))
    end
  end
end
