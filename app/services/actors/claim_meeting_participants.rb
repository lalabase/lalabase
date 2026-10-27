# frozen_string_literal: true

module Actors
  # Tier 1 actor (BaseActor#call template): link a batch of EXTERNAL meeting
  # participations to an org member (Nachtrag: Teilnehmer-Claim). It sets user_id on
  # every external row (user_id and person_id nil, MeetingParticipant.external_in_projects) whose normalized_name matches the target, but
  # only within meetings the ACTING user may WRITE (:meetings), and skipping meetings
  # that already link this member — otherwise the partial unique index
  # (meeting_id, user_id) would raise. display_name stays a snapshot (only user_id
  # changes), consistent with the model's snapshot principle.
  #
  # The read side (which names match which members) is Meetings::ParticipantClaimMatches;
  # this actor re-derives the writable scope and re-checks the target itself, so a
  # tampered POST cannot link outside the caller's authority.
  class ClaimMeetingParticipants < BaseActor
    def initialize(user:, normalized_name:, current_user:)
      super()
      @user = user
      # Idempotent: normalizing an already-normalized key returns it unchanged, so a
      # caller may pass either the stored key or a raw name.
      @normalized_name = MeetingParticipant.normalize_name(normalized_name)
      @current_user = current_user
      @organisation = ActsAsTenant.current_tenant
      @linked_count = 0
    end

    # Number of participations linked — read by the controller for the flash. The
    # actor uses .new(...).call so this reader is available after #call.
    attr_reader :linked_count

    # No single primary record (the actor links a SET of rows); return the target
    # member so Result#resource / logging have something meaningful.
    def record
      @user
    end

    def perform
      guard_target_is_active_member!
      return if @normalized_name.blank? || writable_project_ids.empty?

      ids = linkable_participant_ids
      return if ids.empty?

      # update_all on purpose: one UPDATE, no per-row uniqueness SELECT (an N+1 under
      # Prosopite), and it leaves display_name/normalized_name as the snapshot they
      # must stay (only user_id changes). The skip in #linkable_participant_ids covers
      # the single-threaded partial (meeting_id, user_id) index; under concurrency a
      # parallel claim or SaveMeeting can still slip a row in between the skip-check
      # and this UPDATE — the RecordNotUnique rescue below turns that race into a
      # clean, retryable failure.
      # intentional bulk link; see comment above
      # Read again in the write: the link dialog may have given one of these rows
      # a contact (person_id) in between, and a row keeps one key.
      @linked_count = MeetingParticipant.where(id: ids, user_id: nil, person_id: nil)
                                        .update_all(user_id: @user.id, updated_at: Time.current)
    rescue ActiveRecord::RecordNotUnique
      # Another write linked this member to a target meeting between the skip-check
      # and the UPDATE. Surface a clean domain failure (BaseActor rolls the txn back)
      # instead of a raw 500; the user retries and the next pass's skip excludes it.
      raise ActorError, I18n.t('services.actors.claim_meeting_participants.conflict')
    end

    private

    # Tamper guard (mirrors SaveMeeting#build_desired_participants): the target must
    # be an ACTIVE member of the acting org. A forged / foreign / inactive user id
    # fails cleanly instead of linking. && short-circuits, so #active? is only asked
    # once @user is known present.
    def guard_target_is_active_member!
      valid = @organisation.present? && @user.present? && @user.active? &&
              @organisation.memberships.exists?(user_id: @user.id, active: true)
      raise ActorError, I18n.t('services.actors.not_member') unless valid
    end

    # Reach of the claim: projects where the ACTING user may write meetings (the
    # SAME single source the matcher and the policy use).
    def writable_project_ids
      @writable_project_ids ||= AccessCheck::ProjectAccessService.writable_meetings_project_ids(@current_user, @organisation)
    end

    # External rows with the target name in writable meetings, MINUS meetings that
    # already link this member — the skip that keeps the partial unique index
    # (meeting_id, user_id) from raising in the common single-threaded case.
    def linkable_participant_ids
      candidates = MeetingParticipant.external_in_projects(writable_project_ids)
                                     .where(normalized_name: @normalized_name)
                                     .pluck(:id, :meeting_id)
      return [] if candidates.empty?

      already_linked = MeetingParticipant.where(user_id: @user.id, meeting_id: candidates.map(&:last))
                                         .pluck(:meeting_id).to_set
      candidates.reject { |(_id, meeting_id)| already_linked.include?(meeting_id) }.map(&:first)
    end
  end
end
