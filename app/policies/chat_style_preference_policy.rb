# frozen_string_literal: true

# A chat style preference is always the requesting user's OWN row in the current
# org. The controller resolves it strictly from current_user + current_organisation
# (never from params), so there is no cross-user access surface to gate per-record.
# Membership is already enforced by Organisations::BaseController#set_current_membership.
# This policy only satisfies verify_authorized: any logged-in member may set
# their own level. (ApplicationPolicy#initialize already raises for a nil user.)
class ChatStylePreferencePolicy < ApplicationPolicy
  def update?
    user.present?
  end
end
