# frozen_string_literal: true

require 'rails_helper'

# The people page, S2a: the column "Zuletzt" with its sort, and in the lane
# "Letzter Kontakt" and the meetings of a person. Only what the viewer may
# read counts; every negative claim below stands next to proof that the page
# itself was rendered.
RSpec.describe 'Organisations::People last contact', :ci_guard, type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def member_with(role, first_name:)
    user = create(:user, first_name: first_name, last_name: 'Beispiel')
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    User.find(user.id)
  end

  def viewer_role
    role = create(:role, organisation: organisation)
    create(:permission, role: role, category: 'people', action: 'view_people', allowed: true)
    role
  end

  let(:readable) { create(:project, organisation: organisation, name: 'Relaunch') }
  let(:hidden) { create(:project, organisation: organisation, name: 'Geheimprojekt') }
  let(:viewer) { member_with(viewer_role, first_name: 'Vera') }
  let(:admin) { member_with(create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE), first_name: 'Anna') }
  let(:colleague) { member_with(create(:role, organisation: organisation), first_name: 'Carl') }
  let!(:contact) { create(:person, organisation: organisation, name: 'Doris Dienstleister') }

  let(:frame_headers) { { 'Turbo-Frame' => Organisations::PeopleController::DETAIL_FRAME_ID } }

  before do
    create(:project_permission, user: viewer, project: readable, tickets_access: :read_only, meetings_access: :read_only)
    create(:project_permission, user: colleague, project: readable, tickets_access: :read_only, meetings_access: :read_only)
  end

  # Test data only: Prosopite would read a loop of these as an N+1.
  def meeting(project, at:, title:, person: nil, user: nil)
    Prosopite.pause do
      record = create(:meeting, organisation: organisation, project: project, occurred_at: at, title: title)
      create(:meeting_participant, meeting: record, person: person, user: user, display_name: 'Gast')
      record
    end
  end

  def row_of(body, name)
    body[%r{<li[^>]*people-row[\s\S]*?#{name}[\s\S]*?</li>}]
  end

  describe 'the list' do
    it 'shows the column heads, sorted by name by default with the arrow on NAME' do
      sign_in viewer
      get organisation_people_path(organisation)

      head = response.body[%r{<div class="people-columns"[\s\S]*?</div>}]
      expect(head).to include(I18n.t('views.organisations.people.index.columns.name'),
                              I18n.t('views.organisations.people.index.columns.last'))
      expect(head).not_to include('role=', 'aria-sort')
      active = head[%r{<a[^>]*aria-current="true"[^>]*>[\s\S]*?</a>}]
      expect(active).to include(I18n.t('views.organisations.people.index.columns.name'), 'bi-arrow-down',
                                I18n.t('views.organisations.people.index.columns.sorted'))
      expect(response.body.index('Carl Beispiel')).to be < response.body.index('Doris Dienstleister')
    end

    it 'shows the age of the last contact and "noch nie" without one' do
      meeting(readable, at: 1.day.ago, title: 'Status', person: contact)
      sign_in viewer

      get organisation_people_path(organisation)

      expect(row_of(response.body, 'Doris Dienstleister')).to include('gestern', 'Letztes Meeting: Status')
      expect(row_of(response.body, 'Carl Beispiel')).to include('noch nie')
    end

    it 'sorts by ?sort=last, newest first, and keeps the sort in search, filter and selection links' do
      meeting(readable, at: 1.day.ago, title: 'Status', person: contact)
      sign_in viewer

      get organisation_people_path(organisation, sort: 'last')

      expect(response.body.index('Doris Dienstleister')).to be < response.body.index('Carl Beispiel')
      expect(response.body).to match(/<input type="hidden" name="sort"[^>]*value="last"/)
      expect(response.body).to include(CGI.escapeHTML(organisation_people_path(organisation, kind: 'contacts', sort: 'last')))
      expect(response.body).to include(CGI.escapeHTML('"sort"'))
    end

    # Review round 2: a click on a column head keeps the open person.
    it 'keeps the open person in the column heads' do
      sign_in viewer

      get organisation_people_path(organisation, person_id: contact.id)

      head = response.body[%r{<div class="people-columns"[\s\S]*?</div>}]
      expect(head).to include(CGI.escapeHTML(organisation_people_path(organisation, sort: 'last', person_id: contact.id)))
      # A row click changes the person in the address only: both heads take
      # the live one at click time (layout_toggle#syncFilterContext,
      # spec/system/people_sort_keeps_lane_spec.rb).
      expect(head.scan('data-lane-keep="true"').size).to eq(2)
    end

    it 'drops an unknown sort from every link' do
      sign_in viewer

      get organisation_people_path(organisation, sort: 'evil')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Doris Dienstleister')
      expect(response.body).not_to include('sort=evil')
    end

    it 'is not moved by, and does not show, a meeting the viewer may not read' do
      meeting(readable, at: 5.days.ago, title: 'Status', person: contact)
      meeting(hidden, at: 1.hour.ago, title: 'Geheimrunde', user: colleague)
      sign_in viewer

      get organisation_people_path(organisation, sort: 'last')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Doris Dienstleister')
      expect(response.body.index('Doris Dienstleister')).to be < response.body.index('Carl Beispiel')
      expect(response.body).not_to include('Geheimrunde')
    end
  end

  describe 'the lane' do
    it 'shows the last contact and the three newest meetings of a contact, then "Alle N anzeigen"' do
      meetings = Array.new(4) { |index| meeting(readable, at: (index + 1).days.ago, title: "Runde #{index}", person: contact) }
      sign_in viewer

      get organisation_person_path(organisation, contact), headers: frame_headers

      expect(response.body).to include(I18n.t('views.organisations.people.show.last_contact'), 'Letztes Meeting: Runde 0')
      expect(response.body).to include('Runde 0', 'Runde 1', 'Runde 2', 'Relaunch')
      expect(response.body).not_to include('Runde 3')
      expect(response.body).to include(I18n.t('views.organisations.people.show.all_meetings', count: 4))
      expect(response.body).to include(organisation_meetings_path(organisation, meeting_id: meetings.first.id))
    end

    it 'shows every meeting after "Alle N anzeigen"' do
      Array.new(4) { |index| meeting(readable, at: (index + 1).days.ago, title: "Runde #{index}", person: contact) }
      sign_in viewer

      get organisation_person_path(organisation, contact, meetings: 'all'), headers: frame_headers

      expect(response.body).to include('Runde 3')
      expect(response.body).not_to include(I18n.t('views.organisations.people.show.all_meetings', count: 4))
    end

    it 'leaves out a meeting the viewer may not read, also from the count, and an admin sees it' do
      Array.new(3) { |index| meeting(readable, at: (index + 2).days.ago, title: "Runde #{index}", person: contact) }
      meeting(hidden, at: 1.day.ago, title: 'Geheimrunde', person: contact)
      sign_in viewer

      get organisation_person_path(organisation, contact), headers: frame_headers

      expect(response.body).to include('Runde 0')
      expect(response.body).not_to include('Geheimrunde')
      expect(response.body).not_to include(I18n.t('views.organisations.people.show.all_meetings', count: 4))
      expect(response.body).to include('Letztes Meeting: Runde 0')

      sign_in admin
      get organisation_person_path(organisation, contact), headers: frame_headers

      expect(response.body).to include('Geheimrunde', I18n.t('views.organisations.people.show.all_meetings', count: 4))
    end

    it 'says so when there is no meeting' do
      sign_in viewer

      get organisation_person_path(organisation, contact), headers: frame_headers

      expect(response.body).to include(I18n.t('views.organisations.people.show.no_meeting'))
    end

    describe 'a member (E3)' do
      let(:ticket) { create(:ticket, organisation: organisation, project: readable) }

      it 'shows their newer ticket work as the last contact, in the lane of a member without a row' do
        meeting(readable, at: 4.days.ago, title: 'Planung', user: colleague)
        post = create(:post, ticket: ticket, user: colleague, organisation: organisation)
        Activity.create!(actor: colleague, trackable: ticket, organisation: organisation, action: 'post_added',
                         secondary: post, parameters: { 'skip_notifications' => true }, created_at: 1.day.ago)
        sign_in viewer

        get member_organisation_people_path(organisation, colleague.id), headers: frame_headers

        expect(response.body).to include("Hat Ticket ##{ticket.number} kommentiert, gestern", 'Planung')
      end

      it 'does not count a comment the viewer may not read' do
        meeting(readable, at: 4.days.ago, title: 'Planung', user: colleague)
        post = create(:post, ticket: ticket, user: colleague, organisation: organisation, is_private: true,
                             visible_to_user: admin)
        Activity.create!(actor: colleague, trackable: ticket, organisation: organisation, action: 'post_added',
                         secondary: post, parameters: { 'skip_notifications' => true }, created_at: 1.day.ago)
        sign_in viewer

        get member_organisation_people_path(organisation, colleague.id), headers: frame_headers

        expect(response.body).to include('Letztes Meeting: Planung')
        expect(response.body).not_to include('kommentiert')
      end

      it 'shows the meetings of a member with a row through the account' do
        row = create(:person, organisation: organisation, user: colleague)
        meeting(readable, at: 2.days.ago, title: 'Planung', user: colleague)
        sign_in viewer

        get organisation_person_path(organisation, row), headers: frame_headers

        expect(response.body).to include('Planung', 'Letztes Meeting: Planung')
      end
    end

    it 'reads "Aus dem Konto übernommen am" for a member row without a creator' do
      row = create(:person, organisation: organisation, user: colleague, creator: nil)
      sign_in viewer

      get organisation_person_path(organisation, row), headers: frame_headers

      expect(response.body).to include(I18n.t('views.organisations.people.show.from_account', date: I18n.l(row.created_at.to_date, format: :default)))
    end
  end

  # Review round 1: a row of a former member (a contact with the account's
  # user_id) counts meetings through the account, never ticket work, in the
  # row, in the sort and in the lane alike.
  describe 'a row of a former member' do
    let(:ticket) { create(:ticket, organisation: organisation, project: readable) }
    let!(:former_row) { create(:person, organisation: organisation, user: colleague, name: 'Carl Frueher') }

    before do
      meeting(readable, at: 6.days.ago, title: 'Altrunde', user: colleague)
      Activity.create!(actor: colleague, trackable: ticket, organisation: organisation, action: 'created',
                       parameters: { 'skip_notifications' => true }, created_at: 1.day.ago)
      Membership.find_by(user: colleague, organisation: organisation).update!(active: false)
      sign_in viewer
    end

    it 'shows the meeting through the account and not the ticket work in the row' do
      get organisation_people_path(organisation)

      row = row_of(response.body, 'Carl Frueher')
      expect(row).to include('vor 6 Tagen', 'Letztes Meeting: Altrunde')
      expect(row).not_to include('Ticket')
    end

    it 'shows the meeting and not the ticket work in the lane' do
      get organisation_person_path(organisation, former_row), headers: frame_headers

      expect(response.body).to include('Letztes Meeting: Altrunde', 'Altrunde')
      expect(response.body).not_to include("Hat Ticket ##{ticket.number}")
    end
  end

  it 'shows the last contact and the meetings on a phone' do
    meeting(readable, at: 1.day.ago, title: 'Status', person: contact)
    sign_in viewer

    get organisation_people_path(organisation, person_id: contact.id, viewport: 'mobile')

    expect(response.body).to include('people-mobile-grid', I18n.t('views.organisations.people.show.last_contact'), 'Status')
  end

  it 'asks the database as often for a list of two people as for a list of eight' do
    Prosopite.pause
    sign_in admin
    count = lambda do
      queries = 0
      counter = ->(*, payload) { queries += 1 unless payload[:name] == 'SCHEMA' || payload[:cached] }
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { get organisation_people_path(organisation) }
      queries
    end

    count.call
    small = count.call
    6.times { |index| meeting(readable, at: index.days.ago, title: "M#{index}", person: create(:person, organisation: organisation, name: "Kontakt #{index}")) }
    3.times { |index| member_with(create(:role, organisation: organisation), first_name: "Neu#{index}") }

    expect(count.call).to eq(small)
  ensure
    Prosopite.resume
  end
end
