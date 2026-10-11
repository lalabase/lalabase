# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Notifications::FanoutService, type: :service do
  describe 'project_id assignment in notifications' do
    let(:organisation) { create(:organisation) }
    let(:project) { create(:project, organisation: organisation) }
    let(:user) { create(:user) }
    let(:actor) { create(:user) }
    let(:ticket) { create(:ticket, project: project, creator: user) }

    let(:admin_role) { create(:admin_role, organisation: organisation) }

    before do
      ActsAsTenant.current_tenant = organisation
      Current.user = actor

      # Ensure users have access to the organisation with admin role for project access
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
      create(:membership, user: actor, organisation: organisation, role: admin_role, active: true)
    end

    context 'when creating a notification for a ticket comment' do
      it 'sets the project_id from the ticket' do
        # Create an activity for the comment
        activity = create(:activity,
                          organisation: organisation,
                          trackable: ticket,
                          actor: actor,
                          action: 'commented',
                          key: 'ticket.commented',
                          parameters: {
                            post_excerpt: 'This is a test comment',
                            post_id: SecureRandom.uuid
                          })

        # Create an outbox event for the activity
        outbox_event = create(:outbox_event,
                              organisation: organisation,
                              activity: activity,
                              event_type: 'ticket_commented',
                              payload: activity.parameters)

        # Run the fanout service (pause N+1 detection - fanout internals trigger Prosopite)
        Prosopite.pause
        service = described_class.new(outbox_event)
        result = service.call
        Prosopite.resume

        # Check that notifications were created
        expect(result[:success]).to be true
        expect(result[:notifications_created]).to be > 0

        # Find the created notification
        notification = Notification.where(
          notifiable: ticket,
          actor: actor,
          event_type: 'ticket_commented'
        ).first

        # CRITICAL: The notification should have the project_id set
        expect(notification).to be_present
        expect(notification.project_id).to eq(project.id),
                                           "Expected notification.project_id to be #{project.id}, but got #{notification.project_id}"
        expect(notification.project).to eq(project)
      end
    end

    context 'when creating a notification for a ticket assignment' do
      it 'sets the project_id from the ticket' do
        # Assign the ticket
        ticket.assignees << user

        # Create an activity for the assignment
        activity = create(:activity,
                          organisation: organisation,
                          trackable: ticket,
                          actor: actor,
                          action: 'assigned',
                          key: 'ticket.assigned',
                          parameters: {
                            assignee_id: user.id,
                            assignee_name: user.full_name
                          })

        # Create an outbox event
        outbox_event = create(:outbox_event,
                              organisation: organisation,
                              activity: activity,
                              event_type: 'ticket_assigned',
                              payload: activity.parameters)

        # Run the fanout service (pause N+1 detection - fanout internals trigger Prosopite)
        Prosopite.pause
        service = described_class.new(outbox_event)
        result = service.call
        Prosopite.resume

        # Check that notifications were created
        expect(result[:success]).to be true

        # Find the created notification
        notification = Notification.where(
          notifiable: ticket,
          recipient: user,
          event_type: 'ticket_assigned'
        ).first

        # CRITICAL: The notification should have the project_id set
        expect(notification).to be_present
        expect(notification.project_id).to eq(project.id),
                                           "Expected notification.project_id to be #{project.id}, but got #{notification.project_id}"
        expect(notification.project).to eq(project)
      end
    end

    context 'when creating notifications for different trackable types' do
      it 'sets project_id for Document notifications' do
        document = create(:document, project: project, creator: actor)
        activity = create(:activity,
                          organisation: organisation,
                          trackable: document,
                          actor: actor,
                          action: 'created',
                          key: 'document.created')

        outbox_event = create(:outbox_event,
                              organisation: organisation,
                              activity: activity,
                              event_type: 'document_added',
                              payload: { document_name: document.title })

        # Pause N+1 detection - fanout internals trigger Prosopite
        Prosopite.pause
        service = described_class.new(outbox_event)
        service.call
        Prosopite.resume

        notification = Notification.where(notifiable: document).first
        expect(notification&.project_id).to eq(project.id),
                                            "Document notification should have project_id #{project.id}, but got #{notification&.project_id}"
      end

      it 'sets project_id for Note notifications' do
        note = create(:note, project: project, creator: actor)
        activity = create(:activity,
                          organisation: organisation,
                          trackable: note,
                          actor: actor,
                          action: 'created',
                          key: 'note.created')

        outbox_event = create(:outbox_event,
                              organisation: organisation,
                              activity: activity,
                              event_type: 'note_created',
                              payload: { note_title: note.title })

        # Pause N+1 detection - fanout internals trigger Prosopite
        Prosopite.pause
        service = described_class.new(outbox_event)
        service.call
        Prosopite.resume

        notification = Notification.where(notifiable: note).first
        expect(notification&.project_id).to eq(project.id),
                                            "Note notification should have project_id #{project.id}, but got #{notification&.project_id}"
      end

      it 'sets project_id for Project notifications' do
        # Subscribe user to project so they receive notifications
        # (find_project_members_with_access_optimized has a bug where users_with_access(:read, :general)
        # raises NoMethodError, which causes the entire method to return [] including admin users)
        NotificationSubscription.create!(user: user, subscribable: project, mode: 'follow')

        activity = create(:activity,
                          organisation: organisation,
                          trackable: project,
                          actor: actor,
                          action: 'updated',
                          key: 'project.updated')

        outbox_event = create(:outbox_event,
                              organisation: organisation,
                              activity: activity,
                              event_type: 'project_updated',
                              payload: { action: 'updated' })

        # Pause N+1 detection - fanout internals trigger Prosopite
        Prosopite.pause
        service = described_class.new(outbox_event)
        service.call
        Prosopite.resume

        notification = Notification.where(notifiable: project).first
        expect(notification&.project_id).to eq(project.id),
                                            "Project notification should have project_id #{project.id}, but got #{notification&.project_id}"
      end
    end

    context 'when trackable has no project association' do
      it 'sets project_id to nil gracefully' do
        # Create an activity for organisation (no project)
        activity = create(:activity,
                          organisation: organisation,
                          trackable: organisation,
                          actor: actor,
                          action: 'updated',
                          key: 'organisation.updated')

        outbox_event = create(:outbox_event,
                              organisation: organisation,
                              activity: activity,
                              event_type: 'organisation_updated',
                              payload: { action: 'updated' })

        Prosopite.pause
        service = described_class.new(outbox_event)
        service.call
        Prosopite.resume

        notification = Notification.where(notifiable: organisation).first
        expect(notification&.project_id).to be_nil,
                                            "Organisation notification should have nil project_id, but got #{notification&.project_id}"
      end
    end

    context 'when verifying project determination from trackable' do
      it 'sets project_id correctly from ticket trackable' do
        activity = create(:activity,
                          organisation: organisation,
                          trackable: ticket,
                          actor: actor,
                          action: 'commented',
                          key: 'ticket.commented',
                          parameters: { post_excerpt: 'Debug test' })

        outbox_event = create(:outbox_event,
                              organisation: organisation,
                              activity: activity,
                              event_type: 'ticket_commented',
                              payload: activity.parameters)

        expect(ticket.project).to eq(project)
        expect(ticket.project_id).to eq(project.id)

        Prosopite.pause
        service = described_class.new(outbox_event)
        service.call
        Prosopite.resume

        notification = Notification.last
        expect(notification.project_id).to eq(project.id),
                                           "Notification should have project_id #{project.id} from ticket, but got #{notification.project_id}"
      end
    end
  end
end
