# frozen_string_literal: true

require 'rails_helper'

# Taking a contact over into another organisation, through the page: the menu
# item on the card, the dialog in its frame, the submit. Both tenants are read
# afterwards; every refusal answers with the same status and body; the values
# of the copy come from the source row only.
RSpec.describe 'Organisations::PersonTakeovers', :ci_guard, :people_takeover, type: :request do
  include AllPeopleHelpers

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

  # The card of a person above the organisations (GET /people) offers the takeover as
  # well: the same dialog, loaded into a frame of that page. A fragment of an
  # organisation's controller on a page without an organisation.
  describe 'the dialog on the people page above the organisations' do
    let(:people_page) { "http://www.example.com#{all_people_path(card: "#{north.id}:person:#{source.id}")}" }

    before { sign_in reader }

    it 'renders into its frame and leaves the organisation of the session where it was' do
      get organisation_people_path(south)
      expect(session[:current_organisation_id]).to eq(south.id)

      get new_organisation_person_takeover_path(north, source), headers: frame.merge('Referer' => people_page)

      expect(response).to have_http_status(:ok)
      expect(response.body).to start_with(%(<turbo-frame id="person-takeover-modal-#{source.id}">))
      expect(response.body).to include('Herr Schmidt', organisation_person_takeover_path(north, source))
      expect(session[:current_organisation_id]).to eq(south.id)
      expect(ActsAsTenant.current_tenant).to be_nil
    end

    it 'knows the page it was loaded on as one above the organisations: no assistant for the fragment' do
      get new_organisation_person_takeover_path(north, source), headers: frame.merge('Referer' => people_page)
      expect(controller.send(:page_above_organisations?)).to be(true)

      # The same fragment on the people page of the organisation belongs to that organisation.
      own_page = "http://www.example.com#{organisation_people_path(north, person_id: source.id)}"
      get new_organisation_person_takeover_path(north, source), headers: frame.merge('Referer' => own_page)
      expect(response).to have_http_status(:ok)
      expect(controller.send(:page_above_organisations?)).to be(false)

      # A page of another host with the same path is no page of ours.
      get new_organisation_person_takeover_path(north, source), headers: frame.merge('Referer' => "http://elsewhere.example.com#{all_people_path}")
      expect(controller.send(:page_above_organisations?)).to be(false)
    end

    it 'takes the contact over from there as from the card of the organisation, without moving the session' do
      get organisation_people_path(south)

      expect { submit }.to change { takeover_count(south) }.by(1)

      copy = copies.find { |person| person.name == 'Herr Schmidt' }
      expect(response).to redirect_to(organisation_people_path(south, person_id: copy.id))
      expect(session[:current_organisation_id]).to eq(south.id)
    end

    # The card's menu opens the dialog with from=all_people, and the form carries it. Until
    # the review of #197 every answer led to an organisation's people page, and the reader
    # left the page above the organisations (the session's organisation moving with the
    # next visit there).
    describe 'opened by the card there' do
      let(:from) { Organisations::PersonTakeoversController::FROM_ALL_PEOPLE }

      def card_of(organisation, person)
        all_people_path(card: People::MergedCard.address_of(organisation.id, "person:#{person.id}"))
      end

      it 'carries where it was opened in its form' do
        get new_organisation_person_takeover_path(north, source, from: from), headers: frame

        form = Nokogiri::HTML(response.body).at_css("form[action='#{organisation_person_takeover_path(north, source)}']")
        expect(form.at_css('input[type="hidden"][name="from"]')['value']).to eq(from)
        get new_organisation_person_takeover_path(north, source), headers: frame
        expect(Nokogiri::HTML(response.body).at_css('input[name="from"]')).to be_nil
      end

      it 'comes back to the card of the copy after a takeover, which is the merged person', :aggregate_failures do
        get organisation_people_path(south)

        expect { submit(from: from) }.to change { takeover_count(south) }.by(1)

        copy = copies.find { |person| person.name == 'Herr Schmidt' }
        expect(response).to redirect_to(card_of(south, copy))
        expect(flash[:notice]).to eq(I18n.t('controllers.people.takeover.success', source: 'Nord GmbH'))
        expect(session[:current_organisation_id]).to eq(south.id)
        follow_redirect!
        expect(card_organisations(Nokogiri::HTML(response.body))).to eq(['Nord GmbH', 'Süd GmbH'])
      end

      it 'comes back to the card of the source after "merge instead" and after a reason' do
        existing = takeover_person(south, name: 'Herr Schmidt', email: 'other@example.com')

        expect { submit(from: from, merge_with: "person:#{existing.id}") }.not_to(change { counts })
        expect(response).to redirect_to(card_of(north, source))
        expect(flash[:notice]).to eq(I18n.t('controllers.people.takeover.merged_instead'))

        # A plain HTML submit answers the question as a notice on the card it came from.
        post organisation_person_takeover_path(north, source),
             params: { target: south.id, fields: Actors::TakeOverPerson::DEFAULT_FIELDS, modal_token: token, from: from }
        expect(response).to redirect_to(card_of(north, source))
      end

      # Review of #197: the question about a same-named entry draws the dialog again, and
      # its second submit ("merge instead", "create anyway") has to come back to the card
      # as well. No example sent `from` through the question.
      it 'keeps where it was opened in the dialog the question draws again' do
        takeover_person(south, name: 'Herr Schmidt', email: 'other@example.com')

        expect { submit(from: from) }.not_to(change { counts })

        expect(response).to have_http_status(:unprocessable_content)
        form = Nokogiri::HTML(response.body).at_css("form[action='#{organisation_person_takeover_path(north, source)}']")
        expect(form.at_css('button[name="merge_with"]')).to be_present
        expect(form.at_css('input[type="hidden"][name="from"]')['value']).to eq(from)
      end

      it 'sends a visit without the frame to the card above the organisations' do
        get new_organisation_person_takeover_path(north, source, from: from)

        expect(response).to redirect_to(card_of(north, source))
      end

      it 'answers the one refusal on the list above the organisations' do
        post organisation_person_takeover_path(north, SecureRandom.uuid), params: { target: south.id, from: from }

        expect(response).to redirect_to(all_people_path)
        expect(flash[:alert]).to eq(I18n.t('controllers.people.not_found'))
      end

      it 'reads nothing but its own word: any other value leads where it always did' do
        get new_organisation_person_takeover_path(north, source, from: '//elsewhere.example.com')

        expect(response).to redirect_to(organisation_people_path(north, person_id: source.id))
      end
    end
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

  # From the merges on (People S2): a takeover makes the source and its copy one person for
  # the reader, and the duplicate question offers to merge with the entry that is there
  # already instead of creating a second one.
  describe 'merging' do
    before { sign_in reader }

    def merged
      PersonGroupEntry.where(owner_id: reader.id).pluck(:organisation_id, :person_id)
    end

    def merges
      [PersonGroup.count, PersonGroupEntry.count]
    end

    it 'shows the source and its copy as one person on the list above the organisations' do
      submit

      expect(flash[:notice]).to eq(I18n.t('controllers.people.takeover.success', source: 'Nord GmbH'))
      expect(merged).to contain_exactly([north.id, source.id], [south.id, copies.sole.id])
      get all_people_path
      row = Nokogiri::HTML(response.body).css('tr[data-all-people-row]')
                    .find { |candidate| candidate.at_css('.all-people-row__name').text.strip == 'Herr Schmidt' }
      expect(row_organisations(row)).to eq(['Nord GmbH', 'Süd GmbH'])
    end

    it 'says that the copy was not merged when the source already stands merged with a row of the target' do
      other = takeover_person(south, name: 'H. Schmidt (alt)')
      group = create(:person_group, owner: reader)
      create(:person_group_entry, person_group: group, organisation: north, person_id: source.id)
      create(:person_group_entry, person_group: group, organisation: south, person_id: other.id)

      expect { submit }.to change { takeover_count(south) }.by(1)

      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq(I18n.t('controllers.people.takeover.success_not_merged', source: 'Nord GmbH'))
      expect(merged).to contain_exactly([north.id, source.id], [south.id, other.id])
    end

    # Any other reason (here: the merge collided with another write) gets a sentence that
    # names none. Until 2026-11-17 it said the original stood merged with another entry.
    it 'says that the copy was not merged, without a reason, when the merge failed for another reason' do
      allow(PersonGroupEntry).to receive(:insert_all!).and_wrap_original do |insert, rows|
        insert.call(rows)
        insert.call(rows)
      end

      expect { submit }.to change { takeover_count(south) }.by(1)

      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq(I18n.t('controllers.people.takeover.success_merge_failed', source: 'Nord GmbH'))
      expect(flash[:notice]).not_to eq(I18n.t('controllers.people.takeover.success_not_merged', source: 'Nord GmbH'))
      expect(merges).to eq([0, 0])
    end

    context 'with a same-named entry in the target' do
      let!(:existing) { takeover_person(south, name: 'Herr Schmidt', email: 'other@example.com') }

      it 'offers "merge instead" under the question, as a second submit of the same form' do
        submit

        expect(response).to have_http_status(:unprocessable_content)
        doc = Nokogiri::HTML(response.body)
        button = doc.at_css('form button[type="submit"][name="merge_with"]')
        expect(button['value']).to eq("person:#{existing.id}")
        expect(button.text.strip).to eq(I18n.t('views.organisations.people.takeover.merge_instead', name: 'Herr Schmidt'))
        expect(button.ancestors('form').size).to eq(1)
        expect(button.ancestors('[data-person-takeover-modal-target="question"]').size).to eq(1)
        expect(response.body).to include(CGI.escapeHTML(I18n.t('views.organisations.people.takeover.merge_instead_hint')))
      end

      # Two targets with a namesake each: the question names the target it was asked for,
      # and so do the offers under it, whichever of the two the list draws first.
      it 'offers the namesakes of the chosen target only' do
        aachen = create(:organisation, name: 'Aachen AG')
        takeover_join(reader, aachen, 'manage_people')
        theirs = takeover_person(aachen, name: 'Herr Schmidt')

        offered = lambda do |target|
          submit(target: target.id)
          expect(response).to have_http_status(:unprocessable_content)
          Nokogiri::HTML(response.body).css('button[name="merge_with"]').pluck('value')
        end

        expect(offered.call(south)).to eq(["person:#{existing.id}"])
        expect(offered.call(aachen)).to eq(["person:#{theirs.id}"])
      end

      it 'offers a member of the same name by the address of the member' do
        namesake = takeover_join(create(:user, first_name: 'Herr', last_name: 'Schmidt'), south)
        takeover_join(reader, create(:organisation, name: 'Ost eG'), 'view_people')
        ActsAsTenant.with_tenant(south) { Membership.find_by!(user: reader, organisation: south).role.update!(title: Role::ACCOUNT_ADMIN_TITLE) }

        submit

        values = Nokogiri::HTML(response.body).css('button[name="merge_with"]').pluck('value')
        expect(values).to contain_exactly("person:#{existing.id}", "member:#{namesake.id}")
      end

      it 'merges the source with the entry that is there and creates no row' do
        expect { submit(merge_with: "person:#{existing.id}") }.not_to(change { counts })

        expect(response).to redirect_to(organisation_people_path(north, person_id: source.id))
        expect(response).to have_http_status(:see_other)
        expect(flash[:notice]).to eq(I18n.t('controllers.people.takeover.merged_instead'))
        expect(merged).to contain_exactly([north.id, source.id], [south.id, existing.id])
        expect(session[:current_organisation_id]).not_to eq(south.id)
        expect(ActsAsTenant.current_tenant).to be_nil
      end

      it 'refuses a member whose other visible membership overlaps the source organisation' do
        namesake = create(:user, first_name: 'Herr', last_name: 'Schmidt')
        Prosopite.pause do
          [north, south].each do |organisation|
            takeover_join(namesake, organisation)
            ActsAsTenant.with_tenant(organisation) do
              Membership.find_by!(user: reader, organisation: organisation).role.update!(title: Role::ACCOUNT_ADMIN_TITLE)
            end
          end
        end

        expect { submit(merge_with: "member:#{namesake.id}") }.not_to(change { [counts, merges] })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(CGI.escapeHTML(I18n.t('controllers.people.merge.same_organisation')),
                                         %(<turbo-stream action="remove" target="person-takeover-modal-#{source.id}-#{token}">))
        expect(response.body).not_to include(I18n.t('controllers.people.takeover.merged_instead'))
      end

      it 'answers an entry it cannot merge with like every refusal, and writes nothing' do
        submit(target: create(:organisation).id)
        refusal = [response.status, response.media_type, response.body.gsub(/flash_\h{8}/, 'flash_X')]
        expect(refusal.first).to eq(404)
        expect(refusal.last).to include(I18n.t('controllers.people.not_found'))
        foreign = takeover_person(create(:organisation, name: 'Fremd AG'), name: 'Herr Schmidt')

        answers = Prosopite.pause do
          {
            unknown: { merge_with: "person:#{SecureRandom.uuid}" },
            foreign: { merge_with: "person:#{foreign.id}" },
            malformed: { merge_with: 'oops' },
            other_target: { merge_with: "person:#{existing.id}", target: create(:organisation).id },
            source_as_target: { merge_with: "person:#{source.id}", target: SecureRandom.uuid }
          }.transform_values do |extra|
            expect { submit(**extra) }.not_to(change { [counts, merges] })
            [response.status, response.media_type, response.body.gsub(/flash_\h{8}/, 'flash_X')]
          end
        end

        expect(answers.values.uniq).to eq([refusal]), answers.inspect
      end

      # In production an actor answers a failure it did not expect with the message of
      # the exception. That is no reason for a reader: the dialog closes with one sentence
      # of ours.
      it 'closes the dialog with a sentence of ours when the merge fails for a reason nobody wrote a text for' do
        allow_any_instance_of(Actors::MergePeople).to receive(:raise_unexpected?).and_return(false)
        allow(Rails.logger).to receive(:error)
        allow(PersonGroup).to receive(:lock_for).and_raise(ActiveRecord::Deadlocked, 'Process 4711 waits for ShareLock')

        expect { submit(merge_with: "person:#{existing.id}") }.not_to(change { [counts, merges] })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(CGI.escapeHTML(I18n.t('controllers.people.merge.failed')))
        expect(response.body).not_to include('4711')
      end

      # Enter sends a form through its default button. For Safari up to version 16 at
      # least that is the first submit button that is DRAWN (read in WebKit's source of
      # that release, not tried in the browser): one taken out with the hidden attribute
      # has no box, and Enter went to the first offer to merge. The browser spec runs
      # Chrome, which takes the first button in the markup whatever it looks like, so the
      # markup is held here.
      it 'opens the form with a default button that is drawn, unnamed and out of reach' do
        submit

        buttons = Nokogiri::HTML(response.body).css('form button[type="submit"]')
        default = buttons.first
        expect(buttons.size).to be > 2
        expect(default['name']).to be_nil
        expect(default.attribute('hidden')).to be_nil
        expect(default['style'].to_s).not_to match(/display\s*:\s*none/)
        expect(default['class'].to_s.split).to eq(['sr-only'])
        expect([default['tabindex'], default['aria-hidden']]).to eq(%w[-1 true])
      end

      it 'closes the dialog with the reason when the source already stands merged with a row of the target' do
        group = create(:person_group, owner: reader)
        other = takeover_person(south, name: 'H. Schmidt (alt)')
        create(:person_group_entry, person_group: group, organisation: north, person_id: source.id)
        create(:person_group_entry, person_group: group, organisation: south, person_id: other.id)

        expect { submit(merge_with: "person:#{existing.id}") }.not_to(change { [counts, merges] })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(CGI.escapeHTML(I18n.t('controllers.people.merge.same_organisation')),
                                         %(<turbo-stream action="remove" target="person-takeover-modal-#{source.id}-#{token}">))
      end
    end
  end
end
