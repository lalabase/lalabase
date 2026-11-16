# frozen_string_literal: true

require 'rails_helper'

# Taking a contact over into another organisation, through the page: the menu
# item on the card, the dialog in its frame, the submit. Both tenants are read
# afterwards; every refusal answers with the same status and body; the values
# of the copy come from the source row only.
RSpec.describe 'Organisations::PersonTakeovers', :ci_guard, :people_takeover, type: :request do
  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Süd GmbH') }
  # Reads in north, may not write there; may create people in south.
  let(:reader) { takeover_join(takeover_join(create(:user), north, 'view_people'), south, 'manage_people') }
  let!(:source) do
    takeover_person(north, name: 'Herr Schmidt', function: 'Technik', email: 'schmidt@example.com',
                           phone: '+49 30 1111111', notes: 'Nur vormittags erreichbar')
  end
  let(:frame) { { 'Turbo-Frame' => "person-takeover-modal-#{source.id}" } }
  let(:stream) { { 'Accept' => 'text/vnd.turbo-stream.html, text/html, application/xhtml+xml' } }
  let(:token) { 'a1b2c3d4e5f60718' }

  after { ActsAsTenant.current_tenant = nil }

  def submit(person_id: source.id, target: south.id, fields: Actors::TakeOverPerson::DEFAULT_FIELDS, **extra)
    post organisation_person_takeover_path(north, person_id),
         params: { target: target, fields: fields, modal_token: token }.merge(extra), headers: stream
  end

  def copies
    ActsAsTenant.with_tenant(south) { Person.where(organisation: south).to_a }
  end

  def counts
    [takeover_count(north), takeover_count(south)]
  end

  describe 'the menu item' do
    # An account admin of north sees every row, also a member's (a reader with
    # view_people sees only the members the members page shows them).
    let(:admin) { takeover_join(takeover_join(create(:user), north, title: Role::ACCOUNT_ADMIN_TITLE), south, 'manage_people') }

    def card(person, user: reader)
      sign_in user
      get organisation_people_path(north, person_id: person.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(CGI.escapeHTML(person.name))
      response.body
    end

    let(:item) { new_organisation_person_takeover_path(north, source) }

    it 'is offered to a reader without the right to write in the source' do
      body = card(source)

      expect(body).to include(item, "person-takeover-modal-#{source.id}")
      expect(body).not_to include(edit_organisation_person_path(north, source))
    end

    it 'is absent for a member' do
      member = takeover_join(create(:user, first_name: 'Mia', last_name: 'Mitglied'), north)
      row = takeover_person(north, name: 'Mia Mitglied', user: member)

      expect(card(row, user: admin)).not_to include(new_organisation_person_takeover_path(north, row))
    end

    it "is absent for a deactivated member's row" do
      member = takeover_join(create(:user), north)
      row = takeover_person(north, name: 'Dora Deaktiviert', user: member)
      ActsAsTenant.with_tenant(north) { Membership.find_by!(user: member, organisation: north).update!(active: false) }

      expect(card(row, user: admin)).not_to include(new_organisation_person_takeover_path(north, row))
    end

    it 'is absent when the viewer has no organisation to take the contact to' do
      alone = takeover_join(create(:user), north, 'manage_people')
      takeover_join(alone, create(:organisation), 'view_people')

      body = card(source, user: alone)

      expect(body).not_to include(item)
      expect(body).to include(organisation_person_path(north, source))
    end
  end

  describe 'the dialog' do
    it 'lists only organisations where the viewer may create people, never the source' do
      west = create(:organisation, name: 'West AG')
      takeover_join(reader, west, 'view_people')
      east = create(:organisation, name: 'Ost AG')
      takeover_join(reader, east, 'manage_people', active: false)
      sign_in reader

      get new_organisation_person_takeover_path(north, source), headers: frame

      expect(response).to have_http_status(:ok)
      options = Nokogiri::HTML(response.body).css('select[name="target"] option').map { |option| option['value'] }
      expect(options).to eq([south.id])
      expect(response.body).to include('Herr Schmidt', 'Süd GmbH')
      expect(response.body).not_to include('West AG', 'Ost AG')
    end

    it 'sends a visit without the frame to the card on the list' do
      sign_in reader

      get new_organisation_person_takeover_path(north, source)

      expect(response).to redirect_to(organisation_people_path(north, person_id: source.id))
    end

    it 'ticks every field but the notes' do
      sign_in reader

      get new_organisation_person_takeover_path(north, source), headers: frame

      boxes = Nokogiri::HTML(response.body).css('input[name="fields[]"]').to_h { |box| [box['value'], box['checked'].present?] }
      expect(boxes).to eq('function' => true, 'company' => true, 'email' => true, 'phone' => true, 'notes' => false)
    end

    it 'answers a member, an unknown row, a viewer without a target and one without the right alike' do
      member = takeover_join(create(:user), north)
      row = takeover_person(north, name: 'Mia Mitglied', user: member)
      alone = takeover_join(create(:user), north, 'manage_people')
      admin = takeover_join(takeover_join(create(:user), north, title: Role::ACCOUNT_ADMIN_TITLE), south, 'manage_people')
      former = takeover_join(create(:user), north)
      former_row = takeover_person(north, name: 'Dora Deaktiviert', user: former)
      ActsAsTenant.with_tenant(north) { Membership.find_by!(user: former, organisation: north).update!(active: false) }
      blind = takeover_join(takeover_join(create(:user), north), south, 'manage_people')
      # Each request after the first runs with Prosopite paused: the same
      # queries for another user are a loop of requests, not an N+1.
      cases = [[reader, row.id], [reader, SecureRandom.uuid], [alone, source.id], [admin, row.id], [admin, former_row.id],
               [blind, source.id]]
      answers = cases.each_with_index.map do |(user, id), index|
        sign_in user
        request = -> { get new_organisation_person_takeover_path(north, id), headers: { 'Turbo-Frame' => 'person-takeover-modal-x' } }
        index.zero? ? request.call : Prosopite.pause(&request)
        [response.status, response.body]
      end

      expect(answers.uniq.size).to eq(1)
      expect(answers.first.first).to eq(404)
      expect(answers.first.last).to include(I18n.t('controllers.people.not_found'))
    end
  end

  describe 'the takeover' do
    before { sign_in reader }

    it 'copies the contact into the target and checks both tenants' do
      expect { submit(fields: %w[function email]) }.to change { counts }.from([1, 0]).to([1, 1])

      copy = copies.first
      expect(copy.attributes.slice('name', 'function', 'email', 'phone', 'notes', 'user_id'))
        .to eq('name' => 'Herr Schmidt', 'function' => 'Technik', 'email' => 'schmidt@example.com',
               'phone' => nil, 'notes' => nil, 'user_id' => nil)
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(organisation_people_path(south, person_id: copy.id))
      expect(flash[:notice]).to eq(I18n.t('controllers.people.takeover.success', source: 'Nord GmbH'))
      expect(ActsAsTenant.with_tenant(north) { source.reload.attributes.slice('name', 'notes', 'lock_version') })
        .to eq('name' => 'Herr Schmidt', 'notes' => 'Nur vormittags erreichbar', 'lock_version' => 0)
      expect(ActsAsTenant.current_tenant).to be_nil
    end

    it 'takes no value from the request, only from the source row' do
      submit(fields: %w[email phone notes] + ['name'], name: 'Fake', email: 'fake@example.com',
             person: { name: 'Fake', email: 'fake@example.com', notes: 'forged', user_id: reader.id },
             values: { email: 'fake@example.com' })

      copy = copies.first
      expect(copy.attributes.slice('name', 'email', 'phone', 'notes', 'user_id'))
        .to eq('name' => 'Herr Schmidt', 'email' => 'schmidt@example.com', 'phone' => '+49 30 1111111',
               'notes' => 'Nur vormittags erreichbar', 'user_id' => nil)
    end

    it 'takes no value from the request for a field that is not ticked' do
      submit(fields: %w[email], person: { function: 'Forged', department: 'Forged', notes: 'forged' },
             function: 'Forged', notes: 'forged')

      copy = copies.first
      expect(copy.attributes.values_at('email', 'function', 'department', 'notes')).to eq(['schmidt@example.com', nil, nil, nil])
    end

    it 'reads a person id in another spelling as the same row' do
      expect { submit(person_id: source.id.upcase.delete('-')) }.to change { counts }.from([1, 0]).to([1, 1])

      expect(response).to have_http_status(:see_other)
    end

    it 'names the reason when the copy fails validation, after every right was checked' do
      ActsAsTenant.with_tenant(north) { source.update_column(:email, 'not an address') }

      expect { submit(fields: %w[email]) }.not_to(change { counts })

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(CGI.escapeHTML(I18n.t('controllers.people.takeover.failed')))
      expect(response.body).not_to include(I18n.t('controllers.people.not_found'))
    end

    it 'cannot bring a value the source row does not hold' do
      submit(fields: %w[department company salutation additional_details])

      copy = copies.first
      expect(copy.attributes.values_at('department', 'company', 'salutation')).to eq([nil, 'Beispiel GmbH', nil])
      expect(copy.additional_details).to eq([])
    end

    # The app's rule for writes: the POST keeps the session's organisation. A
    # full page visit of the target moves it; in the browser Turbo renders the
    # redirect's answer without one, so that happens on the next page visit.
    it 'does not move the organisation of the session; a full page visit of the target does' do
      get organisation_people_path(north)
      expect(session[:current_organisation_id]).to eq(north.id)

      submit
      expect(session[:current_organisation_id]).to eq(north.id)

      follow_redirect!
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('controllers.people.takeover.success', source: 'Nord GmbH'))
      expect(session[:current_organisation_id]).to eq(south.id)
      expect(ActsAsTenant.current_tenant).to be_nil
    end
  end

  describe 'one refusal' do
    let(:others) { create(:organisation, name: 'Fremd AG') }

    # The answer, with the person id the request named written as ID: the
    # stream closes the opening the client asked from, whose id carries it.
    # Prosopite is paused after the first request of the example: the same
    # queries for another case are a loop of requests, not an N+1.
    def answer_of(user: reader, person_id: source.id, **options)
      sign_in user
      request = -> { submit(person_id: person_id, **options) }
      expect { @answered ? Prosopite.pause(&request) : request.call }.not_to(change { counts })
      @answered = true
      expect(ActsAsTenant.current_tenant).to be_nil
      # The flash component draws a random id of its own on every render.
      [response.status, response.media_type, response.body.gsub(person_id.to_s, 'ID').gsub(/flash_\h{8}/, 'flash_X')]
    end

    it 'answers every case with the same status and body and writes nothing' do
      member = takeover_join(create(:user), north)
      member_row = takeover_person(north, name: 'Mia Mitglied', user: member)
      former = takeover_join(create(:user), north)
      former_row = takeover_person(north, name: 'Dora Deaktiviert', user: former)
      ActsAsTenant.with_tenant(north) { Membership.find_by!(user: former, organisation: north).update!(active: false) }
      east = create(:organisation)
      takeover_join(reader, east, 'manage_people', active: false)
      west = create(:organisation)
      takeover_join(reader, west, 'view_people')
      blind = takeover_join(takeover_join(create(:user), north), south, 'manage_people')
      both = takeover_join(takeover_join(create(:user), north, 'manage_people'), south, 'manage_people')
      admin = takeover_join(takeover_join(create(:user), north, title: Role::ACCOUNT_ADMIN_TITLE), south, 'manage_people')

      answers = {
        unknown: answer_of(person_id: SecureRandom.uuid),
        member: answer_of(person_id: member_row.id),
        deactivated_member: answer_of(person_id: former_row.id),
        foreign_target: answer_of(target: others.id),
        deactivated_target: answer_of(target: east.id),
        target_without_right: answer_of(target: west.id),
        source_as_target: answer_of(user: both, target: north.id),
        source_without_view_people: answer_of(user: blind),
        malformed_target: answer_of(target: 'x'),
        member_read_by_admin: answer_of(user: admin, person_id: member_row.id),
        deactivated_member_read_by_admin: answer_of(user: admin, person_id: former_row.id)
      }

      confirmed = answers.keys.to_h do |key|
        options = { member: { person_id: member_row.id }, deactivated_member: { person_id: former_row.id },
                    foreign_target: { target: others.id }, deactivated_target: { target: east.id },
                    target_without_right: { target: west.id }, source_without_view_people: { user: blind },
                    source_as_target: { user: both, target: north.id } }.fetch(key, nil)
        next [key, nil] unless options

        target = options.fetch(:target, south.id)
        [:"#{key}_confirmed", answer_of(**options, confirm_target: target)]
      end.compact.to_h
      answers.merge!(confirmed.compact)

      expect(answers.size).to eq(18)
      expect(answers.values.uniq.size).to eq(1), answers.transform_values(&:last).inspect
      status, media_type, body = answers.values.first
      expect([status, media_type]).to eq([404, 'text/vnd.turbo-stream.html'])
      expect(body).to include(I18n.t('controllers.people.not_found'), "person-takeover-modal-ID-#{token}")
    end

    it 'takes a readable contact over with the same request shape (the control of this group)' do
      sign_in reader

      expect { submit }.to change { counts }.from([1, 0]).to([1, 1])
    end
  end

  describe 'a same-named entry in the target' do
    let!(:existing) { takeover_person(south, name: 'Herr Schmidt', email: 'other@example.com') }

    before { sign_in reader }

    it 'asks first and writes nothing' do
      expect { submit }.not_to(change { counts })

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      name = I18n.t('controllers.people.takeover.duplicate_name', name: 'Herr Schmidt')
      question = I18n.t('controllers.people.takeover.duplicate', organisation: 'Süd GmbH', names: name)
      expect(response.body).to include(CGI.escapeHTML(question), "person-takeover-modal-#{source.id}-#{token}",
                                       I18n.t('views.organisations.people.takeover.confirm'))
      confirm = Nokogiri::HTML(response.body).at_css('input[name="confirm_target"]')
      expect(confirm['value']).to eq(south.id)
    end

    it 'creates on the explicit "create anyway" for that target' do
      expect { submit(confirm_target: south.id) }.to change { takeover_count(south) }.by(1)

      expect(response).to have_http_status(:see_other)
    end

    it 'answers a plain HTML submit with the question as a notice on the list' do
      expect do
        post organisation_person_takeover_path(north, source), params: { target: south.id, fields: ['email'], modal_token: token }
      end.not_to(change { counts })

      expect(response).to redirect_to(organisation_people_path(north, person_id: source.id))
      expect(flash[:alert]).to include('Süd GmbH')
    end

    it 'refuses the question when no target is left by the time it is drawn' do
      allow(Actors::TakeOverPerson).to receive(:targets_for).and_return([])

      expect { submit }.not_to(change { counts })

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include(I18n.t('views.organisations.people.takeover.confirm'))
      expect(response.body).to include(I18n.t('controllers.people.not_found'))
    end

    it 'asks again when the confirmation names another target' do
      expect { submit(confirm_target: north.id) }.not_to(change { counts })

      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
