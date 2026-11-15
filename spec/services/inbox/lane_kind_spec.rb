# frozen_string_literal: true

require 'rails_helper'

# What: Inbox::LaneKind, the one owner of "what does this row of the inbox open in the lane".
# Why:  the question used to be `notifiable.is_a?(Ticket)` in seven places, and every other
#       row left the page for the project, whatever it was about. The kind of a row is
#       decided by its EVENT: a notification is filed under the ticket or under the project,
#       and a new note is an event ON THE PROJECT whose object is the activity's secondary.
#       Pinned here: each answer, that a deleted object and a lost activity get the card that
#       says so (never an empty frame), that an unknown class gets nothing (fail-closed), and
#       that every project event there is has an answer, so a new event cannot fall through.
RSpec.describe Inbox::LaneKind do
  include ProjectEventRows

  let(:organisation) { create(:organisation, name: 'Nord GmbH') }
  let(:user) { create(:user) }
  let(:actor) { create(:user) }
  let(:project) { create(:project, organisation: organisation, name: 'Portal') }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def event(action, secondary: nil, parameters: {})
    create(:activity, trackable: project, organisation: organisation, actor: actor, secondary: secondary,
                      key: "project.#{action}", action: action, parameters: parameters)
  end

  # A notification about the project, as the fanout writes it (FanoutService#build_payload).
  def project_row(action, activity: nil, parameters: {})
    create(:notification, recipient: user, actor: actor, organisation: organisation, project: project,
                          notifiable: project, event_type: 'project_announcement', channel: 'in_app',
                          payload: { 'activity_id' => activity&.id || SecureRandom.uuid, 'action' => action,
                                     'parameters' => activity&.parameters || parameters })
  end

  def row_for(action, secondary: nil, parameters: {})
    project_row(action, activity: event(action, secondary: secondary, parameters: parameters))
  end

  describe 'a notification about a ticket' do
    let(:ticket) { create(:ticket, project: project, organisation: organisation, title: 'Login bricht ab') }
    let(:kind) do
      described_class.for(create(:notification, recipient: user, organisation: organisation, project: project,
                                                notifiable: ticket, event_type: 'ticket_commented', channel: 'in_app'))
    end

    it 'answers the ticket, drawn inline, with its page as the full view' do
      expect(kind.target).to eq(ticket)
      expect(kind.body).to eq(:inline)
      expect(kind.frame_path).to be_nil
      expect(kind.card).to be_nil
      expect(kind.full_path).to eq("/org/#{organisation.id}/projects/#{project.id}/tickets/#{ticket.id}")
      expect(kind.project).to eq(project)
      expect(kind.type_key).to eq('ticket')
    end
  end

  describe 'a notification about a project' do
    let(:note) { create(:note, project: project, organisation: organisation, creator: actor, title: 'Protokoll Kickoff') }

    it 'answers the note of a note_created event, in a frame under the organisation of the row' do
      kind = described_class.for(row_for('note_created', secondary: note, parameters: { 'note_title' => note.title }))

      expect(kind.target).to eq(note)
      expect(kind.body).to eq(:frame)
      expect(kind.card).to be_nil
      note_page = "/org/#{organisation.id}/projects/#{project.id}/notes/#{note.id}"
      expect(kind.full_path).to eq(note_page)
      path, query = kind.frame_path.split('?')
      expect(path).to eq(note_page)
      expect(Rack::Utils.parse_query(query)).to eq('frame' => 'content', 'frame_id' => 'ticket_display_frame')
      expect(kind.project).to eq(project)
      expect(kind.type_key).to eq('note')
    end

    it 'answers the document of a document_created event, in a frame under the organisation of the row' do
      document = titled_document(organisation, project, 'Angebot', creator: actor)
      kind = described_class.for(row_for('document_created', secondary: document, parameters: { 'document_title' => 'Angebot' }))

      expect(kind.target).to eq(document)
      expect(kind.body).to eq(:frame)
      expect(kind.card).to be_nil
      document_page = "/org/#{organisation.id}/projects/#{project.id}/documents/#{document.id}"
      expect(kind.full_path).to eq(document_page)
      path, query = kind.frame_path.split('?')
      expect(path).to eq(document_page)
      expect(Rack::Utils.parse_query(query)).to eq('frame' => 'content', 'frame_id' => 'ticket_display_frame')
      expect(kind.project).to eq(project)
      expect(kind.type_key).to eq('document')
    end

    it 'answers the gone card for a document_created event whose document was deleted' do
      document = titled_document(organisation, project, 'Angebot', creator: actor)
      notification = row_for('document_created', secondary: document, parameters: { 'document_title' => 'Angebot' })
      delete_document(organisation, document, by: actor)

      kind = described_class.for(Notification.find(notification.id))

      expect(kind.target).to be_nil
      expect(kind.card).to eq('gone')
      expect(kind.frame_path).to be_nil
      expect(kind.full_path).to be_nil
      expect(kind.card_link).to eq([:project, "/org/#{organisation.id}/projects/#{project.id}"])
    end

    # Probe B12 (S4b): the document without its activity (retention) is gone, like the note.
    it 'answers the gone card for a document_created event whose activity is gone' do
      kind = described_class.for(project_row('document_created', parameters: { 'document_title' => 'Angebot' }))

      expect(kind.target).to be_nil
      expect(kind.card).to eq('gone')
      expect(kind.frame_path).to be_nil
    end

    %w[member_added member_removed permission_changed updated meeting_deleted].each do |action|
      it "answers the card of #{action}, with the project as the place it leads to" do
        kind = described_class.for(row_for(action, parameters: { 'user_name' => 'Kai Kollege' }))

        expect(kind.body).to eq(:card)
        expect(kind.card).to eq(action)
        expect(kind.frame_path).to be_nil
        expect(kind.full_path).to be_nil
        expect(kind.project).to eq(project)
        expect(kind.card_link).to eq([:project, "/org/#{organisation.id}/projects/#{project.id}"])
        expect(kind).not_to be_gone
      end
    end

    it 'answers the gone card for a note_created event whose note was deleted' do
      notification = row_for('note_created', secondary: note, parameters: { 'note_title' => note.title })
      note.destroy!

      kind = described_class.for(Notification.find(notification.id))

      expect(kind.target).to be_nil
      expect(kind.body).to eq(:card)
      expect(kind.card).to eq('gone')
      expect(kind).to be_gone
      expect(kind.frame_path).to be_nil
      expect(kind.card_link).to eq([:project, "/org/#{organisation.id}/projects/#{project.id}"])
    end

    it 'answers the gone card for an event with an object whose activity is gone (retention)' do
      kind = described_class.for(project_row('note_created', parameters: { 'note_title' => 'Protokoll Kickoff' }))

      expect(kind.target).to be_nil
      expect(kind.card).to eq('gone')
      expect(kind.frame_path).to be_nil
    end

    it 'keeps the card of an event without an object when its activity is gone: the payload says all it shows' do
      kind = described_class.for(project_row('member_added', parameters: { 'user_name' => 'Kai Kollege' }))

      expect(kind.card).to eq('member_added')
      expect(kind).not_to be_gone
    end

    it 'does not take an activity of another project for the event' do
      other = create(:project, organisation: organisation, name: 'Lager')
      foreign = create(:activity, trackable: other, organisation: organisation, actor: actor, secondary: note,
                                  key: 'project.note_created', action: 'note_created', parameters: {})
      kind = described_class.for(project_row('note_created', activity: foreign))

      expect(kind.target).to be_nil
      expect(kind.card).to eq('gone')
    end

    it 'answers a card with a link to the object for an event whose object has no display (a meeting)' do
      meeting = create(:meeting, project: project, organisation: organisation, title: 'Kickoff')
      kind = described_class.for(row_for('meeting_created', secondary: meeting, parameters: { 'meeting_title' => 'Kickoff' }))

      expect(kind.body).to eq(:card)
      expect(kind.card).to eq('meeting_created')
      expect(kind.frame_path).to be_nil
      expect(kind.card_link).to eq([:meeting, "/org/#{organisation.id}/projects/#{project.id}/meetings/#{meeting.id}"])
    end

    # Review S4a round 1: a meeting can move into another project. The card leads to where
    # the meeting is now, as the head's link does for an object with a display.
    it 'links the card of a meeting that moved to the project the meeting is in now' do
      meeting = create(:meeting, project: project, organisation: organisation, title: 'Kickoff')
      notification = row_for('meeting_created', secondary: meeting, parameters: { 'meeting_title' => 'Kickoff' })
      elsewhere = create(:project, organisation: organisation, name: 'Lager')
      meeting.update_column(:project_id, elsewhere.id)

      kind = described_class.for(Notification.find(notification.id))

      expect(kind.card_link).to eq([:meeting, "/org/#{organisation.id}/projects/#{elsewhere.id}/meetings/#{meeting.id}"])
      # The lane's head still names the project the row is about.
      expect(kind.project).to eq(project)
    end

    # Review S4a round 1: only a worded card names an object of its own. An event nobody has
    # worded gets the default card, and that card leads to the project, whatever its object is.
    it 'links the default card of an unworded event to the project, also when its object has a page' do
      meeting = create(:meeting, project: project, organisation: organisation, title: 'Kickoff')
      kind = described_class.for(row_for('meeting_moved_in', secondary: meeting, parameters: { 'meeting_title' => 'Kickoff' }))

      expect(kind.card).to eq('default')
      expect(kind.card_link).to eq([:project, "/org/#{organisation.id}/projects/#{project.id}"])
    end

    it 'keeps a ticket that arrives through a project event on the default card' do
      ticket = create(:ticket, project: project, organisation: organisation, title: 'Login bricht ab')
      kind = described_class.for(row_for('ticket_created', secondary: ticket, parameters: { 'ticket_title' => ticket.title }))

      expect(kind.body).to eq(:card)
      expect(kind.card).to eq('default')
      expect(kind.frame_path).to be_nil
      expect(kind.card_link).to eq([:project, "/org/#{organisation.id}/projects/#{project.id}"])
    end
  end

  describe 'a subject without an entry' do
    it 'answers nil for a person' do
      person = create(:person, organisation: organisation)
      notification = create(:notification, recipient: user, organisation: organisation, notifiable: person, channel: 'in_app')

      expect(described_class.for(notification)).to be_nil
    end

    it 'answers nil for a time session group' do
      group = create(:time_session_group, organisation: organisation)
      notification = create(:notification, recipient: user, organisation: organisation, notifiable: group, channel: 'in_app')

      expect(described_class.for(notification)).to be_nil
    end

    it 'answers nil for a row filed under a note (an old row: no event names it)' do
      note = create(:note, project: project, organisation: organisation, creator: actor)
      notification = create(:notification, recipient: user, organisation: organisation, project: project,
                                           notifiable: note, channel: 'in_app')

      expect(described_class.for(notification)).to be_nil
    end

    # Probe B13 (S4b): the same for a row filed under a document.
    it 'answers nil for a row filed under a document (an old row: no event names it)' do
      document = titled_document(organisation, project, 'Angebot', creator: actor)
      notification = create(:notification, recipient: user, organisation: organisation, project: project,
                                           notifiable: document, channel: 'in_app')

      expect(described_class.for(notification)).to be_nil
    end

    it 'answers nil without a notification and for one whose subject is gone' do
      notification = build(:notification, recipient: user, organisation: organisation, notifiable: nil)

      expect(described_class.for(nil)).to be_nil
      expect(described_class.for(notification)).to be_nil
    end
  end

  describe 'the registry' do
    it 'is a frozen constant of classes, looked up by class and never by name' do
      expect(described_class::REGISTRY).to be_frozen
      expect(described_class::REGISTRY.keys).to all(be_a(Class))
      expect(described_class::REGISTRY.values).to all(be_frozen)
      source = Rails.root.glob('app/services/inbox/*.rb').map(&:read).join
      expect(source).not_to match(/constantize|const_get/)
    end

    it 'gives an unknown class no display' do
      stranger = Class.new
      expect(described_class::REGISTRY[stranger]).to be_nil
      expect(described_class::REGISTRY.fetch(SmartFolder, nil)).to be_nil
    end
  end

  # Every event tracked on the project has an answer: a display, a worded card or the default
  # card. The lists are read from their owners, so a new action or key joins this table by itself.
  describe 'every project event' do
    project_actions = Activities::AreaRegistry::AREA_BY_KEY.keys
                                                           .filter_map { |key| key.delete_prefix('project.') if key.start_with?('project.') }
    actions = (Activities::ProjectTarget::SECONDARY_ACTIONS + project_actions).uniq

    it 'reads a list that holds the events this spec names' do
      expect(actions).to include('note_created', 'member_added', 'tickets_bulk_changed', 'document_added')
    end

    actions.each do |action|
      it "has an answer for #{action} (activity present, no object)" do
        kind = described_class.for(row_for(action))

        expect(kind).not_to be_nil
        expect(kind.body).to eq(:card)
        expect(kind.card).to be_in(described_class::WORDED_CARDS + [described_class::DEFAULT_CARD, described_class::GONE_CARD])
        expect(kind.card_link.last).to start_with("/org/#{organisation.id}/")
      end

      it "has an answer for #{action} without its activity" do
        kind = described_class.for(project_row(action))

        expect(kind.card).to be_in(described_class::WORDED_CARDS + [described_class::DEFAULT_CARD, described_class::GONE_CARD])
      end
    end

    it 'has a text in both languages for every worded card, the default and the gone card' do
      keys = described_class::WORDED_CARDS + [described_class::DEFAULT_CARD, described_class::GONE_CARD]
      %i[de en].each do |locale|
        keys.each do |key|
          expect(I18n.exists?("views.organisations.notifications.pane.event_card.#{key}.title", locale, fallback: false))
            .to be(true), "missing #{locale} title for the card #{key}"
        end
      end
    end
  end
end
