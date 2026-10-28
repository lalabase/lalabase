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

      expect(response.body).to include(I18n.t('views.organisations.people.show.duplicate_prefix'),
                                       "person_id=#{twin.id}")
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

  # Often only "Herr Müller" or "Frau Müller" is known. The salutation is free
  # text; the form suggests the usual ones as a grey example only.
  describe 'the salutation' do
    before { sign_in manager }

    it 'saves it from the form and shows it in the lane' do
      patch organisation_person_path(organisation, person),
            params: { person: { salutation: 'Frau Dr.', lock_version: person.lock_version } }
      expect(person.reload.salutation).to eq('Frau Dr.')

      get organisation_person_path(organisation, person), headers: frame_headers

      expect(response.body).to include(Person.human_attribute_name(:salutation), 'Frau Dr.')
    end

    it 'offers a free text field with the suggestions as placeholder' do
      get edit_organisation_person_path(organisation, person), headers: frame_headers

      field = Nokogiri::HTML(response.body).at_css('input#person_salutation')
      expect(field).to be_present
      expect(field['type']).to eq('text')
      expect(field['placeholder']).to eq(I18n.t('views.organisations.people.form.placeholders.salutation'))
    end

    it 'shows no salutation line for a person without one' do
      get organisation_person_path(organisation, person), headers: frame_headers

      expect(response.body).to include('Doris Dienstleister')
      expect(response.body).not_to include(">#{Person.human_attribute_name(:salutation)}<")
    end
  end

  # Review round 1, finding 1: the form only offered ACTIVE members, so the row
  # of a deactivated member showed "Kein Mitglied" selected, and any save (only
  # the phone changed) dropped the link without anybody noticing.
  describe 'a row linked to a deactivated member' do
    let(:former) { member_with(role_with, first_name: 'Frieda') }
    let!(:linked) { create(:person, organisation: organisation, user: former, name: 'Frieda Former') }

    before do
      Membership.find_by(user: former, organisation: organisation).update!(active: false)
      sign_in admin
    end

    it 'keeps the member selected in the edit form' do
      get edit_organisation_person_path(organisation, linked), headers: frame_headers

      expect(response.body).to match(/<option selected="selected" value="#{former.id}">/)
    end

    it 'keeps the link when the form is saved with its own values' do
      patch organisation_person_path(organisation, linked),
            params: { person: { user_id: former.id, phone: '1', lock_version: linked.lock_version } }

      expect(linked.reload.user_id).to eq(former.id)
      expect(linked.phone).to eq('1')
    end
  end

  # Review round 1, finding 2: one users query per contact row that still
  # points at a former member.
  it 'loads the list without one query per contact linked to a former member' do
    formers = Array.new(3) { |index| member_with(role_with, first_name: "Ehemalig#{index}") }
    formers.each { |former| create(:person, organisation: organisation, user: former) }
    Membership.where(user: formers, organisation: organisation).update_all(active: false)
    sign_in admin

    get organisation_people_path(organisation)

    expect(response).to have_http_status(:ok)
  end

  # Review round 1, finding 3: the policy scope and visible_record? each hid
  # the row of a member the reader cannot see, and no request pinned either.
  describe 'a row linked to a member the writer cannot see' do
    let(:project) { create(:project, organisation: organisation) }
    let(:stranger) { member_with(role_with, first_name: 'Sven') }
    let!(:hidden_row) { create(:person, organisation: organisation, user: stranger, phone: 'secret') }

    before do
      create(:project_permission, user: manager, project: project, tickets_access: :read_only)
      create(:project_permission, user: stranger, project: create(:project, organisation: organisation),
                                  tickets_access: :read_only)
      sign_in manager
    end

    it 'answers 404 for show' do
      get organisation_person_path(organisation, hidden_row), headers: frame_headers

      expect(response).to have_http_status(:not_found)
    end

    it 'answers 404 for update and leaves the row alone' do
      patch organisation_person_path(organisation, hidden_row), params: { person: { phone: '0' } }

      expect(response).to have_http_status(:not_found)
      expect(hidden_row.reload.phone).to eq('secret')
    end

    it 'answers 404 for destroy and keeps the row' do
      delete organisation_person_path(organisation, hidden_row)

      expect(response).to have_http_status(:not_found)
      expect(Person.exists?(hidden_row.id)).to be(true)
    end

    # Review round 1, finding 4: the member select must offer only what the
    # members page shows this reader, and only active members.
    it 'offers only visible, active members in the form' do
      colleague = member_with(role_with, first_name: 'Carla')
      create(:project_permission, user: colleague, project: project, tickets_access: :read_only)
      former = member_with(role_with, first_name: 'Fritz')
      create(:project_permission, user: former, project: project, tickets_access: :read_only)
      Membership.find_by(user: former, organisation: organisation).update!(active: false)

      get new_organisation_person_path(organisation), headers: frame_headers

      expect(response.body).to include(%(value="#{colleague.id}"), %(value="#{manager.id}"))
      expect(response.body).not_to include(%(value="#{stranger.id}"))
      expect(response.body).not_to include(%(value="#{former.id}"))
    end
  end

  # Review round 2, finding 1: "Angaben ergänzen" must name the member in the
  # PAGE address too: below the lane width and on a reload only that is used.
  it 'puts the member into the page address of "Angaben ergänzen"' do
    sign_in admin
    member = member_with(role_with, first_name: 'Ohne')

    get member_organisation_people_path(organisation, member.id), headers: frame_headers

    expect(response.body).to include(CGI.escapeHTML({ new: 'person', user_id: member.id }.to_json),
                                     "user_id=#{member.id}", I18n.t('views.organisations.people.show.add_details'))
  end

  it 'opens the form with the member chosen on a full visit with ?new=person&user_id=' do
    sign_in admin
    member = member_with(role_with, first_name: 'Ohne')

    get organisation_people_path(organisation, new: 'person', user_id: member.id)

    expect(response.body).to include(%(type="hidden" value="#{member.id}" name="person[user_id]"))
    expect(response.body[/<input[^>]*id="person_name"[^>]*>/]).to include('readonly', CGI.escapeHTML(member.display_name))
  end

  # Review round 2, finding 2: a raw user_id in the address named any account
  # in the member select, also one the reader may not see or of another org.
  describe 'a raw user_id in the address of the new form' do
    let(:project) { create(:project, organisation: organisation) }
    let(:stranger) { member_with(role_with, first_name: 'Verborgen') }
    let(:outsider) { create(:user, first_name: 'Fremdorga', last_name: 'Nisation') }

    before do
      create(:project_permission, user: manager, project: project, tickets_access: :read_only)
      create(:project_permission, user: stranger, project: create(:project, organisation: organisation),
                                  tickets_access: :read_only)
      create(:membership, user: outsider, organisation: other_organisation)
      sign_in manager
    end

    it 'does not name a member the reader cannot see' do
      get new_organisation_person_path(organisation, user_id: stranger.id), headers: frame_headers

      expect(response.body).not_to include('Verborgen', stranger.id)
    end

    it 'does not name an account of another organisation' do
      get organisation_people_path(organisation, new: 'person', user_id: outsider.id)

      expect(response.body).not_to include('Fremdorga', outsider.id)
    end
  end

  # Review round 2, finding 3: a row whose member was deactivated is a contact;
  # list and lane show the row's own name, not the account's current one.
  it 'shows the row name, not the account, for a row of a deactivated member' do
    former = member_with(role_with, first_name: 'Alt')
    create(:person, organisation: organisation, user: former, name: 'Alt Name')
    Membership.find_by(user: former, organisation: organisation).update!(active: false)
    former.update!(first_name: 'Neu', last_name: 'Anders')
    row = Person.find_by!(user: former)
    sign_in admin

    get organisation_people_path(organisation, person_id: row.id)

    expect(response.body).to include('Alt Name')
    expect(response.body).not_to include('Neu Anders')
  end

  # Review round 2, finding 5: a hand-made request without a usable
  # lock_version must not crash.
  it 'answers a missing lock_version as a stale save, not with an error' do
    sign_in admin

    patch organisation_person_path(organisation, person), params: { person: { phone: '0', lock_version: '' } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(person.reload.phone).to eq('+49 30 1234567')
  end

  # Review round 2, finding 6: a linked row shows the member's name; its own
  # name field is read only there.
  it 'shows the name field read only for a linked row' do
    linked = create(:person, organisation: organisation, user: viewer, name: 'Kopie')
    sign_in admin

    get edit_organisation_person_path(organisation, linked), headers: frame_headers

    expect(response.body).to match(/<input[^>]*readonly="readonly"[^>]*id="person_name"|<input[^>]*id="person_name"[^>]*readonly="readonly"/)
  end

  # Review round 3, finding 1: the member select named the CURRENT account of
  # a deactivated member, also to a reader who may not see that member.
  it 'labels the stored former member with the row name, not the account' do
    project = create(:project, organisation: organisation)
    create(:project_permission, user: manager, project: project, tickets_access: :read_only)
    hidden = member_with(role_with, first_name: 'Kopie')
    create(:project_permission, user: hidden, project: create(:project, organisation: organisation),
                                tickets_access: :read_only)
    row = create(:person, organisation: organisation, user: hidden, name: 'Kopie Name')
    Membership.find_by(user: hidden, organisation: organisation).update!(active: false)
    hidden.update!(first_name: 'Geheim', last_name: 'Neuname')
    sign_in manager

    get edit_organisation_person_path(organisation, row), headers: frame_headers

    expect(response.body).not_to include('Neuname')
    expect(response.body).to match(/<option selected="selected" value="#{hidden.id}">Kopie Name/)
  end

  # Review round 3, finding 2: the name of a former member's row is the only
  # name shown, so it stays editable.
  it 'keeps the name field editable for the row of a former member' do
    former = member_with(role_with, first_name: 'Alt')
    row = create(:person, organisation: organisation, user: former, name: 'Alt Name')
    Membership.find_by(user: former, organisation: organisation).update!(active: false)
    sign_in admin

    get edit_organisation_person_path(organisation, row), headers: frame_headers

    expect(response.body[/<input[^>]*id="person_name"[^>]*>/]).not_to include('readonly')
  end

  # Review round 3, finding 3: ?user_id= only preselects a member without a row
  # who is active.
  describe 'preselecting a member through the address' do
    before { sign_in admin }

    it 'does not preselect a member who already has a row' do
      taken = member_with(role_with, first_name: 'Vergeben')
      create(:person, organisation: organisation, user: taken)

      get new_organisation_person_path(organisation, user_id: taken.id), headers: frame_headers

      expect(response.body).not_to include('selected="selected"')
      expect(response.body[/<input[^>]*id="person_name"[^>]*>/]).not_to include('readonly')
    end

    it 'does not preselect a deactivated member' do
      former = member_with(role_with, first_name: 'Inaktiv')
      Membership.find_by(user: former, organisation: organisation).update!(active: false)

      get new_organisation_person_path(organisation, user_id: former.id), headers: frame_headers

      expect(response.body).not_to include('selected="selected"')
    end
  end

  # Review round 3, finding 4: the address rules of user_id (form group, the
  # "+" takes it away, an unopened one is dropped).
  it 'wires user_id as part of the lane form state' do
    sign_in admin

    get organisation_people_path(organisation, user_id: 'x')

    expect(response.body).to include(CGI.escapeHTML('"form":["new","user_id"]'),
                                     CGI.escapeHTML('["person_id","member_id","user_id"]'),
                                     CGI.escapeHTML('{"user_id":"x"}'))
  end

  # Review round 3, findings 5 and 6: hand-made lock versions.
  it 'creates a person even when the request carries an unusable lock_version' do
    sign_in admin

    expect do
      post organisation_people_path(organisation), params: { person: { name: 'Neu Person', lock_version: '' } }
    end.to change(Person, :count).by(1)
  end

  it 'answers a lock_version beyond the column as a stale save' do
    sign_in admin

    patch organisation_person_path(organisation, person),
          params: { person: { phone: '0', lock_version: '99999999999999999999' } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(person.reload.phone).to eq('+49 30 1234567')
  end

  # Review round 3, finding 7: a duplicate opens like a row, with its own
  # address, not inside the frame alone.
  it 'links a duplicate to the page address of that person' do
    twin = create(:person, organisation: organisation, name: 'Doris Dienstleister')
    sign_in admin

    get organisation_person_path(organisation, person), headers: frame_headers

    link = response.body[/<a[^>]*href="[^"]*person_id=#{twin.id}[^"]*"[^>]*>/]
    expect(link).to include('data-turbo-frame="_top"')
  end

  # The design of 26.10.2026: a member without a row of their own opens in
  # the lane too (?member_id=), with name and email from the account.
  describe 'the lane of a member without a row' do
    let(:project) { create(:project, organisation: organisation) }
    let(:colleague) { member_with(role_with, first_name: 'Kolja') }
    let(:stranger) { member_with(role_with, first_name: 'Sven') }

    before do
      create(:project_permission, user: viewer, project: project, tickets_access: :read_only)
      create(:project_permission, user: colleague, project: project, tickets_access: :read_only)
      create(:project_permission, user: stranger, project: create(:project, organisation: organisation),
                                  tickets_access: :read_only)
    end

    it 'shows the account name, email and what is missing' do
      sign_in viewer

      get member_organisation_people_path(organisation, colleague.id), headers: frame_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(CGI.escapeHTML(colleague.display_name), colleague.email,
                                       I18n.t('views.organisations.people.show.read_only'))
      expect(response.body).not_to include(I18n.t('views.organisations.people.show.add_details'))
    end

    it 'answers 404 for a member the reader cannot see' do
      sign_in viewer

      get member_organisation_people_path(organisation, stranger.id), headers: frame_headers

      expect(response).to have_http_status(:not_found)
    end

    it 'answers 403 without the right' do
      sign_in nobody

      get member_organisation_people_path(organisation, colleague.id), headers: frame_headers

      expect(response).to have_http_status(:forbidden)
    end

    it 'opens the row of a member who has one' do
      row = create(:person, organisation: organisation, user: colleague, function: 'Netzwerk')
      sign_in viewer

      get member_organisation_people_path(organisation, colleague.id)

      expect(response).to redirect_to(organisation_people_path(organisation, person_id: row.id))
    end

    it 'opens on a full visit with ?member_id= and marks the row' do
      sign_in viewer

      get organisation_people_path(organisation, member_id: colleague.id)

      expect(response.body).to include('show-content', CGI.escapeHTML(I18n.t('views.organisations.people.show.bare_text', first_name: colleague.display_name)))
      expect(response.body).to match(/class="people-row selected-row"[^>]*>|data-list-row-id-value="#{colleague.id}"[^>]*class="people-row selected-row"/)
    end

    it 'drops an unreadable ?member_id= from the address' do
      sign_in viewer

      get organisation_people_path(organisation, member_id: stranger.id)

      expect(response.body).not_to include('show-content')
      expect(response.body).to include(CGI.escapeHTML({ member_id: stranger.id }.to_json))
    end
  end

  it 'counts all people, members and contacts in the head and the filters' do
    sign_in admin
    admin

    get organisation_people_path(organisation, kind: 'contacts')

    members = Membership.where(organisation: organisation, active: true).count
    scope = 'views.organisations.people.index'
    line = I18n.t("#{scope}.count_line", people: I18n.t("#{scope}.count_people", count: members + 1),
                                         members: I18n.t("#{scope}.count_members", count: members),
                                         contacts: I18n.t("#{scope}.count_contacts", count: 1))
    expect(response.body).to include(line)
  end

  describe 'the row of an active member' do
    let!(:row) { create(:person, organisation: organisation, user: viewer, function: 'IT', email: 'alt@example.com') }

    before { sign_in admin }

    it 'offers to remove the added details, not to delete the person' do
      get organisation_person_path(organisation, row), headers: frame_headers

      expect(response.body).to include(I18n.t('views.organisations.people.show.remove_details'))
      expect(response.body).not_to include(">#{I18n.t('views.organisations.people.show.delete')}<")
    end

    it 'shows the email of the account, and locks name and email in the form' do
      get edit_organisation_person_path(organisation, row), headers: frame_headers

      expect(response.body[/<input[^>]*id="person_email"[^>]*>/]).to include('readonly', viewer.email)
      expect(response.body).not_to include('name="person[user_id]"')
    end

    it 'keeps the link when the form is saved' do
      patch organisation_person_path(organisation, row), params: { person: { function: 'Netz', lock_version: row.lock_version } }

      expect(row.reload.user_id).to eq(viewer.id)
      expect(row.function).to eq('Netz')
    end
  end

  # External review of 26.10.2026.
  describe 'on a phone' do
    before { sign_in admin }

    it 'keeps the phone view when a save is refused' do
      post organisation_people_path(organisation), params: { person: { name: '' }, viewport: 'mobile' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('people-mobile-grid', 'name="viewport"')
    end

    it 'carries the phone view into the edit form of the lane' do
      get organisation_people_path(organisation, person_id: person.id, viewport: 'mobile')

      expect(response.body).to include(edit_organisation_person_path(organisation, person, viewport: 'mobile'))
    end

    it 'lands on the phone view after a save' do
      patch organisation_person_path(organisation, person),
            params: { person: { phone: '0', lock_version: person.lock_version }, viewport: 'mobile' }

      expect(response).to redirect_to(organisation_people_path(organisation, person_id: person.id, viewport: 'mobile'))
    end
  end

  it 'keeps the member select when a link is refused (the member has a row already)' do
    taken = member_with(role_with, first_name: 'Vergeben')
    create(:person, organisation: organisation, user: taken)
    sign_in admin

    patch organisation_person_path(organisation, person),
          params: { person: { user_id: taken.id, lock_version: person.lock_version } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include('name="person[user_id]"')
    expect(response.body[/<input[^>]*id="person_name"[^>]*>/]).not_to include('readonly')
  end

  it 'opens a row from the keyboard (Enter and Space)' do
    sign_in admin

    get organisation_people_path(organisation)

    row = response.body[/<li[^>]*data-list-row-id-value="#{person.id}"[^>]*>/]
    expect(row).to include(CGI.escapeHTML('keydown.enter->list-row#click'), CGI.escapeHTML('keydown.space->list-row#click'))
  end

  # Review of db1b0288a: the empty lane carried the content marker, so
  # layout-toggle took it for loaded and opened an empty column on every list
  # visit and after a delete.
  it 'renders no content marker in the empty lane, only with something open' do
    sign_in admin

    get organisation_people_path(organisation)
    expect(response.body).not_to match(/class="person-content/)

    get organisation_people_path(organisation, person_id: person.id)
    expect(response.body).to match(/class="person-content/)
  end

  # Review round 4.
  describe 'names of members the reader cannot see' do
    let(:project) { create(:project, organisation: organisation) }
    let(:hidden_writer) { member_with(role_with('manage_people'), first_name: 'Geheim') }

    before do
      create(:project_permission, user: manager, project: project, tickets_access: :read_only)
      create(:project_permission, user: hidden_writer, project: create(:project, organisation: organisation),
                                  tickets_access: :read_only)
    end

    it 'shows neither the creator nor the editor by name' do
      row = Current.set(user: hidden_writer) { create(:person, organisation: organisation, creator: hidden_writer) }
      Current.set(user: hidden_writer) { row.update!(phone: '1') }
      sign_in manager

      get organisation_person_path(organisation, row), headers: frame_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('Geheim')
      expect(response.body).to include(I18n.t('views.organisations.people.history.updated', actor: I18n.t('views.organisations.people.show.someone'),
                                                                                            fields: Person.human_attribute_name(:phone)))
    end
  end

  it 'keeps the phone view in a lane frame (show after "Abbrechen")' do
    sign_in admin

    get organisation_person_path(organisation, person, viewport: 'mobile'), headers: frame_headers

    expect(response.body).not_to include('data-lane-close')
  end

  it 'counts with the right singular and plural forms' do
    sign_in admin
    get organisation_people_path(organisation)

    expect(response.body).to match(/1 Kontakt(?!e)/)
    expect(response.body).not_to include('1 Kontakte')
  end

  it 'names the member of the hint through the name display setting' do
    reader = admin
    reader.preference_store.set!('name_display', 'initial_last')
    member = member_with(role_with, first_name: 'Carla')
    sign_in reader

    get member_organisation_people_path(organisation, member.id), headers: frame_headers

    expect(response.body).not_to include('wofür Carla')
  end

  it 'shows the member select again when a new row asks for a member who has one' do
    taken = member_with(role_with, first_name: 'Vergeben')
    create(:person, organisation: organisation, user: taken)
    sign_in admin

    post organisation_people_path(organisation), params: { person: { name: 'X', user_id: taken.id } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include('name="person[user_id]"')
    expect(response.body).not_to include(%(type="hidden" value="#{taken.id}"))
  end

  it 'opens no form for ?new=person without the right to write' do
    sign_in viewer

    get organisation_people_path(organisation, new: 'person')

    expect(response.body).not_to include('id="person_name"')
  end

  it 'sends ?member_id= of a member with a row to that row' do
    row = create(:person, organisation: organisation, user: viewer)
    sign_in admin

    get organisation_people_path(organisation, member_id: viewer.id)

    expect(response).to redirect_to(organisation_people_path(organisation, person_id: row.id))
  end

  it 'answers a lane request of the index with the member lane' do
    member = member_with(role_with, first_name: 'Lena')
    sign_in admin

    get organisation_people_path(organisation, member_id: member.id), headers: frame_headers

    expect(response.body).to include(I18n.t('views.organisations.people.show.add_details'), member.email)
  end

  it 'shows the account email of an active member in the lane, not an old row email' do
    row = create(:person, organisation: organisation, user: viewer, email: 'alt@example.com')
    sign_in admin

    get organisation_person_path(organisation, row), headers: frame_headers

    expect(response.body).to include(viewer.email)
    expect(response.body).not_to include('alt@example.com')
  end

  it 'has no missing translation on the page' do
    sign_in admin
    get organisation_people_path(organisation, person_id: person.id)

    expect(response.body).not_to include('translation missing', 'Translation missing')
  end
end
