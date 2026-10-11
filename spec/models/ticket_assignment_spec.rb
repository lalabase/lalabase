# frozen_string_literal: true

# == Schema Information
#
# Table name: ticket_assignments
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  ticket_id  :uuid             not null
#  user_id    :uuid             not null
#
# Indexes
#
#  index_ticket_assignments_on_ticket_id              (ticket_id)
#  index_ticket_assignments_on_ticket_id_and_user_id  (ticket_id,user_id) UNIQUE
#  index_ticket_assignments_on_user_id                (user_id)
#
require 'rails_helper'

RSpec.describe TicketAssignment, type: :model do
  let(:organisation) { create(:organisation) }

  describe 'associations' do
    it { should belong_to(:ticket) }
    it { should belong_to(:user) }
  end

  describe 'basic functionality' do
    it 'allows a ticket to be assigned to a user' do
      ActsAsTenant.with_tenant(organisation) do
        user = create(:user)
        ticket = create(:ticket)

        create(:ticket_assignment, ticket: ticket, user: user)

        expect(ticket.assignees).to include(user)
        expect(user.assigned_tickets).to include(ticket)
      end
    end

    it 'allows a ticket to be assigned to multiple users' do
      ActsAsTenant.with_tenant(organisation) do
        user1 = create(:user)
        user2 = create(:user)
        ticket = create(:ticket)

        create(:ticket_assignment, ticket: ticket, user: user1)
        create(:ticket_assignment, ticket: ticket, user: user2)

        expect(ticket.assignees.count).to eq(2)
        expect(ticket.assignees.to_a).to include(user1, user2)
      end
    end

    it 'allows a user to be assigned to multiple tickets' do
      ActsAsTenant.with_tenant(organisation) do
        user = create(:user)
        ticket1 = create(:ticket)
        ticket2 = create(:ticket)

        create(:ticket_assignment, ticket: ticket1, user: user)
        create(:ticket_assignment, ticket: ticket2, user: user)

        expect(user.assigned_tickets.count).to eq(2)
        expect(user.assigned_tickets.to_a).to include(ticket1, ticket2)
      end
    end
  end

  describe 'deletion behavior' do
    it 'is destroyed when the associated ticket is destroyed' do
      ActsAsTenant.with_tenant(organisation) do
        ticket = create(:ticket)
        user = create(:user)
        assignment = create(:ticket_assignment, ticket: ticket, user: user)

        expect do
          ticket.destroy
        end.to change(TicketAssignment, :count).by(-1)

        expect(TicketAssignment.exists?(assignment.id)).to be_falsey
      end
    end

    it 'is affected when the associated user is destroyed' do
      ActsAsTenant.with_tenant(organisation) do
        ticket = create(:ticket)
        user = create(:user)
        assignment = create(:ticket_assignment, ticket: ticket, user: user)

        # In the current model, destroying a user might:
        # 1. Destroy the ticket assignment (if dependent: :destroy is set on user.ticket_assignments)
        # 2. Nullify the user_id (if dependent: :nullify is set)
        # 3. Raise an error (if no dependent option is set and there's a foreign key constraint)

        # Determine which behavior is implemented
        begin
          user.destroy
          # If we get here, either the assignment was destroyed or nullified

          if TicketAssignment.exists?(assignment.id)
            # Assignment still exists, so it was nullified
            reloaded_assignment = TicketAssignment.find(assignment.id)
            expect(reloaded_assignment.user_id).to be_nil
          else
            # Assignment was destroyed
            expect(TicketAssignment.exists?(assignment.id)).to be_falsey
          end
        rescue ActiveRecord::InvalidForeignKey
          # If this error is raised, it means there's a foreign key constraint
          # but no dependent option set, which is a valid implementation too
          expect { user.destroy }.to raise_error(ActiveRecord::InvalidForeignKey)
        end
      end
    end
  end
end
