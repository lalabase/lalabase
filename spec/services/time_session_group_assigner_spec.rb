# frozen_string_literal: true

# spec/services/time_session_group_assigner_spec.rb
#
# What: unit spec for the shared assign PORO behind both AssignTimeSessionsToGroup
#   and CreateGroupAndAssignTimeSessions.
# Why: pins the two-sided billed guard (the P1 invoice-integrity contract), the
#   pre-write counters the call sites turn into flashes, and the uniform
#   updated_at touch — all in one place so the two actors cannot drift.

require 'rails_helper'

RSpec.describe TimeSessionGroupAssigner, type: :service do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:group) { create(:time_session_group, organisation: organisation, creator: user) }

  before do
    # The PORO raises Actors::ActorError, which is defined as a load-time side
    # effect inside base_actor.rb (no autoloadable actor_error.rb). This spec
    # drives the PORO directly and references no actor class, so force BaseActor
    # to load — otherwise the raise_error(Actors::ActorError) matchers below hit
    # an uninitialized constant in an isolated run (eager_load off locally).
    Actors::BaseActor.name
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
  end

  def session(**attrs)
    create(:time_session, { organisation: organisation, project: project, creator: user }.merge(attrs))
  end

  # The bulk call site's scope shape: an explicit id set.
  def scope_for(*sessions)
    TimeSession.where(id: sessions.map(&:id))
  end

  describe 'happy path' do
    it 'assigns the sessions to the group and touches updated_at' do
      sessions = Array.new(3) { session(time_session_group: nil) }
      ids = sessions.map(&:id)
      TimeSession.where(id: ids).update_all(updated_at: 1.hour.ago)

      TimeSessionGroupAssigner.call(sessions: scope_for(*sessions), group: group)

      reloaded = TimeSession.where(id: ids)
      expect(reloaded.pluck(:time_session_group_id).uniq).to eq([group.id])
      expect(reloaded.where(updated_at: 1.minute.ago..).count).to eq(3)
    end

    it 'returns the pre-write counters' do
      other_group = create(:time_session_group, organisation: organisation, creator: user)
      other_project = create(:project, organisation: organisation, name: 'Zweitprojekt')
      s1 = session(time_session_group: nil)
      s2 = session(time_session_group: other_group) # already assigned
      s3 = session(project: other_project, time_session_group: nil) # second project

      outcome = TimeSessionGroupAssigner.call(sessions: scope_for(s1, s2, s3), group: group)

      expect(outcome.assigned_count).to eq(3)
      expect(outcome.already_assigned_count).to eq(1)
      expect(outcome.project_names).to match_array([project.name, 'Zweitprojekt'])
    end
  end

  describe 'billed target group guard' do
    it 'raises :group_billed and writes nothing' do
      billed_group = create(:time_session_group, :billed, organisation: organisation, creator: user)
      s = session(time_session_group: nil)

      expect { TimeSessionGroupAssigner.call(sessions: scope_for(s), group: billed_group) }
        .to raise_error(Actors::ActorError) { |e| expect(e.code).to eq(:group_billed) }

      expect(s.reload.time_session_group_id).to be_nil
    end

    # Race defense (plan §9.8-1): the guard must re-read billed from the DB at
    # write time. The in-memory group here is deliberately STALE — loaded
    # unbilled, then invoiced concurrently (update_all bypasses the object).
    # Without the #reload the stale false would let the assignment through.
    it 'rejects a group that was invoiced after it was loaded (stale in-memory object)' do
      stale_group = create(:time_session_group, organisation: organisation, creator: user)
      TimeSessionGroup.where(id: stale_group.id).update_all(billed: true)
      s = session(time_session_group: nil)

      expect { TimeSessionGroupAssigner.call(sessions: scope_for(s), group: stale_group) }
        .to raise_error(Actors::ActorError) { |e| expect(e.code).to eq(:group_billed) }

      expect(s.reload.time_session_group_id).to be_nil
    end
  end

  describe 'billed sessions guard (both sides)' do
    it 'raises :sessions_billed when a session is itself billed' do
      billed_session = session(billed: true)
      clean = session(time_session_group: nil)

      expect { TimeSessionGroupAssigner.call(sessions: scope_for(billed_session, clean), group: group) }
        .to raise_error(Actors::ActorError) { |e| expect(e.code).to eq(:sessions_billed) }

      expect(clean.reload.time_session_group_id).to be_nil
    end

    it 'raises :sessions_billed when a session sits in a billed source group' do
      billed_source = create(:time_session_group, :billed, organisation: organisation, creator: user)
      from_billed = session(time_session_group: billed_source)

      expect { TimeSessionGroupAssigner.call(sessions: scope_for(from_billed), group: group) }
        .to raise_error(Actors::ActorError) { |e| expect(e.code).to eq(:sessions_billed) }

      expect(from_billed.reload.time_session_group_id).to eq(billed_source.id)
    end
  end

  describe 'edge cases' do
    it 'handles an empty scope without error and reports zero counters' do
      outcome = TimeSessionGroupAssigner.call(sessions: TimeSession.none, group: group)

      expect(outcome.assigned_count).to eq(0)
      expect(outcome.already_assigned_count).to eq(0)
      expect(outcome.project_names).to eq([])
    end

    it 'rejects a billed target group even when the scope is empty (target guard runs first)' do
      billed_group = create(:time_session_group, :billed, organisation: organisation, creator: user)

      expect { TimeSessionGroupAssigner.call(sessions: TimeSession.none, group: billed_group) }
        .to raise_error(Actors::ActorError) { |e| expect(e.code).to eq(:group_billed) }
    end
  end
end
