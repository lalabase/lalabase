# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Activity user data handling', type: :model do
  let(:organisation) { create(:organisation) }
  let(:actor) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: actor, organisation: organisation)
    Current.user = actor
  end

  # Efficient cleanup that avoids N+1 on outbox_events (dependent: :destroy)
  def clear_all_activities
    OutboxEvent.where(activity_id: Activity.select(:id)).delete_all
    Activity.delete_all
  end

  describe 'GDPR compliance' do
    let(:assignee) { create(:user) }
    let(:member_role) { create(:role, title: 'Developer', organisation: organisation) }

    before do
      create(:membership, user: assignee, organisation: organisation, role: member_role)
      # Create ticket here to avoid activity creation during test
      ticket
      # Clear any creation activities
      clear_all_activities
    end

    context 'when tracking user assignments' do
      it 'does not store personal user data in parameters' do
        ticket.track_assignee_added(assignee)

        activity = Activity.last
        expect(activity.action).to eq('assigned')

        # Should NOT store personal data
        expect(activity.parameters).not_to have_key('assignee_name')
        expect(activity.parameters).not_to have_key('assignee_email')
        expect(activity.parameters).not_to have_key('assignee_id')

        # Should only store non-personal metadata
        expect(activity.parameters['user_role']).to eq('Developer')
        expect(activity.parameters['display_name']).to eq(ticket.display_title)

        # Should use secondary association for user reference
        expect(activity.secondary).to eq(assignee)
      end

      it 'does not store personal user data when removing assignments' do
        ticket.track_assignee_removed(assignee)

        activity = Activity.last
        expect(activity.action).to eq('unassigned')

        # Should NOT store personal data
        expect(activity.parameters).not_to have_key('assignee_name')
        expect(activity.parameters).not_to have_key('assignee_email')

        # Should use secondary association
        expect(activity.secondary).to eq(assignee)
      end
    end

    context 'when displaying user information' do
      it 'retrieves user data from associations dynamically' do
        ticket.track_assignee_added(assignee)
        activity = Activity.where(action: 'assigned').last

        # Helper methods should retrieve data from association
        expect(activity.assignee_display_name).to eq(assignee.full_name)
        expect(activity.assignee_email).to eq(assignee.email)
      end

      it 'handles deleted users gracefully' do
        ticket.track_assignee_added(assignee)
        activity = Activity.last

        # Delete the user
        assignee.destroy
        activity.reload

        # Should return fallback for deleted user
        expect(activity.assignee_display_name).to eq(I18n.t('activities.deleted_user'))
        expect(activity.assignee_email).to be_nil
      end
    end

    context 'when tracking subscriber changes' do
      it 'does not store subscriber PII in parameters' do
        ticket.track_subscriber_added(assignee)

        activity = Activity.last
        expect(activity.action).to eq('subscriber_added')

        # Should NOT store personal data
        expect(activity.parameters).not_to have_key('subscriber_name')
        expect(activity.parameters).not_to have_key('subscriber_id')

        # Should only store non-personal metadata
        expect(activity.parameters['display_name']).to eq(ticket.display_title)

        # Should use secondary association for user reference
        expect(activity.secondary).to eq(assignee)
      end

      it 'does not store subscriber PII when removing subscribers' do
        ticket.track_subscriber_removed(assignee)

        activity = Activity.last
        expect(activity.action).to eq('subscriber_removed')

        # Should NOT store personal data
        expect(activity.parameters).not_to have_key('subscriber_name')
        expect(activity.parameters).not_to have_key('subscriber_id')

        # Should use secondary association
        expect(activity.secondary).to eq(assignee)
      end

      it 'retrieves subscriber name from secondary association' do
        ticket.track_subscriber_added(assignee)
        activity = Activity.last

        expect(activity.subscriber_display_name).to eq(assignee.display_name)
      end

      it 'handles deleted subscriber gracefully' do
        ticket.track_subscriber_added(assignee)
        activity = Activity.last

        assignee.destroy
        activity.reload

        expect(activity.subscriber_display_name).to eq(I18n.t('activities.deleted_user'))
      end
    end

    context 'when tracking post additions' do
      let(:post) { create(:post, ticket: ticket, user: actor) }

      it 'does not store post author data in parameters' do
        ticket.track_post_added(post)

        activity = Activity.where(action: 'post_added').last!
        expect(activity.action).to eq('post_added')

        # Should NOT store author personal data
        expect(activity.parameters).not_to have_key('post_author')
        expect(activity.parameters).not_to have_key('author_name')
        expect(activity.parameters).not_to have_key('author_email')

        # Should store only content excerpt
        expect(activity.parameters['post_excerpt']).to be_present
        expect(activity.parameters['has_attachments']).to be_in([true, false])

        # Should use secondary association for post reference
        expect(activity.secondary).to eq(post)
      end

      it 'retrieves post author from association' do
        ticket.track_post_added(post)
        activity = Activity.where(action: 'post_added').last!

        expect(activity.post_author_display_name).to eq(actor.full_name)
      end
    end
  end

  describe 'message formatting with user data' do
    let(:assignee) { create(:user, first_name: 'Max', last_name: 'Mustermann') }

    before do
      create(:membership, user: assignee, organisation: organisation,
                          role: create(:role, title: 'Tester', organisation: organisation))
    end

    it 'formats assignment message correctly' do
      clear_all_activities

      ticket.track_assignee_added(assignee)
      activity = Activity.where(action: 'assigned').last

      expect(activity).to be_present
      message = activity.detailed_message
      expect(message).to include(actor.full_name) # actor name
      expect(message).to include('Max Mustermann') # assignee name
      expect(message).to include('Tester') # role
      expect(message).to include(ticket.display_title) # ticket
    end

    it 'formats unassignment message correctly' do
      clear_all_activities

      ticket.track_assignee_removed(assignee)
      activity = Activity.where(action: 'unassigned').last

      expect(activity).to be_present
      message = activity.detailed_message
      expect(message).to include(actor.full_name) # actor name
      expect(message).to include('Max Mustermann') # assignee name
      expect(message).to include(ticket.display_title) # ticket
    end
  end

  describe 'actor handling' do
    it 'does not store actor data in parameters' do
      ticket.update!(title: 'New Title')

      activity = Activity.where(action: 'title_changed').last
      expect(activity).to be_present

      # Should NOT store actor data in parameters
      expect(activity.parameters).not_to have_key('actor_name')
      expect(activity.parameters).not_to have_key('actor_email')

      # Should use actor association
      expect(activity.actor).to eq(actor)
    end

    it 'retrieves actor data dynamically' do
      ticket.update!(title: 'New Title')
      activity = Activity.where(action: 'title_changed').last

      expect(activity.actor_display_name).to eq(actor.full_name)
    end

    it 'handles nil actor gracefully' do
      ticket.update!(title: 'New Title')
      activity = Activity.where(action: 'title_changed').last

      # Simulate a scenario where actor reference is somehow nil
      # (In practice, this shouldn't happen due to foreign key constraints)
      allow(activity).to receive(:actor).and_return(nil)

      expect(activity.actor_display_name).to eq(I18n.t('activities.deleted_user'))
    end
  end

  describe 'data anonymization compatibility' do
    let(:assignee) { create(:user) }

    before do
      create(:membership, user: assignee, organisation: organisation)
    end

    it 'allows user anonymization without breaking activity history' do
      # Create some activities
      ticket.track_assignee_added(assignee)
      ticket.track_assignee_removed(assignee)

      activities = Activity.where(secondary: assignee).includes(:secondary)
      expect(activities.count).to eq(2)

      # Simulate user anonymization (keeping the record but clearing personal data)
      assignee.update!(
        first_name: 'ANON',
        last_name: 'USER',
        email: "anon-#{assignee.id}@example.com"
      )

      # Activities should still be readable (reload to get updated user data)
      activities.reload.each do |activity|
        expect(activity.secondary).to eq(assignee)
        expect(activity.assignee_display_name).to eq('ANON USER')
      end
    end
  end

  describe 'TicketAssignment does not create duplicate activities' do
    let(:assignee) { create(:user) }

    before do
      create(:membership, user: assignee, organisation: organisation)
      ticket
      clear_all_activities
    end

    it 'does not create activity when TicketAssignment is created directly' do
      expect do
        TicketAssignment.create!(ticket: ticket, user: assignee)
      end.not_to change(Activity, :count)
    end

    it 'does not create activity when TicketAssignment is destroyed' do
      assignment = TicketAssignment.create!(ticket: ticket, user: assignee)

      expect do
        assignment.destroy!
      end.not_to change(Activity, :count)
    end
  end

  describe 'SaveTicket integration' do
    let(:assignee1) { create(:user) }
    let(:assignee2) { create(:user) }

    before do
      create(:membership, user: assignee1, organisation: organisation)
      create(:membership, user: assignee2, organisation: organisation)
      # Assignees must have access to the ticket's project (R5) — org membership alone no
      # longer makes a user assignable.
      create(:project_permission, user: assignee1, project: project, tickets_access: 'read_write')
      create(:project_permission, user: assignee2, project: project, tickets_access: 'read_write')
    end

    it 'tracks assignments without storing personal data' do
      # Use minimal params compatible with the current Ticket model (custom attributes based)
      params = {
        title: 'Test Ticket',
        assignee_ids: [assignee1.id, assignee2.id]
      }

      actor_service = Actors::SaveTicket.new(project: project, params: params, current_user: actor)
      result = actor_service.call

      expect(result.success?).to be true

      # Check assignment activities (includes secondary to avoid N+1)
      assignment_activities = Activity.where(action: 'assigned').includes(:secondary)
      expect(assignment_activities.count).to eq(2)

      assignment_activities.each do |activity|
        # Should not store personal data
        expect(activity.parameters.keys).not_to include('assignee_name', 'assignee_email', 'assignee_id')
        # Should have secondary association
        expect(activity.secondary).to be_in([assignee1, assignee2])
      end
    end
  end
end
