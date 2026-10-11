# frozen_string_literal: true

# Parses an operator-typed euro amount into cents
# (doc/billing_preisliste_rabatt_plan.md §6). Strict on purpose: anything it
# cannot read becomes nil, never 0.
#
# The naive `value.tr(',', '.').to_d` this replaces turned "1.234,50" into
# "1.234.50", where BigDecimal stops at the second separator -- 1234,50 EUR was
# published as 1,23 EUR, and the ladder passed every invariant on the way. The
# input is a free text field, so the German thousands dot is the obvious thing
# for an operator to type.
#
# nil (rather than 0) for unreadable input is what lets the caller tell "left
# blank" apart from "deliberately zero" -- a distinction the whole price path
# depends on.
#
# Entry point: cents
module Subscriptions
  class MoneyInput
    # Accepts: "29", "29,50", "29.50", "1.234,50", "1,234.50", " 29,50 € ".
    # Rejects: "", "abc", "29,5,0", "-5", "29,50 EUR" (only the € SIGN is
    # stripped, and only at the edges -- the three-letter code is not).
    # The integer part is either a bare 0 or starts with a non-zero digit:
    # without that, "0,005" parses as an English thousands group and yields 5.00
    # EUR -- a plausible typo for half a cent turning into five euros.
    GERMAN = /\A(?:0|[1-9]\d{0,2}(?:\.\d{3})*)(?:,\d{1,2})?\z/
    # The English form REQUIRES its decimal point. Without that requirement a
    # bare "2,999" fell into the thousands branch and published 2.999,00 EUR
    # where 2,99 was meant -- a factor of 1000, silently, and the ladder passed
    # every invariant afterwards. A comma group with no decimal point is
    # genuinely ambiguous in a German UI (three decimals, i.e. not a price, or
    # English thousands), so it is refused rather than guessed. "1.234" and
    # "1234" both stay typeable, and those are the two forms the error message
    # already names.
    ENGLISH = /\A(?:0|[1-9]\d{0,2}(?:,\d{3})*)\.\d{1,2}\z/
    PLAIN = /\A\d+(?:[.,]\d{1,2})?\z/

    class << self
      def cents(value)
        normalised = normalise(value)
        return nil if normalised.nil?

        (BigDecimal(normalised) * 100).round
      end

      private

      def normalise(value)
        # The currency sign is stripped only at the EDGES: deleting it globally
        # would turn the nonsense "29€50" into a confident 2950 EUR.
        cleaned = value.to_s.gsub(/\s+/, '').sub(/\A€/, '').sub(/€\z/, '')
        return nil if cleaned.empty?

        case cleaned
        # Order matters: the plain form is checked LAST, because "1.234" is a
        # valid thousands group in German and would otherwise be read as 1.234.
        when GERMAN then cleaned.delete('.').tr(',', '.')
        when ENGLISH then cleaned.delete(',')
        when PLAIN then cleaned.tr(',', '.')
        end
      end
    end
  end
end
