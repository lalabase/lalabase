# frozen_string_literal: true

# Shared "assign time sessions to a billing group" logic used by both
# Actors::AssignTimeSessionsToGroup and Actors::CreateGroupAndAssignTimeSessions.
# It runs the two-sided billed guard, gathers the flash counters BEFORE the write,
# and performs the set-based update_all. Kept as a PORO (pattern #107,
# TicketAssignmentSync) so both actors share ONE write path WITHOUT composing
# actors — a nested actor's failure Result would not roll back the outer
# transaction (plan §9.8-2).
#
# Runs inside the caller's actor transaction (BaseActor#perform wraps it), so the
# billed re-reads reflect committed state at write time — the defence against a
# racing mark_as_billed (plan §9.8-1). A guard violation raises Actors::ActorError,
# which BaseActor#with_error_mapping turns into a coded failure Result
# (:group_billed / :sessions_billed).
class TimeSessionGroupAssigner
  ERROR_SCOPE = 'services.time_session_group_assigner'

  # Pre-write counters handed back to the actor for the call sites' flashes.
  Outcome = Struct.new(:assigned_count, :already_assigned_count, :project_names, keyword_init: true)

  def self.call(sessions:, group:)
    new(sessions: sessions, group: group).call
  end

  def initialize(sessions:, group:)
    @sessions = sessions
    @group = group
  end

  def call
    guard_target_group_unbilled!
    guard_no_billed_sessions!
    outcome = gather_counters
    assign!
    outcome
  end

  private

  # Re-read the target group's billed flag inside the transaction (#reload
  # bypasses the default scope, so it holds even without a current tenant) to
  # reject a group that was invoiced concurrently.
  def guard_target_group_unbilled!
    return unless @group.reload.billed?

    raise Actors::ActorError.new(I18n.t("#{ERROR_SCOPE}.group_billed"), code: :group_billed)
  end

  # All-or-nothing: reject the whole batch if any session is already billed itself
  # OR still hangs in a billed source group (else invoiced sessions could be pulled
  # out of their billed group via update_all).
  def guard_no_billed_sessions!
    return unless billed_session_in_scope?

    raise Actors::ActorError.new(I18n.t("#{ERROR_SCOPE}.sessions_billed"), code: :sessions_billed)
  end

  def billed_session_in_scope?
    @sessions.where(billed: true).exists? ||
      @sessions.joins(:time_session_group).where(time_session_groups: { billed: true }).exists?
  end

  def gather_counters
    Outcome.new(
      assigned_count: @sessions.count,
      already_assigned_count: @sessions.where.not(time_session_group_id: nil).count,
      project_names: @sessions.joins(:project).distinct.pluck('projects.name')
    )
  end

  def assign!
    # Set-based write by design (plan §9.8-6): keeps the deliberate validation and
    # touch bypass of today's behaviour; updated_at is touched uniformly on all
    # call sites.
    @sessions.update_all(time_session_group_id: @group.id, updated_at: Time.current)
  end
end
