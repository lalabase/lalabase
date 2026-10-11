# frozen_string_literal: true

# Headless policy for the org-level participant-claim actions (Nachtrag). There is
# no single record — a claim spans projects — so authorization is simply "may the
# user WRITE meetings anywhere in this org". The per-project reach is re-derived and
# re-checked in Meetings::ParticipantClaimMatches (read) and
# Actors::ClaimMeetingParticipants (write); this gate keeps a meetings-reader out of
# the link/reject endpoints entirely (denial → redirect via user_not_authorized).
class MeetingParticipantClaimPolicy < ApplicationPolicy
  def link?
    return false unless organisation

    AccessCheck::ProjectAccessService.writable_meetings_project_ids(user, organisation).any?
  end

  alias reject? link?
end
