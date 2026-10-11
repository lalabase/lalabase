# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Dashboard::BriefingActivityGroup do
  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:actor)        { create(:user) }
  let(:other_actor)  { create(:user) }
  let(:ticket)       { create(:ticket, project: project) }
  let(:other_ticket) { create(:ticket, project: project) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  describe '.aggregate' do
    it 'collapses multiple activities by the same actor on the same trackable to one group' do
      created   = create(:activity, trackable: ticket, actor: actor, action: 'created', created_at: 3.hours.ago)
      assigned  = create(:activity, trackable: ticket, actor: actor, action: 'assigned', created_at: 2.hours.ago)
      edited    = create(:activity, trackable: ticket, actor: actor, action: 'updated', created_at: 1.hour.ago)

      groups = described_class.aggregate([edited, assigned, created])

      expect(groups.size).to eq(1)
      group = groups.first
      expect(group.trackable).to eq(ticket)
      expect(group.actor).to eq(actor)
      expect(group.headline_action).to eq(:created)
      expect(group.secondary_count).to eq(2)
      expect(group.latest_at).to be_within(1.second).of(edited.created_at)
    end

    it 'picks the highest-ranked action as headline (created > assigned > commented > status_changed > edited)' do
      assigned       = create(:activity, trackable: ticket, actor: actor, action: 'assigned')
      status_changed = create(:activity, trackable: ticket, actor: actor, action: 'status_changed')

      group = described_class.aggregate([status_changed, assigned]).first
      expect(group.headline_action).to eq(:assigned)
    end

    it 'maps unmapped actions (priority_changed, title_changed, …) to :edited' do
      activity = create(:activity, trackable: ticket, actor: actor, action: 'priority_changed')

      group = described_class.aggregate([activity]).first
      expect(group.headline_action).to eq(:edited)
    end

    it 'keeps separate groups for different actors on the same trackable' do
      a1 = create(:activity, trackable: ticket, actor: actor, action: 'created')
      a2 = create(:activity, trackable: ticket, actor: other_actor, action: 'assigned')

      groups = described_class.aggregate([a1, a2])
      expect(groups.size).to eq(2)
      expect(groups.map(&:actor)).to contain_exactly(actor, other_actor)
    end

    it 'keeps separate groups for the same actor across different trackables' do
      a1 = create(:activity, trackable: ticket, actor: actor, action: 'created')
      a2 = create(:activity, trackable: other_ticket, actor: actor, action: 'created')

      groups = described_class.aggregate([a1, a2])
      expect(groups.size).to eq(2)
      expect(groups.map(&:trackable)).to contain_exactly(ticket, other_ticket)
    end

    it 'orders groups by latest_at descending' do
      old_ticket_activity   = create(:activity, trackable: ticket,       actor: actor, action: 'created',  created_at: 5.hours.ago)
      fresh_other_activity  = create(:activity, trackable: other_ticket, actor: actor, action: 'assigned', created_at: 10.minutes.ago)

      groups = described_class.aggregate([old_ticket_activity, fresh_other_activity])
      expect(groups.first.trackable).to eq(other_ticket)
      expect(groups.last.trackable).to eq(ticket)
    end

    it 'reports secondary_count = 0 when only one activity exists for the group' do
      activity = create(:activity, trackable: ticket, actor: actor, action: 'created')
      group = described_class.aggregate([activity]).first
      expect(group.secondary_count).to eq(0)
    end
  end
end
