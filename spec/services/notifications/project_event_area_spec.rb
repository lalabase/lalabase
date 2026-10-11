# frozen_string_literal: true

require 'rails_helper'

# A notification whose subject is a PROJECT is measured by the area of the EVENT it
# reports, not by the project: the project carries ticket, note, meeting and member
# events alike (Activities::AreaRegistry), and their parameters travel in the payload
# (a moved ticket's title and number, a note's title, a new member's address).
#
# Until 2026-10-08 such a row counted as "whole project": every member is subscribed to
# the project on joining (ProjectPermission#auto_subscribe_user), so a person who may
# read only documents received, and read through the token inbox, the title and number
# of every ticket moved in or out. Companion of area_rights_spec.rb (subject types) and
# spec/requests/api/project_event_notifications_spec.rb (what the token inbox returns).
RSpec.describe 'Notifications about project events, by the area of the event', :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:member_role) { create(:role, organisation: organisation) }
  let(:writer) { create(:user) }
  let(:source) { create(:project, organisation: organisation, name: 'Quelle') }
  let(:target) { create(:project, organisation: organisation, name: 'Ziel') }

  before { ActsAsTenant.current_tenant = organisation }

  after do
    ActsAsTenant.current_tenant = nil
    Current.reset
  end

  def member(areas_by_project)
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: member_role, active: true)
    areas_by_project.each do |project, areas|
      create(:project_permission, user: user, project: project, **Array(areas).to_h { |area| [:"#{area}_access", 'read_only'] })
    end
    user
  end

  def drain_outbox
    OutboxEvent.where(processed_at: nil).order(:created_at).each do |event|
      Notifications::FanoutService.new(event).call
    end
  end

  def received(user, project)
    Notification.where(recipient: user, notifiable: project, channel: 'in_app')
  end

  describe 'delivery of a ticket move' do
    let!(:docs_only) { member(source => :documents, target => :documents) }
    let!(:notes_only) { member(source => :notes, target => :notes) }
    let!(:ticket_reader) { member(source => :tickets, target => :tickets) }
    let!(:source_reader) { member(source => :tickets, target => :documents) }

    before do
      create(:membership, user: writer, organisation: organisation, role: admin_role, active: true)
      ticket = create(:ticket, project: source, organisation: organisation, creator: writer, title: 'Umzugsplan')
      Current.user = writer
      Prosopite.pause do
        expect(Actors::MoveTicket.call(ticket: ticket, target_project: target, current_user: writer)).to be_success
        drain_outbox
      end
    end

    it 'reaches who may read tickets there, and nobody with documents or notes alone' do
      expect(received(ticket_reader, source).pluck(Arel.sql("payload->>'action'"))).to eq(['ticket_moved_out'])
      expect(received(ticket_reader, target).pluck(Arel.sql("payload->>'action'"))).to eq(['ticket_moved_in'])

      expect(Notification.where(recipient: [docs_only, notes_only])).not_to exist
    end

    # The moved ticket lives in a project whose tickets this person may not read: the
    # row there would name it. The row of the project it left stays theirs.
    it 'tells a reader of the old project only that it left' do
      expect(received(source_reader, source)).to exist
      expect(received(source_reader, target)).not_to exist
    end
  end

  describe 'delivery of other events tracked on the project' do
    let!(:tickets_only) { member(source => :tickets) }
    let!(:notes_reader) { member(source => :notes) }
    let!(:meetings_reader) { member(source => :meetings) }
    let!(:members_reader) { member(source => :members) }
    let(:newcomer) { create(:user) }

    before do
      create(:membership, user: writer, organisation: organisation, role: admin_role, active: true)
      create(:membership, user: newcomer, organisation: organisation, role: member_role, active: true)
      Current.user = writer
      Prosopite.pause do
        create(:note, project: source, organisation: organisation, creator: writer, title: 'Protokoll', create_embeddings: false)
        create(:meeting, project: source, organisation: organisation, creator: writer, title: 'Kickoff')
        create(:project_permission, user: newcomer, project: source, documents_access: 'read_only')
        source.track_member_added(newcomer, documents_access: 'read_only')
        drain_outbox
      end
    end

    def actions_for(user) = received(user, source).pluck(Arel.sql("payload->>'action'"))

    it 'reaches each reader with the events of their area only' do
      expect(actions_for(notes_reader)).to eq(['note_created'])
      expect(actions_for(meetings_reader)).to eq(['meeting_created'])
      expect(actions_for(members_reader)).to eq(['member_added'])
      expect(actions_for(tickets_only)).to be_empty
    end
  end

  # The registry's contract (nil = drop) holds for delivery too: an event nobody has
  # placed in an area reaches nobody. Also not an account admin who follows the
  # project: ProjectAccessService#can? lets an admin through before it looks at the
  # area at all, so an area that does not exist would not stop them.
  describe 'delivery of an event without a rule' do
    let!(:reader_of_everything) { member(source => ProjectPermission.access_areas) }
    let(:admin) { create(:user) }

    it 'reaches nobody' do
      [writer, admin].each do |user|
        create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
      end
      NotificationSubscription.create!(user: admin, subscribable: source, mode: 'follow')
      activity = create(:activity, organisation: organisation, trackable: source, actor: writer,
                                   action: 'something_nobody_maps', key: 'project.something_nobody_maps')
      event = OutboxEvent.find_by!(activity: activity)

      result = Prosopite.pause { Notifications::FanoutService.new(event).call }

      expect(result).to include(success: true)
      expect(Notification.where(recipient: [reader_of_everything, admin])).not_to exist
    end

    it 'reaches the same admin with project news' do
      create(:membership, user: writer, organisation: organisation, role: admin_role, active: true)
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
      NotificationSubscription.create!(user: admin, subscribable: source, mode: 'follow')
      activity = create(:activity, organisation: organisation, trackable: source, actor: writer,
                                   action: 'updated', key: 'project.updated')

      Prosopite.pause { Notifications::FanoutService.new(OutboxEvent.find_by!(activity: activity)).call }

      expect(Notification.where(recipient: admin, notifiable: source)).to exist
    end
  end

  describe 'reading' do
    let(:user) { member(source => :documents) }

    def row(action, parameters = {})
      create(:notification, recipient: user, organisation: organisation, project: source, notifiable: source,
                            channel: 'in_app', state: 'queued',
                            payload: { 'action' => action, 'parameters' => parameters })
    end

    def readable_ids
      Notification.where(recipient: user).accessible_for(user, organisation).pluck(:id)
    end

    let!(:rows) do
      {
        moved_in: row('ticket_moved_in', 'ticket_title' => 'Umzugsplan', 'ticket_number' => 9173),
        moved_out: row('ticket_moved_out', 'ticket_title' => 'Umzugsplan', 'ticket_number' => 9173),
        bulk: row('tickets_bulk_changed', 'ticket_numbers' => [7705, 7706]),
        note: row('note_created', 'note_title' => 'Protokoll'),
        meeting: row('meeting_created', 'meeting_title' => 'Kickoff'),
        member: row('member_added', 'user_name' => 'Neo'),
        document: row('document_created', 'document_title' => 'Vertrag'),
        renamed: row('updated'),
        unknown: row('something_nobody_maps')
      }
    end

    it 'lists a project event only for a reader of its area, and project news for any area' do
      expect(readable_ids).to match_array(rows.values_at(:document, :renamed).map(&:id))
    end

    it 'counts by the same rule' do
      expect(Notification.inbox_unread(user, organisation).count).to eq(2)
      expect(user.unread_notifications_count(organisation)).to eq(2)
    end

    it 'brings the ticket events back with the right' do
      ProjectPermission.find_by(user: user, project: source).update!(tickets_access: 'read_only')
      Current.reset

      expect(readable_ids).to match_array(rows.values_at(:moved_in, :moved_out, :bulk, :document, :renamed).map(&:id))
    end

    # The registry's contract (nil = drop): a project event nobody has placed in an area
    # reaches no reader, rather than every reader of the project.
    it 'shows an event without a rule to nobody, not even to a reader of every area' do
      ProjectPermission.find_by(user: user, project: source)
                       .update!(ProjectPermission.access_areas.to_h { |area| [:"#{area}_access", 'read_only'] })
      Current.reset

      expect(readable_ids).to match_array(rows.except(:unknown).values.map(&:id))
    end
  end
