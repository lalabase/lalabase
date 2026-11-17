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
#
# The merges of the people above the organisations follow the row
# (PersonGroupEntry.follow_to_row): an entry that named the member by account
# names the row from now on, for every owner. This is the one moment such an
# entry would lose its target while a row exists; with the link gone, the
# account no longer leads to the row. So the entries are rewritten FIRST, while
# the row still carries the account, by statements that find the row
# themselves (no read of its own per membership). Those tables carry no
# tenant; the row is named inside the block below, the one place of this
# callback where the tenant is lifted.
module PersonLinkRelease
  extend ActiveSupport::Concern

  included do
    after_destroy :release_person_link
  end

  private

  def release_person_link
    ActsAsTenant.without_tenant do
      rows = Person.where(organisation_id: organisation_id, user_id: user_id)
      PersonGroupEntry.follow_to_row(organisation_id: organisation_id, user_id: user_id, rows: rows)
      rows.update_all(user_id: nil, updated_at: Time.current)
    end
  end
end
