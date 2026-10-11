# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NotificationSubscription, '.toggle_for' do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, creator: create(:user)) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    create(:membership, user: ticket.creator, organisation: organisation, role: admin_role, active: true) unless ticket.creator == user
  end

  describe 'toggle ON when no subscription exists' do
    it 'creates a follow subscription' do
      result = described_class.toggle_for(user: user, item: ticket)

      expect(result).to be_a(NotificationSubscription)
      expect(result.mode).to eq('follow')
      expect(result.user).to eq(user)
      expect(result.subscribable).to eq(ticket)
    end
  end

  describe 'toggle OFF when currently following' do
    context 'when auto-rules would NOT subscribe (not assignee, not creator)' do
      before do
        described_class.create!(user: user, subscribable: ticket, mode: 'follow')
      end

      it 'destroys the subscription' do
        result = described_class.toggle_for(user: user, item: ticket)

        expect(result).to be_nil
        expect(described_class.find_by(user: user, subscribable: ticket)).to be_nil
      end
    end

    context 'when auto-rules would subscribe (user is assignee)' do
      before do
        described_class.create!(user: user, subscribable: ticket, mode: 'follow')
        create(:ticket_assignment, user: user, ticket: ticket)
      end

      it 'sets mode to mute (explicit opt-out)' do
        result = described_class.toggle_for(user: user, item: ticket)

        expect(result.mode).to eq('mute')
        expect(result).to be_persisted
      end
    end

    context 'when auto-rules would subscribe (user is creator with auto-follow)' do
      let(:ticket) { create(:ticket, project: project, creator: user) }

      it 'sets mode to mute when auto_follow_created is enabled' do
        # auto_subscribe_creator already creates follow subscription
        user.notification_settings.update('auto_follow_created' => true)
        expect(described_class.find_by(user: user, subscribable: ticket)&.mode).to eq('follow')

        result = described_class.toggle_for(user: user, item: ticket)

        expect(result.mode).to eq('mute')
      end

      it 'destroys subscription when auto_follow_created is disabled' do
        user.notification_settings.update('auto_follow_created' => false)
        # Create subscription manually since auto-subscribe didn't fire
        described_class.find_or_create_by!(user: user, subscribable: ticket, mode: 'follow')

        result = described_class.toggle_for(user: user, item: ticket)

        expect(result).to be_nil
      end
    end
  end

  describe 'toggle ON when currently muted' do
    before do
      described_class.create!(user: user, subscribable: ticket, mode: 'mute')
    end

    it 'updates to follow' do
      result = described_class.toggle_for(user: user, item: ticket)

      expect(result.mode).to eq('follow')
      expect(result).to be_persisted
    end
  end

  describe 'explicit mode parameter' do
    it 'creates follow when mode=follow' do
      result = described_class.toggle_for(user: user, item: ticket, mode: 'follow')

      expect(result.mode).to eq('follow')
    end

    it 'creates mute when mode=mute' do
      result = described_class.toggle_for(user: user, item: ticket, mode: 'mute')

      expect(result.mode).to eq('mute')
    end

    it 'destroys subscription when mode is anything else' do
      described_class.create!(user: user, subscribable: ticket, mode: 'follow')
      result = described_class.toggle_for(user: user, item: ticket, mode: 'destroy')

      expect(result).to be_nil
      expect(described_class.find_by(user: user, subscribable: ticket)).to be_nil
    end
  end

  describe '.auto_would_subscribe?' do
    it 'returns true when user is assignee' do
      create(:ticket_assignment, user: user, ticket: ticket)

      expect(described_class.auto_would_subscribe?(user, ticket)).to be true
    end

    it 'returns true when user is creator with auto_follow_created enabled' do
      creator_ticket = create(:ticket, project: project, creator: user)
      user.notification_settings.update('auto_follow_created' => true)

      expect(described_class.auto_would_subscribe?(user, creator_ticket)).to be true
    end

    it 'returns false when user is creator with auto_follow_created disabled' do
      creator_ticket = create(:ticket, project: project, creator: user)
      user.notification_settings.update('auto_follow_created' => false)

      expect(described_class.auto_would_subscribe?(user, creator_ticket)).to be false
    end

    it 'returns false when user has no relation to ticket' do
      expect(described_class.auto_would_subscribe?(user, ticket)).to be false
    end

    it 'returns false for non-ticket items' do
      expect(described_class.auto_would_subscribe?(user, project)).to be false
    end
  end

  describe '#watching?' do
    it 'returns true when mode is follow' do
      sub = described_class.create!(user: user, subscribable: ticket, mode: 'follow')
      expect(sub.watching?).to be true
    end

    it 'returns false when mode is mute' do
      sub = described_class.create!(user: user, subscribable: ticket, mode: 'mute')
      expect(sub.watching?).to be false
    end
  end
end
