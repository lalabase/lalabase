# frozen_string_literal: true

# spec/services/actors/create_group_and_assign_time_sessions_spec.rb
#
# What: unit spec for the CreateGroupAndAssignTimeSessions actor.
# Why: pins the ONE-transaction contract (plan §9.8-2) — a billed session in the
#   assign step must leave NO orphaned group behind — plus the coded failures the
#   call sites map (blank/invalid name -> :validation_failed; billed guard).

require 'rails_helper'

RSpec.describe Actors::CreateGroupAndAssignTimeSessions, type: :service do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

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

  def build(sessions:, name: 'Juni 2026')
    described_class.new(sessions: sessions, name: name, organisation: organisation, current_user: user)
  end

  describe 'success' do
    it 'creates the (unbilled) group, assigns the sessions and exposes counters' do
      sessions = Array.new(2) { session }
      actor = build(sessions: scope_for(*sessions))

      result = actor.call

      expect(result).to be_success
      group = result.resource
      expect(group).to be_persisted
      expect(group.billed).to be(false)
      expect(group.creator).to eq(user)
      expect(actor.outcome.assigned_count).to eq(2)
      expect(TimeSession.where(id: sessions.map(&:id)).pluck(:time_session_group_id).uniq).to eq([group.id])
    end
  end

  describe 'atomicity (no orphaned group)' do
    it 'rolls the fresh group back when a scoped session is already billed' do
      billed_session = session(billed: true)
      clean = session
      before_count = TimeSessionGroup.count

      result = build(sessions: scope_for(billed_session, clean)).call

      expect(result).not_to be_success
      expect(result.code).to eq(:sessions_billed)
      expect(TimeSessionGroup.count).to eq(before_count)
      expect(clean.reload.time_session_group_id).to be_nil
    end
  end

  describe 'invalid name' do
    it 'returns a :validation_failed failure and creates no group' do
      before_count = TimeSessionGroup.count

      result = build(sessions: scope_for(session), name: '').call

      expect(result).not_to be_success
      expect(result.code).to eq(:validation_failed)
      expect(TimeSessionGroup.count).to eq(before_count)
    end
  end
end
