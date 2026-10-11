# frozen_string_literal: true

# The seat state of ONE account at ONE measurement-month boundary (M1a,
# doc/abrechnungsmodell_plan.md §4 step 1; T18 in
# doc/billing_agentur_konto_plan.md §17.3): who occupied a counted seat when the
# month began. The peak evaluation (M2) replays a month from here instead of
# walking the account's entire history every time.
#
# DERIVED AND RECOMPUTABLE -- deliberately the OPPOSITE of AiUsageRollup's
# write-once rule, and neither table may be "fixed" to match the other. A
# rollup's source (ai_usages) gets deleted, so a second aggregation would write
# a poorer value over a settled period; ON CONFLICT DO NOTHING is its only safe
# write. seat_events by contrast is append-only and never deleted, so this row
# is reproducible from the same source at any time -- and §9 of the plan DEPENDS
# on that: a missing event is repaired by a backdated create!, after which the
# affected snapshots MUST be recomputed. The writer
# (Subscriptions::SeatSnapshotWriter) therefore overwrites on rerun; a
# write-once rule here would make that repair impossible.
#
# `pairs` carries the occupied (organisation, user) pairs, not just a number.
# Two reasons, both from the plan: replaying a month on a count alone is the
# plus/minus counter §4 forbids (removing user A from organisation 1 frees no
# seat while A still sits in organisation 2 of the same account), and the frozen
# organisation_name keeps the row readable after the organisation is deleted --
# which §5 needs and which is the normal end state of these references.
# `seat_count` is redundant on purpose (the distinct users across the pairs,
# D4.1), and the redundancy is ENFORCED by validation rather than hoped for.
#
# A missing row is NOT a fourth status: it is a gap, and finding gaps is the
# M1b watcher's job. The three statuses live in Subscriptions::Constants.
# == Schema Information
#
# Table name: seat_snapshots
#
#  id           :uuid             not null, primary key
#  computed_at  :datetime         not null
#  error        :string
#  pairs        :jsonb            default([]), not null
#  period_start :date             not null
#  seat_count   :integer
#  status       :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  account_id   :uuid             not null
#
# Indexes
#
#  idx_seat_snapshots_unique_period      (account_id,period_start) UNIQUE
#  index_seat_snapshots_on_period_start  (period_start)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
class SeatSnapshot < ApplicationRecord
  # Billing lives ABOVE the tenants: no acts_as_tenant here, deliberately
  # (app/models/CLAUDE.md, trap 3). Adding one would silently filter every row
  # away in batch runs that have no current tenant, instead of raising.
  belongs_to :account

  # What every pairs entry must carry. organisation_name is not decoration: an
  # entry without it becomes an unlabelled UUID the moment the organisation is
  # deleted, and answering "which organisations were involved" (§5) is the
  # reason the name is frozen in at all.
  PAIR_KEYS = %w[organisation_id organisation_name user_id].freeze

  scope :for_period, ->(period_start) { where(period_start: period_start) }
  scope :chronological, -> { order(:period_start) }

  # An ANSWER, in the sense the M1b gap watcher needs: the boundary was asked
  # and something came back. "Cannot be known" (not_reconstructible) IS an
  # answer and must never be re-asked, or the sweep would rewrite the same rows
  # forever. A crashed attempt (failed) is NOT an answer, so the next run retries
  # it -- which is how a transient error heals itself instead of sitting in the
  # table as a permanent hole.
  #
  # Named after that meaning rather than after the two statuses it happens to
  # list today: a fourth status would have to decide which side it falls on, and
  # a name like `ok_or_not_reconstructible` would hide that decision. The list
  # itself lives in Constants, because #answered? below has to answer the same
  # question about a single loaded row.
  scope :answered, lambda {
    where(status: Subscriptions::Constants::SEAT_SNAPSHOT_ANSWERED_STATUSES)
  }

  validates :period_start, :computed_at, presence: true
  validates :status, inclusion: { in: Subscriptions::Constants::SEAT_SNAPSHOT_STATUSES }
  validate :period_start_is_month_start
  validate :contents_match_status

  class << self
    # THE one conversion from a period_start date to the instant it describes
    # (A6): midnight Europe/Berlin, while occurred_at and the app itself run on
    # UTC. Every consumer -- the writer now, the M2 replay later -- goes through
    # here; a second hand-written conversion is how one caller silently measures
    # a UTC month. The snapshot for 2026-09-01 describes 2026-08-31 22:00 UTC.
    # Subscriptions::SeatPeak forms BOTH ends of its window with it, so a month
    # can never be half German and half UTC.
    #
    # The state AT this instant INCLUDES events whose occurred_at equals it
    # exactly (SeatEvent.up_to is inclusive, matching A7: apply every event of
    # one timestamp, then measure). A replay starting from this snapshot must
    # therefore begin STRICTLY after the boundary.
    def boundary_moment(period_start)
      period_start.in_time_zone(Subscriptions::Constants::BILLING_TIME_ZONE)
    end

    # A period_start out of operator input, or nil when the input is not one.
    # THE one parser: the admin page and the seat_peaks:* tasks both take a month
    # from a human, and the year bound below had to be written twice by hand
    # before it lived here.
    #
    # Two traps, both measured rather than imagined:
    #
    #   Date.parse   reads "Augustsonstwas" and "letzter Monat" as 2026-08-01
    #                without complaining, so a typo produces a confident answer
    #                about a month nobody asked for.
    #   Date.iso8601 accepts "-9999-01-01" -- a valid Ruby Date, year 10000 BC,
    #                outside the range PostgreSQL can store. The next query dies
    #                with PG::DatetimeFieldOverflow, which is a 500 on a page
    #                whose whole point is to answer instead of crashing (review
    #                finding on #529).
    #
    # Hence the shape check first: exactly four digits, no sign, no shorthand.
    # That is also precisely what the tasks print as their usage line.
    PERIOD_INPUT = /\A\d{4}-\d{2}-\d{2}\z/

    def parse_period(raw)
      text = raw.to_s.strip
      return nil unless PERIOD_INPUT.match?(text)

      normalise_period(Date.iso8601(text))
    rescue Date::Error
      nil
    end

    # A Date, Time or TimeWithZone to the first day of the month it lies in.
    #
    # A Time is converted to Europe/Berlin FIRST. The app runs on UTC, so
    # `Time.current.to_date` between 00:00 and 02:00 Berlin time on the first of
    # a month still answers the PREVIOUS month -- the exact two-hour trap that
    # current_period below exists to avoid, and it would have come back through
    # any caller passing a Time.
    def normalise_period(value)
      value = value.in_time_zone(Subscriptions::Constants::BILLING_TIME_ZONE) if value.respond_to?(:hour)
      value.to_date.beginning_of_month
    end

    # Which measurement month are we in? In Europe/Berlin, so that during the
    # two hours after local midnight on the 1st this answers the new month and
    # not the old one (A6). Here rather than in a caller because both the admin
    # page and the boundary sweep need it, and two hand-written copies would
    # disagree exactly during those two hours a month.
    def current_period
      normalise_period(Time.current)
    end

    # The one definition of how seat_count derives from pairs (D4.1): distinct
    # users, because the same user in two organisations of this account occupies
    # ONE seat. The writer computes with it and the validation recomputes with
    # it -- two hand-written copies would be exactly the drift the validation
    # exists to catch.
    def distinct_user_count(pairs)
      pairs.map { |pair| pair.stringify_keys['user_id'] }.uniq.size
    end

    # THE one way to turn a SeatEvent into a pairs entry. Two callers build this
    # shape -- the writer when it lays down a boundary, and the M2 replay on
    # every counting event -- and PAIR_KEYS above validates it, so a second
    # hand-written literal would be a third copy of the same three keys.
    #
    # organisation_name comes from the event's FROZEN copy, never from
    # event.organisation&.name: the organisation being gone is the normal end
    # state of these rows and the whole reason the name is carried at all.
    def pair_from(event)
      { 'organisation_id' => event.organisation_id,
        'organisation_name' => event.organisation_name,
        'user_id' => event.user_id }
    end
  end

  def ok?
    status == Subscriptions::Constants::SEAT_SNAPSHOT_STATUS_OK
  end

  def not_reconstructible?
    status == Subscriptions::Constants::SEAT_SNAPSHOT_STATUS_NOT_RECONSTRUCTIBLE
  end

  def failed?
    status == Subscriptions::Constants::SEAT_SNAPSHOT_STATUS_FAILED
  end

  # The row-level twin of the `answered` scope, reading the same list. The
  # writer needs it to refuse DOWNGRADING an answered row to `failed`: under a
  # concurrent run the unique index turns the loser's insert into an exception,
  # and without this guard the loser's rescue would find the winner's measured
  # row and overwrite it with a failure.
  def answered?
    Subscriptions::Constants::SEAT_SNAPSHOT_ANSWERED_STATUSES.include?(status)
  end

  private

  # A period_start off the month's first day would silently start a SECOND grid
  # of boundaries next to the real one -- the unique index could not see the
  # collision, and the M1b gap check would report gaps that are misfiled rows.
  def period_start_is_month_start
    return if period_start.nil? || period_start == period_start.beginning_of_month

    errors.add(:period_start, :must_be_month_start)
  end

  # The three statuses promise different contents, and a row where they disagree
  # poisons every consumer silently: an ok row whose seat_count contradicts its
  # pairs makes either the invoice or the support answer wrong, and a
  # not_reconstructible row carrying a 0 is exactly the lie §3 forbids. A rule
  # rather than a comment, and it is the reason the writer saves through
  # validations instead of upserting past them.
  def contents_match_status
    case status
    when Subscriptions::Constants::SEAT_SNAPSHOT_STATUS_OK
      validate_measured_contents
    when Subscriptions::Constants::SEAT_SNAPSHOT_STATUS_NOT_RECONSTRUCTIBLE,
         Subscriptions::Constants::SEAT_SNAPSHOT_STATUS_FAILED
      validate_unmeasured_contents
    end
  end

  def validate_measured_contents
    errors.add(:error, :only_on_failed) if error.present?

    entries = well_formed_pairs
    return errors.add(:pairs, :malformed_entry) if entries.nil?

    if seat_count.nil?
      errors.add(:seat_count, :required_when_ok)
    elsif seat_count != self.class.distinct_user_count(entries)
      errors.add(:seat_count, :must_match_pairs)
    end
  end

  def validate_unmeasured_contents
    errors.add(:seat_count, :forbidden_without_measurement) unless seat_count.nil?
    errors.add(:pairs, :must_be_empty_without_measurement) if pairs.present?

    if failed?
      errors.add(:error, :required_on_failed) if error.blank?
    elsif error.present?
      errors.add(:error, :only_on_failed)
    end
  end

  # nil when pairs is not an array of hashes each carrying the three keys.
  # Stringified before checking, because in-memory rows may carry symbol keys
  # while a reloaded JSONB column always answers with strings.
  def well_formed_pairs
    return nil unless pairs.is_a?(Array)

    entries = pairs.map { |entry| entry.is_a?(Hash) ? entry.stringify_keys : nil }
    return nil if entries.any?(&:nil?)
    return nil unless entries.all? { |entry| PAIR_KEYS.all? { |key| entry[key].present? } }

    entries
  end
end