end

# Reading or archiving one row of the inbox does the same to the other rows about the
# same subject (cascade_notifiable_state). With the area of the event, rows about the
# same PROJECT can differ in who may see them: the cascade must not reach the hidden
# ones, or a reader of documents who archives "project renamed" silently archives the
# "ticket moved" rows, which are then gone when the tickets right comes back.
RSpec.describe 'Notifications about project events: one row read or archived', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  def row(action)
    ActsAsTenant.with_tenant(organisation) do
      create(:notification, recipient: user, organisation: organisation, project: project, notifiable: project,
                            channel: 'in_app', state: 'queued', read_at: nil, payload: { 'action' => action })
    end
  end

  let!(:shown) { row('updated') }
  let!(:shown_sibling) { row('view_configuration_created') }
  let!(:hidden) { row('ticket_moved_in') }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: create(:role, organisation: organisation),
                          active: true)
      create(:project_permission, user: user, project: project, documents_access: 'read_only')
    end
    sign_in user
  end

  it 'archives the rows the person sees, not the hidden one' do
    patch archive_organisation_notification_path(organisation, shown), as: :json

    expect(response).to have_http_status(:ok)
    expect(shown_sibling.reload.state).to eq('archived')
    expect(hidden.reload.state).to eq('queued')
  end

  it 'marks the rows the person sees read, not the hidden one' do
    patch mark_read_organisation_notification_path(organisation, shown), as: :json

    expect(response).to have_http_status(:ok)
    expect(shown_sibling.reload.read_at).to be_present
    expect(hidden.reload.read_at).to be_nil
  end
end
