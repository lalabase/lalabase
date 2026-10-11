# frozen_string_literal: true

# One transition of one billable seat (T16, doc/billing_agentur_konto_plan.md
# §17.2). APPEND-ONLY: rows are inserted by SeatEventRecording and are never
# updated and never deleted. A wrong snapshot (T18) is repairable by recomputing
# it from these rows; a missing event is not repairable at all, which is why the
# hardening sits on the writer and not on any consumer.
#
# The organisation, user and role references are provenance, not association
# contracts: there are no foreign keys, and all three readers return nil once
# the referenced record is gone -- which is the entire reason this table exists.
# Read the organisation's name from `organisation_name`, never from
# `organisation&.name`.
#
# HOW TO RECONSTRUCT a seat count for a past date: filter to ONE account first,
# then per (organisation_id, user_id) take the newest event with
# occurred_at <= date, keep the ones where `counted` is true, then dedup the
# user_ids across the account -- that last step is D4.1 and the reason user_id is
# kept even after the user is deleted (§17.4).
#
# The account filter comes FIRST and is not a detail: after an organisation moves
# accounts, the same pair carries a `moved_out` in the old and a `moved_in` in the
# new account with the SAME occurred_at, so "the newest event for this pair" only
# has an answer once one account is picked. Use the `for_account` scope.
#
# A period BEFORE an account's `opening` event is not reconstructible at all, and
# an answer of zero would be a lie rather than a measurement. Consumers have to
# be able to say "not reconstructible" -- see doc/abrechnungsmodell_plan.md §3.
# == Schema Information
#
# Table name: seat_events
#
#  id                :uuid             not null, primary key
#  billable          :boolean          not null
#  counted           :boolean          not null
#  event             :string           not null
#  occurred_at       :datetime         not null
#  organisation_name :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  account_id        :uuid             not null
#  organisation_id   :uuid             not null
#  role_id           :uuid
#  user_id           :uuid             not null
#
# Indexes
#
#  idx_seat_events_account_occurred      (account_id,occurred_at)
#  idx_seat_events_membership_timeline   (organisation_id,user_id,occurred_at)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
class SeatEvent < ApplicationRecord
  # Billing lives ABOVE the tenants: no acts_as_tenant here, deliberately
  # (app/models/CLAUDE.md, trap 3). Adding one would silently filter every row
  # away instead of raising -- and this table is read by cross-account batch
  # jobs that have no current tenant at all.
  belongs_to :account

  # optional: true is not laxness -- a deleted organisation, a deleted role and
  # an anonymised user are the NORMAL end states of these rows.
  belongs_to :organisation, optional: true
  belongs_to :user, optional: true
  # CAUTION: Role IS tenant-scoped (role.rb:25) while this table is not. Reading
  # `seat_event.role` while a DIFFERENT organisation is the current tenant
  # returns nil, not the role -- the same trap 3 this file avoids for itself.
  # Cross-account readers must resolve it inside ActsAsTenant.with_tenant, or
  # read the frozen `billable` flag, which is what they usually want anyway.
  belongs_to :role, optional: true

  # APPEND-ONLY, enforced rather than asked for: a comment stating the rule while
  # the code allows the opposite is how a "never rewritten" table quietly starts
  # being rewritten. create! still works -- persisted? is false during the insert.
  def readonly?
    persisted?
  end

  before_destroy { throw :abort }

  validates :organisation_id, :organisation_name, :user_id, :occurred_at, presence: true
  validates :event, inclusion: { in: Subscriptions::Constants::SEAT_EVENTS }
  validates :billable, :counted, inclusion: { in: [true, false] }
  validate :counted_matches_event

  scope :chronological, -> { order(:occurred_at, :created_at) }
  # Named up_to, not until: `until` is a Ruby keyword and reads as a loop in a
  # scope chain. No consumer exists yet, so this is the cheap moment to name it.
  scope :up_to, ->(moment) { where(occurred_at: ..moment) }
  # The seat-bearing transitions. A `removed` or `moved_out` event never counts,
  # so this is not the same as "every event".
  scope :counting, -> { where(counted: true) }
  # Everything an account-scoped reconstruction may look at. The account filter
  # is NOT optional: after a move the same (organisation, user) pair carries a
  # moved_out in the old and a moved_in in the new account with the SAME
  # occurred_at, so "the newest event for this pair" is only well defined once
  # one account is picked. Without it, created_at order decides the answer.
  scope :for_account, ->(account) { where(account_id: account) }
  # The events INSIDE a measurement window (M2), exclusive at BOTH ends -- which
  # is why this is not `up_to` twice.
  #
  # The END is load-bearing. `to` is the NEXT month's boundary, and an event
  # sitting exactly on it already belongs to that month's snapshot (up_to is
  # inclusive, matching A7). Counting it here as well would let a September
  # activation raise an August peak, and therefore an August invoice.
  #
  # The START is exclusive to match the contract stated on
  # SeatSnapshot.boundary_moment, NOT because it changes any answer: the opening
  # state already reflects every event at that instant, and re-applying them
  # writes the same pairs back. Said plainly so that nobody builds a test on it
  # -- such a test would pass with `>` and with `>=` and prove nothing.
  scope :strictly_between, lambda { |from, to|
    where(arel_table[:occurred_at].gt(from)).where(arel_table[:occurred_at].lt(to))
  }

  # The reconstruction from the file header, in code, so that there is exactly ONE
  # of it. It already existed twice, as that comment and as a spec helper, and M0b
  # would have written the third by hand -- the point at which CLAUDE.md says to
  # stop and name the thing.
  #
  # Naive on purpose: it walks the account's entire history. Bounding that is what
  # the period snapshot (T18/M1) is for. Until then correctness beats speed, and
  # the accounts this runs against hold single-digit numbers of rows.
  #
  # Says nothing about whether the account is reconstructible AT ALL for that
  # moment: a period before the account's `opening` yields an empty list here, and
  # empty means "no seats recorded", not "no seats". That distinction belongs to
  # the caller (doc/abrechnungsmodell_plan.md §3) and is why this returns
  # events/ids rather than a count.
  #
  # Returns the EVENTS, one per occupied pair, because the snapshot writer (M1a)
  # needs the pairs and their frozen organisation_name, not only the count. The
  # id variant below derives from this one -- a second hand-written
  # reconstruction next to it would be exactly the duplication this method was
  # extracted to end.
  def self.counted_events_for(account:, at: Time.current)
    for_account(account).up_to(at).chronological
                        .index_by { |event| [event.organisation_id, event.user_id] }
                        .values.select(&:counted)
  end

  def self.counted_user_ids_for(account:, at: Time.current)
    counted_events_for(account: account, at: at).map(&:user_id).uniq
  end

  # From when on can this account be reconstructed at all? nil means "never yet",
  # and a caller has to say that rather than answer zero.
  #
  # Reads ONE marker, set by the opening backfill (SystemSetting
  # #seat_stream_opened_at). The earlier version derived the moment from the
  # `opening` rows instead, and that could not answer for an installation whose
  # recorder ran from day one: there the backfill correctly writes no row, so
  # there was nothing to derive from and the first account of a fresh install
  # stayed "not reconstructible" forever. An `opening` row is bound to a PAIR;
  # the question is about the SYSTEM. A pair-bound row can never answer it.
  #
  # The marker alone, NOT `[opened_at, account.created_at].max`. The earlier
  # version argued that an account born after the marker needs no opening of its
  # own -- true -- and then concluded the wrong thing from it. Taking the later
  # of the two declared every boundary BEFORE such an account's creation
  # unreadable, and the state at those boundaries is not unknown at all: the
  # account did not exist, so it held zero seats, and that is a measurement
  # rather than the lie §3 forbids.
  #
  # What that cost: the signup month of every new customer had no seat peak, and
  # that is the month of their FIRST invoice (review finding on #529, measured).
  # The account parameter stays in the signature -- the answer is per account by
  # nature, and the day an account carries its own opening moment this is where
  # it belongs.
  #
  # ⚠️ Known hole, unchanged by this: an organisation that had no account when
  # the backfill ran contributed no opening (SeatEvent.write_event skips and only
  # logs). Attach it to an account later and the reconstruction answers a
  # confident zero. It is the nightly drift check that catches that, not this
  # method -- see §9 of doc/abrechnungsmodell_plan.md.
  def self.reconstructible_from(_account, opened_at: SystemSetting.seat_stream_opened_at)
    opened_at
  end

  # The ONE write seam for this table.
  #
  # TWO recorders feed it: SeatEventRecording from membership callbacks, and
  # SeatRoleFlipRecording when a Role#billable flip moves every seat of a role at
  # once. Both need the same protection against a row nobody can attribute, and
  # writing that check a second time by hand is exactly the "same rule enforced
  # by hand" signal from CLAUDE.md. It lives here instead.
  #
  # Takes the LOADED account, not an id: belongs_to :account validates presence,
  # so an id makes that validation fetch the same account again for every single
  # row -- and a role flip writes one row per membership. Same reason
  # Subscriptions::SeatOpeningBackfill passes the object.
  #
  # Returns nil instead of raising when the row cannot be attributed. This runs
  # AFTER the commit: raising would fail a request whose membership or role
  # change already stuck, and it would not save the event either. The gap is
  # visible in the log; a 500 after a successful write would only confuse.
  def self.write_event(account:, organisation_id:, organisation_name:, user_id:, role_id:,
                       event:, counted:, billable:, occurred_at:, source:)
    if account.nil? || organisation_name.blank?
      Rails.logger.error(
        "SeatEvent skipped: #{source} organisation=#{organisation_id} " \
        "account=#{account&.id.inspect} -- organisation without account or name"
      )
      return nil
    end

    create!(account: account, organisation_id: organisation_id,
            organisation_name: organisation_name, user_id: user_id, role_id: role_id,
            event: event, counted: counted, billable: billable, occurred_at: occurred_at)
  end

  # True once the organisation this row came from no longer exists.
  def organisation_deleted?
    organisation_id.present? && organisation.nil?
  end

  private

  # Type and `counted` have to agree. A rule rather than a comment, because a row
  # where they disagree makes every reconstruction after it wrong, silently: a
  # stopping type claiming counted over-counts (invoice too high), a starting
  # type denying it under-counts (too low). `opening` has no expectation, it
  # records whatever the state was.
  def counted_matches_event
    expected = Subscriptions::Constants::SEAT_EVENT_COUNTED_EXPECTATION[event]
    return if expected.nil? || counted.nil? || counted == expected

    errors.add(:counted, expected ? :must_count_for_event : :cannot_count_for_event)
  end
end
