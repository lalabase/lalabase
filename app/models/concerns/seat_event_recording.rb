# frozen_string_literal: true

# Writes the seat history (T16, doc/billing_agentur_konto_plan.md §17.2).
#
# ONE write seam per CLASS, not one per caller. §17.1 lists four paths that end
# a membership (RemoveMembershipService, Admin::UsersController, Organisation
# cascade, User::DeletionLifecycle#soft_delete_and_anonymize!). Making each of
# them remember to log is exactly the "same rule enforced by hand for the third
# time" signal from CLAUDE.md, so the rule lives here instead.
#
# TWO classes map to the `memberships` table -- ::Membership and
# Admin::Membership -- and they never share a save cycle. This concern therefore
# has to be included in BOTH, or the whole admin half writes nothing; the first
# version of T16 shipped only the tenant-side include and silently lost every
# backend account deletion. The guard spec asserts the property (every model on
# this table includes this concern) instead of listing the two known classes.
#
# All four paths use destroy!/destroy_all, which run callbacks. `delete_all` and
# `update_all` would not -- verified 2026-08-05 that none exists on memberships
# in app/ or lib/, and the guard spec keeps checking. ONE known blind spot
# remains, pinned by that spec: `Role has_many :memberships, dependent: :nullify`
# (role.rb:32) issues an update_all at runtime, which strips role_id without a
# callback and thus without a `deactivated` event. Unreachable today because
# Organisations::RolesController refuses to delete a role that still has
# memberships, and the organisation cascade destroys memberships before roles --
# but that is an ordering accident, not a construction.
#
# WHAT COUNTS AS A SEAT is defined by Subscriptions::SeatCounter:
# `active: true AND roles.billable: true`. This recorder deliberately triggers
# on that COMBINED state and not, as §17.2 worded it, on the `active` toggle
# alone -- a membership moved to a non-billable role loses its seat without
# `active` ever changing, and a log that missed it would disagree with the
# counter it exists to explain.
#
# WHAT THIS RECORDER CANNOT SEE is the other half of that same combined state:
# the ROLE flipping its billable flag. No membership is saved then, so no
# callback here fires, while the counted state of every membership of that role
# changes at once. That half lives in SeatRoleFlipRecording (P1,
# doc/abrechnungsmodell_plan.md §9). Both write through SeatEvent.write_event.
#
# THREE CALLBACK SUBTLETIES, each one load-bearing:
#
# 1. Distinct method names. Rails deduplicates commit callbacks BY METHOD NAME
#    -- see the comment on Membership#assign_org_recognition_colors, which lost
#    a callback to exactly that. Nothing here may reuse an existing name.
# 2. after_commit, not after_create, for the create path. Membership's own
#    `assign_default_role` is an after_create that assigns role_id in a SECOND
#    write. An event written during after_create would freeze `billable` from a
#    role that is not assigned yet -- and would freeze it as false.
# 3. The removal payload is captured in before_destroy, not read in
#    after_commit. When an Organisation is destroyed it cascades into its
#    memberships; by commit time the organisations row is gone, so
#    `organisation.account_id` and `organisation.name` -- the two values that
#    make the event attributable at all -- can no longer be resolved. Capturing
#    early and writing late keeps both properties: real associations, and no
#    event for a transaction that rolled back.
module SeatEventRecording
  extend ActiveSupport::Concern

  included do
    after_save :remember_seat_state_before_transaction
    after_commit :record_seat_transition, on: %i[create update]
    before_destroy :capture_seat_removal_snapshot
    after_commit :record_seat_removal, on: :destroy
    after_rollback :forget_seat_state_before_transaction
  end

  private

  # Does this membership count as a seat right now?
  def seat_counted?
    active? && seat_role_billable?(role_id)
  end

  # The raw state as this TRANSACTION found it, captured at its first save.
  #
  # Not attribute_before_last_save in the commit callback: after_commit fires
  # once per record per transaction while that helper only knows the LAST save,
  # so a seat move followed by any second save of the same membership would read
  # as "nothing changed". Measured on the version without this: deactivating and
  # then saving again in one transaction wrote 0 rows while SeatCounter had
  # already dropped to 0. Membership#assign_default_role is itself a second save
  # on the create path, which is how close this always was.
  #
  # Raw attributes rather than the resolved seat state, so that no Role lookup
  # happens inside the save -- the resolution stays in the commit callback where
  # the memo is reset.
  def remember_seat_state_before_transaction
    return if instance_variable_defined?(:@seat_state_before_transaction)

    @seat_state_before_transaction = [attribute_before_last_save('active'),
                                      attribute_before_last_save('role_id')]
  end

  def forget_seat_state_before_transaction
    return unless instance_variable_defined?(:@seat_state_before_transaction)

    remove_instance_variable(:@seat_state_before_transaction)
  end

  # ... and did it count when the transaction started? On create both attributes
  # come back nil, which correctly reads as "was not a seat".
  def seat_counted_before_transaction?
    active_before, role_id_before = @seat_state_before_transaction
    return false unless active_before

    seat_role_billable?(role_id_before)
  end

  # Memoised per role_id, but ONLY for the duration of one callback (see the
  # reset in the entry points): every event asks twice -- once to decide whether
  # the seat moved, once to freeze the flag -- and a bulk membership import would
  # otherwise pay for that second SELECT on every row. Holding the memo across
  # saves would go stale the moment a role flips its flag between two saves of
  # the same object.
  def seat_role_billable?(identifier)
    return false if identifier.blank?
    return false if organisation.nil?

    @seat_role_billable ||= {}
    return @seat_role_billable[identifier] if @seat_role_billable.key?(identifier)

    @seat_role_billable[identifier] = lookup_seat_role_billable(identifier) || false
  end

  # EACH TWIN ASKS ITS OWN ROLE CLASS. ::Membership resolves to ::Role, which is
  # tenant-scoped (role.rb:25) and therefore needs the membership's organisation
  # as the current tenant -- the same with_tenant discipline
  # Subscriptions::SeatCounter uses (D5), rather than a without_tenant query in a
  # money-relevant path. Admin::Membership resolves to Admin::Role, which carries
  # no acts_as_tenant on purpose (that is the entire reason the shadow models
  # exist), so wrapping it in with_tenant is not just pointless, it is wrong: it
  # asks for a tenant on a class that has none.
  #
  # The hardcoded ::Role plus with_tenant left 11 examples red in
  # spec/controllers/admin/users_controller_spec.rb with NoTenantSet. Measured
  # afterwards, and worth stating precisely: the ADMIN PATH ITSELF WORKS -- a
  # real request creating and deleting a user through Admin::UsersController
  # succeeds (302, deleted_at set). Only the controller-spec environment loses
  # the tenant inside the after_commit, so this was a red suite and never a
  # broken screen. Asking the association for its class is correct either way,
  # and it makes the twin behave like a twin instead of borrowing the other
  # half's class.
  def lookup_seat_role_billable(identifier)
    klass = self.class.reflect_on_association(:role).klass
    return klass.find_by(id: identifier)&.billable? unless klass.respond_to?(:scoped_by_tenant?)

    ActsAsTenant.with_tenant(organisation) { klass.find_by(id: identifier)&.billable? }
  end

  def record_seat_transition
    @seat_role_billable = nil
    was = seat_counted_before_transaction?
    forget_seat_state_before_transaction
    became = seat_counted?
    return if became == was

    event = if became
              Subscriptions::Constants::SEAT_EVENT_ACTIVATED
            else
              Subscriptions::Constants::SEAT_EVENT_DEACTIVATED
            end

    write_seat_event(
      event: event,
      counted: became,
      account: organisation&.account,
      organisation_name: organisation&.name,
      role_id: role_id,
      billable: seat_role_billable?(role_id)
    )
  end

  def capture_seat_removal_snapshot
    @seat_role_billable = nil
    @seat_removal_snapshot = {
      # The loaded account, not its id, for the same reason SeatEvent.write_event
      # asks for it -- and captured HERE while the organisation still resolves,
      # exactly like organisation_name below.
      account: organisation&.account,
      organisation_name: organisation&.name,
      role_id: role_id,
      billable: seat_role_billable?(role_id)
    }
  end

  def record_seat_removal
    return if @seat_removal_snapshot.blank?

    write_seat_event(
      event: Subscriptions::Constants::SEAT_EVENT_REMOVED,
      # A removed membership never counts. The seat's last COUNTING state is
      # already in the preceding activated/deactivated event, so a
      # reconstruction never needs to interpret this row differently.
      counted: false,
      **@seat_removal_snapshot
    )
  end

  # An account or a name missing here is structurally impossible:
  # AccountAutoAssignable builds an Account in a before_validation on every
  # organisation create, and production is backfilled. What happens if it occurs
  # anyway -- log, drop the single event, do not raise -- is decided in
  # SeatEvent.write_event, because the role recorder needs the identical rule.
  def write_seat_event(account:, organisation_name:, role_id:, billable:, event:, counted:)
    SeatEvent.write_event(
      account: account,
      organisation_id: organisation_id,
      organisation_name: organisation_name,
      user_id: user_id,
      role_id: role_id,
      event: event,
      counted: counted,
      billable: billable,
      occurred_at: Time.current,
      source: "membership=#{id}"
    )
  end
end
