# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ProjectDeletionJob, :ci_guard, type: :job do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:role, organisation: organisation, title: 'account_admin') }
  let(:user) { create(:user) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  describe '#perform' do
    let(:project) do
      p = create(:project, organisation: organisation)
      p.archive!(user)
      p
    end

    it 'does not delete non-archived projects' do
      active_project = create(:project, organisation: organisation)

      expect do
        described_class.new.perform(active_project.id, organisation.id, user.id)
      end.not_to change(Project, :count)
    end

    it 'deletes archived project and dependent records' do
      ticket = create(:ticket, project: project, organisation: organisation, creator: user)
      note = create(:note, project: project, organisation: organisation)
      time_session = create(:time_session, project: project, organisation: organisation)

      expect do
        described_class.new.perform(project.id, organisation.id, user.id)
      end.to change(Project, :count).by(-1)

      expect(Ticket.find_by(id: ticket.id)).to be_nil
      expect(Note.find_by(id: note.id)).to be_nil
      expect(TimeSession.find_by(id: time_session.id)).to be_nil
    end

    it 'cleans up activities before deletion' do
      ticket = create(:ticket, project: project, organisation: organisation, creator: user)
      activity = create(:activity,
                        trackable: ticket,
                        actor: user,
                        organisation: organisation,
                        action: 'created',
                        key: 'ticket.created')

      described_class.new.perform(project.id, organisation.id, user.id)

      expect(Activity.find_by(id: activity.id)).to be_nil
    end

    it 'cleans up outbox events before activities' do
      ticket = create(:ticket, project: project, organisation: organisation, creator: user)
      activity = create(:activity,
                        trackable: ticket,
                        actor: user,
                        organisation: organisation,
                        action: 'created',
                        key: 'ticket.created')
      outbox_event = create(:outbox_event,
                            activity: activity,
                            organisation: organisation)

      # Should not raise FK violation
      expect do
        described_class.new.perform(project.id, organisation.id, user.id)
      end.not_to raise_error

      expect(OutboxEvent.find_by(id: outbox_event.id)).to be_nil
      expect(Activity.find_by(id: activity.id)).to be_nil
    end

    # The rows went on with an empty project_id until 2026-10-08, and a row without a
    # project passes the inbox rule as a system message (Notification.readable): what
    # an area right had hidden, a ticket's title or a member's address in the payload,
    # came back through the token inbox once the project was gone. So every row goes,
    # except an e-mail row that went out: its mail log is how a later bounce or spam
    # complaint finds the person (EmailWebhookProcessorJob, EmailLog's 30-day failure
    # count), and the log cannot exist without the row. No inbox shows an e-mail row.
    it 'deletes the notifications of the project, and keeps a sent e-mail row with its mail log' do
      ticket = create(:ticket, project: project, organisation: organisation, creator: user)
      other_project = create(:project, organisation: organisation)
      gone = [
        create(:notification, organisation: organisation, project: project, recipient: user, notifiable: project,
                              channel: 'in_app',
                              payload: { 'action' => 'ticket_moved_in', 'parameters' => { 'ticket_title' => 'Plan' } }),
        create(:notification, organisation: organisation, project: project, recipient: user, notifiable: ticket,
                              channel: 'in_app'),
        create(:notification, organisation: organisation, project: project, recipient: user, notifiable: ticket,
                              channel: 'email')
      ]
      sent = create(:notification, organisation: organisation, project: project, recipient: user, notifiable: project,
                                   channel: 'email')
      sent_log = create(:email_log, organisation: organisation, notification: sent, status: 'sent')
      others = [
        create(:notification, organisation: organisation, project: other_project, recipient: user,
                              notifiable: other_project, channel: 'email'),
        create(:notification, organisation: organisation, project: nil, recipient: user, notifiable: organisation)
      ]
      other_log = create(:email_log, organisation: organisation, notification: others.first)

      described_class.new.perform(project.id, organisation.id, user.id)

      expect(Notification.where(id: gone.map(&:id))).not_to exist
      expect(sent.reload.project_id).to be_nil
      expect(EmailLog.where(id: [sent_log.id, other_log.id]).count).to eq(2)
      expect(Notification.where(id: others.map(&:id)).pluck(:project_id)).to contain_exactly(other_project.id, nil)
      expect(Notification.where(recipient: user).channel_in_app.accessible_for(user, organisation).pluck(:id))
        .to eq([others.last.id])
    end

    it 'cleans up notification preferences' do
      NotificationPreference.create!(
        user: user,
        organisation: organisation,
        event_type: 'ticket_commented',
        channel: 'email',
        enabled: true,
        scope_type: 'Project',
        scope_id: project.id
      )

      expect do
        described_class.new.perform(project.id, organisation.id, user.id)
      end.to change(NotificationPreference, :count).by(-1)
    end

    it 'does nothing for non-existent projects' do
      expect do
        described_class.new.perform(SecureRandom.uuid, organisation.id, user.id)
      end.not_to raise_error
    end
  end
end
