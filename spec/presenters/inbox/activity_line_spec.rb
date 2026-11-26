# frozen_string_literal: true

require 'rails_helper'

# The actor of an inbox line is named like everywhere else (User#display_name):
# a member without a name never appears with the login address they hide
# (User::EmailDisplay).
RSpec.describe Inbox::ActivityLine, :ci_guard do
  def line_for(actor)
    described_class.new(instance_double(Notification, actor: actor))
  end

  it 'names the actor by name' do
    expect(line_for(build(:user, first_name: 'Nina', last_name: 'Beispiel')).actor_name).to eq('Nina Beispiel')
  end

  it 'never names a nameless actor by a hidden login address' do
    ghost = build(:user, first_name: nil, last_name: nil, email: 'ghost-login@example.com', email_visibility: 'none')

    expect(line_for(ghost).actor_name).to eq(I18n.t('users.unnamed'))
  end

  it 'names a nameless actor who shows a contact address by that address' do
    ghost = build(:user, first_name: nil, last_name: nil, email: 'ghost-login@example.com',
                         email_visibility: 'contact', contact_email: 'ghost.team@example.com')

    expect(line_for(ghost).actor_name).to eq('ghost.team')
  end

  # The time of a line is when the row's latest event happened (happened_at): a row
  # created days ago whose latest event came a moment ago says so, and a row the fanout
  # wrote late (it arrived a moment ago, last_event_at) names the time of its event.
  describe '#time_ago' do
    include ActiveSupport::Testing::TimeHelpers

    def minutes_ago(count)
      I18n.t('views.common.relative_time_ago', time: I18n.t('datetime.distance_in_words.x_minutes', count: count))
    end

    # A row as the database hands it out, unsaved: only its times count here.
    def row_with(**times)
      ActsAsTenant.without_tenant { Notification.new(**times) }
    end

    it 'speaks of the latest event, not of the moment the row was created' do
      freeze_time do
        line = described_class.new(row_with(created_at: 3.days.ago, first_event_at: 3.days.ago,
                                            happened_at: 5.minutes.ago, last_event_at: 5.minutes.ago))

        expect(line.time_ago).to eq(minutes_ago(5))
      end
    end

    it 'speaks of when the latest event happened, not of when it reached the row' do
      freeze_time do
        line = described_class.new(row_with(created_at: 1.minute.ago, first_event_at: 40.minutes.ago,
                                            happened_at: 40.minutes.ago, last_event_at: 1.minute.ago))

        expect(line.time_ago).to eq(minutes_ago(40))
      end
    end

    # A row written before the column: last_event_at was the event's own time then.
    it 'takes last_event_at for a row without happened_at' do
      freeze_time do
        line = described_class.new(row_with(created_at: 3.days.ago, first_event_at: 3.days.ago,
                                            happened_at: nil, last_event_at: 5.minutes.ago))

        expect(line.time_ago).to eq(minutes_ago(5))
      end
    end
  end

  # S4: a notification about a PROJECT reports one of its events, and the line reads what the
  # event is about from the payload the fanout wrote. Nothing but the notification is read.
  describe 'an event on a project' do
    def event_line(action, parameters = {}, notifiable_type: 'Project', event_type: 'project_announcement', actor: build(:user, first_name: 'Kai', last_name: 'Kollege'))
      described_class.new(instance_double(Notification, actor: actor, notifiable_type: notifiable_type, event_type: event_type,
                                                        payload: { 'action' => action, 'parameters' => parameters }))
    end

    it 'words the event by its action where the event card has a text' do
      line = event_line('note_created', { 'note_title' => 'Protokoll Kickoff' }, event_type: 'document_added')

      expect(line.event_words).to eq(I18n.t('views.organisations.notifications.pane.event_card.note_created.what'))
      expect(line.who_did_what).to eq("Kai Kollege #{line.event_words}")
      # The row of the list keeps the words of the event type.
      expect(line.label).to eq(I18n.t('views.organisations.notifications.event_short.document_added'))
    end

    it 'keeps the words of the event type for an action without a text of its own' do
      line = event_line('tickets_bulk_changed', {}, event_type: 'project_announcement')

      expect(line.event_words).to eq(line.label)
    end

    it 'names the event alone without an actor' do
      line = event_line('member_added', { 'user_name' => 'Mia Neu' }, actor: nil)

      expect(line.who_did_what).to eq(I18n.t('views.organisations.notifications.pane.event_card.member_added.what'))
    end

    it 'reads the title of the object: a note, a document, a meeting, and nothing else' do
      expect(event_line('note_created', { 'note_title' => 'Protokoll Kickoff' }).object_title).to eq('Protokoll Kickoff')
      expect(event_line('document_created', { 'document_title' => 'Angebot' }).object_title).to eq('Angebot')
      expect(event_line('meeting_deleted', { 'meeting_title' => 'Kickoff' }).object_title).to eq('Kickoff')
      expect(event_line('member_added', { 'user_name' => 'Mia Neu' }).object_title).to be_nil
      expect(event_line('ticket_moved_in', { 'ticket_title' => 'Login bricht ab' }).object_title).to be_nil
    end

    it 'names what the event is about: a title, a member, a ticket' do
      expect(event_line('note_created', { 'note_title' => 'Protokoll Kickoff', 'creator_name' => 'Kai Kollege' }).object_name)
        .to eq('Protokoll Kickoff')
      expect(event_line('member_added', { 'user_name' => 'Mia Neu' }).object_name).to eq('Mia Neu')
      expect(event_line('ticket_moved_in', { 'ticket_title' => 'Login bricht ab' }).object_name).to eq('Login bricht ab')
      expect(event_line('updated', { 'project_name' => 'Portal' }).object_name).to be_nil
      expect(event_line('note_created', { 'note_title' => '' }).object_name).to be_nil
    end

    it 'reads nothing from the payload of a notification that is not about a project' do
      line = event_line('note_created', { 'note_title' => 'Nicht der Titel' }, notifiable_type: 'Ticket', event_type: 'ticket_commented')

      expect(line.object_title).to be_nil
      expect(line.object_name).to be_nil
      expect(line.event_words).to eq(I18n.t('views.organisations.notifications.event_short.ticket_commented'))
    end

    it 'survives a payload without parameters or with parameters that are no hash' do
      bare = described_class.new(instance_double(Notification, actor: nil, notifiable_type: 'Project',
                                                               event_type: 'project_announcement', payload: {}))
      odd = event_line('note_created', ['Protokoll'])

      expect([bare.object_name, bare.object_title, odd.object_name]).to eq([nil, nil, nil])
      expect(bare.event_words).to eq(bare.label)
    end
  end
end
