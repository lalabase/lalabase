# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Notifications::Suppressor do
  let(:organisation) { create(:organisation) }
  let(:actor) { create(:user) }
  let(:recipient) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, creator: recipient) }

  let(:activity) do
    create(:activity,
           organisation: organisation,
           trackable: ticket,
           actor: actor,
           action: 'post_added',
           key: 'ticket.post_added',
           parameters: { post_excerpt: 'Test comment' })
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: actor, organisation: organisation, active: true)
    create(:membership, user: recipient, organisation: organisation, active: true)
  end

  describe '#should_suppress?' do
    context 'self-action suppression' do
      it 'suppresses when recipient is the actor' do
        suppressor = described_class.new(activity, actor, 80, 'in_app')
        expect(suppressor.should_suppress?).to be true
        expect(suppressor.suppression_reasons).to include(:self_action)
      end

      it 'suppresses guaranteed recipients when they are the actor' do
        suppressor = described_class.new(activity, actor, 80, 'in_app', guaranteed: true)
        expect(suppressor.should_suppress?).to be true
        expect(suppressor.suppression_reasons).to include(:self_action)
      end

      it 'does not suppress when recipient is different from actor' do
        suppressor = described_class.new(activity, recipient, 80, 'in_app')
        expect(suppressor.should_suppress?).to be false
      end

      context 'system_message exception' do
        let(:system_activity) do
          create(:activity,
                 organisation: organisation,
                 trackable: ticket,
                 actor: actor,
                 action: 'created',
                 key: 'ticket.created',
                 parameters: {})
        end

        it 'does NOT suppress self-action when event type is system_message' do
          suppressor = described_class.new(system_activity, actor, 80, 'in_app')
          expect(suppressor.should_suppress?).to be false
          expect(suppressor.suppression_reasons).not_to include(:self_action)
        end

        it 'does NOT suppress guaranteed self-action when event type is system_message' do
          suppressor = described_class.new(system_activity, actor, 80, 'in_app', guaranteed: true)
          expect(suppressor.should_suppress?).to be false
        end

        it 'still suppresses self-action for non-system event types' do
          suppressor = described_class.new(activity, actor, 80, 'in_app')
          expect(suppressor.should_suppress?).to be true
          expect(suppressor.suppression_reasons).to include(:self_action)
        end
      end
    end

    context 'score-based suppression' do
      it 'suppresses non-guaranteed recipients with low score' do
        suppressor = described_class.new(activity, recipient, 5, 'in_app')
        expect(suppressor.should_suppress?).to be true
        expect(suppressor.suppression_reasons).to include(:low_score)
      end

      it 'does NOT suppress guaranteed recipients with low score' do
        suppressor = described_class.new(activity, recipient, 5, 'in_app', guaranteed: true)
        expect(suppressor.should_suppress?).to be false
      end

      it 'does not suppress non-guaranteed recipients with high score' do
        suppressor = described_class.new(activity, recipient, 80, 'in_app')
        expect(suppressor.should_suppress?).to be false
      end
    end

    context 'mute suppression' do
      it 'suppresses guaranteed recipients who have muted the subscription' do
        # auto_subscribe_creator may have created a follow subscription,
        # so switch the existing one to mute instead of creating a new one
        sub = NotificationSubscription.find_by(user: recipient, subscribable: ticket)
        if sub
          sub.update_column(:mode, 'mute')
        else
          NotificationSubscription.new(
            user: recipient,
            subscribable: ticket,
            organisation: organisation,
            mode: 'mute'
          ).save!(validate: false)
        end

        suppressor = described_class.new(activity, recipient, 80, 'in_app', guaranteed: true)
        expect(suppressor.should_suppress?).to be true
        expect(suppressor.suppression_reasons).to include(:muted_subscription)
      end
    end

    context 'duplicate suppression removed' do
      it 'does not respond to suppress_duplicate?' do
        suppressor = described_class.new(activity, recipient, 80, 'in_app')
        expect(suppressor.respond_to?(:suppress_duplicate?, true)).to be false
      end
    end
  end
end
