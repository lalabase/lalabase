# frozen_string_literal: true

require 'rails_helper'

# The ONE owner of "is this a date bound I can hand to the database" (S3c T3).
#
# The rule has two halves and the second one is the expensive half to get wrong:
# `Date.strptime` reads "999999999-01-01" as a perfectly good year, and the query
# after it dies with PG::DatetimeFieldOverflow -- a 500 out of a typeable
# parameter. So the examples below do not stop at `be_nil`: the accepted window is
# handed to PostgreSQL for real, because a green vacuum is exactly how this class
# of bug got shipped once already.
RSpec.describe TimeSessions::DateBound do
  describe '.call' do
    it 'normalises a well-formed bound' do
      expect(described_class.call(value: '  2026-05-01 ')).to eq('2026-05-01')
    end

    it 'answers nil for an absent bound' do
      expect(described_class.call(value: nil)).to be_nil
      expect(described_class.call(value: '')).to be_nil
      expect(described_class.call(value: '   ')).to be_nil
    end

    # The FORM half: everything a human or a model might type that is not the
    # four-digit ISO shape.
    ['31.08.2026', '05/01/2026', 'letzter Monat', '2026-5-1', '2026-05-01T10:00',
     '2026-05-01 ODER 1=1'].each do |raw|
      it "refuses #{raw.inspect} on its form" do
        expect(described_class.call(value: raw)).to be_nil
      end
    end

    # The CALENDAR half: right shape, impossible day.
    %w[2026-13-01 2026-02-30 2026-00-10].each do |raw|
      it "refuses #{raw.inspect} on the calendar" do
        expect(described_class.call(value: raw)).to be_nil
      end
    end

    # ⚠️ The half the panel lost when the rule was copied by hand. Each of these
    # IS a valid Ruby Date and none of them is a value PostgreSQL can hold.
    ['99999-01-01', '999999999-01-01', '-9999-01-01', '-4713-01-01'].each do |raw|
      it "refuses #{raw.inspect}, a Ruby date PostgreSQL cannot store" do
        expect(Date.strptime(raw, '%Y-%m-%d')).to be_a(Date), 'precondition: strptime alone accepts it'
        expect(described_class.call(value: raw)).to be_nil
      end
    end

    # Boundary of the accepted window, n-1 / n on both ends: five digits and a
    # sign are out, four digits are in, all the way to the edges of the format.
    it 'accepts the four-digit edges and refuses one digit more' do
      expect(described_class.call(value: '0001-01-01')).to eq('0001-01-01')
      expect(described_class.call(value: '9999-12-31')).to eq('9999-12-31')
      expect(described_class.call(value: '10000-01-01')).to be_nil
      expect(described_class.call(value: '00001-01-01')).to be_nil
    end

    # Not a vacuum. The point of the form check is what the DATABASE does with the
    # result, so these two take the road the callers take: bound -> Time.zone.parse
    # -> a real query. A spec that stopped at `be_nil` is how this class of bug got
    # shipped once already.
    describe 'against the database itself' do
      let(:organisation) { create(:organisation) }

      before { ActsAsTenant.current_tenant = organisation }
      after { ActsAsTenant.current_tenant = nil }

      # One example per bound rather than a loop: three identical COUNTs in one
      # example look like an N+1 to Prosopite, and a suppressed Prosopite is a
      # worse trade than three examples.
      %w[0001-01-01 2026-05-01 9999-12-31].each do |raw|
        it "hands #{raw} to PostgreSQL without an overflow" do
          bound = described_class.call(value: raw)

          expect { TimeSession.where('occurred_on >= ?', Time.zone.parse(bound)).count }
            .not_to raise_error
        end
      end

      # The mutation probe for the example above: take the form check away and the
      # very same road really does blow up, so the guard is not decoration.
      it 'is guarding a real failure, not a hypothetical one' do
        expect { TimeSession.where('occurred_on >= ?', Time.zone.parse('999999999-01-01')).count }
          .to raise_error(ActiveRecord::StatementInvalid, /out of range/)
      end
    end
  end

  describe '.valid?' do
    it 'agrees with .call on both answers' do
      expect(described_class.valid?(value: '2026-05-01')).to be(true)
      expect(described_class.valid?(value: '999999999-01-01')).to be(false)
      expect(described_class.valid?(value: nil)).to be(false)
    end
  end
end
