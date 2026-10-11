# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Ticket auto-subscribe behavior' do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:creator) { create(:user) }
  let(:assignee) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: creator, organisation: organisation, role: admin_role, active: true)
    create(:membership, user: assignee, organisation: organisation, role: admin_role, active: true)
  end

  describe 'creator auto-subscribe (Ticket#auto_subscribe_creator)' do
    context 'when auto_follow_created is enabled (default)' do
      before do
        creator.notification_settings.update('auto_follow_created' => true)
      end

      it 'creates a follow subscription for the creator' do
        ticket = create(:ticket, project: project, creator: creator)

        sub = NotificationSubscription.find_by(user: creator, subscribable: ticket)
        expect(sub).to be_present
        expect(sub.mode).to eq('follow')
      end
    end

    context 'when auto_follow_created is disabled' do
      before do
        creator.notification_settings.update('auto_follow_created' => false)
      end

      it 'does NOT create a subscription for the creator' do
        ticket = create(:ticket, project: project, creator: creator)

        sub = NotificationSubscription.find_by(user: creator, subscribable: ticket)
        expect(sub).to be_nil
      end
    end
  end

  describe 'assignee auto-subscribe (TicketAssignment#auto_subscribe_assignee)' do
    let(:ticket) { create(:ticket, project: project, creator: creator) }

    it 'creates a follow subscription when assigned' do
      create(:ticket_assignment, user: assignee, ticket: ticket)

      sub = NotificationSubscription.find_by(user: assignee, subscribable: ticket)
      expect(sub).to be_present
      expect(sub.mode).to eq('follow')
    end

    it 'respects existing mute subscription' do
      NotificationSubscription.create!(
        user: assignee, subscribable: ticket, mode: 'mute'
      )

      create(:ticket_assignment, user: assignee, ticket: ticket)

      sub = NotificationSubscription.find_by(user: assignee, subscribable: ticket)
      expect(sub.mode).to eq('mute')
    end
  end

  describe 'assignee auto-unsubscribe (TicketAssignment#auto_unsubscribe_assignee)' do
    let(:ticket) { create(:ticket, project: project, creator: creator) }

    it 'destroys follow subscription when unassigned' do
      assignment = create(:ticket_assignment, user: assignee, ticket: ticket)
      expect(NotificationSubscription.find_by(user: assignee, subscribable: ticket)).to be_present

      assignment.destroy

      expect(NotificationSubscription.find_by(user: assignee, subscribable: ticket)).to be_nil
    end

    it 'does NOT destroy mute subscription when unassigned' do
      assignment = create(:ticket_assignment, user: assignee, ticket: ticket)
      sub = NotificationSubscription.find_by(user: assignee, subscribable: ticket)
      sub.update!(mode: 'mute')

      assignment.destroy

      expect(NotificationSubscription.find_by(user: assignee, subscribable: ticket)).to be_present
      expect(NotificationSubscription.find_by(user: assignee, subscribable: ticket).mode).to eq('mute')
    end

    it 'keeps subscription if user is also creator with auto-follow' do
      creator.notification_settings.update('auto_follow_created' => true)
      creator_ticket = create(:ticket, project: project, creator: creator)
      assignment = create(:ticket_assignment, user: creator, ticket: creator_ticket)

      assignment.destroy

      sub = NotificationSubscription.find_by(user: creator, subscribable: creator_ticket)
      expect(sub).to be_present
      expect(sub.mode).to eq('follow')
    end

    it 'removes subscription if user is creator but auto-follow is off' do
      creator.notification_settings.update('auto_follow_created' => false)
      creator_ticket = create(:ticket, project: project, creator: creator)

      # Creator won't have auto-subscribed, so create manually
      NotificationSubscription.find_or_create_by(
        user: creator, subscribable: creator_ticket, mode: 'follow'
      )

      assignment = create(:ticket_assignment, user: creator, ticket: creator_ticket)
      assignment.destroy

      expect(NotificationSubscription.find_by(user: creator, subscribable: creator_ticket)).to be_nil
    end
  end
end
