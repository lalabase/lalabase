# frozen_string_literal: true

require 'rails_helper'

# What the people directory may show about meetings and the last contact of a
# person (S2a). Only what the viewer may read counts: a meeting in a project
# without read access, an activity on an unreadable ticket and a private
# comment the viewer may not read never count, not in the list, not in the
# last contact. No hint at anything hidden.
RSpec.describe People::Contacts, :ci_guard do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def member(first_name, role: create(:role, organisation: organisation))
    user = create(:user, first_name: first_name, last_name: 'Beispiel')
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    User.find(user.id)
  end

  let(:readable) { create(:project, organisation: organisation, name: 'Offen') }
  let(:hidden) { create(:project, organisation: organisation, name: 'Verborgen') }
  let(:viewer) { member('Vera') }
  let(:admin) { member('Anna', role: create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE)) }
  let(:colleague) { member('Carl') }
  let(:contact) { create(:person, organisation: organisation, name: 'Doris Dienstleister') }

  before do
    create(:project_permission, user: viewer, project: readable, tickets_access: :read_only, meetings_access: :read_only)
  end

  def meeting_with(project, at:, title:, person: nil, user: nil)
    meeting = create(:meeting, organisation: organisation, project: project, occurred_at: at, title: title)
    create(:meeting_participant, meeting: meeting, person: person, user: user,
                                 display_name: person&.name || user&.display_name || 'Gast')
    meeting
  end

  def ticket_activity(user, ticket, action:, at:, secondary: nil)
    Activity.create!(actor: user, trackable: ticket, organisation: organisation, action: action,
                     secondary: secondary, parameters: { 'skip_notifications' => true }, created_at: at)
  end

  def contacts(user = viewer)
    described_class.new(viewer: User.find(user.id), organisation: organisation)
  end

  def subject_for(person: nil, user: nil, member: false)
    described_class::Subject.new(person_id: person&.id, user_id: user&.id, member: member)
  end

  describe '#meetings_for' do
    it 'lists the readable meetings of a contact through person_id, newest first' do
      older = meeting_with(readable, at: 10.days.ago, title: 'Kick-off', person: contact)
      newer = meeting_with(readable, at: 2.days.ago, title: 'Status', person: contact)
      meeting_with(hidden, at: 1.day.ago, title: 'Geheim', person: contact)

      expect(contacts.meetings_for(person: contact).to_a).to eq([newer, older])
    end

    it 'shows an admin the meeting of every project' do
      meeting_with(readable, at: 2.days.ago, title: 'Status', person: contact)
      secret = meeting_with(hidden, at: 1.day.ago, title: 'Geheim', person: contact)

      expect(contacts(admin).meetings_for(person: contact).first).to eq(secret)
    end

    it 'finds the meetings of a member without a person row through user_id' do
      attended = meeting_with(readable, at: 3.days.ago, title: 'Planung', user: colleague)

      expect(contacts.meetings_for(user: colleague).to_a).to eq([attended])
    end

    it 'joins person_id and user_id for a member with a row, each meeting once' do
      row = create(:person, organisation: organisation, user: colleague)
      by_user = meeting_with(readable, at: 3.days.ago, title: 'Planung', user: colleague)
      by_person = meeting_with(readable, at: 1.day.ago, title: 'Abnahme', person: row)

      expect(contacts.meetings_for(person: row, user: colleague).to_a).to eq([by_person, by_user])
    end

    it 'finds nothing for nobody' do
      expect(contacts.meetings_for.to_a).to be_empty
    end
  end

  describe '#last_contacts' do
    it 'takes the newest readable meeting of a contact, never one it may not read' do
      meeting_with(readable, at: 5.days.ago, title: 'Status', person: contact)
      meeting_with(hidden, at: 1.day.ago, title: 'Geheim', person: contact)

      last = contacts.last_contacts([subject_for(person: contact)]).first

      expect([last.kind, last.meeting_title]).to eq([:meeting, 'Status'])
      expect(last.at).to be_within(1.second).of(5.days.ago)
    end

    it 'is nil without anything readable' do
      meeting_with(hidden, at: 1.day.ago, title: 'Geheim', person: contact)

      expect(contacts.last_contacts([subject_for(person: contact)])).to eq([nil])
    end

    describe 'a member (E3: the newer of meeting and own ticket activity)' do
      let(:ticket) { create(:ticket, organisation: organisation, project: readable, number: 142) }
      let(:hidden_ticket) { create(:ticket, organisation: organisation, project: hidden) }

      before { meeting_with(readable, at: 4.days.ago, title: 'Status', user: colleague) }

      it 'takes a newer comment on a readable ticket' do
        post = create(:post, ticket: ticket, user: colleague, organisation: organisation)
        ticket_activity(colleague, ticket, action: 'post_added', secondary: post, at: 1.day.ago)

        last = contacts.last_contacts([subject_for(user: colleague, member: true)]).first

        expect([last.kind, last.action, last.ticket_number]).to eq([:ticket, :commented, 142])
      end

      it 'keeps the meeting when the activity is older' do
        ticket_activity(colleague, ticket, action: 'status_changed', at: 9.days.ago)

        expect(contacts.last_contacts([subject_for(user: colleague, member: true)]).first.kind).to eq(:meeting)
      end

      it 'ignores an activity on a ticket the viewer may not read' do
        ticket_activity(colleague, hidden_ticket, action: 'created', at: 1.hour.ago)

        expect(contacts.last_contacts([subject_for(user: colleague, member: true)]).first.kind).to eq(:meeting)
        expect(contacts(admin).last_contacts([subject_for(user: colleague, member: true)]).first.kind).to eq(:ticket)
      end

      it 'ignores a private comment the viewer may not read' do
        addressee = member('Paula')
        post = create(:post, ticket: ticket, user: colleague, organisation: organisation,
                             is_private: true, visible_to_user: addressee)
        ticket_activity(colleague, ticket, action: 'post_added', secondary: post, at: 1.hour.ago)

        expect(contacts.last_contacts([subject_for(user: colleague, member: true)]).first.kind).to eq(:meeting)
        expect(contacts(admin).last_contacts([subject_for(user: colleague, member: true)]).first.kind).to eq(:ticket)
      end

      it 'ignores ticket activities that are no own work (subscribing) and bulk runs' do
        ticket_activity(colleague, ticket, action: 'subscriber_added', at: 1.hour.ago)
        Activity.create!(actor: colleague, trackable: ticket, organisation: organisation, action: 'status_changed',
                         parameters: { 'skip_notifications' => true, 'bulk_run_member' => true }, created_at: 1.hour.ago)

        expect(contacts.last_contacts([subject_for(user: colleague, member: true)]).first.kind).to eq(:meeting)
      end

      it 'counts no activity for a contact, also a former member' do
        former_row = create(:person, organisation: organisation, user: colleague)
        ticket_activity(colleague, ticket, action: 'created', at: 1.hour.ago)

        # The same account once as a member and once as a contact row in one
        # call: only the member entry may count the ticket work.
        member_last, contact_last = contacts.last_contacts([subject_for(user: colleague, member: true),
                                                            subject_for(person: former_row, user: colleague, member: false)])

        expect([member_last.kind, contact_last.kind]).to eq(%i[ticket meeting])
      end
    end

    # Counts the queries itself, so Prosopite (which would flag the setup and
    # the second call of the same shape) stays out of this one.
    it 'asks the database the same number of times for two people and for six' do
      Prosopite.pause
      people = Array.new(6) { |index| create(:person, organisation: organisation, name: "Kontakt #{index}") }
      members = Array.new(6) { |index| member("Mitglied#{index}") }
      people.each_with_index { |person, index| meeting_with(readable, at: index.days.ago, title: "M#{index}", person: person) }
      members.each_with_index { |user, index| meeting_with(readable, at: index.hours.ago, title: "U#{index}", user: user) }

      count = lambda do |size|
        subjects = people.first(size).map { |person| subject_for(person: person) } +
                   members.first(size).map { |user| subject_for(user: user, member: true) }
        queries = 0
        counter = ->(*, payload) { queries += 1 unless payload[:name] == 'SCHEMA' || payload[:cached] }
        ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
          contacts.last_contacts(subjects)
        end
        queries
      end

      expect(count.call(6)).to eq(count.call(2))
    ensure
      Prosopite.resume
    end
  end
end
