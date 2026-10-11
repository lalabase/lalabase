# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NotificationSubscription, 'source' do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, creator: create(:user)) }

  before do
    ActsAsTenant.current_tenant = organisation
    [user, other_user, ticket.creator].each do |u|
      create(:membership, user: u, organisation: organisation, role: admin_role, active: true)
    end
  end

  describe 'source validation' do
    it 'accepts valid source values' do
      NotificationSubscription::SOURCES.each do |source|
        sub = described_class.new(
          user: user, subscribable: ticket, organisation: organisation,
          mode: 'follow', source: source,
          subscribed_by: source == 'manual' ? other_user : nil
        )
        sub.valid?
        expect(sub.errors[:source]).to be_empty, "Expected '#{source}' to be valid"
      end
    end

    it 'rejects invalid source values' do
      sub = described_class.new(
        user: user, subscribable: ticket, organisation: organisation,
        mode: 'follow', source: 'invalid'
      )
      expect(sub).not_to be_valid
      expect(sub.errors[:source]).to be_present
    end

    it 'allows nil source' do
      sub = described_class.new(
        user: user, subscribable: ticket, organisation: organisation,
        mode: 'follow', source: nil
      )
      sub.valid?
      expect(sub.errors[:source]).to be_empty
    end
  end

  describe 'subscribed_by validation for manual source' do
    it 'requires subscribed_by when source is manual' do
      sub = described_class.new(
        user: user, subscribable: ticket, organisation: organisation,
        mode: 'follow', source: 'manual', subscribed_by: nil
      )
      expect(sub).not_to be_valid
      expect(sub.errors[:subscribed_by]).to be_present
    end

    it 'does not require subscribed_by for non-manual sources' do
      sub = described_class.new(
        user: user, subscribable: ticket, organisation: organisation,
        mode: 'follow', source: 'creator', subscribed_by: nil
      )
      sub.valid?
      expect(sub.errors[:subscribed_by]).to be_empty
    end
  end

  describe '.system_subscribe with source' do
    it 'sets source when creating new subscription' do
      sub = described_class.system_subscribe(
        user: user, item: ticket, source: NotificationSubscription::SOURCE_CREATOR
      )
      expect(sub.source).to eq('creator')
    end

    it 'does not overwrite existing source' do
      described_class.system_subscribe(
        user: user, item: ticket, source: NotificationSubscription::SOURCE_CREATOR
      )
      sub = described_class.system_subscribe(
        user: user, item: ticket, source: NotificationSubscription::SOURCE_ASSIGNEE
      )
      expect(sub.source).to eq('creator')
    end

    it 'respects mute even with source' do
      described_class.create!(user: user, subscribable: ticket, mode: 'mute')
      sub = described_class.system_subscribe(
        user: user, item: ticket, source: NotificationSubscription::SOURCE_ASSIGNEE
      )
      expect(sub).to be_nil
    end
  end

  describe '.subscribe_other' do
    it 'creates a manual subscription' do
      sub = described_class.subscribe_other(
        user: other_user, item: ticket, subscribed_by: user
      )
      expect(sub).to be_persisted
      expect(sub.source).to eq('manual')
      expect(sub.subscribed_by).to eq(user)
      expect(sub.user).to eq(other_user)
      expect(sub.mode).to eq('follow')
    end

    it 'returns existing subscription if already following' do
      existing = described_class.system_subscribe(user: other_user, item: ticket)
      sub = described_class.subscribe_other(
        user: other_user, item: ticket, subscribed_by: user
      )
      expect(sub.id).to eq(existing.id)
    end

    it 'returns nil if user has muted' do
      described_class.create!(user: other_user, subscribable: ticket, mode: 'mute')
      sub = described_class.subscribe_other(
        user: other_user, item: ticket, subscribed_by: user
      )
      expect(sub).to be_nil
    end

    it 'is idempotent on race condition' do
      # First create
      described_class.subscribe_other(user: other_user, item: ticket, subscribed_by: user)
      # Second attempt should not raise
      expect do
        described_class.subscribe_other(user: other_user, item: ticket, subscribed_by: user)
      end.not_to raise_error
    end
  end

  describe 'auto_subscribe_creator sets source' do
    it 'creates subscription with creator source' do
      creator = create(:user)
      create(:membership, user: creator, organisation: organisation, role: admin_role, active: true)
      creator.notification_settings.update('auto_follow_created' => true)

      new_ticket = create(:ticket, project: project, creator: creator)

      sub = described_class.find_by(user: creator, subscribable: new_ticket)
      expect(sub).to be_present
      expect(sub.source).to eq('creator')
    end
  end

  describe 'auto_subscribe_assignee sets source' do
    it 'creates subscription with assignee source' do
      create(:ticket_assignment, user: other_user, ticket: ticket)

      sub = described_class.find_by(user: other_user, subscribable: ticket)
      expect(sub).to be_present
      expect(sub.source).to eq('assignee')
    end
  end

  describe '.toggle_for sets source on new self-subscribe' do
    it 'sets source to self' do
      sub = described_class.toggle_for(user: user, item: ticket)
      expect(sub.source).to eq('self')
    end
  end

  describe 'scopes' do
    it '.visible excludes muted subscriptions' do
      # Clear any auto-created subscriptions first
      described_class.where(subscribable: ticket).destroy_all

      described_class.create!(user: user, subscribable: ticket, mode: 'follow')
      described_class.create!(user: other_user, subscribable: ticket, mode: 'mute')

      visible = described_class.for_item(ticket).visible
      expect(visible.count).to eq(1)
      expect(visible.first.user).to eq(user)
    end

    it '.with_subscribers eager loads user and subscribed_by' do
      described_class.create!(user: user, subscribable: ticket, mode: 'follow')

      subs = described_class.for_item(ticket).with_subscribers
      expect(subs.first.association(:user)).to be_loaded
      expect(subs.first.association(:subscribed_by)).to be_loaded
    end
  end
end
