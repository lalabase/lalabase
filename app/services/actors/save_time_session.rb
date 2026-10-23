# frozen_string_literal: true

# app/services/actors/save_time_session.rb
#
# Tier-1 actor: saves a TimeSession (create + update) including its billing-
# group transition in ONE transaction (before: service transaction + separate
# update = two commits, so a validation failure kept the group change).
#
# Group semantics (plan doc/actors_t3_save_time_session_plan.md, [P1] twin of
# UpdateTimeSessionGroupBilling's :billed key): group_change is a
# { requested:, group: } pair. requested: false (key absent in the form) means
# NO group change; requested: true with group: nil (blank value) is an explicit
# removal; with a group it is an assignment. The group is resolved by the
# CALLER (tenant-scoped find, so a foreign id stays a 404 — T1 pattern); the
# actor re-checks its billed state inside the transaction.
#
# Billed guards (D3, race parity §9.8-1, re-read inside the transaction):
# assigning to a billed group -> :group_billed; changing the group of a billed
# session -> :session_billed. No silent billing takeover any more (before:
# add_time_session_to_group copied group.billed? onto the session).
module Actors
  class SaveTimeSession < BaseActor
    ERROR_SCOPE = 'services.save_time_session'

    def initialize(time_session:, attributes:, group_change:, current_user:)
      super()
      @time_session = time_session
      @attributes = attributes.to_h # decouple from ActionController::Parameters
      @group_change = group_change
      @current_user = current_user
    end

    def record
      @time_session
    end

    def perform
      refresh_persisted_state
      guard_meeting_project!
      guard_group_transition!
      @time_session.assign_attributes(@attributes)
      apply_group_transition
      @time_session.save!
    end

    private

    # Race defense (§9.8-1): re-read the persisted state inside the transaction
    # WITHOUT losing the controller's in-memory subject resolution
    # (ensure_valid_subject already set ticket/meeting on the instance):
    # snapshot the pending changes, reload, re-apply. A concurrently billed
    # session then fails prevent_changes_when_billed instead of slipping
    # through with a stale billed? == false.
    def refresh_persisted_state
      return unless @time_session.persisted?

      pending = @time_session.changes.transform_values(&:last)
      @time_session.reload
      @time_session.assign_attributes(pending)
    end

    # A booking on a meeting takes the meeting's row lock, the one
    # Actors::MoveMeeting holds while it moves the meeting and its bookings. A
    # move that committed meanwhile has taken the meeting into another project;
    # the booking would land in the old one, so it is refused.
    def guard_meeting_project!
      meeting = @time_session.meeting
      return unless meeting

      meeting.lock!
      return if meeting.project_id == @time_session.project_id

      raise ActorError.new(I18n.t("#{ERROR_SCOPE}.meeting_moved"), code: :meeting_moved)
    end

    def target_group
      @group_change[:group]
    end

    # A submitted value equal to the current group is NOT a transition (parity
    # with the previous old != new controller check and T2's no-transition path).
    def group_transition?
      @group_change[:requested] && target_group&.id != @time_session.time_session_group_id
    end

    # #reload on the group bypasses the default scope (works without a current
    # tenant) and rejects a group that was invoiced concurrently.
    def guard_group_transition!
      return unless group_transition?

      raise ActorError.new(I18n.t("#{ERROR_SCOPE}.group_billed"), code: :group_billed) if target_group&.reload&.billed?
      raise ActorError.new(I18n.t("#{ERROR_SCOPE}.session_billed"), code: :session_billed) if @time_session.billed?
    end

    # Assignment leaves billed untouched — the guard guarantees an unbilled
    # group AND an unbilled session. Removal keeps the previous service
    # semantics (billed: false).
    def apply_group_transition
      return unless group_transition?

      @time_session.time_session_group = target_group
      @time_session.billed = false if target_group.nil?
    end
  end
end
