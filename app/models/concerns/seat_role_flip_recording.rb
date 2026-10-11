# frozen_string_literal: true

# Writes seat events when a Role#billable flip moves every seat of that role at
# once (P1, doc/abrechnungsmodell_plan.md §9).
#
# WHY THIS EXISTS SEPARATELY FROM SeatEventRecording. That concern hangs on
# Membership callbacks and describes the seat of ONE membership. A role flip
# saves no membership at all, so those callbacks structurally cannot see it --
# and the counted state of every membership of the role changes in the same
# instant. Before this, the stream kept reporting seats that Subscriptions::
# SeatCounter had already stopped counting, i.e. it drifted towards a TOO HIGH
# invoice, which is the direction that reaches a customer.
#
# Not reachable through the UI today: Organisations::RolesController deliberately
# refuses to permit :billable (roles_controller.rb:112, RolePolicy#update_billable?
# is prepared but unwired). The guest-role screen that will permit it is named in
# doc/billing_agentur_konto_plan.md as a precondition for the first paying
# customer, so the hole opens exactly when money starts moving. The recorder is
# hardened first, on purpose, rather than as part of that screen.
#
# TWO CLASSES map to the `roles` table -- ::Role and Admin::Role -- and they
# never share a save cycle, so this has to be included in BOTH. That is the exact
# mistake T16 made with SeatEventRecording (incident 3 in
# spec/models/admin_twin_concern_parity_guard_spec.rb), and the same guard now
# holds this concern to the same rule.
#
# NOT COVERED, deliberately, because no callback can see it either: DELETING a
# role. And the two twins do not even fail the same way, which is worth naming
# precisely in a file whose whole point is that they behave alike:
#
#   ::Role       has_many :memberships, dependent: :nullify  (role.rb:32)
#                -> update_all, no callback, NO event at all
#   Admin::Role  has_many :memberships, dependent: :destroy  (admin/role.rb:55)
#                -> destroy runs callbacks, so SeatEventRecording writes `removed`
#
# The same operator action therefore produces two different streams depending on
# which half of the backend it came from. Unreachable today (the roles screen
# refuses to delete a role that still has memberships), and out of scope here --
# but recorded, because "the blind spot is symmetrical" would be wrong.
module SeatRoleFlipRecording
  extend ActiveSupport::Concern

  included do
    # Distinct method names, like every other commit callback around here: Rails
    # deduplicates commit callbacks BY METHOD NAME, and Membership already lost
    # one to exactly that (see Membership#assign_org_recognition_colors).
    after_save :remember_seat_billable_before_transaction
    after_commit :record_seat_role_flip, on: :update
    after_rollback :forget_seat_billable_before_transaction
  end

  private

  # WHY THE VALUE IS REMEMBERED instead of read from saved_change_to_billable? in
  # the commit callback: after_commit fires ONCE per record per transaction, and
  # saved_change_to_* only knows the LAST save. A flip followed by any second
  # save of the same role -- a rename in the same form submit, a sync that
  # touches it -- would report "billable did not change" and write nothing.
  #
  # Measured on the version without this: two saves in one transaction wrote 0
  # rows while SeatCounter had already dropped to 0. That is the same drift
  # towards a too high invoice this concern exists to prevent, one layer up.
  #
  # Not reachable through today's single write path (Actors::SaveRole saves the
  # role exactly once, and Permission does not touch: true), which is precisely
  # why it had to be fixed before the guest-role screen adds a second save.
  def remember_seat_billable_before_transaction
    # A create moves no seat: a brand new role has no memberships yet. Skipping
    # it also keeps the variable from surviving into the next transaction, where
    # it would compare against a stale starting point.
    return if previously_new_record?
    return unless saved_change_to_billable?
    return if instance_variable_defined?(:@seat_billable_before_transaction)

    @seat_billable_before_transaction = saved_change_to_billable.first
  end

  def forget_seat_billable_before_transaction
    return unless instance_variable_defined?(:@seat_billable_before_transaction)

    remove_instance_variable(:@seat_billable_before_transaction)
  end

  def record_seat_role_flip
    return unless instance_variable_defined?(:@seat_billable_before_transaction)

    before = @seat_billable_before_transaction
    forget_seat_billable_before_transaction
    # Flipped there and back inside one transaction: no net move, so no event.
    # The stream records what the committed state IS, not how it got there.
    return if before == billable?

    event = if billable?
              Subscriptions::Constants::SEAT_EVENT_ACTIVATED
            else
              Subscriptions::Constants::SEAT_EVENT_DEACTIVATED
            end

    # ONE moment for the whole flip, not one per row. A7 requires the peak
    # calculation to be independent of the insertion order of simultaneous
    # events; a timestamp per row would smear one decision across however long
    # the write loop took and make that order visible.
    occurred_at = Time.current

    flipped_memberships.each { |membership| write_flip_event(membership, event, occurred_at) }
  end

  # Only memberships that are ACTIVE: an inactive one counted before the flip and
  # counts after it, so it moves no seat and an event would claim a transition
  # that did not happen. Same definition of a seat as Subscriptions::SeatCounter
  # (`active: true AND roles.billable: true`).
  #
  # The organisation comes preloaded and is read PER MEMBERSHIP rather than from
  # the role: nothing in the schema forces a membership to sit in the same
  # organisation as its role (`add_foreign_key "memberships", "roles"` constrains
  # existence, not the pair), and SeatCounter counts a membership under ITS OWN
  # organisation. Anchoring the event to the role's organisation instead would
  # write a row for a pair that does not exist and leave the real one untouched,
  # which is worse than writing nothing.
  def flipped_memberships
    memberships.active.includes(organisation: :account)
  end

  def write_flip_event(membership, event, occurred_at)
    organisation = membership.organisation

    SeatEvent.write_event(
      account: organisation&.account,
      organisation_id: membership.organisation_id,
      organisation_name: organisation&.name,
      user_id: membership.user_id,
      role_id: id,
      event: event,
      # counted and billable agree here by construction: the membership is
      # active, so after the flip the seat counts exactly when the role is
      # billable. They are still passed separately because the column pair means
      # two different things everywhere else in this table.
      counted: billable?,
      billable: billable?,
      occurred_at: occurred_at,
      source: "role=#{id} membership=#{membership.id}"
    )
  end
end
