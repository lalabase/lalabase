# frozen_string_literal: true

# spec/services/actors/assign_time_sessions_to_group_spec.rb
#
# What: unit spec for the AssignTimeSessionsToGroup actor (existing group).
# Why: pins that the actor exposes the pre-write counters via #outcome, that
#   #record is the group, and that a billed-guard violation becomes a coded
#   failure Result with the whole write rolled back.

require 'rails_helper'

RSpec.describe Actors::AssignTimeSessionsToGroup, type: :service do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:group) { create(:time_session_group, organisation: organisation, creator: user) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
  end

  def session(**attrs)
    create(:time_session, { organisation: organisation, project: project, creator: user, time_session_group: nil }.merge(attrs))
  end

  def scope_for(*sessions)
    TimeSession.where(id: sessions.map(&:id))
  end

  describe 'success' do
    it 'assigns the sessions, exposes the counters, and returns the group as #record' do
      sessions = Array.new(2) { session }
      actor = described_class.new(sessions: scope_for(*sessions), group: group, current_user: user)

      result = actor.call

      expect(result).to be_success
      expect(result.resource).to eq(group)
      expect(actor.outcome.assigned_count).to eq(2)
      expect(TimeSession.where(id: sessions.map(&:id)).pluck(:time_session_group_id).uniq).to eq([group.id])
    end
  end

  describe 'billed guard' do
    it 'returns a :group_billed failure and rolls the write back' do
      billed_group = create(:time_session_group, :billed, organisation: organisation, creator: user)
      s = session
      actor = described_class.new(sessions: scope_for(s), group: billed_group, current_user: user)

      result = actor.call

      expect(result).not_to be_success
      expect(result.code).to eq(:group_billed)
      expect(s.reload.time_session_group_id).to be_nil
    end
  end
end
