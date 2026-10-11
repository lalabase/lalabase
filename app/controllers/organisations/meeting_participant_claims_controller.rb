# frozen_string_literal: true

# Org-level participant-claim actions (Nachtrag: Teilnehmer-Claim). A claim links
# external participations to an org member across EVERY project the acting user may
# write meetings in, so this is a slim Organisations::BaseController — deliberately
# NOT the project-nested MeetingsController (bound to @project) and NOT
# ProjectController, whose controller-name-derived area gate would resolve to a
# non-existent :meeting_participant_claim area and deny everyone (the Slice-3 trap).
#
# Authorization is the headless MeetingParticipantClaimPolicy (may-write-meetings-
# anywhere); a meetings-reader is redirected (Pundit → user_not_authorized), the
# app convention rather than a literal 403. The load-bearing per-project checks live
# in the actor and the match PORO, not here.
module Organisations
  class MeetingParticipantClaimsController < Organisations::BaseController
    # link: verknüpfen — a batch, association-syncing write → the actor.
    def link
      authorize :meeting_participant_claim, :link?

      target = org_member(params[:user_id])
      return claim_result(:alert, 'flash.meeting_participant_claims.target_missing') if target.nil?

      actor = Actors::ClaimMeetingParticipants.new(
        user: target, normalized_name: params[:normalized_name].to_s, current_user: current_user
      )
      result = actor.call

      if !result.success?
        claim_result(:alert, 'flash.meeting_participant_claims.link_failed')
      elsif actor.linked_count.zero?
        # Nothing new to link (all already linked, or concurrently claimed): a green
        # "0 linked" would read as success — say plainly that nothing changed.
        claim_result(:notice, 'flash.meeting_participant_claims.nothing_to_link', name: target.display_name)
      else
        claim_result(:notice, 'flash.meeting_participant_claims.linked',
                     count: actor.linked_count, name: target.display_name)
      end
    end

    # reject: nicht verknüpfen — a single create → trivial, stays in the controller
    # (seam rule). find_or_create_by keeps a double-click idempotent.
    def reject
      authorize :meeting_participant_claim, :reject?

      target = org_member(params[:user_id])
      normalized = MeetingParticipant.normalize_name(params[:normalized_name])
      return claim_result(:alert, 'flash.meeting_participant_claims.target_missing') if target.nil? || normalized.blank?

      MeetingParticipantClaimRejection.find_or_create_by!(user: target, normalized_name: normalized)
      claim_result(:notice, 'flash.meeting_participant_claims.rejected', name: target.display_name)
    rescue ActiveRecord::RecordNotUnique
      # Race backstop (two rejects at once): the pair is recorded, treat as done.
      claim_result(:notice, 'flash.meeting_participant_claims.rejected', name: target.display_name)
    end

    private

    # Only an actual member of this org is a valid target — a forged / foreign id is
    # simply not found. (The actor additionally requires an ACTIVE membership.)
    def org_member(user_id)
      return nil if user_id.blank?

      @current_organisation.users.find_by(id: user_id)
    end

    # Every branch answers the same way: flash + redirect back to the index the user
    # came from, whose recomputed hint then reflects the change. :see_other so Turbo
    # treats the POST response as a Visit.
    def claim_result(flash_type, flash_key, **opts)
      redirect_back fallback_location: organisation_meetings_path(@current_organisation),
                    status: :see_other, flash_type => t(flash_key, **opts)
    end
  end
end
