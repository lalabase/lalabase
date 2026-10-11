# frozen_string_literal: true

# Contract of the EffectiveDating concern
# (doc/billing_preisliste_rabatt_plan.md D4/§10).
#
# Deliberately run against BOTH including models, not just one: the no-overlap
# rule is parameterised per model via `effective_dating_scope`, and a forgotten
# or wrong scope declaration on the second model would be invisible in a suite
# that only exercises the first -- green tests while two discounts of the same
# account happily overlap.
#
# Host spec must provide:
#   `dated_record(attrs)`      -> builds an unsaved record in the SAME scope
#   `dated_record!(attrs)`     -> creates a persisted record in the same scope
#   `expected_scope_columns`   -> the columns effective_dating_scope was given
#
# Cross-scope isolation is NOT covered here: PriceList's only scope column is
# plan_key, and there is exactly one valid plan key today, so a second scope
# cannot be constructed without inventing one. AccountDiscount covers it in its
# own spec ("does not restrict a different account in the same period"), and the
# scope-declaration example above catches a wrong or forgotten scope for both.
RSpec.shared_examples 'an effectively dated record' do
  let(:monday) { Date.new(2026, 3, 2) }

  describe 'scope declaration' do
    # The direct guard against the failure mode above: this breaks immediately
    # if someone adds a model, includes the concern and forgets the scope, or
    # renames a scope column without touching the declaration.
    it 'declares the expected scope columns' do
      expect(described_class.effective_dating_scope_columns).to eq(expected_scope_columns)
    end
  end

  describe 'period validation' do
    it 'accepts an open end' do
      expect(dated_record(starts_on: monday, ends_on: nil)).to be_valid
    end

    it 'accepts ends_on on the same day as starts_on (a one-day window)' do
      expect(dated_record(starts_on: monday, ends_on: monday)).to be_valid
    end

    it 'rejects ends_on before starts_on' do
      record = dated_record(starts_on: monday, ends_on: monday - 1.day)

      expect(record).not_to be_valid
      expect(record.errors[:ends_on]).to be_present
    end

    it 'requires starts_on' do
      expect(dated_record(starts_on: nil)).not_to be_valid
    end
  end

  describe 'no-overlap rule' do
    before { dated_record!(starts_on: monday, ends_on: monday + 30.days) }

    it 'rejects an identical period' do
      expect(dated_record(starts_on: monday, ends_on: monday + 30.days)).not_to be_valid
    end

    it 'rejects a period overlapping by a single day' do
      # Starts on the existing record's LAST day -- ends_on is inclusive, so
      # this is an overlap, not a handover.
      expect(dated_record(starts_on: monday + 30.days, ends_on: monday + 60.days)).not_to be_valid
    end

    it 'rejects a period fully contained in the existing one' do
      expect(dated_record(starts_on: monday + 5.days, ends_on: monday + 10.days)).not_to be_valid
    end

    it 'rejects a period enclosing the existing one' do
      expect(dated_record(starts_on: monday - 5.days, ends_on: monday + 60.days)).not_to be_valid
    end

    it 'accepts a directly adjacent successor' do
      # The normal succession: predecessor ends the day before the successor
      # starts. If this ever fails, no price can ever be replaced.
      expect(dated_record(starts_on: monday + 31.days, ends_on: nil)).to be_valid
    end

    it 'accepts a directly adjacent predecessor' do
      expect(dated_record(starts_on: monday - 10.days, ends_on: monday - 1.day)).to be_valid
    end

    it 'rejects any later period once an open-ended one exists' do
      dated_record!(starts_on: monday + 31.days, ends_on: nil)

      expect(dated_record(starts_on: monday + 365.days, ends_on: nil)).not_to be_valid
    end

    it 'does not flag a record against itself on update' do
      # Without the `where.not(id:)` exclusion every saved record would collide
      # with its own stored row and become permanently unsavable.
      record = dated_record!(starts_on: monday + 31.days, ends_on: monday + 60.days)

      expect(record.update(ends_on: monday + 90.days)).to be(true)
    end
  end

  describe '#effective_on? and .effective_on' do
    let!(:record) { dated_record!(starts_on: monday, ends_on: monday + 30.days) }

    it 'includes the first day' do
      expect(record.effective_on?(monday)).to be(true)
      expect(described_class.effective_on(monday)).to include(record)
    end

    it 'includes the last day (ends_on is inclusive)' do
      expect(record.effective_on?(monday + 30.days)).to be(true)
      expect(described_class.effective_on(monday + 30.days)).to include(record)
    end

    it 'excludes the day before it starts' do
      expect(record.effective_on?(monday - 1.day)).to be(false)
      expect(described_class.effective_on(monday - 1.day)).not_to include(record)
    end

    it 'excludes the day after it ends' do
      expect(record.effective_on?(monday + 31.days)).to be(false)
      expect(described_class.effective_on(monday + 31.days)).not_to include(record)
    end

    it 'stays effective indefinitely with an open end' do
      open_record = dated_record!(starts_on: monday + 31.days, ends_on: nil)

      expect(open_record.effective_on?(monday + 10.years)).to be(true)
      expect(described_class.effective_on(monday + 10.years)).to include(open_record)
    end
  end

  describe 'missing scope configuration' do
    # ensure, not a bare sequence: without it a failing example inside would
    # leave the class attribute nil for every LATER example in the process, and
    # the resulting cascade would point everywhere except here.
    around do |example|
      original = described_class.effective_dating_scope_columns
      described_class.effective_dating_scope_columns = nil
      begin
        example.run
      ensure
        described_class.effective_dating_scope_columns = original
      end
    end

    # Without this guard an unconfigured model would silently get a TABLE-WIDE
    # no-overlap rule -- wrong for every caller, and invisible until two
    # unrelated rows collide in production.
    it 'fails loudly instead of applying a table-wide rule' do
      expect { dated_record(starts_on: monday).valid? }
        .to raise_error(EffectiveDating::ScopeNotConfiguredError)
    end
  end
end
