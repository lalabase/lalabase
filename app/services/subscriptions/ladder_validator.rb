# frozen_string_literal: true

# Checks the two invariants a seat ladder must satisfy as a WHOLE
# (doc/billing_preisliste_rabatt_plan.md §4): gapless and non-overlapping, per
# billing interval. Deliberately not model validations -- they hold for a price
# level, not for a row, and a ladder under construction could never satisfy them.
#
# Works on plain attribute hashes, not on PriceTier records, so it can run
# BEFORE anything is written: the publishing actor rejects a broken ladder
# instead of rolling one back.
#
# Entry point: errors_for
module Subscriptions
  class LadderValidator
    class << self
      # Returns an array of human-readable error keys with interpolation data,
      # empty when the ladder is sound. One entry per defect, so the operator
      # sees every problem at once instead of fixing them one deploy at a time.
      def errors_for(tier_attributes)
        missing_interval_errors(tier_attributes) +
          by_interval(tier_attributes).flat_map do |billing_interval, rungs|
            interval_errors(billing_interval, rungs)
          end
      end

      private

      # An interval that is not submitted at all produced NO error before,
      # because the check only ever iterated the groups that were present:
      # publishing a monthly-only ladder silently removed yearly billing, and
      # every "does a price apply" check kept saying yes.
      def missing_interval_errors(tier_attributes)
        submitted = tier_attributes.map { |attrs| attrs[:billing_interval].to_s }.uniq
        (Constants::BILLING_INTERVAL_KEYS - submitted).map do |billing_interval|
          error(:ladder_interval_missing, billing_interval)
        end
      end

      def by_interval(tier_attributes)
        tier_attributes.group_by { |attrs| attrs[:billing_interval].to_s }
      end

      def interval_errors(billing_interval, rungs)
        sorted = rungs.sort_by { |attrs| attrs[:min_seats].to_i }
        errors = []
        errors.concat(start_errors(billing_interval, sorted))
        errors.concat(continuity_errors(billing_interval, sorted))
        errors.concat(open_end_errors(billing_interval, sorted))
        errors.concat(amount_errors(billing_interval, sorted))
        errors
      end

      # Nothing else in the system ever looks at an amount: PriceTier allows 0,
      # the continuity check only reads seat numbers, and a ladder of zeros
      # satisfies every invariant. Skipping one of fourteen fields would have
      # given the product away, with no warning banner -- a price level applies,
      # after all.
      #
      # nil means the input was unreadable (Subscriptions::MoneyInput returns
      # nil, never 0, precisely so this stays distinguishable from a typed zero).
      def amount_errors(billing_interval, sorted)
        sorted.filter_map do |rung|
          # fetch, not []: an ABSENT key means "not offered" and defaults to 0
          # (seeds and specs omit the half they do not use), while an explicitly
          # nil value means the operator typed something unreadable. Only the
          # latter is an error in its own right.
          base = rung.fetch(:base_amount_cents, 0)
          per_seat = rung.fetch(:per_seat_amount_cents, 0)

          next error(:ladder_amount_unreadable, billing_interval, min_seats: rung[:min_seats]) if
            base.nil? || per_seat.nil?
          next if base.to_i.positive? || per_seat.to_i.positive?

          error(:ladder_amount_missing, billing_interval, min_seats: rung[:min_seats])
        end
      end

      # A ladder that starts at 2 leaves the single-seat account without a
      # price -- the defect only surfaces when such an account tries to pay.
      def start_errors(billing_interval, sorted)
        return [] if sorted.first[:min_seats].to_i == 1

        [error(:ladder_must_start_at_one, billing_interval,
               min_seats: sorted.first[:min_seats])]
      end

      # Each rung must begin exactly one seat above where the previous one
      # ended: a hole means an unpriceable seat count, an overlap means two
      # prices for the same one.
      def continuity_errors(billing_interval, sorted)
        sorted.each_cons(2).filter_map do |previous, current|
          next open_rung_error(billing_interval, previous) if previous[:max_seats].nil?

          expected = previous[:max_seats].to_i + 1
          next if current[:min_seats].to_i == expected

          error(:ladder_not_contiguous, billing_interval,
                expected: expected, actual: current[:min_seats])
        end
      end

      def open_rung_error(billing_interval, rung)
        error(:ladder_open_rung_not_last, billing_interval, min_seats: rung[:min_seats])
      end

      # Without an open last rung the ladder has an implicit ceiling, and the
      # first account to grow past it silently has no price at all.
      def open_end_errors(billing_interval, sorted)
        return [] if sorted.last[:max_seats].nil?

        [error(:ladder_must_end_open, billing_interval, max_seats: sorted.last[:max_seats])]
      end

      # Returns the RAW registry key. Translating it into a label is the
      # caller's job (PublishPriceList) -- this class produces data, not
      # sentences, and its specs assert on keys.
      def error(key, billing_interval, **details)
        { key: key, billing_interval: billing_interval, **details }
      end
    end
  end
end
