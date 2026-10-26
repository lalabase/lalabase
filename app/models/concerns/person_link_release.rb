# frozen_string_literal: true

# Leaving an organisation keeps the person row of that organisation and drops
# only its link to the account: the row still names the person (its own name
# column), the member half of the directory just stops showing them as a
# member. Deactivation keeps the link, it is reversible.
#
# A concern because two classes write the memberships table without sharing a
# save cycle: ::Membership (RemoveMembershipService, the members page) and
# Admin::Membership (the operator's removal, Admin::User erasure). Both include
# it; spec/models/admin_twin_concern_parity_guard_spec.rb keeps it that way.
#
# update_all, without tenant: the person's own validations and tracking have
# nothing to say about a link the membership took with it, and the callback may
# run with any tenant set (or none, in the admin backend).
module PersonLinkRelease
  extend ActiveSupport::Concern

  included do
    after_destroy :release_person_link
  end

  private

  def release_person_link
    ActsAsTenant.without_tenant do
      Person.where(organisation_id: organisation_id, user_id: user_id).update_all(user_id: nil, updated_at: Time.current)
    end
  end
end
