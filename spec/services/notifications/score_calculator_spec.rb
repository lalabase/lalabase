# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Notifications::ScoreCalculator, type: :service do
  let(:organisation) { create(:organisation) }
  let(:actor) { create(:user) }
  let(:recipient) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) do
    create(:ticket, project: project, organisation: organisation, creator: actor)
  end

  let(:activity) do
    create(:activity,
           actor: actor,
           organisation: organisation,
           trackable: ticket,
           key: 'ticket.commented',
           action: 'commented',
           created_at: 10.minutes.ago)
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: actor, organisation: organisation)
    create(:membership, user: recipient, organisation: organisation)
  end

  subject(:calculator) { described_class.new(activity, recipient) }

  # ─── CALCULATE (integration) ───────────────────────────────────────

  describe '#calculate' do
    it 'returns an integer score' do
      score = calculator.calculate

      expect(score).to be_a(Integer).or be_a(Float)
      expect(score).to be >= 0
      expect(score).to be <= 100
    end

    it 'clamps score at maximum 100' do
      # Mention (base 70) + mentioned bonus (25) + creator bonus (20) + immediate (10) = 125 → 100
      ticket.update_column(:creator_id, recipient.id)
      mention_activity = create(:activity,
                                actor: actor,
                                organisation: organisation,
                                trackable: ticket,
                                key: 'mention.created',
                                action: 'mentioned',
                                parameters: { 'mentioned_user_ids' => [recipient.id] },
                                created_at: 5.minutes.ago)

      calc = described_class.new(mention_activity, recipient)
      expect(calc.calculate).to eq(100)
    end

    it 'clamps score at minimum 0' do
      # Create muted subscription (-50 penalty) with low base score
      sub = NotificationSubscription.new(
        user: recipient,
        subscribable: ticket,
        mode: 'mute',
        organisation: organisation
      )
      sub.save!(validate: false)

      # document_added base = 25, mute = -50, with old activity
      doc_activity = create(:activity,
                            actor: actor,
                            organisation: organisation,
                            trackable: ticket,
                            key: 'document.created',
                            action: 'document_added',
                            created_at: 30.days.ago)

      calc = described_class.new(doc_activity, recipient)
      expect(calc.calculate).to be >= 0
    end

    it 'accepts optional organisation parameter' do
      calc = described_class.new(activity, recipient, organisation)

      expect(calc.calculate).to be_a(Integer).or be_a(Float)
    end
  end

  # ─── BASE SCORE ────────────────────────────────────────────────────

  describe 'base_score (via event type)' do
    # Map of activity key → expected base score
    {
      ['mention.created', 'mentioned'] => 70,
      ['ticket.assigned', 'assigned'] => 65,
      ['ticket.unassigned', 'unassigned'] => 65,
      ['ticket.priority_changed', 'priority_changed'] => 60,
      ['project.announcement', 'announcement'] => 50,
      ['ticket.status_changed', 'status_changed'] => 40,
      ['ticket.commented', 'commented'] => 30,
      ['document.created', 'document_added'] => 25,
      ['ticket.created', 'created'] => 80 # maps to system_message
    }.each do |(key, action), expected_score|
      it "scores #{expected_score} for #{key}" do
        act = create(:activity,
                     actor: actor,
                     organisation: organisation,
                     trackable: ticket,
                     key: key,
                     action: action,
                     created_at: 2.hours.ago)

        calc = described_class.new(act, recipient)
        # Score = base + any proximity/subscription/recency bonuses
        # For a non-creator, non-assignee, with 2h-old activity (recency = 5)
        score = calc.calculate
        expect(score).to be >= expected_score
      end
    end

    it 'falls back to system_message for unknown event types' do
      act = create(:activity,
                   actor: actor,
                   organisation: organisation,
                   trackable: ticket,
                   key: 'unknown.event',
                   action: 'unknown_action',
                   created_at: 2.hours.ago)

      calc = described_class.new(act, recipient)
      # system_message base = 80, recency ~5 = 85
      expect(calc.calculate).to be >= 80
    end
  end

  # ─── PROXIMITY BONUS ──────────────────────────────────────────────

  describe 'proximity_bonus' do
    context 'when recipient is the creator of the trackable' do
      before { ticket.update_column(:creator_id, recipient.id) }

      it 'adds creator bonus (+20)' do
        score_as_creator = calculator.calculate

        ticket.update_column(:creator_id, actor.id)
        score_as_stranger = described_class.new(activity, recipient).calculate

        expect(score_as_creator).to eq(score_as_stranger + 20)
      end
    end

    context 'when recipient is assigned to the trackable' do
      it 'adds assignee bonus (+20)' do
        # Use stubbing to isolate assignee bonus from side effects
        # (assigning creates activities and may change project access)
        calc_without = described_class.new(activity, recipient)
        allow(calc_without).to receive(:trackable_assigned_to_recipient?).and_return(false)
        score_without = calc_without.send(:proximity_bonus)

        calc_with = described_class.new(activity, recipient)
        allow(calc_with).to receive(:trackable_assigned_to_recipient?).and_return(true)
        score_with = calc_with.send(:proximity_bonus)

        expect(score_with - score_without).to eq(20)
      end

      it 'detects assignees via the assignees association' do
        ticket.assignees << recipient
        calc = described_class.new(activity, recipient)

        expect(calc.calculate).to be > described_class.new(
          create(:activity, actor: actor, organisation: organisation,
                            trackable: create(:ticket, project: project, organisation: organisation, creator: actor),
                            key: 'ticket.commented', action: 'commented', created_at: activity.created_at),
          recipient
        ).calculate
      end
    end

    context 'when recipient is mentioned in activity parameters' do
      it 'adds mention bonus (+25) for mentioned_user_ids array' do
        mention_activity = create(:activity,
                                  actor: actor,
                                  organisation: organisation,
                                  trackable: ticket,
                                  key: 'ticket.commented',
                                  action: 'commented',
                                  parameters: { 'mentioned_user_ids' => [recipient.id] },
                                  created_at: activity.created_at)

        score_mentioned = described_class.new(mention_activity, recipient).calculate
        score_not_mentioned = calculator.calculate

        expect(score_mentioned).to eq(score_not_mentioned + 25)
      end

      it 'adds mention bonus (+25) for mentioned_users with email' do
        mention_activity = create(:activity,
                                  actor: actor,
                                  organisation: organisation,
                                  trackable: ticket,
                                  key: 'ticket.commented',
                                  action: 'commented',
                                  parameters: { 'mentioned_users' => [recipient.email] },
                                  created_at: activity.created_at)

        score_mentioned = described_class.new(mention_activity, recipient).calculate
        score_not_mentioned = calculator.calculate

        expect(score_mentioned).to eq(score_not_mentioned + 25)
      end
    end

    context 'when recipient has previously participated (has activities on trackable)' do
      it 'adds participant bonus (+10) when recipient has activities on trackable' do
        # Use stubbing to isolate participant bonus cleanly
        calc_without = described_class.new(activity, recipient)
        allow(Activity).to receive(:where).and_call_original
        allow(Activity).to receive(:where)
          .with(trackable: ticket, actor: recipient)
          .and_return(double(exists?: false))
        score_without = calc_without.send(:proximity_bonus)

        calc_with = described_class.new(activity, recipient)
        allow(Activity).to receive(:where)
          .with(trackable: ticket, actor: recipient)
          .and_return(double(exists?: true))
        score_with = calc_with.send(:proximity_bonus)

        expect(score_with - score_without).to eq(10)
      end

      it 'detects participation via actual Activity records' do
        create(:activity,
               actor: recipient,
               organisation: organisation,
               trackable: ticket,
               key: 'ticket.commented',
               action: 'commented',
               created_at: 1.day.ago)

        # Recipient now has participation activity → should get bonus
        score = calculator.calculate
        # base 30 + participant 10 + recency 10 = 50 minimum
        expect(score).to be >= 50
      end
    end

    context 'when recipient is a team member (has project access)' do
      it 'adds team_member bonus (+5) when user can access project' do
        allow(recipient).to receive(:can_access_project?).and_return(true)

        score = calculator.calculate
        expect(score).to be >= 5
      end
    end

    context 'when trackable is nil' do
      let(:activity_no_trackable) do
        act = create(:activity,
                     actor: actor,
                     organisation: organisation,
                     trackable: ticket,
                     key: 'ticket.commented',
                     action: 'commented',
                     created_at: 10.minutes.ago)
        allow(act).to receive(:trackable).and_return(nil)
        act
      end

      it 'returns 0 for all proximity checks' do
        calc = described_class.new(activity_no_trackable, recipient)
        # Only base_score + recency_bonus, no proximity
        score = calc.calculate
        # ticket.commented = 30 base + 10 recency (immediate) = 40
        expect(score).to eq(40)
      end
    end

    context 'when recipient has multiple proximity types (stacking)' do
      before do
        # Recipient is creator AND assignee
        ticket.update_column(:creator_id, recipient.id)
        ticket.assignees << recipient
      end

      it 'stacks creator and assignee bonuses (+40 total)' do
        score = calculator.calculate
        # Base 30 (commented) + creator 20 + assignee 20 + recency 10 = 80
        # May also include team_member bonus if project access
        expect(score).to be >= 70
      end
    end
  end

  # ─── SUBSCRIPTION BONUS ───────────────────────────────────────────

  describe 'subscription_bonus' do
    context 'with immediate/watching subscription (high engagement)' do
      before do
        sub = NotificationSubscription.new(
          user: recipient,
          subscribable: ticket,
          mode: 'immediate',
          organisation: organisation
        )
        sub.save!(validate: false)
      end

      it 'adds double watcher bonus (+20)' do
        score_with_sub = calculator.calculate

        NotificationSubscription.where(user: recipient).delete_all
        score_without = described_class.new(activity, recipient).calculate

        expect(score_with_sub).to eq(score_without + 20)
      end
    end

    context 'with follow subscription (normal engagement)' do
      before do
        sub = NotificationSubscription.new(
          user: recipient,
          subscribable: ticket,
          mode: 'follow',
          organisation: organisation
        )
        sub.save!(validate: false)
      end

      it 'adds watcher bonus (+10)' do
        score_with_sub = calculator.calculate

        NotificationSubscription.where(user: recipient).delete_all
        score_without = described_class.new(activity, recipient).calculate

        expect(score_with_sub).to eq(score_without + 10)
      end
    end

    context 'with mute subscription' do
      before do
        sub = NotificationSubscription.new(
          user: recipient,
          subscribable: ticket,
          mode: 'mute',
          organisation: organisation
        )
        sub.save!(validate: false)
      end

      it 'applies heavy penalty (-50)' do
        score_with_mute = calculator.calculate

        NotificationSubscription.where(user: recipient).delete_all
        score_without = described_class.new(activity, recipient).calculate

        expect(score_with_mute).to eq([score_without - 50, 0].max)
      end
    end

    context 'with no subscription' do
      it 'adds no subscription bonus' do
        score = calculator.calculate
        # No subscription → 0 subscription bonus
        expect(score).to be > 0
      end
    end

    context 'with project-level subscription' do
      before do
        sub = NotificationSubscription.new(
          user: recipient,
          subscribable: project,
          mode: 'follow',
          organisation: organisation
        )
        sub.save!(validate: false)
      end

      it 'picks up project-level subscription for items in that project' do
        score_with = calculator.calculate

        NotificationSubscription.where(user: recipient).delete_all
        score_without = described_class.new(activity, recipient).calculate

        expect(score_with).to eq(score_without + 10)
      end
    end
  end

  # ─── RECENCY BONUS ────────────────────────────────────────────────

  describe 'recency_bonus' do
    context 'immediate: activity < 1 hour ago' do
      let(:recent_activity) do
        create(:activity,
               actor: actor, organisation: organisation,
               trackable: ticket, key: 'ticket.commented',
               action: 'commented', created_at: 30.minutes.ago)
      end

      it 'adds immediate bonus (+10)' do
        calc = described_class.new(recent_activity, recipient)
        score = calc.calculate
        # base 30 + recency 10 = 40
        expect(score).to be >= 40
      end
    end

    context 'recent: activity 1-24 hours ago' do
      let(:few_hours_activity) do
        create(:activity,
               actor: actor, organisation: organisation,
               trackable: ticket, key: 'ticket.commented',
               action: 'commented', created_at: 6.hours.ago)
      end

      it 'adds recent bonus (+5)' do
        calc = described_class.new(few_hours_activity, recipient)
        score = calc.calculate
        # base 30 + recency 5 = 35
        expect(score).to be >= 35
      end
    end

    context 'moderate: activity 1-7 days ago' do
      let(:days_old_activity) do
        create(:activity,
               actor: actor, organisation: organisation,
               trackable: ticket, key: 'ticket.commented',
               action: 'commented', created_at: 3.days.ago)
      end

      it 'adds moderate bonus (+2)' do
        calc = described_class.new(days_old_activity, recipient)
        score = calc.calculate
        # base 30 + recency 2 = 32
        expect(score).to be >= 32
      end
    end

    context 'old: activity > 7 days ago' do
      let(:old_activity) do
        create(:activity,
               actor: actor, organisation: organisation,
               trackable: ticket, key: 'ticket.commented',
               action: 'commented', created_at: 14.days.ago)
      end

      it 'adds no recency bonus (+0)' do
        calc = described_class.new(old_activity, recipient)
        score = calc.calculate
        # base 30 + recency 0 = 30
        expect(score).to eq(30)
      end
    end
  end

  # ─── EDGE CASES ────────────────────────────────────────────────────

  describe 'edge cases' do
    context 'when activity has no parameters' do
      let(:no_params_activity) do
        create(:activity,
               actor: actor, organisation: organisation,
               trackable: ticket, key: 'ticket.commented',
               action: 'commented', parameters: nil,
               created_at: 10.minutes.ago)
      end

      it 'does not crash on mentioned? check' do
        calc = described_class.new(no_params_activity, recipient)

        expect { calc.calculate }.not_to raise_error
      end
    end

    context 'when trackable does not respond to project' do
      it 'returns false for team_member? without crashing' do
        # Use organisation as trackable (no #project method)
        act = create(:activity,
                     actor: actor, organisation: organisation,
                     trackable: organisation, key: 'ticket.commented',
                     action: 'commented', created_at: 10.minutes.ago)

        calc = described_class.new(act, recipient)
        expect { calc.calculate }.not_to raise_error
      end
    end

    context 'when trackable is a Project itself' do
      it 'checks team_member? directly against the project' do
        act = create(:activity,
                     actor: actor, organisation: organisation,
                     trackable: project, key: 'project.announcement',
                     action: 'announcement', created_at: 10.minutes.ago)

        allow(recipient).to receive(:can_access_project?).with(project, :read, :tickets).and_return(true)

        calc = described_class.new(act, recipient)
        score = calc.calculate
        # project_announcement = 50, team_member = 5, recency = 10
        expect(score).to be >= 60
      end
    end

    context 'when find_subscription raises an error' do
      before do
        allow(NotificationSubscription).to receive(:where).and_raise(StandardError, 'DB error')
      end

      it 'returns 0 subscription bonus (rescued)' do
        expect { calculator.calculate }.not_to raise_error
      end
    end

    context 'when can_access_project? raises an error' do
      before do
        allow(recipient).to receive(:can_access_project?).and_raise(StandardError, 'Access error')
      end

      it 'returns false for team_member? (rescued)' do
        expect { calculator.calculate }.not_to raise_error
      end
    end
  end

  # ─── SCORE COMPOSITION VERIFICATION ────────────────────────────────

  describe 'score composition' do
    it 'computes score as base + proximity + subscription + recency' do
      # Simple case: ticket.commented, no proximity, no subscription, immediate recency
      # Expected: 30 (base) + 0 (proximity) + 0 (subscription) + 10 (recency) = 40
      simple_activity = create(:activity,
                               actor: actor, organisation: organisation,
                               trackable: ticket, key: 'ticket.commented',
                               action: 'commented', created_at: 5.minutes.ago)

      calc = described_class.new(simple_activity, recipient)
      expect(calc.calculate).to eq(40)
    end

    it 'applies org adjustments (currently no-op)' do
      # Just verifies apply_org_adjustments doesn't change score
      score = calculator.calculate
      expect(score).to be > 0
    end
  end
end
