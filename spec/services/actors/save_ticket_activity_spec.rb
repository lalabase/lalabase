# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Actors::SaveTicket, type: :service do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
    create(:membership, user: other_user, organisation: organisation)
    # Assignees must have access to the ticket's project (R5) — org membership alone no
    # longer makes a user assignable.
    create(:project_permission, user: user, project: project, tickets_access: 'read_write')
    create(:project_permission, user: other_user, project: project, tickets_access: 'read_write')
    Current.user = user
  end

  describe 'activity tracking for assignments' do
    context 'when creating a ticket with assignees' do
      it 'creates assignment activities', :aggregate_failures do
        ticket_params = {
          title: 'Test Ticket',
          custom_attributes: {
            'status' => 'open',
            'priority' => 'normal'
          },
          assignee_ids: [user.id, other_user.id]
        }

        # Execute the actor
        actor = described_class.new(project: project, params: ticket_params, id: nil, current_user: user)
        result = actor.call
        expect(result.success?).to be true

        ticket = Ticket.last
        expect(ticket.assignees.map(&:id)).to match_array([user.id, other_user.id])

        activities = Activity.where(trackable: ticket).order(:created_at)

        expect(activities.count).to eq(3) # 1 for create + 2 for assignments
        expect(activities.map(&:action)).to include('created', 'assigned')

        assignment_activities = activities.where(action: 'assigned')
        expect(assignment_activities.count).to eq(2)
        expect(assignment_activities.map(&:secondary_id)).to match_array([user.id, other_user.id])
      end
    end

    context 'when updating ticket assignments' do
      let(:ticket) do
        # Create ticket without callbacks to set up initial state
        t = build(:ticket, project: project, organisation: organisation)
        t.define_singleton_method(:track_activities?) { false }
        t.save!
        t
      end

      it 'tracks added and removed assignees' do
        Prosopite.pause
        ticket.assignees = [user]
        Activity.destroy_all # Clear activities for clean test
        Prosopite.resume

        # Enable tracking
        ticket.define_singleton_method(:track_activities?) { true }

        # Update assignees - remove user, add other_user
        ticket_params = {
          assignee_ids: [other_user.id]
        }

        actor = described_class.new(project: project, params: ticket_params, id: ticket.id, current_user: user)
        result = actor.call
        expect(result.success?).to be true

        # Filter only assignment-related activities
        assignment_activities = Activity.where(trackable: ticket, action: %w[assigned unassigned])

        # Check removal activity
        removal = assignment_activities.find_by(action: 'unassigned')
        expect(removal).to be_present
        expect(removal.secondary_id).to eq(user.id)

        # Check addition activity
        addition = assignment_activities.find_by(action: 'assigned')
        expect(addition).to be_present
        expect(addition.secondary_id).to eq(other_user.id)
      end

      it 'tracks when all assignees are removed' do
        Prosopite.pause
        ticket.assignees = [user, other_user]
        Activity.destroy_all
        Prosopite.resume

        ticket.define_singleton_method(:track_activities?) { true }

        # Remove all assignees
        ticket_params = {
          assignee_ids: []
        }

        actor = described_class.new(project: project, params: ticket_params, id: ticket.id, current_user: user)
        result = actor.call
        expect(result.success?).to be true

        activities = Activity.where(trackable: ticket, action: 'unassigned')
        expect(activities.count).to eq(2)
        expect(activities.pluck(:secondary_id)).to match_array([user.id, other_user.id])
      end
    end
  end
end
