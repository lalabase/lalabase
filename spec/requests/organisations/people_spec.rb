# frozen_string_literal: true

require 'rails_helper'

# The people directory page and its writes. Every action against the right
# (PersonPolicy, D7): 403 without it, view_people reads but never writes,
# manage_people writes (a guest role too), an account admin needs no row, and
# another organisation answers 404.
RSpec.describe 'Organisations::People', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def role_with(*actions, billable: true, title: nil)
    role = create(:role, organisation: organisation, billable: billable, **{ title: title }.compact)
    actions.each { |action| create(:permission, role: role, category: 'people', action: action, allowed: true) }
    role
  end

  def member_with(role, first_name: 'Max')
    user = create(:user, first_name: first_name, last_name: "Muster#{SecureRandom.hex(2)}")
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    user
  end

  let(:admin) { member_with(role_with(title: Role::ACCOUNT_ADMIN_TITLE)) }
  let(:viewer) { member_with(role_with('view_people')) }
  let(:manager) { member_with(role_with('manage_people')) }
  let(:guest_manager) { member_with(role_with('manage_people', billable: false)) }
  let(:nobody) { member_with(role_with) }
  let!(:person) { create(:person, organisation: organisation, name: 'Doris Dienstleister', phone: '+49 30 1234567') }

  let(:frame_headers) { { 'Turbo-Frame' => Organisations::PeopleController::DETAIL_FRAME_ID } }
  let(:valid_params) { { person: { name: 'Erika Beispiel', function: 'Administratorin' } } }

  describe 'without the right' do
    before { sign_in nobody }

    it 'answers 403 on every action and changes nothing' do
      get organisation_people_path(organisation)
      expect(response).to have_http_status(:forbidden)

      get organisation_person_path(organisation, person), headers: frame_headers
      expect(response).to have_http_status(:forbidden)

      get new_organisation_person_path(organisation), headers: frame_headers
      expect(response).to have_http_status(:forbidden)

      get edit_organisation_person_path(organisation, person), headers: frame_headers
      expect(response).to have_http_status(:forbidden)

      expect { post organisation_people_path(organisation), params: valid_params }.not_to change(Person, :count)
      expect(response).to have_http_status(:forbidden)

      patch organisation_person_path(organisation, person), params: { person: { phone: '0' } }
      expect(response).to have_http_status(:forbidden)

      expect { delete organisation_person_path(organisation, person) }.not_to change(Person, :count)
      expect(response).to have_http_status(:forbidden)
      expect(person.reload.phone).to eq('+49 30 1234567')
    end

    it 'shows no menu entry in the sidebar' do
      get organisation_root_path(organisation)
      follow_redirect! while response.redirect?

      expect(response.body).to include(I18n.t('navigation.all_organisations'))
      expect(response.body).not_to include(organisation_people_path(organisation))
    end

    it 'shows no entry on the mobile "more" page' do
      get organisation_mobile_more_path(organisation)

      expect(response.body).to include(I18n.t('mobile.more'))
      expect(response.body).not_to include(organisation_people_path(organisation))
    end
  end

  describe 'with view_people only' do
    before { sign_in viewer }

    it 'shows the list and the person, without write controls' do
      get organisation_people_path(organisation, person_id: person.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Doris Dienstleister', '+49 30 1234567')
      expect(response.body).not_to include(new_organisation_person_path(organisation))
      expect(response.body).not_to include(edit_organisation_person_path(organisation, person))
    end

    it 'shows the person in the lane frame' do
      get organisation_person_path(organisation, person), headers: frame_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(<turbo-frame id="#{Organisations::PeopleController::DETAIL_FRAME_ID}">), 'Doris Dienstleister')
    end

    it 'is refused every write with 403' do
      expect { post organisation_people_path(organisation), params: valid_params }.not_to change(Person, :count)
      expect(response).to have_http_status(:forbidden)

      patch organisation_person_path(organisation, person), params: { person: { phone: '0' } }
      expect(response).to have_http_status(:forbidden)

      expect { delete organisation_person_path(organisation, person) }.not_to change(Person, :count)
      expect(response).to have_http_status(:forbidden)

      get new_organisation_person_path(organisation), headers: frame_headers
      expect(response).to have_http_status(:forbidden)
    end

    it 'shows the menu entry in the sidebar' do
      get organisation_root_path(organisation)
      follow_redirect! while response.redirect?

      expect(response.body).to include(%(href="#{organisation_people_path(organisation)}"), I18n.t('navigation.people'))
    end

    it 'shows the entry on the mobile "more" page' do
      get organisation_mobile_more_path(organisation)

      expect(response.body).to include(%(href="#{organisation_people_path(organisation)}"))
    end
  end

  shared_examples 'may write' do
    it 'creates a person and lands on the list with it open' do
      expect { post organisation_people_path(organisation), params: valid_params.merge(q: 'erika') }.to change(Person, :count).by(1)

      created = Person.find_by!(name: 'Erika Beispiel')
      expect(response).to redirect_to(organisation_people_path(organisation, person_id: created.id, q: 'erika'))
      expect(created.creator_id).to eq(writer.id)
    end

    it 'updates a person' do
      patch organisation_person_path(organisation, person),
            params: { person: { phone: '0', lock_version: person.lock_version } }

      expect(response).to redirect_to(organisation_people_path(organisation, person_id: person.id))
      expect(person.reload.phone).to eq('0')
    end

    it 'deletes a person' do
      expect { delete organisation_person_path(organisation, person) }.to change(Person, :count).by(-1)
      expect(response).to redirect_to(organisation_people_path(organisation))
    end

    it 'opens the form in the lane' do
      get new_organisation_person_path(organisation), headers: frame_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="person_name"', I18n.t('views.organisations.people.form.shared_hint'))
    end
  end

  describe 'with manage_people' do
    let(:writer) { manager }

    before { sign_in manager }

    include_examples 'may write'
  end

  describe 'a guest role (billable: false) with manage_people' do
    let(:writer) { guest_manager }

    before { sign_in guest_manager }

    include_examples 'may write'
  end

  describe 'an account admin without any permission row' do
    let(:writer) { admin }

    before do
      expect(Permission.where(category: 'people', role: admin.memberships.first.role)).to be_empty
      sign_in admin
    end

    include_examples 'may write'
  end

  describe 'another organisation' do
    let(:foreign_person) do
      ActsAsTenant.with_tenant(other_organisation) { create(:person, organisation: other_organisation) }
    end

    before { sign_in admin }

    # One request per example: after a 404 the test session is signed out.
    it 'answers 404 for show of a person of another organisation' do
      get organisation_person_path(organisation, foreign_person), headers: frame_headers

      expect(response).to have_http_status(:not_found)
    end

    it 'answers 404 for update and leaves the row alone' do
      patch organisation_person_path(organisation, foreign_person), params: { person: { phone: '0' } }

      expect(response).to have_http_status(:not_found)
      expect(Person.unscoped.find(foreign_person.id).phone).to be_nil
    end

    it 'answers 404 for destroy and keeps the row' do
      delete organisation_person_path(organisation, foreign_person)

      expect(response).to have_http_status(:not_found)
      expect(Person.unscoped.exists?(foreign_person.id)).to be(true)
    end

    # The app's rule for an organisation the user is not a member of (every
    # page, ApplicationController#load_tenant_from_session): to the picker,
    # nothing of the other organisation rendered.
    it 'sends the page of an organisation the user is not in to the organisation picker' do
      foreign_person
      get organisation_people_path(other_organisation)

      expect(response).to redirect_to(select_organisation_path)
    end
  end

  describe 'the lane' do
    before { sign_in manager }

    it 'opens a person on a full visit with ?person_id=' do
      get organisation_people_path(organisation, person_id: person.id)

      expect(response.body).to include('show-content', 'Doris Dienstleister', 'selected-row')
    end

    it 'opens the form on a full visit with ?new=person' do
      get organisation_people_path(organisation, new: 'person')

      expect(response.body).to include('id="person_name"')
    end

    it 'answers a lane request of the index with the lane alone' do
      get organisation_people_path(organisation, person_id: person.id), headers: frame_headers

      expect(response.body).to start_with(%(<turbo-frame id="#{Organisations::PeopleController::DETAIL_FRAME_ID}">))
      expect(response.body).to include('Doris Dienstleister')
    end

    it 'sends a full visit of show to the index with the person open' do
      get organisation_person_path(organisation, person)

      expect(response).to redirect_to(organisation_people_path(organisation, person_id: person.id))
    end

    it 'renders the mobile list and detail one after the other' do
      get organisation_people_path(organisation, person_id: person.id, viewport: 'mobile')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('people-mobile-grid', 'Doris Dienstleister')
    end

    it 'shows the form again with the reason when the save is refused' do
      post organisation_people_path(organisation), params: { person: { name: '' } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('id="person_name"')
    end

    it 'shows the current values and the stale message when someone else saved first' do
      stale_version = person.lock_version
      person.update!(phone: 'from the other side')

      patch organisation_person_path(organisation, person), params: { person: { phone: 'mine', lock_version: stale_version } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(CGI.escapeHTML(I18n.t('controllers.people.update.stale')), 'from the other side')
      expect(person.reload.phone).to eq('from the other side')
    end

    it 'shows a duplicate hint for a row with the same name' do
      twin = create(:person, organisation: organisation, name: 'doris  DIENSTLEISTER')

      get organisation_person_path(organisation, person), headers: frame_headers

      expect(response.body).to include(I18n.t('views.organisations.people.show.duplicates_title'),
                                       organisation_person_path(organisation, twin))
    end

    it 'lists the history without values' do
      patch organisation_person_path(organisation, person), params: { person: { phone: '0', lock_version: person.lock_version } }

      get organisation_person_path(organisation, person), headers: frame_headers

      expect(response.body).to include(I18n.t('views.organisations.people.history.title'))
    end

    it 'filters and searches the list' do
      get organisation_people_path(organisation, kind: 'contacts', q: 'dienst')

      expect(response.body).to include('Doris Dienstleister')
      expect(response.body).not_to include(CGI.escapeHTML(manager.display_name))
    end
  end

  it 'has no missing translation on the page' do
    sign_in admin
    get organisation_people_path(organisation, person_id: person.id)

    expect(response.body).not_to include('translation missing', 'Translation missing')
  end
end
