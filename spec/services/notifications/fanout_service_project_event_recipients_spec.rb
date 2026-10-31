# frozen_string_literal: true

require 'rails_helper'

# WHO an event on a project reaches. project_event_area_spec.rb holds the other half, who
# may see it: the gate that every recipient passes.
#
# Until 2026-10-31 the lookup asked for an area that does not exist. It raised on every
# event, a rescue answered with an empty list, and only people with a subscription to the
# project were left: never an account admin, never someone reading through a role. The
# only sign of it was a warning in the log. The lookup now asks for the area of the event,
# and a failure stays a failure.
RSpec.describe Notifications::FanoutService, 'recipients of a project event', :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  let!(:actor) { account_admin }

  after do
    ActsAsTenant.current_tenant = nil
    Current.reset
  end

  def account_admin(active: true)
    create(:user).tap do |user|
      create(:membership, user: user, organisation: organisation, role: admin_role, active: active)
    end
  end

  # Reads through a role with a right on all projects, without a row on this project.
  def role_reader(*areas)
    role = create(:role, organisation: organisation)
    areas.each do |area|
      create(:permission, role: role, category: 'projects', action: "read_access_#{area}_all_projects", allowed: true)
    end
    create(:user).tap do |user|
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  # A direct member who, unlike one added the normal way, has no subscription.
  def member_without_subscription(*areas)
    create(:user).tap do |user|
      create(:membership, user: user, organisation: organisation, role: create(:role, organisation: organisation), active: true)
      create(:project_permission, user: user, project: project, skip_auto_subscribe: true,
                                  **areas.to_h { |area| [:"#{area}_access", 'read_only'] })
    end
  end

  def fan_out(action)
    activity = create(:activity, organisation: organisation, trackable: project, actor: actor, action: action,
                                 key: "project.#{action}", parameters: {})
    Prosopite.pause { described_class.new(OutboxEvent.find_by!(activity: activity)).call }
  end

  def received(user, action, channel: 'in_app')
    Notification.where(recipient: user, notifiable: project, channel: channel)
                .where(Arel.sql("payload->>'action' = :action"), action: action)
  end

  describe 'an account admin without a subscription' do
    let!(:admin) { account_admin }

    %w[updated created ticket_moved_in note_created document_created meeting_created member_added].each do |action|
      it "receives #{action}" do
        expect(fan_out(action)).to include(success: true)
        expect(received(admin, action)).to exist
      end
    end

    it 'does not hear about their own action' do
      fan_out('updated')

      expect(received(actor, 'updated')).not_to exist
    end

    # Someone who has worked on the project: a mute also lowers the score, and for them
    # that alone stays above the threshold, so the mute itself has to hold.
    it 'is told by a muted project to stay out of it, in the inbox and by mail' do
      create(:activity, organisation: organisation, trackable: project, actor: admin, action: 'updated',
                        key: 'project.updated', skip_notifications: true)
      NotificationSubscription.create!(user: admin, subscribable: project, mode: 'mute')

      fan_out('updated')

      expect(Notification.where(recipient: admin)).not_to exist
    end

    # There is no project switch on any page: the event type in the notification settings
    # is how an admin turns this down. Per type, so the other type still arrives.
    it 'can turn an event type off in the notification settings' do
      create(:notification_preference, user: admin, organisation: organisation, event_type: 'project_announcement',
                                       channel: 'in_app', enabled: false, frequency: 'never')

      fan_out('updated')
      fan_out('note_created')

      expect(received(admin, 'updated')).not_to exist
      expect(received(admin, 'note_created')).to exist
    end
  end

  describe 'a deactivated account admin' do
    it 'receives nothing, while an active one does' do
      deactivated = account_admin(active: false)
      active = account_admin

      fan_out('updated')

      expect(received(active, 'updated')).to exist
      expect(Notification.where(recipient: deactivated)).not_to exist
    end
  end

  # Not the membership but the account: can_access_project? only knows the membership,
  # so here the check on the user is the only thing left.
  describe 'an account admin whose user is switched off' do
    it 'receives nothing, while an active one does' do
      switched_off = account_admin.tap { |user| user.update_column(:active, false) }
      active = account_admin

      fan_out('updated')

      expect(received(active, 'updated')).to exist
      expect(Notification.where(recipient: switched_off)).not_to exist
    end
  end

  describe 'a reader through a role, without a row on the project' do
    let!(:notes_reader) { role_reader(:notes) }

    it 'receives the events of their area and no others' do
      fan_out('note_created')
      fan_out('ticket_moved_in')

      expect(received(notes_reader, 'note_created')).to exist
      expect(received(notes_reader, 'ticket_moved_in')).not_to exist
    end

    it 'receives project news, which ask for any area' do
      fan_out('updated')

      expect(received(notes_reader, 'updated')).to exist
    end

    # Actors::RevokeProjectMember keeps a row of nothing but no_access, because the right
    # of the role would take over without it.
    it 'receives nothing once blocked on this project' do
      create(:project_permission, user: notes_reader, project: project, skip_auto_subscribe: true)

      fan_out('note_created')
      fan_out('updated')

      expect(Notification.where(recipient: notes_reader)).not_to exist
    end
  end

  describe 'a direct member without a subscription' do
    let!(:tickets_reader) { member_without_subscription(:tickets) }

    it 'has no subscription to start from' do
      expect(NotificationSubscription.where(user: tickets_reader)).not_to exist
    end

    it 'receives the events of their area and no others' do
      fan_out('ticket_moved_in')
      fan_out('note_created')

      expect(received(tickets_reader, 'ticket_moved_in')).to exist
      expect(received(tickets_reader, 'note_created')).not_to exist
    end

    it 'receives project news' do
      fan_out('updated')

      expect(received(tickets_reader, 'updated')).to exist
    end
  end

  # Which event belongs to which area, written out here and not read from
  # Activities::AreaRegistry: the table is what the registry is held against. Every event
  # a project really emits, with one reader per area and nobody else in the running.
  describe 'each event, among one reader per area' do
    let!(:readers) { %i[tickets notes documents meetings members].index_with { |area| member_without_subscription(area) } }

    {
      'ticket_moved_in' => :tickets, 'ticket_moved_out' => :tickets,
      'note_created' => :notes, 'document_created' => :documents,
      'meeting_created' => :meetings, 'meeting_deleted' => :meetings,
      'meeting_moved_in' => :meetings, 'meeting_moved_out' => :meetings,
      'member_added' => :members, 'member_removed' => :members, 'permission_changed' => :members,
      'updated' => nil, 'created' => nil
    }.each do |action, area|
      it "reaches #{area ? "the reader of #{area}" : 'all of them'} with #{action}" do
        fan_out(action)

        reached = readers.select { |_area, reader| received(reader, action).exists? }.keys
        expect(reached).to match_array(area ? [area] : readers.keys)
      end
    end
  end

  describe 'a member of the organisation with no right on the project' do
    it 'receives nothing, while a reader does' do
      outsider = member_without_subscription
      reader = member_without_subscription(:tickets)

      fan_out('updated')

      expect(received(reader, 'updated')).to exist
      expect(Notification.where(recipient: outsider)).not_to exist
    end
  end

  # A mail goes out at once from score 80 (Notification#should_send_immediately?). Who is
  # here by role alone has no subscription bonus, so nothing about a project may reach
  # that line, also not for someone who has worked on the project before. Every event a
  # project really emits is listed: a new one belongs here.
  describe 'mail to a recipient without a subscription' do
    let!(:admin) { account_admin }

    before do
      create(:activity, organisation: organisation, trackable: project, actor: admin, action: 'updated',
                        key: 'project.updated', skip_notifications: true)
    end

    %w[created updated member_added member_removed permission_changed ticket_moved_in ticket_moved_out
       document_created note_created meeting_created meeting_deleted meeting_moved_in meeting_moved_out].each do |action|
      it "is not sent at once for #{action}" do
        fan_out(action)

        row = received(admin, action, channel: 'email').first
        expect(row).to be_present
        expect(row.should_send_immediately?).to be(false), "score #{row.score}, type #{row.event_type}"
      end
    end

    it 'stays what a subscription buys: the line can be crossed' do
      NotificationSubscription.create!(user: admin, subscribable: project, mode: 'follow')

      fan_out('updated')

      expect(received(admin, 'updated', channel: 'email').first.should_send_immediately?).to be(true)
    end
  end

  # Through the real write, not a hand-built activity. The event type decides the mail, and
  # a project's "created" used to fall back on the action alone: a system message, score
  # 80 and more, a mail at once to every admin, and that mail does not even render.
  describe 'a new project' do
    let!(:admin) { account_admin }

    it 'reaches the other admins as project news, not as a system message' do
      Current.user = actor
      new_project = create(:project, organisation: organisation)
      Prosopite.pause { OutboxEvent.where(processed_at: nil).find_each { |event| described_class.new(event).call } }

      rows = Notification.where(recipient: admin, notifiable: new_project)
      expect(rows.pluck(:channel)).to contain_exactly('in_app', 'email')
      expect(rows.pluck(:event_type).uniq).to eq(['project_announcement'])
      expect(rows.map(&:should_send_immediately?)).to all(be(false))
    end
  end

  # A rescue that answered with [] made every failure a success. A lookup that fails
  # writes nothing, so a retry starts clean.
  describe 'a failing lookup' do
    let!(:subscriber) { member_without_subscription(:tickets) }
    let(:activity) do
      create(:activity, organisation: organisation, trackable: project, actor: actor, action: 'ticket_moved_in',
                        key: 'project.ticket_moved_in', parameters: {})
    end
    let(:event) { OutboxEvent.find_by!(activity: activity) }

    before do
      NotificationSubscription.system_subscribe(user: subscriber, item: project)
      allow(AccessCheck::ProjectAccessService).to receive(:users_with_access).and_raise('connection lost')
    end

    it 'is a failure of the event, and nobody gets half of it' do
      result = Prosopite.pause { described_class.new(event).call }

      expect(result).to include(success: false, error: 'connection lost')
      expect(Notification.where(notifiable: project)).not_to exist
    end

    it 'leaves the event to its retry' do
      Prosopite.pause { event.process! }

      expect(event.reload).to have_attributes(processed_at: nil, retry_count: 1)
      expect(event.available_at).to be > Time.current
    end
  end
end
